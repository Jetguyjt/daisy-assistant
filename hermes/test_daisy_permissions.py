"""The Permissions list's guard side: the asks log (asks.jsonl), and grants the app writes from a switch.
Run: python3 hermes/test_daisy_permissions.py"""

import fcntl
import hashlib
import importlib.util
import json
import logging
import os
import stat
import sys
import tempfile
import time
from pathlib import Path

HOME = Path(os.path.realpath(tempfile.mkdtemp(prefix="daisy-permissions-")))
WORK = Path(os.path.realpath(tempfile.mkdtemp(prefix="daisy-permissions-work-")))  # scripts live here, never in ~
os.environ["HERMES_HOME"] = str(HOME)
os.environ["DAISY_SESSION"] = "1"
for name in ("HERMES_CRON_SESSION", "HERMES_SESSION_PLATFORM", "HERMES_SESSION_KEY", "HERMES_SESSION_ID",
             "HERMES_SINGLE_QUERY_SESSION", "HERMES_YOLO_MODE"):
    os.environ.pop(name, None)
for name in ("daisy.guard", "daisy.learned"):
    logging.getLogger(name).addHandler(logging.NullHandler())
    logging.getLogger(name).propagate = False


def load():
    for name in [n for n in sys.modules if n == "daisy_plugin" or n.startswith("daisy_plugin.")]:
        del sys.modules[name]
    folder = Path(__file__).parent / "daisy"
    spec = importlib.util.spec_from_file_location("daisy_plugin", folder / "__init__.py", submodule_search_locations=[str(folder)])
    module = importlib.util.module_from_spec(spec)
    sys.modules["daisy_plugin"] = module
    spec.loader.exec_module(module)
    return module


failures = 0


def check(label, condition):
    global failures
    try:
        ok = condition() if callable(condition) else condition
    except Exception as error:  # a crash in a check is a failure, not the end of the run
        ok = False
        label = f"{label} ({type(error).__name__}: {error})"
    if not ok:
        failures += 1
        print("FAIL", label)


plugin = load()
registry = plugin.registry
grants = sys.modules["daisy_plugin.guard.grants"]
asks = sys.modules["daisy_plugin.guard.asks"]
policy = sys.modules["daisy_plugin.guard.policy"]
DAISY = HOME / "daisy"
ASKS = DAISY / "asks.jsonl"

obj = {"type": "object", "properties": {}}
registry.add(registry.TypedTool(name="fake_edit", description="", parameters=obj, risk="write",
                                card=lambda a: f"Edit {a.get('name', 'a doc')}\n{a.get('text', '')}",
                                run=lambda a: {"edited": True}))
registry.add(registry.TypedTool(name="fake_read", description="", parameters=obj, risk="read",
                                card=lambda a: "Look", run=lambda a: {}))
registry.add(registry.TypedTool(name="fake_click", description="", parameters=obj, risk="ui",
                                card=lambda a: f"Click the “{a.get('label', '')}” button in {a.get('app')}",
                                run=lambda a: {}))

EDIT = {"name": "Essay", "text": "fix the intro"}
SEND = {"to": ["Dad <dad@example.com>"], "subject": "Essay draft", "body": "Here's the draft."}
SHARE = {"file_id": "1BudgetSheet00000000000000", "name": "Budget 2026", "audience": "anyone"}
DELETE = {"file_id": "1BudgetSheet00000000000000", "name": "Budget 2026"}


def ask(tool, args, session, turn="t1", **hook):
    policy._cards.sessions.clear()  # five cards a minute is tested in test_daisy_guard.py, not here
    hook.setdefault("task_id", session)
    hook.setdefault("session_id", session)
    return plugin.on_pre_tool_call(tool_name=tool, args=args, turn_id=turn, **hook)


def runs(tool, args, session, turn="t1", **hook):
    return ask(tool, args, session, turn, **hook) is None


def carded(tool, args, session, turn="t1", **hook):
    result = ask(tool, args, session, turn, **hook)
    return bool(result) and result["action"] == "approve"


def blocked(tool, args, session, turn="t1", **hook):
    result = ask(tool, args, session, turn, **hook)
    return bool(result) and result["action"] == "block"


def noted():
    try:
        return [json.loads(line) for line in ASKS.read_text().splitlines() if line.strip()]
    except OSError:
        return []


