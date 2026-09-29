"""Standing permissions: what a grant lets through without a card, for how long, and what it never touches.
Run: python3 hermes/test_daisy_grants.py"""

import hashlib
import importlib.util
import itertools
import json
import logging
import os
import stat
import sys
import tempfile
import time
from pathlib import Path

HOME = Path(os.path.realpath(tempfile.mkdtemp(prefix="daisy-grants-")))
WORK = Path(os.path.realpath(tempfile.mkdtemp(prefix="daisy-grants-work-")))  # scripts live here, never in ~
os.environ["HERMES_HOME"] = str(HOME)
os.environ["DAISY_SESSION"] = "1"
for name in ("HERMES_CRON_SESSION", "HERMES_SESSION_PLATFORM", "HERMES_SESSION_KEY", "HERMES_SESSION_ID",
             "HERMES_SINGLE_QUERY_SESSION", "HERMES_YOLO_MODE"):
    os.environ.pop(name, None)
logging.getLogger("daisy.guard").addHandler(logging.NullHandler())
logging.getLogger("daisy.guard").propagate = False
logging.getLogger("daisy.learned").addHandler(logging.NullHandler())
logging.getLogger("daisy.learned").propagate = False


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
policy = sys.modules["daisy_plugin.guard.policy"]
DAISY = HOME / "daisy"
ids = itertools.count(1)

obj = {"type": "object", "properties": {}}
registry.add(registry.TypedTool(name="fake_edit", description="", parameters=obj, risk="write",
                                card=lambda a: f"Edit {a.get('name', 'a doc')}\n{a.get('text', '')}",
                                run=lambda a: {"edited": True}))
registry.add(registry.TypedTool(name="fake_other", description="", parameters=obj, risk="write",
                                card=lambda a: "Change something else", run=lambda a: {}))
registry.add(registry.TypedTool(name="fake_own", description="", parameters=obj, risk="own",
                                card=lambda a: "Add a task", run=lambda a: {}))
for risk in ("send", "share", "delete"):
    registry.add(registry.TypedTool(name=f"fake_{risk}", description="", parameters=obj, risk=risk,
                                    card=lambda a, r=risk: f"{r.title()} something", run=lambda a: {}))


def click_card(args):
    action = args.get("action", "click")
    if action == "type":
        return f"Type in {args.get('app')}: “{args.get('text', '')}”"
    if action == "key":
        return f"Press {args.get('keys')} in {args.get('app')}"
    return f"Click the “{args.get('label', '')}” button in {args.get('app')}"


registry.add(registry.TypedTool(name="fake_click", description="", parameters=obj, risk="ui", card=click_card,
                                run=lambda a: {}))


def ask(tool, args, session=None, turn="t1", **hook):
    session = session or f"s-{next(ids)}"
    hook.setdefault("task_id", session)
    hook.setdefault("session_id", session)
    return plugin.on_pre_tool_call(tool_name=tool, args=args, turn_id=turn, **hook)


def runs(tool, args, session, turn="t1", **hook):
    return ask(tool, args, session=session, turn=turn, **hook) is None


def carded(tool, args, session, turn="t1", **hook):
    policy._cards.sessions.clear()  # five cards a minute is tested in test_daisy_guard.py, not here
    result = ask(tool, args, session=session, turn=turn, **hook)
    return bool(result) and result["action"] == "approve"


def blocked(tool, args, session, turn="t1", **hook):
    result = ask(tool, args, session=session, turn=turn, **hook)
    return bool(result) and result["action"] == "block"


def grant(args, session, turn="t1"):
    """The model asks for a grant, the card comes up, the user says yes, Hermes runs the tool."""
    card = ask("approval_grant", args, session=session, turn=turn)
    assert card and card["action"] == "approve", card
    os.environ["HERMES_SESSION_KEY"] = session
    try:
        return json.loads(registry.handler_for(registry.get("approval_grant"))(args))
    finally:
        os.environ.pop("HERMES_SESSION_KEY", None)


def on_file():
    try:
        return json.loads((DAISY / "grants.json").read_text())["grants"]
    except (OSError, ValueError, KeyError):
        return []


def write_grants(items):
    """What the Daisy app does: rewrite the whole file."""
    DAISY.mkdir(parents=True, exist_ok=True)
    (DAISY / "grants.json").write_text(json.dumps({"version": 1, "grants": items}))
    os.chmod(DAISY / "grants.json", 0o600)


