"""Who is calling decides what's allowed.

- chat: Daisy's own conversation, and gateway and CLI sessions. Reads run; risky actions stop at a card.
- worker: a background job the Daisy app started as its own ACP session. Reads only; anything else is
  blocked, because nobody is watching it.
- cron: a scheduled run. Reads only, plus actions pre-approved with fixed parameters in
  $HERMES_HOME/daisy/cron-allow.json. Nobody is there to answer a card, so nothing else runs.

The orchestrator lists workers in $HERMES_HOME/daisy/roles.json:
    {"version": 1, "sessions": {"<acp session id>": "worker"}}
In a Daisy process (DAISY_SESSION=1) a session that isn't listed is chat, and a missing or unreadable
file means no workers. Hermes passes the ACP session id as task_id (it stays the same when compression
gives the conversation a new session_id), so both ids are looked up.

cron-allow.json:
    {"version": 1, "allow": [
        {"tool": "imsg_send", "args": {"to": "+15551234567"}, "free": ["text"]},
        {"tool": "terminal", "command": "remindctl add 'Check the inbox digest'"},
        {"tool": "gmail_send", "job": "inbox-digest", "args": {"to": "me@example.com"}, "free": ["subject", "body"]}
    ]}
An entry matches when the tool is the same, every value in "args" is exactly equal, and every other
argument of the call is named in "free". Terminal entries match the whole command word for word, and
the same "workdir" (none when the entry has none). "job" limits an entry to one cron job (the job id in
the run's task id, cron:<job>:<run>). A missing or broken file pre-approves nothing, and nothing
overrides the hard blocks (javascript: links, Daisy's guard settings)."""

from __future__ import annotations

import json
import os
import threading
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

from . import targets
from .commands import same_command
from .verdict import Verdict, allow, block

# Frozen at import, like Hermes's own yolo flag: code running later in the process can't flip it.
DAISY_PROCESS = os.environ.get("DAISY_SESSION") == "1"
ROLES = ("chat", "worker", "cron")
TRUE = ("1", "true", "yes", "on")

WORKER = ("Blocked by Daisy's guard: this is a background job, and background jobs can only read. {what} "
          "needs the user, so report back instead of doing it.")
CRON = ("Blocked by Daisy's guard: scheduled jobs can only read, plus actions pre-approved in {path}. {what} "
        "isn't pre-approved, so leave it for the user.")


def roles_file() -> Path:
    return targets.hermes_home() / "daisy" / "roles.json"


def cron_allow_file() -> Path:
    return targets.hermes_home() / "daisy" / "cron-allow.json"


class _JsonFile:
    """A small JSON file, read again only when it changes."""

    def __init__(self, keep_last_good: bool):
        self.keep_last_good = keep_last_good
        self.lock = threading.Lock()
        self.cache: Dict[str, Tuple[Any, Any]] = {}

    def load(self, path: Path) -> Any:
        key = str(path)
        try:
            info = path.stat()
            stamp = (info.st_mtime_ns, info.st_size, info.st_ino)
        except OSError:
            with self.lock:
                self.cache.pop(key, None)
            return None
        with self.lock:
            cached = self.cache.get(key)
            if cached and cached[0] == stamp:
                return cached[1]
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            with self.lock:
                if self.keep_last_good and cached:
                    return cached[1]
            return None
        with self.lock:
            self.cache[key] = (stamp, data)
        return data


# roles.json keeps its last good copy while the orchestrator is halfway through rewriting it, so a
# worker never turns into chat for a moment. cron-allow.json doesn't: broken means nothing is allowed.
_roles = _JsonFile(keep_last_good=True)
_cron_allow = _JsonFile(keep_last_good=False)


def session_env(name: str) -> str:
    """A per-session Hermes setting (HERMES_CRON_SESSION, HERMES_SESSION_PLATFORM...), read the way
    Hermes reads it: the session's own context first, then the process environment."""
    try:
        from gateway.session_context import get_session_env
        return str(get_session_env(name, "") or "")
    except Exception:
        return os.environ.get(name, "") or ""


def is_cron(task_id: str) -> bool:
    return task_id.startswith("cron:") or session_env("HERMES_CRON_SESSION").strip().lower() in TRUE


def role_for(task_id: str = "", session_id: str = "") -> str:
    if is_cron(task_id):
        return "cron"
    if not DAISY_PROCESS:
        return "chat"
    data = _roles.load(roles_file())
    sessions = data.get("sessions") if isinstance(data, dict) else None
    if not isinstance(sessions, dict):
        return "chat"
    listed = [sessions.get(key) for key in (task_id, session_id) if key and key in sessions]
    if not listed:
        return "chat"
    # Anything listed that isn't plainly "chat" is treated as a worker, the stricter of the two.
    return "chat" if all(role == "chat" for role in listed) else "worker"


def preapproved(tool_name: str, args: Dict[str, Any], task_id: str) -> bool:
    data = _cron_allow.load(cron_allow_file())
    entries = data.get("allow") if isinstance(data, dict) else None
    if not isinstance(entries, list):
        return False
    job = task_id.split(":")[1] if task_id.startswith("cron:") and task_id.count(":") >= 1 else ""
    for entry in entries:
        if not isinstance(entry, dict) or entry.get("tool") != tool_name:
            continue
        if "job" in entry and str(entry.get("job")) != job:
            continue
        if tool_name == "terminal":
            wanted, given = entry.get("command"), args.get("command")
            if not isinstance(wanted, str) or not isinstance(given, str) or not same_command(wanted, given):
                continue
            if (args.get("workdir") or "") != (entry.get("workdir") or ""):
                continue
            return True
        fixed, free = entry.get("args", {}), entry.get("free", [])
        if not isinstance(fixed, dict) or not isinstance(free, list):
            continue
        if any(key not in args or args[key] != value for key, value in fixed.items()):
            continue
        if any(key not in fixed and key not in free for key in args):
            continue
        return True
    return False


def enforce(role: str, tool_name: str, args: Dict[str, Any], verdict: Verdict, task_id: str) -> Verdict:
    """Narrows a verdict to what the role may do."""
    if role == "chat" or (verdict.decision == "allow" and verdict.read_only):
        return verdict
    if role == "cron" and not verdict.hard and preapproved(tool_name, args, task_id):
        return allow(title=verdict.title, rule="cron-allowed")
    if verdict.decision == "block":
        return verdict
    what = verdict.title or f"Running {tool_name}"
    if role == "cron":
        return block(CRON.format(what=what, path=cron_allow_file()), title=what)
    return block(WORKER.format(what=what), title=what)