def write_grants(items):
    """What the Daisy app does: the whole file, 0600."""
    DAISY.mkdir(parents=True, exist_ok=True)
    (DAISY / "grants.json").write_text(json.dumps({"version": 1, "grants": items}))
    os.chmod(DAISY / "grants.json", 0o600)


def switched_on(tools=(), app="", scripts=(), pins=None, grant_id="g-settings"):
    """A grant the way the app's Permissions switch writes one: forever, one scope, by settings."""
    return {"id": grant_id, "what": "Add to Google Docs", "duration": "forever", "given": time.time(),
            "tools": list(tools), "app": app, "scripts": list(scripts), "pins": pins or {},
            "covers": ["Add to Google Docs (docs_write)"], "by": "settings"}


def reset():
    for name in ("grants.json", "grants.jsonl", "grant-offers.json", "roles.json", "asks.jsonl"):
        path = DAISY / name
        if path.is_dir():
            path.rmdir()
        elif path.exists():
            path.unlink()
    policy._granted_calls.sessions.clear()
    policy._cards.sessions.clear()


# The asks log: one line for every card shown, and nothing else

reset()
check("a read isn't noted", runs("fake_read", {}, "a1") and noted() == [])
check("a card is", carded("fake_edit", EDIT, "a1"))
line = noted()[-1] if noted() else {}
check("with when, which session and what the card said",
      line.get("session") == "a1" and line.get("title") == "Edit Essay" and abs(line.get("at", 0) - time.time()) < 60)
check("its risk and scope", line.get("tool") == "fake_edit" and line.get("risk") == "write"
      and line.get("grantable") is True and line.get("scope") == "fake_edit" and "why" not in line)
check("the log is private", stat.S_IMODE(ASKS.stat().st_mode) == 0o600)
check("a block isn't noted", blocked("fake_edit", {**EDIT, "url": "javascript:alert(1)"}, "a1") and len(noted()) == 1)
check("asking for a grant isn't noted", carded("approval_grant", {"what": "x", "tools": ["fake_edit"]}, "a1")
      and len(noted()) == 1)
check("a card with no turn to belong to isn't noted", carded("fake_edit", EDIT, "a-noturn", turn="") and len(noted()) == 1)
DAISY.joinpath("roles.json").write_text(json.dumps({"version": 1, "sessions": {"job-1": "worker"}}))
check("a background job's step is blocked, not noted", blocked("fake_edit", EDIT, "job-1") and len(noted()) == 1)
check("so is a cron run's", blocked("fake_edit", EDIT, "cron-x", task_id="cron:digest:1") and len(noted()) == 1)
grants.roles.DAISY_PROCESS = False
check("cards outside a Daisy process aren't noted", carded("fake_edit", EDIT, "a2") and len(noted()) == 1)
grants.roles.DAISY_PROCESS = True
write_grants([switched_on(tools=["fake_edit"])])
check("a step a grant lets through isn't a card, so it isn't noted", runs("fake_edit", EDIT, "a3") and len(noted()) == 1)

# How each card is scoped, the way a grant would have to name it

reset()
carded("fake_click", {"app": " Pages ", "label": "Bold"}, "b1")
click = noted()[-1]
check("clicking in one app is scoped to that app", click["scope"] == "fake_click@pages" and click["app"] == "Pages"
      and click["grantable"] is True)
tools_dir = WORK / "tools"
tools_dir.mkdir()
(tools_dir / "fix.py").write_text("print('fixed')\n")
(tools_dir / "helper.py").write_text("def fix():\n    pass\n")
carded("terminal", {"command": f"python3 {tools_dir}/fix.py"}, "b1")
script = noted()[-1]
check("a script is scoped to its real path", script["scope"] == f"script:{tools_dir}/fix.py"
      and script["script"] == f"{tools_dir}/fix.py" and script["grantable"] is True and script["tool"] == "terminal")
carded("mcp__notion__update_page", {"page": "x"}, "b1")
check("an MCP edit is scoped to its name", noted()[-1]["scope"] == "mcp__notion__update_page" and noted()[-1]["grantable"])


def reason_for(tool, args):
    before = len(noted())
    if not carded(tool, args, "b2"):
        return None
    new = noted()[before:]
    if len(new) != 1 or new[0]["grantable"] or "scope" in new[0]:
        return None
    return new[0]["why"], new[0]["reason"]