def reset():
    for name in ("grants.json", "grants.jsonl", "grant-offers.json", "roles.json"):
        try:
            (DAISY / name).unlink()
        except FileNotFoundError:
            pass
    policy._granted_calls.sessions.clear()
    policy._cards.sessions.clear()


def log_lines():
    try:
        return [json.loads(line) for line in (DAISY / "grants.jsonl").read_text().splitlines() if line.strip()]
    except OSError:
        return []


EDIT = {"name": "Essay", "text": "fix the intro"}

# The card is the yes

request_card = ask("approval_grant", {"what": "edit all my essay docs without asking", "tools": ["fake_edit"]},
                   session="c1")
title, _, detail = request_card["message"].partition(" — ")
check("asking for a grant is always a card", request_card["action"] == "approve")
check("the request card says what and until when",
      title == "Let Daisy use fake_edit without asking, until this request is done")
check("it quotes the user", "You said: “edit all my essay docs without asking”" in detail)
check("it lists exactly what's covered", "• Use fake_edit (fake_edit)" in detail)
check("it says what still asks", "sending, sharing or deleting anything" in detail and "everything not listed" in detail)
check("it says when it ends", detail.startswith("Until this request is done (3 hours at most)."))
forever_card = ask("approval_grant", {"what": "from now on you can add tasks and edit docs",
                                      "tools": ["fake_own", "fake_edit"], "duration": "forever"}, session="c2")
forever_title, _, forever_detail = forever_card["message"].partition(" — ")
check("the forever card says from now on", forever_title == "Let Daisy use fake_own and use fake_edit without asking, from now on")
check("and how to turn it off", "until you turn it off in Setup under Standing permissions" in forever_detail)
check("three things or more are counted in the title", ask(
    "approval_grant", {"what": "x", "tools": ["fake_own", "fake_edit", "fake_other"]}, session="c3")["message"]
      .startswith("Let Daisy do 3 kinds of steps without asking, until this request is done — "))
check("real tools get plain words", ask("approval_grant", {"what": "x", "tools": ["docs_write"]}, session="c4")["message"]
      .startswith("Let Daisy add to Google Docs without asking, until this request is done — "))
check("each card has its own rule key", request_card["rule_key"].startswith("daisy.grant.")
      and request_card["rule_key"] != forever_card["rule_key"])


def refused(args, words):
    result = ask("approval_grant", args, session="refusals")
    return bool(result) and result["action"] == "block" and words in result["message"]


check("a grant can't cover asking for grants", refused({"what": "x", "tools": ["approval_grant"]}, "can't cover asking"))
check("sends can't be granted", refused({"what": "x", "tools": ["fake_send"]}, "sends things"))
check("shares can't be granted", refused({"what": "x", "tools": ["fake_share"]}, "shares things"))
check("deletes can't be granted", refused({"what": "x", "tools": ["fake_delete"]}, "deletes things"))
check("real sends can't be granted", refused({"what": "x", "tools": ["gmail_send"]}, "always get their own card"))
check("reads don't need one", refused({"what": "x", "tools": ["gmail_search"]}, "only reads"))
check("write_file already runs", refused({"what": "x", "tools": ["write_file"]}, "already runs without Daisy's card"))
check("the shell can't be granted whole", refused({"what": "x", "tools": ["terminal"]}, "can't be granted as a whole"))
check("unknown tools are refused", refused({"what": "x", "tools": ["make_coffee"]}, "no tool named make_coffee"))
check("it needs the user's words", refused({"tools": ["fake_edit"]}, "own words"))
check("it needs something to cover", refused({"what": "x"}, "Name what the grant covers"))
check("duration is request or forever", refused({"what": "x", "tools": ["fake_edit"], "duration": "week"}, "duration is"))
check("clicking needs one app", refused({"what": "x", "tools": ["fake_click"]}, "only granted for one app"))
check("never a terminal", refused({"what": "x", "tools": ["fake_click"], "app": "Terminal"}, "typing runs commands"))
check("never Daisy's own window", refused({"what": "x", "tools": ["fake_click"], "app": "Daisy"}, "where the cards are"))
check("app only with clicking", refused({"what": "x", "tools": ["fake_edit"], "app": "Pages"}, "app only goes with"))
check("MCP sends are refused", refused({"what": "x", "tools": ["mcp__github__merge_pull_request"]}, "isn't an edit"))
check("nothing refused ends up on file", on_file() == [])

# A grant exists only after its card was approved

