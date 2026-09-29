"""Standing permissions ("grants"): the user said Daisy can do a kind of step without asking, so for this
request, or from now on, those steps run without a card.

What a grant can cover, and nothing else:
- typed tools with risk write, own or ui, by name. A ui grant names the one app it's for, and a click on
  a send, delete or share button, Return, shortcuts, typing a line break, and anything in a terminal
  still get their card.
- running script files the user named (a file, or the files directly in one folder), exactly as they
  were when the grant was given. A script that changed, a helper next to it that changed, or a new
  script in that folder asks again.
- MCP tools whose name says they edit (update_page, add_row), by exact name.
Sends, shares, deletes, installs, settings, memory and skill writes, new sites after reading, and
everything the guard blocks keep their card or their block. So does a call that emails, invites or
notifies people, or touches something shared.

Where: only in a chat session of a Daisy process, and only where someone could have answered the card
(the guard checks that first). Never a background job, a cron run, yolo or a one-shot run.

How long: "request" covers one Hermes session (the ACP session id, which Hermes passes as task_id and
keeps through compression) and one turn (turn_id, new with every user message), 3 hours at most.
"forever" covers every chat session until the user turns it off in Setup.

Files in $HERMES_HOME/daisy/, which the guard never lets the assistant write, all 0600:
- grants.json: {"version": 1, "grants": [...]}, written here and by the Daisy app, each change under an
  flock on .grants.lock and through a temp file and a rename. Broken or missing means no grants.
- grants.jsonl: one line per call that ran under a grant, for the app's transcript. Capped.
- grant-offers.json: grantable cards from the last few minutes, keyed by a hash of the card's text, so
  the app offers "Yes to all like this" on exactly those.

approval_grant (tools/grants.py) asks for one. The guard cards it and holds the grant it describes as
pending; the tool's run(), which Hermes only calls once that card was approved, turns on exactly that
one. A denied or unanswered card leaves nothing."""

from __future__ import annotations

import fcntl
import hashlib
import json
import logging
import os
import re
import stat
import threading
import time
import uuid
from collections import OrderedDict
from contextlib import contextmanager, suppress
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterator, List, Optional, Tuple

from .. import registry
from . import roles, shell, targets
from .classify import (BROWSER_SERVERS, CALENDAR_WORDS, DELETE_WORDS, SAFE_KEYS, SEND_WORDS, SHARE_WORDS, _mcp_parts,
                       words)
from .verdict import Verdict

log = logging.getLogger("daisy.guard")

TOOL = "approval_grant"
VERSION = 1
GRANTABLE_RISKS = ("write", "own", "ui")
REQUEST_SECONDS = 3 * 3600
PENDING_SECONDS = 300.0
OFFER_SECONDS = 600.0
MAX_OFFERS = 32
MAX_TOOLS = 12
MAX_LOG_BYTES = 256 * 1024
KEEP_LOG_LINES = 500
MAX_PINNED = 100
MAX_PIN_BYTES = 1024 * 1024
LOCK_WAIT = 2.0

# Arguments that reach other people: calendar guests and their emails, notes in a shared folder.
PEOPLE = ("notify", "notify_guests", "guests", "attendees", "invitees", "shared")
# Programs that run a script file named as their first argument.
INTERPRETERS = re.compile(r"python[0-9.]*|bash|sh|zsh|node|ruby|perl")
CODE_SUFFIXES = (".py", ".sh", ".bash", ".zsh", ".command", ".js", ".mjs", ".cjs", ".ts", ".rb", ".pl")
TERMINALS = ("terminal", "iterm", "warp", "ghostty", "kitty", "alacritty", "wezterm", "hyper")
# Words on a ui card that mean it may do more than an edit: a send, delete or share button, a permission,
# sign-in or payment prompt, quitting, or an element with no label to go by.
UI_STOPS = (SEND_WORDS | DELETE_WORDS | SHARE_WORDS |
            {"allow", "confirm", "ok", "sign", "signin", "login", "logout", "password", "passcode", "authorize",
             "trust", "install", "quit", "order", "checkout", "unlabeled"})