check("a send says why it always asks", reason_for("gmail_send", SEND) == ("send", "Sends always ask"))
check("so does a share", reason_for("drive_share", SHARE) == ("share", "Shares always ask"))
check("and a delete", reason_for("drive_delete", DELETE) == ("delete", "Deletes always ask"))
check("the risk is the tool's own", noted()[-1]["risk"] == "delete")
check("a delete in the shell too", (reason_for("terminal", {"command": f"rm {tools_dir}/helper.py"}) or ("",))[0] == "delete")
check("an install", (reason_for("terminal", {"command": "brew install ffmpeg"}) or ("",))[0] == "install")
check("a command that isn't a script", (reason_for("terminal", {"command": "npm test"}) or ("",))[0] == "command")
check("an edit that reaches people", (reason_for("fake_edit", {**EDIT, "guests": ["a@example.com"]}) or ("",))[0] == "people")
check("a Send button", (reason_for("fake_click", {"app": "Pages", "label": "Send"}) or ("",))[0] == "ui")
check("an MCP delete", (reason_for("mcp__notion__delete_page", {"page": "x"}) or ("",))[0] == "delete")
check("driving the browser directly", (reason_for("browser_click", {"ref": "e1"}) or ("",))[0] == "browser")
check("running code", (reason_for("execute_code", {"code": "import os\nos.system('make')"}) or ("",))[0] == "code")
check("why_not is empty for what a grant can cover",
      grants.why_not("fake_edit", EDIT, policy.card("fake_edit", "Edit Essay")) == ("", ""))
check("titles are kept short", len(json.loads(asks.line("fake_edit", {}, policy.card("fake_edit", "x" * 500), "s"))["title"])
      <= asks.MAX_TITLE)

# Capped, and it never gets in the way

reset()
DAISY.mkdir(parents=True, exist_ok=True)
old = json.dumps({"at": 1, "session": "old", "tool": "fake_edit", "title": "old", "grantable": True,
                  "scope": "fake_edit"}) + "\n"