reset()
asked = {"what": "edit them all", "tools": ["fake_edit"]}
ask("approval_grant", asked, session="d1")
check("a card nobody approved leaves nothing", on_file() == [] and carded("fake_edit", EDIT, "d1"))
os.environ["HERMES_SESSION_KEY"] = "d1"
handler = registry.handler_for(registry.get("approval_grant"))
check("run() for other arguments than the card showed does nothing",
      "Nothing was granted" in json.loads(handler({"what": "edit them all", "tools": ["fake_other"]}))["error"]
      and on_file() == [])
os.environ["HERMES_SESSION_KEY"] = "someone-else"
check("run() in another session does nothing", "error" in json.loads(handler(asked)) and on_file() == [])
os.environ["HERMES_SESSION_KEY"] = "d1"
done = json.loads(handler(asked))
check("run() after the card turns it on", done.get("granted") is True and len(on_file()) == 1)
check("and only once", "error" in json.loads(handler(asked)) and len(on_file()) == 1)
os.environ.pop("HERMES_SESSION_KEY", None)
check("the grant is what the card showed", on_file()[0]["tools"] == ["fake_edit"] and on_file()[0]["duration"] == "request"
      and on_file()[0]["session"] == "d1" and on_file()[0]["turn"] == "t1" and on_file()[0]["by"] == "daisy")
check("files are private", all(stat.S_IMODE((DAISY / name).stat().st_mode) == 0o600 for name in ("grants.json",)))
check("no temp files are left behind", not [p for p in DAISY.iterdir() if p.name.endswith(".tmp")])

reset()
check("a request grant with no turn to end with is refused",
      blocked("approval_grant", {"what": "x", "tools": ["fake_edit"]}, "nosuchturn", turn=""))

# Request grants: this session, this turn

reset()
grant({"what": "edit all of them", "tools": ["fake_edit"]}, "r1", "turn-a")
check("covers the next matching call in the same turn", runs("fake_edit", EDIT, "r1", "turn-a"))
check("and the one after", runs("fake_edit", {"name": "Other essay", "text": "x"}, "r1", "turn-a"))
check("not a tool it doesn't name", carded("fake_other", {}, "r1", "turn-a"))
check("ends with the next user message", carded("fake_edit", EDIT, "r1", "turn-b"))
check("not in another session", carded("fake_edit", EDIT, "r2", "turn-a"))
check("same ACP session after compression (new session_id, same task_id)",
      runs("fake_edit", EDIT, "r1", "turn-a", session_id="r1-compressed"))
check("tool calls from code without a turn id join the latest turn",
      runs("fake_edit", EDIT, "r1", ""))
items = on_file()
items[0]["expires"] = time.time() - 1
write_grants(items)
check("never past the few-hour backstop", carded("fake_edit", EDIT, "r1", "turn-a"))

# Forever grants: every chat session

reset()
grant({"what": "from now on add tasks without asking", "tools": ["fake_own"], "duration": "forever"}, "f1")
check("forever covers a new session and turn", runs("fake_own", {}, "f-new", "z9"))
check("forever grants have no session", "session" not in on_file()[0] and on_file()[0]["duration"] == "forever")
# own runs without a card anyway; after reading outside content it's carded, and that's what a grant covers.
ask("read_file", {"path": "/tmp/x"}, session="f-tainted", turn="t1")
check("an own tool carded after reading runs under the grant", runs("fake_own", {}, "f-tainted", "t1"))
check("without a grant it would have been a card", carded("fake_other", {}, "f-tainted", "t1"))

# What a grant never covers

reset()
write_grants([{"id": "g-forged", "what": "everything", "duration": "forever", "given": time.time(),
               "tools": ["fake_edit", "fake_send", "fake_share", "fake_delete", "approval_grant", "gmail_send",
                         "fake_click"], "app": "Pages", "scripts": [], "pins": {}}])
check("sends keep their card", carded("fake_send", {}, "n1"))
check("shares keep their card", carded("fake_share", {}, "n2"))
check("deletes keep their card", carded("fake_delete", {}, "n3"))
check("a grant can't cover asking for grants", carded("approval_grant", {"what": "x", "tools": ["fake_edit"]}, "n4"))
check("calls that reach people keep their card", carded("fake_edit", {**EDIT, "notify_guests": True}, "n5")
      and carded("fake_edit", {**EDIT, "guests": ["a@example.com"]}, "n5") and carded("fake_edit", {**EDIT, "shared": True}, "n5"))
