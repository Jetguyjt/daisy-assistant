"""The learned log: each memory write Hermes makes gets one line saying what changed and who did it.
Run: python3 hermes/test_daisy_learned.py"""

import importlib.util
import json
import logging
import os
import shutil
import stat
import sys
import tempfile
import types
from pathlib import Path

HOME = Path(tempfile.mkdtemp(prefix="daisy-learned-"))
os.environ["HERMES_HOME"] = str(HOME)
os.environ["DAISY_SESSION"] = "1"
for name in ("HERMES_CRON_SESSION", "HERMES_SESSION_PLATFORM", "HERMES_SESSION_KEY", "HERMES_YOLO_MODE"):
    os.environ.pop(name, None)


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
    if not condition:
        failures += 1
        print("FAIL", label)


plugin = load()
learned = importlib.import_module("daisy_plugin.learned")
MEMORIES = HOME / "memories"
MEMORIES.mkdir(parents=True)
USER = MEMORIES / "USER.md"
LOG = HOME / "daisy" / "learned.jsonl"

# Hermes sets the write origin per turn in tools.skill_provenance; this stands in for it.
provenance = types.ModuleType("tools.skill_provenance")
provenance.origin = "assistant_tool"
provenance.get_current_write_origin = lambda: provenance.origin
sys.modules.setdefault("tools", types.ModuleType("tools"))
sys.modules["tools.skill_provenance"] = provenance


def write_user(entries):
    USER.write_text("\n§\n".join(entries), encoding="utf-8")


def user_entries():
    return learned.entries(USER.read_text(encoding="utf-8")) if USER.exists() else []


class Store:
    """What Hermes's MemoryStore does to USER.md for each action (tools/memory_tool_store.py)."""

    def __init__(self, also=None):
        self.also = also  # a write from somewhere else that lands during the call

    def __call__(self, args):
        if self.also:
            self.also()
        entries = user_entries()
        ops = args.get("operations") or [args]
        for op in ops:
            action = op.get("action")
            content = (op.get("content") or op.get("new_text") or "").strip()
            old = (op.get("old_text") or "").strip()
            if action == "add":
                if content in entries:
                    if not args.get("operations"):
                        return json.dumps({"success": True, "message": "Entry already exists (no duplicate added)."})
                    continue
                entries.append(content)
            else:
                hits = [i for i, e in enumerate(entries) if old in e]
                if len({entries[i] for i in hits}) != 1:
                    return json.dumps({"success": False, "error": f"No entry matched '{old}'."})
                if action == "replace":
                    entries[hits[0]] = content
                else:
                    del entries[hits[0]]
        write_user(entries)
        return json.dumps({"success": True, "done": True, "target": "user", "message": "Entry added."})


def call(args, store=None, tool="memory", **context):
    calls = []

    def next_call(payload=None):
        calls.append(payload)
        return (store or Store())(args)

    context.setdefault("session_id", "s-1")
    context.setdefault("tool_call_id", "call-1")
    result = learned.around_tool(tool_name=tool, args=args, next_call=next_call, original_args=args, **context)
    check(f"{tool} call goes through exactly once", len(calls) == 1)
    return result


def lines():
    return [json.loads(line) for line in LOG.read_text(encoding="utf-8").splitlines()] if LOG.exists() else []


# Registration: one middleware, around every tool call.
class Context:
    def __init__(self):
        self.middleware = []

    def register_middleware(self, kind, callback):
        self.middleware.append((kind, callback))


ctx = Context()
learned.register(ctx)
check("registers tool_execution middleware", ctx.middleware == [("tool_execution", learned.around_tool)])
logging.getLogger("daisy.learned").disabled = True
try:
    learned.register(object())  # a Hermes without middleware
except Exception:
    check("an older Hermes doesn't break the plugin's registration", False)
logging.getLogger("daisy.learned").disabled = False

write_user(["Josh is in high school", "Uses Outlook for mail"])