# MCP tools a grant can name: an edit word in the name and nothing that sends, deletes, shares, runs code
# or answers for the user.
MCP_EDITS = {"create", "insert", "update", "patch", "modify", "edit", "set", "add", "write", "append", "put",
             "rename", "move", "copy", "label", "mark", "star", "archive", "save", "store", "change", "draft",
             "upsert", "format", "replace"}
MCP_NOT_EDITS = (SEND_WORDS | DELETE_WORDS | SHARE_WORDS |
                 {"install", "run", "execute", "exec", "call", "invoke", "trigger", "approve", "accept", "decline",
                  "reject", "merge", "close", "assign", "enable", "disable", "cancel", "schedule", "start", "stop",
                  "restart", "lock", "unlock", "import", "sync", "restore", "reset", "eval", "evaluate", "script",
                  "transfer", "grant"})

# What the card and Setup call each tool. Anything else is "Use <name>".
LABELS = {
    "docs_write": "Add to Google Docs",
    "sheets_write": "Change Google Sheets",
    "calendar_write": "Add and change calendar events",
    "gmail_modify": "Archive, label and mark emails",
    "drive_upload": "Upload files to Google Drive (they stay private)",
    "notes_create": "Create notes",
    "notes_append": "Add to notes",
    "reminders_add": "Add reminders",
    "reminders_complete": "Check off reminders",
    "contacts_alias_save": "Save nicknames for contacts",
    "computer_act": "Click and type in {app}",
}

STILL_ASKS = ("Still asks every time: sending, sharing or deleting anything; anything that emails, invites or "
              "notifies people or changes something shared; and everything not listed above.")
UNTIL = {"request": "Until this request is done (3 hours at most). The next thing you ask starts fresh.",
         "forever": "From now on, in every conversation, until you turn it off in Setup under Standing permissions."}
NO_TURN = ("Blocked by Daisy's guard: this request has no turn id, so a grant for it would have no end. Ask the "
           "user each time instead.")


def folder() -> Path:
    return targets.hermes_home() / "daisy"


def grants_file() -> Path:
    return folder() / "grants.json"


def log_file() -> Path:
    return folder() / "grants.jsonl"


def offers_file() -> Path:
    return folder() / "grant-offers.json"


def lock_file() -> Path:
    return folder() / ".grants.lock"


# Files

@contextmanager
def _locked() -> Iterator[None]:
    """The lock the app takes too, around every read-change-write of grants.json and the offers."""
    folder().mkdir(mode=0o700, parents=True, exist_ok=True)
    handle = os.open(lock_file(), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        deadline = time.monotonic() + LOCK_WAIT
        while True:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() > deadline:
                    raise TimeoutError("the grants file is busy")
                time.sleep(0.02)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)
    finally:
        os.close(handle)


def _read(path: Path) -> Dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _write(path: Path, data: Any) -> None:
    """The whole file through a temp file in the same folder and a rename, 0600."""
    temporary = path.parent / f".{path.name}.{uuid.uuid4().hex}.tmp"
    handle = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as out:
            json.dump(data, out, ensure_ascii=False, sort_keys=True, indent=1)
            out.flush()
            os.fsync(out.fileno())
        os.replace(temporary, path)
    except BaseException:
        with suppress(OSError):
            os.unlink(temporary)
        raise


def _listed(data: Dict[str, Any], key: str) -> List[Dict[str, Any]]:
    items = data.get(key)
    return [item for item in items if isinstance(item, dict)] if isinstance(items, list) else []


class _Cache:
    """grants.json, read again only when it changes."""

    def __init__(self):
        self.lock = threading.Lock()
        self.stamp: Any = None
        self.grants: List[Dict[str, Any]] = []

    def load(self) -> List[Dict[str, Any]]:
        path = grants_file()
        try:
            info = path.stat()
            stamp = (str(path), info.st_mtime_ns, info.st_size, info.st_ino)
        except OSError:
            return []
        with self.lock:
            if stamp == self.stamp:
                return self.grants
        grants = _listed(_read(path), "grants")
        with self.lock:
            self.stamp, self.grants = stamp, grants
        return grants


_cache = _Cache()


def load() -> List[Dict[str, Any]]:
    """Every grant in grants.json, live or not."""
    return _cache.load()