ASKS.write_text(old * (asks.MAX_BYTES // len(old) + 10))
os.chmod(ASKS, 0o600)
before = len(noted())
carded("fake_edit", EDIT, "c1")
after = noted()
check("past the cap it's cut to its newest half", ASKS.stat().st_size < asks.MAX_BYTES * 0.6
      and abs(len(after) - (before + 1) // 2) <= 1)
check("and the newest line is kept", after[-1]["session"] == "c1")
check("no temp files are left behind", not [p for p in DAISY.iterdir() if p.name.endswith(".tmp")])

held = os.open(DAISY / ".asks.lock", os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(held, fcntl.LOCK_EX)
started = time.monotonic()
check("a busy lock doesn't hold the card up", carded("fake_edit", EDIT, "c2") and time.monotonic() - started < 1)
check("and the line still goes in", noted()[-1]["session"] == "c2")
fcntl.flock(held, fcntl.LOCK_UN)
os.close(held)

reset()
ASKS.mkdir()
check("a log that can't be written leaves the card as it was", carded("fake_edit", EDIT, "c3"))
ASKS.rmdir()
real_scope = grants.call_scope
grants.call_scope = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom"))
try:
    asks.note("chat", "fake_edit", EDIT, policy.card("fake_edit", "Edit Essay"), "c4", "t1")
    check("noting never raises", True)
except Exception:
    check("noting never raises", False)
grants.call_scope = real_scope
ASKS.write_text("")
os.chmod(ASKS, 0o644)
carded("fake_edit", EDIT, "c5")
check("a log that was left readable is made private again", stat.S_IMODE(ASKS.stat().st_mode) == 0o600)

# Grants the app writes from a Permissions switch

reset()
write_grants([switched_on(tools=["fake_edit"])])
check("a forever grant from a switch covers the next matching call", runs("fake_edit", EDIT, "d1"))
check("in any chat session", runs("fake_edit", {"name": "Other", "text": "y"}, "d2", "t9"))
log = [json.loads(line) for line in (DAISY / "grants.jsonl").read_text().splitlines()]
check("and each step is logged under it", len(log) == 2 and {entry["grant"] for entry in log} == {"g-settings"})
check("not something else", carded("fake_click", {"app": "Pages", "label": "Bold"}, "d1"))
check("not with people in it", carded("fake_edit", {**EDIT, "notify": True}, "d1"))
DAISY.joinpath("roles.json").write_text(json.dumps({"version": 1, "sessions": {"job-2": "worker"}}))
check("never in a background job", blocked("fake_edit", EDIT, "job-2"))
check("never in a cron run", blocked("fake_edit", EDIT, "cron-y", task_id="cron:digest:2"))
os.environ["HERMES_YOLO_MODE"] = "1"
check("never where nobody could answer", blocked("fake_edit", EDIT, "d3"))
os.environ.pop("HERMES_YOLO_MODE")

write_grants([switched_on(tools=["fake_click"], app="Pages")])
check("a switch for clicking in one app covers that app", runs("fake_click", {"app": "pages", "label": "Bold"}, "d4"))
check("not another app", carded("fake_click", {"app": "Mail", "label": "Bold"}, "d4"))
check("not a Send button in it", carded("fake_click", {"app": "Pages", "label": "Send"}, "d4"))

# A grant on file for a send, share or delete does nothing, however it got there

reset()
write_grants([switched_on(tools=["gmail_send", "gmail_reply", "imsg_send", "drive_share", "drive_delete",
                                 "gmail_delete", "calendar_delete", "tasks_remove", "approval_grant",
                                 "mcp__notion__delete_page", "mcp__slack__send_message", "terminal", "execute_code"],
                          grant_id="g-forged")])
check("a hand-written gmail_send grant covers nothing", carded("gmail_send", SEND, "e1"))
check("nor a drive_delete one", carded("drive_delete", DELETE, "e1"))
check("nor a drive_share one", carded("drive_share", SHARE, "e1"))
check("nor an MCP delete", carded("mcp__notion__delete_page", {"page": "x"}, "e1"))
check("nor an MCP send", carded("mcp__slack__send_message", {"text": "x"}, "e1"))
check("nor a command", carded("terminal", {"command": "npm test"}, "e1"))
check("nothing ran under it", not (DAISY / "grants.jsonl").exists())
check("and each of those was noted as always asking", all(not entry["grantable"] for entry in noted()) and len(noted()) == 6)
check("the guard's own check says so too", not any(grants.grantable(name) for name in (
    "gmail_send", "drive_share", "drive_delete", "approval_grant", "terminal", "execute_code", "mcp__notion__delete_page")))
check("while what a switch can turn on passes it", all(grants.grantable(name) for name in (
    "docs_write", "notes_append", "tasks_add", "computer_act", "mcp__notion__update_page")))

# Scripts from a switch stay as they were when it was turned on

reset()


def pins_now(place):
    """What the app pins when the switch goes on: every script in the folder, hashed."""
    return {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(Path(place).iterdir())
            if path.suffix == ".py"}


fix = f"python3 {tools_dir}/fix.py"
write_grants([switched_on(scripts=[f"{tools_dir}/fix.py"], pins=pins_now(tools_dir))])
check("a script switched on runs", runs("terminal", {"command": fix}, "f1"))
check("only that script", carded("terminal", {"command": f"python3 {tools_dir}/helper.py"}, "f1"))
(tools_dir / "fix.py").write_text("import smtplib\n")
check("changed since, it asks again", carded("terminal", {"command": fix}, "f1"))
check("and that ask is noted with its scope", noted()[-1]["scope"] == f"script:{tools_dir}/fix.py")
(tools_dir / "fix.py").write_text("print('fixed')\n")
(tools_dir / "new.py").write_text("print('new')\n")
check("a new script next to it asks again", carded("terminal", {"command": fix}, "f1"))
(tools_dir / "new.py").unlink()
check("back as it was, it runs", runs("terminal", {"command": fix}, "f1"))
write_grants([switched_on(scripts=[f"{tools_dir}/fix.py"], pins={})])
check("a script grant with no pins covers nothing", carded("terminal", {"command": fix}, "f2"))

# Turning a switch off

reset()
write_grants([switched_on(tools=["fake_edit"]), switched_on(tools=["notes_append"], grant_id="g-other")])
check("on, it runs", runs("fake_edit", EDIT, "g1"))
write_grants([switched_on(tools=["notes_append"], grant_id="g-other")])
check("off (the app rewrites the file without it), it's a card again", carded("fake_edit", EDIT, "g2"))
check("and noted again", noted()[-1]["scope"] == "fake_edit")
write_grants([switched_on(tools=["fake_edit"])])
check("revoked by id, the same", grants.revoke("g-settings") and carded("fake_edit", EDIT, "g3"))

print("permissions checks:", "ok" if failures == 0 else f"{failures} failed")
sys.exit(1 if failures else 0)