# A write in the conversation.
result = call({"action": "add", "target": "user", "content": "  Prefers short answers  "})
check("the result comes back unchanged", json.loads(result)["success"] is True)
first = lines()
check("one line per write", len(first) == 1)
check("the line says what was added, where, and by whom",
      first and first[0]["action"] == "add" and first[0]["entry"] == "Prefers short answers"
      and first[0]["target"] == "user" and first[0]["file"] == "USER.md" and first[0]["origin"] == "assistant_tool"
      and first[0]["session"] == "s-1" and first[0]["call"] == "call-1" and first[0]["v"] == 1)
check("the log is private", stat.S_IMODE(LOG.stat().st_mode) == 0o600)

# Hermes's review changes something on its own: the whole old entry is kept for Undo.
provenance.origin = "background_review"
call({"action": "replace", "target": "user", "old_text": "Outlook", "content": "Uses Gmail for mail"}, tool_call_id="call-2")
replace = lines()[-1]
check("a review write is marked as the review's", replace["origin"] == "background_review")
check("a replace keeps the whole entry it took out", replace["was"] == "Uses Outlook for mail"
      and replace["old_text"] == "Outlook" and replace["entry"] == "Uses Gmail for mail")

call({"action": "remove", "target": "user", "old_text": "high school"}, tool_call_id="call-3")
remove = lines()[-1]
check("a remove keeps the whole entry", remove["action"] == "remove" and remove["was"] == "Josh is in high school"
      and "entry" not in remove)

# A batch: one line per operation, in order, with its position.
before = len(lines())
call({"target": "user", "operations": [
    {"action": "add", "content": "Has a sister named Priya"},
    {"action": "replace", "old_text": "short answers", "new_text": "Prefers short, direct answers"},
    {"action": "add", "content": "Uses Gmail for mail"}]}, tool_call_id="call-4")
batch = lines()[before:]
check("a batch logs each change, skipping adds that were already there",
      [(line["action"], line["op"]) for line in batch] == [("add", 0), ("replace", 1)])
check("batch lines share the call", {line["call"] for line in batch} == {"call-4"})
check("a batch replace written as new_text is still found", batch[1]["entry"] == "Prefers short, direct answers"
      and batch[1]["was"] == "Prefers short answers")

# Nothing is logged for writes that didn't happen.
count = len(lines())
call({"action": "add", "target": "user", "content": "Has a sister named Priya"})
check("adding an entry that's already there isn't a change", len(lines()) == count)
call({"action": "remove", "target": "user", "old_text": "no such thing"})
check("a failed write isn't logged", len(lines()) == count)


def staged(args):
    return json.dumps({"success": True, "staged": True, "pending_id": "p1", "message": "Staged for approval"})


call({"action": "add", "target": "user", "content": "Waiting on approval"}, store=staged)
check("a staged write isn't logged", len(lines()) == count)
call({"action": "add", "target": "user", "content": "Refused"},
     store=lambda args: json.dumps({"error": "Blocked by Daisy's guard: nobody can approve it."}))
check("a blocked write isn't logged", len(lines()) == count)
call({"action": "add", "target": "nowhere", "content": "Bad target"}, store=lambda args: json.dumps({"success": True}))
check("an unknown target isn't logged", len(lines()) == count)

# Something else writes during the call: the change is still logged, but which entry went can't be
# known for sure, so "was" is left out. Another program changing a different entry shows up when the
# replay doesn't match the file...
write_user(["Likes tea", "Plays tennis"])
elsewhere = Store(also=lambda: write_user(["Likes tea", "Plays tennis", "Added by hand"]))
call({"action": "replace", "target": "user", "old_text": "tea", "content": "Likes coffee"}, store=elsewhere)
raced = lines()[-1]
check("a replace raced by another program is logged without a guess", raced["entry"] == "Likes coffee" and "was" not in raced)

# ...and another memory call in this process (the review runs next to the conversation) by overlap.
write_user(["Likes tea", "Plays tennis"])
provenance.origin = "assistant_tool"
review = Store(also=lambda: call({"action": "replace", "target": "user", "old_text": "tea", "content": "Likes green tea"},
                                 tool_call_id="call-inner"))
count = len(lines())
call({"action": "replace", "target": "user", "old_text": "green tea", "content": "Likes coffee"}, store=review,
     tool_call_id="call-outer")