def _live(grant: Dict[str, Any], session: str, turn: str, now: float) -> bool:
    duration = grant.get("duration")
    if duration == "forever":
        return True
    if duration != "request":
        return False
    return (bool(session) and bool(turn) and grant.get("session") == session and grant.get("turn") == turn
            and _number(grant.get("expires")) > now)


def _number(value: Any) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def _prune(grants: List[Dict[str, Any]], now: float) -> List[Dict[str, Any]]:
    """Drops request grants past their backstop."""
    return [grant for grant in grants if grant.get("duration") == "forever"
            or (grant.get("duration") == "request" and _number(grant.get("expires")) > now)]


def add(grant: Dict[str, Any]) -> Dict[str, Any]:
    with _locked():
        now = time.time()
        data = _read(grants_file())
        grants = _prune(_listed(data, "grants"), now)
        grants.append(grant)
        _write(grants_file(), {"version": VERSION, "grants": grants})
    return grant


def revoke(grant_id: str) -> bool:
    """Takes one grant out. The app does the same from Setup."""
    with _locked():
        grants = _listed(_read(grants_file()), "grants")
        kept = [grant for grant in grants if grant.get("id") != grant_id]
        if len(kept) == len(grants):
            return False
        _write(grants_file(), {"version": VERSION, "grants": kept})
    return True


# What a call would need a grant for

@dataclass(frozen=True)
class Call:
    """The part of a carded call a grant is matched against."""
    tool: str
    app: str = ""       # ui tools: the app, lower case
    script: str = ""    # scripts: the script's real path


def call_scope(tool_name: str, args: Dict[str, Any], verdict: Verdict) -> Optional[Call]:
    """What a grant would have to cover for this carded call to run, or None when no grant can."""
    if tool_name == TOOL or verdict.decision != "card" or verdict.hard:
        return None
    tool = registry.get(tool_name)
    if tool is not None:
        if tool.risk not in GRANTABLE_RISKS or verdict.rule != tool.name or _reaches_people(args):
            return None
        if tool.risk == "ui":
            app = _app(args)
            return Call(tool.name, app=app) if app and _plain_ui(args, verdict, app) else None
        return Call(tool.name)
    if tool_name == "terminal" and verdict.rule == "run":
        script = _script(args, verdict)
        return Call(tool_name, script=script) if script else None
    if tool_name.startswith("mcp_") and verdict.rule == "write" and mcp_edit(tool_name):
        return Call(tool_name)
    return None


def covers(grant: Dict[str, Any], call: Call) -> bool:
    if call.script:
        return _script_pinned(grant, call.script)
    tools = grant.get("tools")
    if not isinstance(tools, list) or call.tool not in tools or call.tool == TOOL:
        return False
    if call.app:
        return _app_name(grant.get("app")) == call.app
    return True


def covering(role: str, session: str, turn: str, tool_name: str, args: Dict[str, Any],
             verdict: Verdict) -> Optional[Dict[str, Any]]:
    """The live grant that covers this carded call, or None. Only chat sessions in a Daisy process use
    grants."""
    if role != "chat" or not roles.DAISY_PROCESS:
        return None
    call = call_scope(tool_name, args, verdict)
    if call is None:
        return None
    now = time.time()
    for grant in load():
        if _live(grant, session, turn, now) and covers(grant, call):
            return grant
    return None


def _reaches_people(args: Dict[str, Any]) -> bool:
    return any(args.get(key) not in (None, False, "", [], {}) for key in PEOPLE)


def _app_name(value: Any) -> str:
    return " ".join(str(value or "").split()).lower()


def _app(args: Dict[str, Any]) -> str:
    return _app_name(args.get("app"))


def _plain_ui(args: Dict[str, Any], verdict: Verdict, app: str) -> bool:
    """A click, scroll or plain typing that's only an edit. Anything that could send, delete, share,
    answer a prompt or run a command keeps its card."""
    if any(name in app for name in TERMINALS) or "daisy" in app or args.get("modifiers"):
        return False
    if any(key in args for key in ("coordinate", "from_coordinate", "to_coordinate")):
        return False  # a spot on screen has no label to check, so it could be any button
    action = str(args.get("action") or "").strip().lower()
    if action == "key":
        return str(args.get("keys") or "").strip().lower().replace(" ", "") in SAFE_KEYS
    text = args.get("text") if action == "type" else args.get("value") if action == "set_value" else None
    title = verdict.title or ""
    if isinstance(text, str):
        if "\n" in text or "\r" in text:
            return False
        if text:
            title = title.replace(text, " ")
    return not set(words(title)) & UI_STOPS