check("but the same call without them runs", runs("fake_edit", {**EDIT, "notify_guests": False, "guests": []}, "n5"))
check("hard blocks stay blocked", blocked("fake_edit", {**EDIT, "url": "javascript:alert(1)"}, "n6"))
check("guard files stay blocked", blocked("terminal", {"command": f"cp /tmp/x {HOME}/daisy/grants.json"}, "n6"))
DAISY.joinpath("roles.json").write_text(json.dumps({"version": 1, "sessions": {"job-1": "worker"}}))
check("never in a background job", blocked("fake_edit", EDIT, "job-1"))
check("never in a cron run", blocked("fake_edit", EDIT, "cron-x", task_id="cron:digest:1"))
os.environ["HERMES_YOLO_MODE"] = "1"
check("never where nobody could answer (yolo)", blocked("fake_edit", EDIT, "n7"))
os.environ.pop("HERMES_YOLO_MODE")
os.environ["HERMES_SINGLE_QUERY_SESSION"] = "1"
check("never where nobody could answer (one-shot)", blocked("fake_edit", EDIT, "n8"))
os.environ.pop("HERMES_SINGLE_QUERY_SESSION")
grants.roles.DAISY_PROCESS = False
check("never outside a Daisy process (CLI, gateway)", carded("fake_edit", EDIT, "n9"))
grants.roles.DAISY_PROCESS = True
check("a grant for a tool in chat still runs", runs("fake_edit", EDIT, "n10"))
check("the ask tool can't be covered by forging one either", "approval_grant" not in [
    c.tool for c in [grants.call_scope("approval_grant", {}, policy.card("grant", "x"))] if c])

# Clicking and typing: one app, and never the risky parts

check("clicks in the granted app run", runs("fake_click", {"app": "Pages", "label": "Bold"}, "u1"))
check("the app name is matched loosely", runs("fake_click", {"app": " pages ", "label": "Bold"}, "u1"))
check("not in another app", carded("fake_click", {"app": "Mail", "label": "Bold"}, "u1"))
check("not a Send button", carded("fake_click", {"app": "Pages", "label": "Send"}, "u1"))
check("not a Delete button", carded("fake_click", {"app": "Pages", "label": "Delete"}, "u1"))
check("not a permission prompt", carded("fake_click", {"app": "Pages", "label": "Allow"}, "u1"))
check("plain typing runs", runs("fake_click", {"app": "Pages", "action": "type", "text": "delete the intro"}, "u1"))
check("a line break doesn't", carded("fake_click", {"app": "Pages", "action": "type", "text": "hi\nthere"}, "u1"))
check("arrow keys run", runs("fake_click", {"app": "Pages", "action": "key", "keys": "down"}, "u1"))
check("Return doesn't", carded("fake_click", {"app": "Pages", "action": "key", "keys": "return"}, "u1"))
check("shortcuts don't", carded("fake_click", {"app": "Pages", "action": "key", "keys": "cmd+w"}, "u1"))
check("modifier clicks don't", carded("fake_click", {"app": "Pages", "label": "Bold", "modifiers": ["cmd"]}, "u1"))

# The log

reset()
grant({"what": "edit them", "tools": ["fake_edit"]}, "l1")
runs("fake_edit", EDIT, "l1")
line = log_lines()[-1]
check("every call under a grant is logged", line["tool"] == "fake_edit" and line["title"] == "Edit Essay"
      and line["session"] == "l1" and line["turn"] == "t1" and line["grant"] == on_file()[0]["id"])
check("the log is private", stat.S_IMODE((DAISY / "grants.jsonl").stat().st_mode) == 0o600)
(DAISY / "grants.jsonl").write_text("x" * (grants.MAX_LOG_BYTES + 10) + "\n" + "{}\n" * 600)
runs("fake_edit", EDIT, "l1")
check("the log stays capped", (DAISY / "grants.jsonl").stat().st_size < grants.MAX_LOG_BYTES
      and log_lines()[-1]["tool"] == "fake_edit")
os.chmod(DAISY / "grants.jsonl", 0o400)
check("a grant that can't be logged isn't used", carded("fake_edit", EDIT, "l1"))
os.chmod(DAISY / "grants.jsonl", 0o600)
policy._granted_calls.sessions.clear()
policy._cards.sessions.clear()
allowed = sum(runs("fake_edit", EDIT, "l1") for _ in range(policy.MAX_GRANTED))
check("a grant runs a batch", allowed == policy.MAX_GRANTED)
check("but not a runaway loop", carded("fake_edit", EDIT, "l1"))