overlapped = lines()[count:]
check("both overlapping writes are logged", [line["call"] for line in overlapped] == ["call-inner", "call-outer"])
check("overlapping writes don't guess the old entry", all("was" not in line for line in overlapped))
call({"action": "replace", "target": "user", "old_text": "coffee", "content": "Likes cocoa"}, tool_call_id="call-after")
check("the next write on its own is exact again", lines()[-1]["was"] == "Likes coffee")

# Other tools go straight through, untouched and unlogged.
count = len(lines())
result = call({"command": "ls"}, store=lambda args: "listing", tool="terminal")
check("other tools pass through", result == "listing" and len(lines()) == count)

# The tool's own errors pass through as themselves; the log never adds one.
try:
    learned.around_tool(tool_name="memory", args={"action": "add", "target": "user", "content": "x"},
                        next_call=lambda payload=None: (_ for _ in ()).throw(RuntimeError("disk full")))
    check("a failing write raises", False)
except RuntimeError as error:
    check("the tool's error is the one raised", str(error) == "disk full")
check("a failing write isn't logged", len(lines()) == count)

# A broken log never breaks the write.
saved_home = os.environ["HERMES_HOME"]
blocked_home = Path(tempfile.mkdtemp(prefix="daisy-learned-broken-"))
(blocked_home / "memories").mkdir()
(blocked_home / "daisy").write_text("a file where the folder should be")
os.environ["HERMES_HOME"] = str(blocked_home)
result = learned.around_tool(tool_name="memory", args={"action": "add", "target": "user", "content": "Still saved"},
                             next_call=lambda payload=None: json.dumps({"success": True}))
check("a log that can't be written doesn't stop the write", json.loads(result) == {"success": True})
os.environ["HERMES_HOME"] = saved_home

# Without Hermes's provenance module the origin is unknown, not a guess.
del sys.modules["tools.skill_provenance"]
call({"action": "add", "target": "user", "content": "Origin unknown"})
check("no provenance means unknown", lines()[-1]["origin"] == "unknown")
sys.modules["tools.skill_provenance"] = provenance

# The file is cut back to its newest lines, every one still whole JSON.
learned.MAX_BYTES = 2_000
for number in range(40):
    call({"action": "add", "target": "user", "content": f"Filler fact number {number}"})
kept = LOG.read_text(encoding="utf-8").splitlines()
check("the log stays under its cap", LOG.stat().st_size <= learned.MAX_BYTES)
check("the newest lines are kept", json.loads(kept[-1])["entry"] == "Filler fact number 39")
check("every kept line is whole", all(json.loads(line)["v"] == 1 for line in kept))
check("no temporary files are left", not [p for p in LOG.parent.iterdir() if p.name.endswith(".tmp")])
check("the log is still private after a trim", stat.S_IMODE(LOG.stat().st_mode) == 0o600)

# The agent can't edit the log from a chat: the guard refuses shell and file writes there.
for command in ("echo '{}' >> ~/.hermes/daisy/learned.jsonl", "rm $HERMES_HOME/daisy/learned.jsonl"):
    verdict = plugin.classify("terminal", {"command": command})
    check(f"the guard refuses {command!r}", verdict.decision == "block")
check("write_file can't reach the log", plugin.classify("write_file", {"path": "~/.hermes/daisy/learned.jsonl"}).decision == "block")
policy = importlib.import_module("daisy_plugin.guard.policy")
blocked = policy.decide("terminal", {"command": "echo '{}' >> ~/.hermes/daisy/learned.jsonl"}, session_id="g-1", task_id="g-1", turn_id="t1")
check("the guard's decision on a shell write to the log is a block", blocked and blocked["action"] == "block")
check("memory writes themselves are judged as before: no card in a plain chat",
      policy.decide("memory", {"action": "add", "target": "user", "content": "Likes jazz"}, session_id="g-2", task_id="g-2", turn_id="t1") is None)

shutil.rmtree(HOME, ignore_errors=True)
shutil.rmtree(blocked_home, ignore_errors=True)
print("learned checks:", "ok" if failures == 0 else f"{failures} failed")
sys.exit(1 if failures else 0)