def mcp_edit(name: str) -> bool:
    server, tool = _mcp_parts(name)
    found, place = set(tool), set(server)
    return (bool(found & MCP_EDITS) and not found & MCP_NOT_EDITS and not place & BROWSER_SERVERS
            and not (found | place) & CALENDAR_WORDS)


# Scripts

def _sha256(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for block in iter(lambda: source.read(65536), b""):
            digest.update(block)
    return digest.hexdigest()


def _code_file(entry: os.DirEntry) -> bool:
    try:
        info = entry.stat(follow_symlinks=True)
    except OSError:
        return False
    return stat.S_ISREG(info.st_mode) and (entry.name.lower().endswith(CODE_SUFFIXES) or bool(info.st_mode & 0o111))


def snapshot(place: str) -> Dict[str, str]:
    """Hashes of the script files directly in a folder: its code files and anything executable."""
    pins: Dict[str, str] = {}
    with os.scandir(place) as entries:
        for entry in sorted(entries, key=lambda item: item.name):
            if not _code_file(entry):
                continue
            real = os.path.realpath(entry.path)
            if os.path.dirname(real) != place:
                continue  # a link to somewhere else isn't this folder's script
            if os.path.getsize(real) > MAX_PIN_BYTES:
                raise registry.Refused(f"{short_path(real)} is over 1 MB, which is too big to be a script Daisy "
                                       "can hold to how it is now.")
            pins[real] = _sha256(real)
            if len(pins) > MAX_PINNED:
                raise registry.Refused(f"{short_path(place)} has more than {MAX_PINNED} scripts. Name the script "
                                       "or a smaller folder.")
    return pins


def _script_pinned(grant: Dict[str, Any], script: str) -> bool:
    """The script is one the grant covers, it and every script next to it are as they were when the
    grant was given, and nothing new that could run appeared beside it."""
    pins = grant.get("pins") if isinstance(grant.get("pins"), dict) else {}
    runnable = grant.get("scripts") if isinstance(grant.get("scripts"), list) else []
    place = os.path.dirname(script)
    if script not in pins or not (script in runnable or place in runnable):
        return False
    try:
        for path, digest in pins.items():
            if os.path.dirname(path) == place and os.path.exists(path) and _sha256(path) != digest:
                return False
        if _sha256(script) != pins[script]:
            return False
        with os.scandir(place) as entries:
            for entry in entries:
                if _code_file(entry) and os.path.realpath(entry.path) not in pins:
                    return False
    except OSError:
        return False
    return True


def _script(args: Dict[str, Any], verdict: Verdict) -> str:
    """The real path of the script file a terminal call runs, when it's exactly one script run
    (`python3 fix.py`, `./tidy.sh`, `bash ~/bin/x.sh`) and the guard carded it as that. "" otherwise."""
    command = args.get("command") or args.get("cmd") or ""
    if not isinstance(command, str):
        return ""
    parsed = shell.parse(command)
    if parsed.error or parsed.substitutions or parsed.operators or len(parsed.segments) != 1:
        return ""
    segment = parsed.segments[0]
    if segment.redirects or segment.heredocs or not segment.words or segment.words[0].assignment():
        return ""
    argv = []
    for word in segment.words:
        text, exact = word.text({})
        if not exact:
            return ""
        argv.append((text, word))
    first = argv[0][0]
    if INTERPRETERS.fullmatch(first.rsplit("/", 1)[-1]):
        if len(argv) < 2 or argv[1][0].startswith("-"):
            return ""
        shown, word = argv[1]
    elif "/" in first:
        shown, word = argv[0]
    else:
        return ""
    if "://" in shown or verdict.title not in (f"Run the script {shown}", f"Run {shown}"):
        return ""
    path = shown
    first_part = word.parts[0] if word.parts else None
    if path.startswith("~/") and first_part and first_part[0] == "lit" and not first_part[2]:
        path = os.path.join(os.environ.get("HOME", ""), path[2:])
    if not os.path.isabs(path):
        workdir = str(args.get("workdir") or args.get("cwd") or "")
        if not os.path.isabs(workdir):  # the terminal's own folder isn't known here, and ~ may not be expanded
            return ""
        path = os.path.join(workdir, path)
    real = os.path.realpath(path)
    return real if os.path.isfile(real) else ""


def short_path(path: str) -> str:
    home = os.environ.get("HOME", "")
    return "~" + path[len(home):] if home and (path == home or path.startswith(home + "/")) else path


# Words for cards and Setup

def label(tool: str, app: str = "") -> str:
    text = LABELS.get(tool)
    if text is None:
        text = f"Use {tool} in {{app}}" if app else f"Use {tool}"
    return text.replace("{app}", app or "one app")


def _scripts_line(runnable: List[str], pins: Dict[str, str]) -> str:
    place = runnable[0]
    if os.path.isdir(place):
        count = sum(1 for path in pins if os.path.dirname(path) == place)
        return (f"Run the scripts in {short_path(place)}, as they are now ({count} file{'s' if count != 1 else ''}). "
                "One that changes, or a new one there, asks again.")
    return f"Run {short_path(place)}, as it is now. If it or a script next to it changes, it asks again."


def covered_lines(tools: List[str], app: str, runnable: List[str], pins: Dict[str, str]) -> List[str]:
    lines = [f"{label(name, app if _risk(name) == 'ui' else '')} ({name})" for name in tools]
    if any(_risk(name) == "ui" for name in tools):
        lines.append(f"Clicks on send, delete or share buttons, Return, shortcuts and line breaks in {app} still ask.")
    if runnable:
        lines.append(_scripts_line(runnable, pins))
    return lines


def _risk(name: str) -> str:
    tool = registry.get(name)
    return tool.risk if tool is not None else ""


# Asking for a grant (approval_grant)

def plan(args: Dict[str, Any]) -> Dict[str, Any]:
    """The grant an approval_grant call asks for, checked. Raises registry.Refused with what to fix."""
    args = args if isinstance(args, dict) else {}
    what = " ".join(str(args.get("what") or "").split())
    if not what:
        raise registry.Refused("Say what the user allowed, in their own words (what).")
    if len(what) > 300:
        raise registry.Refused("what should be the user's own words, under 300 characters.")
    duration = str(args.get("duration") or "request").strip().lower()
    if duration not in UNTIL:
        raise registry.Refused("duration is request (until this request is done) or forever (only when the user "
                               "said from now on, always or every time).")
    raw_tools = args.get("tools") or []
    if isinstance(raw_tools, str):
        raw_tools = [raw_tools]
    if not isinstance(raw_tools, list):
        raise registry.Refused("tools is a list of tool names.")
    tools: List[str] = []
    for raw in raw_tools:
        name = str(raw or "").strip()
        if name and name not in tools:
            _check_tool(name)
            tools.append(name)
    if len(tools) > MAX_TOOLS:
        raise registry.Refused(f"A grant covers at most {MAX_TOOLS} tools. Ask for what the user named.")
    app = " ".join(str(args.get("app") or "").split())
    uses_ui = any(_risk(name) == "ui" for name in tools)
    if uses_ui:
        low = app.lower()
        if not app:
            raise registry.Refused("Clicking and typing is only granted for one app: say which (app).")
        if len(app) > 60 or any(name in low for name in TERMINALS) or "daisy" in low:
            raise registry.Refused(f"Clicking and typing in {app} can't be granted: in a terminal, typing runs "
                                   "commands, and Daisy's own window is where the cards are.")
    elif app:
        raise registry.Refused("app only goes with a tool that clicks and types (computer_act).")
    runnable: List[str] = []
    pins: Dict[str, str] = {}
    scripts = str(args.get("scripts") or "").strip()
    if scripts:
        runnable, pins = _scripts(scripts)
    if not tools and not runnable:
        raise registry.Refused("Name what the grant covers: tools, or scripts to run.")
    return {"what": what, "duration": duration, "tools": tools, "app": app, "scripts": runnable, "pins": pins,
            "covers": covered_lines(tools, app, runnable, pins)}


def _check_tool(name: str) -> None:
    if name == TOOL:
        raise registry.Refused("A grant can't cover asking for grants.")
    if name in ("write_file", "patch"):
        raise registry.Refused(f"{name} already runs without Daisy's card (Hermes asks on its own for sensitive "
                               "files, and a grant doesn't change that). Leave it out.")
    if name in ("terminal", "execute_code", "process", "process_manage"):
        raise registry.Refused(f"{name} can't be granted as a whole. To run the user's scripts without a card, "
                               "give scripts: the script file or its folder.")
    tool = registry.get(name)
    if tool is not None:
        if tool.risk == "read":
            raise registry.Refused(f"{name} only reads and never asks. Leave it out.")
        if tool.risk not in GRANTABLE_RISKS:
            raise registry.Refused(f"{name} {'sends' if tool.risk == 'send' else tool.risk + 's'} things, and "
                                   "those always get their own card, grant or not.")
        return
    if name.startswith("mcp_") and mcp_edit(name):
        return
    if name.startswith("mcp_"):
        raise registry.Refused(f"{name} isn't an edit (its name says it sends, deletes, shares, runs or answers "
                               "something), so it keeps its card.")
    raise registry.Refused(f"There's no tool named {name} that a grant can cover. Grants cover tools that edit or "
                           "add things (docs_write, notes_append...), and scripts.")


def _scripts(value: str) -> Tuple[List[str], Dict[str, str]]:
    path = os.path.expanduser(value) if value.startswith("~") else value
    if not os.path.isabs(path):
        raise registry.Refused("scripts is the full path of a script or a folder of scripts, starting with / or ~.")
    real = os.path.realpath(path)
    home = os.path.realpath(os.environ.get("HOME", "") or "/")
    if targets.guard_path(real + "/") or targets.guard_path(path + "/"):
        raise registry.Refused("Scripts in Daisy's own settings can't be granted.")
    if os.path.isdir(real):
        if real in ("/", home) or real.startswith(("/System", "/usr", "/bin", "/sbin", "/Library")):
            raise registry.Refused(f"{short_path(real)} is too broad. Name the folder the scripts are in.")
        pins = snapshot(real)
        if not pins:
            raise registry.Refused(f"There are no scripts directly in {short_path(real)}.")
        return [real], pins
    if not os.path.isfile(real):
        raise registry.Refused(f"There's no file or folder at {value}.")
    pins = snapshot(os.path.dirname(real))
    if real not in pins:
        if os.path.getsize(real) > MAX_PIN_BYTES:
            raise registry.Refused(f"{short_path(real)} is over 1 MB, too big to hold to how it is now.")
        pins[real] = _sha256(real)
    return [real], pins


def card_parts(proposal: Dict[str, Any]) -> Tuple[str, str]:
    """The approval_grant card: what runs without a card, for how long, and what still asks."""
    phrases = [line.split(" (")[0] for line in proposal["covers"][:len(proposal["tools"])]]
    if proposal["scripts"]:
        place = proposal["scripts"][0]
        phrases.append(f"run the scripts in {short_path(place)}" if os.path.isdir(place)
                       else f"run {os.path.basename(place)}")
    phrases = [phrase[:1].lower() + phrase[1:] for phrase in phrases]
    if len(phrases) == 1:
        doing = phrases[0]
    elif len(phrases) == 2:
        doing = f"{phrases[0]} and {phrases[1]}"
    else:
        doing = f"do {len(phrases)} kinds of steps"
    until = "until this request is done" if proposal["duration"] == "request" else "from now on"
    title = f"Let Daisy {doing} without asking, {until}"
    detail = "\n".join([UNTIL[proposal["duration"]], f"You said: “{proposal['what']}”", "Runs without a card:",
                        *[f"• {line}" for line in proposal["covers"]], STILL_ASKS])
    return title, detail


def card_text(args: Dict[str, Any]) -> str:
    title, detail = card_parts(plan(args))
    return f"{title}\n{detail}"


def _key(args: Dict[str, Any]) -> str:
    return json.dumps(args if isinstance(args, dict) else {}, sort_keys=True, ensure_ascii=False, default=str)


class _Pending:
    """Grants whose card is up, by the exact call. run() takes one back once, in the same session."""

    def __init__(self):
        self.lock = threading.Lock()
        self.items: "OrderedDict[str, Tuple[float, str, str, Dict[str, Any]]]" = OrderedDict()

    def hold(self, args: Dict[str, Any], session: str, turn: str, proposal: Dict[str, Any]) -> None:
        key = f"{session}\n{_key(args)}"
        with self.lock:
            self.items.pop(key, None)
            self.items[key] = (time.monotonic(), session, turn, proposal)
            while len(self.items) > 64:
                self.items.popitem(last=False)

    def take(self, args: Dict[str, Any], session: str) -> Optional[Tuple[str, Dict[str, Any]]]:
        with self.lock:
            found = self.items.pop(f"{session}\n{_key(args)}", None)
        if found is None or time.monotonic() - found[0] > PENDING_SECONDS:
            return None
        return found[2], found[3]


_pending = _Pending()


def hold(args: Dict[str, Any], session: str, turn: str, proposal: Dict[str, Any]) -> None:
    """Called by the guard once it has decided to card an approval_grant call."""
    _pending.hold(args, session, turn, proposal)


def activate(args: Dict[str, Any], session: str) -> Optional[Dict[str, Any]]:
    """Turns on the grant this session's approved approval_grant card showed, once. None when no card
    showed this exact call."""
    found = _pending.take(args, session)
    if found is None:
        return None
    turn, proposal = found
    now = time.time()
    grant = {"id": "g-" + uuid.uuid4().hex[:12], "given": now, "by": "daisy", **proposal}
    if proposal["duration"] == "request":
        grant.update(session=session, turn=turn, expires=now + REQUEST_SECONDS)
    return add(grant)


# "Yes to all like this" and the log

def message_digest(message: str) -> str:
    return hashlib.sha256(message.encode("utf-8")).hexdigest()


def offer(tool_name: str, args: Dict[str, Any], verdict: Verdict, session: str, turn: str, message: str) -> None:
    """Notes a grantable card the user can answer with "Yes to all like this": the grant it would give,
    for this session and turn only."""
    if not roles.DAISY_PROCESS or not session or not turn:
        return
    call = call_scope(tool_name, args, verdict)
    if call is None:
        return
    if call.script:
        pins = snapshot(os.path.dirname(call.script))
        pins.setdefault(call.script, _sha256(call.script))
        grant = {"tools": [], "app": "", "scripts": [call.script], "pins": pins,
                 "covers": covered_lines([], "", [call.script], pins)}
    else:
        app = " ".join(str(args.get("app") or "").split()) if call.app else ""
        grant = {"tools": [call.tool], "app": app, "scripts": [], "pins": {},
                 "covers": covered_lines([call.tool], app, [], {})}
    now = time.time()
    entry = {"digest": message_digest(message), "session": session, "turn": turn, "at": now, "grant": grant}
    with _locked():
        offers = [item for item in _listed(_read(offers_file()), "offers")
                  if now - _number(item.get("at")) < OFFER_SECONDS]
        offers = (offers + [entry])[-MAX_OFFERS:]
        _write(offers_file(), {"version": VERSION, "offers": offers})


def ran(grant: Dict[str, Any], session: str, turn: str, tool_name: str, verdict: Verdict) -> None:
    """One line in grants.jsonl for a call that ran under a grant. Raises if it can't be written, and
    then the call gets its card instead: nothing runs under a grant without showing up."""
    line = json.dumps({"at": time.time(), "session": session, "turn": turn, "grant": grant.get("id", ""),
                       "tool": tool_name, "title": verdict.title or tool_name}, ensure_ascii=False) + "\n"
    path = log_file()
    with _locked():
        handle = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            os.write(handle, line.encode("utf-8"))
        finally:
            os.close(handle)
        if path.stat().st_size > MAX_LOG_BYTES:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)[-KEEP_LOG_LINES:]
            temporary = path.parent / f".{path.name}.{uuid.uuid4().hex}.tmp"
            with open(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w", encoding="utf-8") as out:
                out.writelines(lines)
            os.replace(temporary, path)
