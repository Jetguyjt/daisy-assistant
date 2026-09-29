"""A tool can't loosen the guard by rewriting grants.json or cron-allow.json while it runs, however it
builds the path. Run: python3 hermes/test_daisy_sealed.py"""

import importlib.util
import json
import logging
import os
import sys
import tempfile
from pathlib import Path

HOME = Path(os.path.realpath(tempfile.mkdtemp(prefix="daisy-sealed-")))
os.environ["HERMES_HOME"] = str(HOME)
os.environ["DAISY_SESSION"] = "1"
logging.getLogger("daisy.guard").addHandler(logging.NullHandler())
logging.getLogger("daisy.guard").propagate = False

folder = Path(__file__).parent / "daisy"
spec = importlib.util.spec_from_file_location("daisy_plugin", folder / "__init__.py", submodule_search_locations=[str(folder)])
plugin = importlib.util.module_from_spec(spec)
sys.modules["daisy_plugin"] = plugin
spec.loader.exec_module(plugin)
sealed = sys.modules["daisy_plugin.guard.sealed"]

failures = 0


def check(label, condition):
    global failures
    if not condition:
        failures += 1
        print("FAIL", label)


GRANTS = HOME / "daisy" / "grants.json"
ALLOW = HOME / "daisy" / "cron-allow.json"
GRANTS.parent.mkdir(parents=True, exist_ok=True)
old = {"id": "g1", "duration": "request", "session": "s", "turn": "t", "expires": 9e12, "tools": ["docs_write"]}


def write(path, data):
    # The way code would: a path built at run time, a plain write.
    Path(os.path.join(os.environ["HERMES_HOME"], "dai" + "sy", path.name)).write_text(json.dumps(data))


def ids():
    return [g["id"] for g in json.loads(GRANTS.read_text())["grants"]]


write(GRANTS, {"version": 1, "grants": [old]})
sealed.around_tool("execute_code", {}, lambda: write(GRANTS, {"version": 1, "grants": [
    old, {"id": "evil", "duration": "forever", "tools": ["docs_write"]}]}))
check("a forever grant written by code is taken back out", ids() == ["g1"])

sealed.around_tool("terminal", {}, lambda: write(GRANTS, {"version": 1, "grants": [dict(old, tools=["docs_write", "sheets_write"])]}))
check("a grant widened by a tool is put back", json.loads(GRANTS.read_text())["grants"][0]["tools"] == ["docs_write"])

sealed.around_tool("execute_code", {}, lambda: write(GRANTS, {"version": 1, "grants": []}))
check("a removal stays removed", ids() == [])

app = {"id": "app1", "duration": "request", "session": "s", "turn": "t", "expires": 9e12, "tools": ["notes_append"]}
sealed.around_tool("write_file", {}, lambda: write(GRANTS, {"version": 1, "grants": [app]}))
check("a request grant landing mid-call (Yes to all) stays", ids() == ["app1"])

legit = {"id": "ok", "duration": "forever", "tools": ["docs_write"]}
sealed.around_tool("approval_grant", {}, lambda: write(GRANTS, {"version": 1, "grants": [app, legit]}))
check("approval_grant itself can add a forever grant", ids() == ["app1", "ok"])

result = sealed.around_tool("execute_code", {}, lambda: "tool output")
check("the tool's own result passes through", result == "tool output")

write(ALLOW, {"version": 1, "allow": [{"tool": "terminal", "command": "remindctl list"}]})
sealed.around_tool("execute_code", {}, lambda: write(ALLOW, {"version": 1, "allow": [
    {"tool": "terminal", "command": "remindctl list"}, {"tool": "gmail_send", "args": {"to": "x@example.com"}, "free": ["body"]}]}))
check("an entry added to cron-allow.json by a tool is taken out",
      json.loads(ALLOW.read_text())["allow"] == [{"tool": "terminal", "command": "remindctl list"}])

try:
    sealed.around_tool("execute_code", {}, lambda: (_ for _ in ()).throw(RuntimeError("tool broke")))
    check("a tool's own error still reaches Hermes", False)
except RuntimeError:
    pass

print("sealed checks:", "ok" if failures == 0 else f"{failures} failed")
sys.exit(1 if failures else 0)