# Revoking

reset()
grant({"what": "edit them", "tools": ["fake_edit"], "duration": "forever"}, "v1")
check("covered before revoking", runs("fake_edit", EDIT, "v2"))
write_grants([])
check("the app rewriting the file without it turns it off", carded("fake_edit", EDIT, "v3"))
grant({"what": "edit them", "tools": ["fake_edit"], "duration": "forever"}, "v4")
check("revoke by id", grants.revoke(on_file()[0]["id"]) and carded("fake_edit", EDIT, "v5") and on_file() == [])
check("revoking something gone is a no", grants.revoke("g-nothing") is False)
(DAISY / "grants.json").write_text("{not json")
check("a broken file is no grants", carded("fake_edit", EDIT, "v6"))

# "Yes to all like this": the guard notes grantable cards for the app

reset()
card = ask("fake_edit", EDIT, session="y1", turn="t1")
offers = json.loads((DAISY / "grant-offers.json").read_text())["offers"]
check("a grantable card is offered", len(offers) == 1 and offers[0]["session"] == "y1" and offers[0]["turn"] == "t1"
      and offers[0]["grant"]["tools"] == ["fake_edit"])
check("keyed by the card's exact text", offers[0]["digest"] == hashlib.sha256(card["message"].encode()).hexdigest())
check("offers are private", stat.S_IMODE((DAISY / "grant-offers.json").stat().st_mode) == 0o600)
ask("fake_send", {}, session="y1")
ask("fake_click", {"app": "Pages", "label": "Send"}, session="y1")
ask("approval_grant", {"what": "x", "tools": ["fake_edit"]}, session="y1")
check("sends, risky clicks and grant cards aren't",
      len(json.loads((DAISY / "grant-offers.json").read_text())["offers"]) == 1)
offer = offers[0]
write_grants([{"id": "g-card", "what": "Yes to all like this", "duration": "request", "session": offer["session"],
               "turn": offer["turn"], "given": time.time(), "expires": time.time() + 3600, "by": "card",
               **offer["grant"]}])
check("the app's grant covers the rest of that request", runs("fake_edit", {"name": "Next", "text": "y"}, "y1", "t1"))
check("and ends with it", carded("fake_edit", EDIT, "y1", "t2"))

# The model can't write a grant itself

reset()
target = f"{HOME}/daisy/grants.json"
check("not with the shell", blocked("terminal", {"command": f"echo '{{}}' > {target}"}, "m1"))
check("not through $HERMES_HOME", blocked("terminal", {"command": "sed -i '' s/a/b/ ${HERMES_HOME}/daisy/grants.json"}, "m1"))
check("not with code", blocked("execute_code", {"code": f"open({target!r}, 'w').write('{{}}')"}, "m1"))
check("not with write_file", blocked("write_file", {"path": target, "content": "{}"}, "m1"))
check("not with patch", blocked("patch", {"path": target, "old": "a", "new": "b"}, "m1"))
check("nothing got written", on_file() == [])

# Scripts: the ones the user named, as they are now

reset()
tools_dir = WORK / "tools"
tools_dir.mkdir()
(tools_dir / "fix.py").write_text("import helper\nhelper.fix()\n")
(tools_dir / "helper.py").write_text("def fix():\n    pass\n")
(tools_dir / "notes.txt").write_text("not a script")
other = WORK / "elsewhere.py"
other.write_text("print('hi')\n")
fix = f"python3 {tools_dir}/fix.py"
check("a script is a card without a grant", carded("terminal", {"command": fix}, "p1"))
check("scripts need a full path", refused({"what": "x", "scripts": "tools"}, "full path"))
check("not a whole home folder", refused({"what": "x", "scripts": os.path.expanduser("~")}, "too broad"))
check("not Daisy's settings", refused({"what": "x", "scripts": str(DAISY)}, "Daisy's own settings"))
check("a folder with no scripts is refused", refused({"what": "x", "scripts": str(WORK / "empty-nope")}, "no file or folder"))
scripts_card = ask("approval_grant", {"what": "run my tools scripts", "scripts": str(tools_dir)}, session="p0")
check("the scripts card says as they are now", f"Run the scripts in {tools_dir}, as they are now (2 files)" in scripts_card["message"]
      and scripts_card["message"].startswith(f"Let Daisy run the scripts in {tools_dir} without asking"))
grant({"what": "run my tools scripts", "scripts": str(tools_dir)}, "p1")
check("the grant pins the scripts, not the notes", sorted(on_file()[0]["pins"]) == [str(tools_dir / "fix.py"), str(tools_dir / "helper.py")])
check("a granted script runs", runs("terminal", {"command": fix}, "p1"))
check("with a relative path and a workdir", runs("terminal", {"command": "python3 fix.py", "workdir": str(tools_dir)}, "p1"))
check("not a relative path without one", carded("terminal", {"command": "python3 fix.py"}, "p1"))
check("not with its output sent somewhere", carded("terminal", {"command": fix + " > out.txt"}, "p1"))
check("not a script outside the folder", carded("terminal", {"command": f"python3 {other}"}, "p1"))
check("not when chained", not runs("terminal", {"command": fix + " && rm x"}, "p1"))
(tools_dir / "notes.txt").write_text("changed notes")
check("data next to it can change", runs("terminal", {"command": fix}, "p1"))
(tools_dir / "helper.py").write_text("import smtplib\n")
check("a changed helper next to it asks again", carded("terminal", {"command": fix}, "p1"))
(tools_dir / "helper.py").write_text("def fix():\n    pass\n")
check("back as it was, it runs", runs("terminal", {"command": fix}, "p1"))
(tools_dir / "fix.py").write_text("import os\n")
check("a changed script asks again", carded("terminal", {"command": fix}, "p1"))
(tools_dir / "fix.py").write_text("import helper\nhelper.fix()\n")
(tools_dir / "new.py").write_text("print('new')\n")
check("a new script in the folder asks again", carded("terminal", {"command": fix}, "p1")
      and carded("terminal", {"command": f"python3 {tools_dir}/new.py"}, "p1"))
(tools_dir / "new.py").unlink()
check("gone again, it runs", runs("terminal", {"command": fix}, "p1"))
(tools_dir / "run.sh").write_text("#!/bin/sh\necho hi\n")
os.chmod(tools_dir / "run.sh", 0o700)
check("a new executable there asks too", carded("terminal", {"command": f"{tools_dir}/run.sh"}, "p1"))
grant({"what": "run my tools scripts", "scripts": str(tools_dir)}, "p3")
check("run by its path, once it was there for the grant", runs("terminal", {"command": f"{tools_dir}/run.sh"}, "p3"))
(tools_dir / "run.sh").unlink()

reset()
card = ask("terminal", {"command": fix}, session="p2")
offer = json.loads((DAISY / "grant-offers.json").read_text())["offers"][0]
check("a script card offers that one script, pinned",
      offer["grant"]["scripts"] == [str(tools_dir / "fix.py")] and str(tools_dir / "helper.py") in offer["grant"]["pins"])
write_grants([{"id": "g-s", "what": "Yes to all like this", "duration": "request", "session": "p2", "turn": "t1",
               "given": time.time(), "expires": time.time() + 60, "by": "card", **offer["grant"]}])
check("which then runs for the rest of the request", runs("terminal", {"command": fix}, "p2"))
check("only that script", carded("terminal", {"command": f"python3 {tools_dir}/helper.py"}, "p2"))

# MCP tools that only edit

reset()
grant({"what": "update my notion pages", "tools": ["mcp__notion__update_page"]}, "k1")
check("an edit MCP tool runs under its grant", runs("mcp__notion__update_page", {"page": "x"}, "k1"))
check("its delete sibling doesn't", carded("mcp__notion__delete_page", {"page": "x"}, "k1"))

# After reading outside content, the ask still shows what was read

reset()
ask("read_file", {"path": "/tmp/mail.txt"}, session="h1", turn="t1")
tainted = ask("approval_grant", {"what": "x", "tools": ["fake_edit"]}, session="h1", turn="t1")
check("a grant asked for after reading says so", "Heads up: this came after reading files" in tainted["message"])
DAISY.joinpath("roles.json").write_text(json.dumps({"version": 1, "sessions": {"job-2": "worker"}}))
check("a background job can't even ask", blocked("approval_grant", {"what": "x", "tools": ["fake_edit"]}, "job-2"))
os.environ["HERMES_SESSION_KEY"] = "job-2"
check("so there's nothing to turn on", "error" in json.loads(registry.handler_for(registry.get("approval_grant"))(
    {"what": "x", "tools": ["fake_edit"]})) and on_file() == [])
os.environ.pop("HERMES_SESSION_KEY", None)

print("grants checks:", "ok" if failures == 0 else f"{failures} failed")
sys.exit(1 if failures else 0)
