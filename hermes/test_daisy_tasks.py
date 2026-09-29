"""Tasks tools: statuses, the shared tasks.json (lock, re-read, atomic write), cards, how the guard treats
them, and the todo_list import. Everything runs on temp files; nothing touches the real task list.
Run: python3 hermes/test_daisy_tasks.py"""

import importlib
import importlib.util
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).parent
FIXTURES = HERE / "fixtures" / "tasks"
SCRIPT = HERE.parent / "scripts" / "import-hermes-todos.py"
WORK = Path(tempfile.mkdtemp(prefix="daisy-tasks-"))
TASKS = WORK / "data" / "tasks.json"
os.environ["HERMES_HOME"] = str(WORK / "home")
os.environ["DAISY_TASKS_FILE"] = str(TASKS)
os.environ["DAISY_SESSION"] = "1"
for name in ("HERMES_CRON_SESSION", "HERMES_SESSION_PLATFORM", "HERMES_SESSION_KEY", "HERMES_SINGLE_QUERY_SESSION",
             "HERMES_YOLO_MODE"):
    os.environ.pop(name, None)


def load():
    for name in [n for n in sys.modules if n == "daisy_plugin" or n.startswith("daisy_plugin.")]:
        del sys.modules[name]
    folder = HERE / "daisy"
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
registry = plugin.registry
tasks = importlib.import_module("daisy_plugin.tools.tasks")
policy = importlib.import_module("daisy_plugin.guard.policy")
listing, adding, updating, removing = (registry.get(name) for name in ("tasks_list", "tasks_add", "tasks_update", "tasks_remove"))


def run(tool, args):
    return json.loads(registry.handler_for(tool)(args))


def checked(tool, args):
    """What Hermes does: the guard checks the call (and notes its plan), then the tool runs."""
    tool.card(args)
    return run(tool, args)


def stored():
    return json.loads(TASKS.read_text())


def fresh(content=None):
    for path in (TASKS, Path(str(TASKS) + ".lock")):
        if path.exists():
            path.unlink()
    if content is not None:
        TASKS.parent.mkdir(parents=True, exist_ok=True)
        TASKS.write_text(content)


def titled(title):
    return next(item for item in tasks.load() if item["title"] == title)


# Statuses: the same cases the app's tests use.
cases = json.loads((FIXTURES / "status-cases.json").read_text())["cases"]
for case in cases:
    got = tasks.read_status(case["text"])
    check(f"status {case['text']!r} -> {got}", got == (case["status"], case.get("leftover")))
check("nine statuses with names", [name for _, name in tasks.STATUSES] ==
      ["Idea", "To do", "In progress", "Needs review", "Waiting", "Blocked", "Submitted", "Done", "Dropped"])
check("submitted, done and dropped are finished", set(tasks.FINISHED) == {"submitted", "done", "dropped"})
check("open is everything else", [s for s, _ in tasks.STATUSES if tasks.is_open({"status": s})] ==
      ["idea", "todo", "in_progress", "needs_review", "waiting", "blocked"])

# Reading files: old ones, hand-edited ones and the app's own come through without losing a task.
legacy = tasks.load(FIXTURES / "legacy-tasks.json")
check("legacy statuses map across", [i["status"] for i in legacy] == ["todo", "in_progress", "done"])
check("legacy tasks have no parent", all(i["parent"] is None for i in legacy))
expected = json.loads((FIXTURES / "odd-tasks-expected.json").read_text())["tasks"]
odd = [{key: item[key] for key in expected[0]} for item in tasks.load(FIXTURES / "odd-tasks.json")]
check("odd file reads exactly as the app reads it", odd == expected)
check("unknown status text is kept in the notes", odd[0]["notes"].endswith("Status: almost there"))
app = tasks.load(FIXTURES / "app-written.json")
check("the app's file reads", [(i["title"], i["status"], i["order"]) for i in app] ==
      [("Harvard", "todo", 1), ("Why Harvard", "needs_review", 2), ("Old idea", "dropped", 3)])
check("the app's parents line up", app[1]["parent"] == app[0]["id"])
check("stable ids match the app's", tasks.stable_id("school-list") == "5889073B-27DB-5E8C-B26D-1FFA513015B2"
      and tasks.stable_id("c3d4e5f6-a7b8-4c9d-8e0f-1a2b3c4d5e6f") == "C3D4E5F6-A7B8-4C9D-8E0F-1A2B3C4D5E6F")
index = tasks.Index(tasks.load(FIXTURES / "odd-tasks.json"))
tops = [item["title"] for _, item in index.tree() if index.parent[item["id"]] is None]
check("loops and lost parents end up top-level", {"Loop A", "Loop B", "Lost subtask"} <= set(tops))
check("real nesting stays", index.under(next(i for i in index.items if i["title"] == "Reach schools")) == "Finalize the school list")

# The tools.
check("four tools", all((listing, adding, updating, removing)))
check("risks", (listing.risk, adding.risk, updating.risk, removing.risk) == ("read", "own", "own", "delete"))
check("they work before the file exists", all(tool.check() for tool in (listing, adding, updating, removing)))
recorder_tools = []


class Recorder:
    def register_system_prompt_section(self, *a, **k):
        pass

    def register_hook(self, *a, **k):
        pass

    def register_middleware(self, *a, **k):
        pass

    def register_tool(self, name, toolset, schema, handler, **kwargs):
        recorder_tools.append(name)


plugin.register(Recorder())
check("they register in Daisy sessions", {"tasks_list", "tasks_add", "tasks_update", "tasks_remove"} <= set(recorder_tools))
check("the status enum is the nine ids", adding.parameters["properties"]["tasks"]["items"]["properties"]["status"]["enum"]
      == [s for s, _ in tasks.STATUSES])

# Adding a list, nested, in one call.
fresh()
essays = {"tasks": [
    {"title": "Harvard", "project": "College Applications"},
    {"title": "Why Harvard", "parent": "Harvard", "status": "needs_review", "due": "2026-11-01", "notes": "150 words.\nAbout a hobby."},
    {"title": "Intellectual experience", "parent": "Harvard"},
    {"title": "Yale", "project": "College Applications", "status": "In progress"},
    {"title": "Yale short takes", "parent": "Yale", "status": "needs to get started"},
    {"title": "Return library books"}]}
card = adding.card(essays)
check("the card counts the tasks", card.startswith("Add 6 tasks\n"))
check("the card nests subtasks and shows everything", "• Harvard — To do · College Applications" in card
      and "    • Why Harvard — Needs review · due 2026-11-01" in card and "About a hobby." in card
      and "    • Yale short takes — To do" in card and "• Return library books — To do" in card)
check("checking writes nothing", not TASKS.exists())
result = run(adding, essays)
check("added all six", len(result["added"]) == 6 and result["open"] == 6)
saved = stored()
check("the file is a list, 0600", isinstance(saved, list) and (TASKS.stat().st_mode & 0o777) == 0o600)
check("the lock file is 0600", (Path(str(TASKS) + ".lock").stat().st_mode & 0o777) == 0o600)
by_title = {item["title"]: item for item in saved}
check("subtasks point at their parent", by_title["Why Harvard"]["parent"] == by_title["Harvard"]["id"]
      and by_title["Yale short takes"]["parent"] == by_title["Yale"]["id"])
check("subtasks take the parent's project", by_title["Why Harvard"]["project"] == "College Applications")
check("statuses are stored as ids", [i["status"] for i in saved] == ["todo", "needs_review", "todo", "in_progress", "todo", "todo"])
check("order follows the call", [i["order"] for i in saved] == [1, 2, 3, 4, 5, 6])
check("new tasks start at revision 1 with a timestamp", all(i["revision"] == 1 and i["updatedAt"].endswith("Z") for i in saved))
check("top-level tasks have no parent key", "parent" not in by_title["Return library books"])
check("running the same list again adds nothing", checked(adding, essays)["added"] == []
      and len(stored()) == 6)
again = adding.card({"tasks": [{"title": "Harvard", "project": "College Applications"}, {"title": "Harvard supplement", "parent": "Harvard"}]})
check("an existing parent is used, not added again", again.startswith("Add a task: Harvard supplement")
      and "Already on the list, not added again: Harvard" in again)
one = checked(adding, {"tasks": [{"title": "Why Yale", "parent": "Yale", "notes": "Keep it short"}]})
check("a parent already on the list, by title", titled("Why Yale")["parent"] == by_title["Yale"]["id"])
check("later tasks go last", titled("Why Yale")["order"] == 7 and one["added"][0]["status"] == "To do")
checked(adding, {"tasks": [{"title": "Scholarship essay", "status": "almost there"}]})
check("a status that isn't one becomes To do, the text kept", titled("Scholarship essay")["status"] == "todo"
      and titled("Scholarship essay")["notes"] == "Status: almost there")
checked(adding, {"title": "One-off", "due": "2026-10-02"})
check("a single task without a list works", titled("One-off")["due"] == "2026-10-02")


def refused(tool, args, words):
    try:
        tool.card(args)
    except registry.Refused as refusal:
        return words in str(refusal)
    return False


check("a bad date is refused", refused(adding, {"tasks": [{"title": "X", "due": "2026-02-30"}]}, "isn't a due date"))
check("a missing parent is refused", refused(adding, {"tasks": [{"title": "X", "parent": "Princeton"}]}, "no task called “Princeton”"))
check("a loop in one call is refused", refused(adding, {"tasks": [{"title": "A", "parent": "B"}, {"title": "B", "parent": "A"}]},
                                             "ends up under itself"))
check("an empty title is refused", refused(adding, {"tasks": [{"title": "  "}]}, "title"))
check("too many at once is refused", refused(adding, {"tasks": [{"title": f"T{n}"} for n in range(201)]}, "up to 200"))

# Updating.
change = {"changes": [{"task": "Why Harvard", "status": "done"}, {"task": "Yale short takes", "due": "2026-11-15",
                                                                   "add_note": "Ask Ms. Lee"}]}
card = updating.card(change)
check("the update card shows each change", card.startswith("Update 2 tasks\n") and "• Why Harvard (under Harvard)" in card
      and "Status: Needs review → Done" in card and "Due: none → “2026-11-15”" in card and "Ask Ms. Lee" in card)
before = titled("Why Harvard")["revision"]
result = run(updating, change)
check("updated both", [u["title"] for u in result["updated"]] == ["Why Harvard", "Yale short takes"])
check("status changed and revision bumped", titled("Why Harvard")["status"] == "done" and titled("Why Harvard")["revision"] == before + 1)
check("add_note keeps what was there", titled("Yale short takes")["notes"] == "Ask Ms. Lee")
checked(updating, {"changes": [{"task": titled("Why Yale")["id"], "add_note": "Under 200 words"}]})
check("an id works too, notes appended", titled("Why Yale")["notes"] == "Keep it short\n\nUnder 200 words")
checked(updating, {"changes": [{"task": titled("Yale")["id"][:8], "status": "Needs review"}]})
check("the start of an id works, names work", titled("Yale")["status"] == "needs_review")
checked(updating, {"changes": [{"task": "Yale", "project": "Colleges"}]})
check("a project move takes the subtasks along", {titled(t)["project"] for t in ("Yale", "Yale short takes", "Why Yale")} == {"Colleges"})
checked(updating, {"changes": [{"task": "Return library books", "parent": "Harvard"}]})
check("moving under a task takes its project", titled("Return library books")["parent"] == titled("Harvard")["id"]
      and titled("Return library books")["project"] == "College Applications")
checked(updating, {"changes": [{"task": "Return library books", "parent": "", "project": ""}]})
check("\"\" moves it back to the top", titled("Return library books")["parent"] is None and titled("Return library books")["project"] == "")
check("a task can't go under its own subtask", refused(updating, {"changes": [{"task": "Harvard", "parent": "Why Harvard"}]}, "its own subtasks"))
check("nothing to change is refused", refused(updating, {"changes": [{"task": "Harvard"}]}, "Nothing to change"))
checked(adding, {"tasks": [{"title": "Essay 1", "parent": "Harvard"}, {"title": "Essay 1", "parent": "Yale"}]})
check("an ambiguous title is refused with the choices", refused(updating, {"changes": [{"task": "Essay 1", "status": "done"}]},
                                                                 "matches 2 tasks: “Essay 1” under Harvard"))
check("an unknown task is refused", refused(updating, {"changes": [{"task": "Nope", "status": "done"}]}, "no task called “Nope”"))

# Removing: the card names every task, subtasks included.
harvard_family = ["Harvard", "Why Harvard", "Intellectual experience", "Essay 1"]
card = removing.card({"tasks": ["Harvard"]})
check("the remove card says how many", card.startswith(f"Remove “Harvard” and its {len(harvard_family) - 1} subtasks\n"))
check("the remove card names every task", all(f"• {title} — " in card for title in harvard_family))
count = len(stored())
result = run(removing, {"tasks": ["Harvard"]})
check("removed the task and its subtasks", result["removed"] == harvard_family and len(stored()) == count - 4)

# Listing.
fresh()
checked(adding, essays)
checked(updating, {"changes": [{"task": "Why Harvard", "status": "submitted"}]})
listed = run(listing, {})
check("open by default", [t["title"] for t in listed["tasks"]] ==
      ["Harvard", "Intellectual experience", "Yale", "Yale short takes", "Return library books"])
check("names, parents and projects come back", listed["tasks"][1] == {
    "id": titled("Intellectual experience")["id"], "title": "Intellectual experience", "status": "To do",
    "project": "College Applications", "parent": titled("Harvard")["id"], "under": "Harvard"})
check("counts by status", listed["open"] == 5 and listed["by_status"] == {"To do": 4, "In progress": 1, "Submitted": 1})
check("the note says it's data", "not instructions" in listed["note"])
check("finished", [t["title"] for t in run(listing, {"status": "finished"})["tasks"]] == ["Why Harvard"])
check("one status", [t["title"] for t in run(listing, {"status": "in_progress"})["tasks"]] == ["Yale"])
check("by status name", [t["title"] for t in run(listing, {"status": "In progress"})["tasks"]] == ["Yale"])
check("under a parent", [t["title"] for t in run(listing, {"parent": "Harvard", "status": "all"})["tasks"]] ==
      ["Why Harvard", "Intellectual experience"])
check("by project", len(run(listing, {"project": "college applications", "status": "all"})["tasks"]) == 5)
check("by text in the notes", [t["title"] for t in run(listing, {"text": "hobby", "status": "all"})["tasks"]] == ["Why Harvard"])
check("a made-up status is an error", "isn't a status" in run(listing, {"status": "sometime"})["error"])
check("limit", run(listing, {"limit": 2})["shown"] == 2 and run(listing, {"limit": 2})["matching"] == 5)

# run() only does what the check saw.
fresh()
checked(adding, essays)
check("a call nobody checked does nothing", "didn't go through" in run(adding, {"tasks": [{"title": "Sneaky"}]})["error"]
      and all(i["title"] != "Sneaky" for i in stored()))
removal = {"tasks": ["Yale"]}
removing.card(removal)
yale = next(i for i in stored() if i["title"] == "Yale")
raw = stored()
next(i for i in raw if i["title"] == "Yale")["status"] = "done"
next(i for i in raw if i["title"] == "Yale")["revision"] += 1
TASKS.write_text(json.dumps(raw))
check("a list that changed after the card isn't touched", "changed after" in run(removing, removal)["error"]
      and any(i["title"] == "Yale" for i in stored()))

# Tasks the tools don't touch are written back exactly as they were.
fresh((FIXTURES / "legacy-tasks.json").read_text())
original = stored()
checked(adding, {"tasks": [{"title": "New one"}]})
after = stored()
check("untouched old tasks stay byte for byte", after[:3] == original and after[3]["title"] == "New one")
check("new tasks go after the old order", after[3]["order"] == 1)
checked(updating, {"changes": [{"task": "Outline the physics lab report", "status": "in_progress"}]})
changed = stored()[0]
check("a touched old task is written in the new form", changed["status"] == "in_progress" and changed["revision"] == 2
      and isinstance(changed["updatedAt"], str) and changed["order"] == 0)
check("the others still aren't touched", stored()[1:3] == original[1:3])

# A file that can't be read is never written over.
fresh("{not json")
check("a broken file is refused", refused(adding, {"tasks": [{"title": "X"}]}, "isn't valid JSON"))
check("and left alone", TASKS.read_text() == "{not json")
check("listing says so", "isn't valid JSON" in run(listing, {})["error"])

# Two writers: the lock, and reading again inside it.
fresh()
holder = subprocess.Popen([sys.executable, "-c", (
    "import fcntl, os, sys, time\n"
    "fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)\n"
    "fcntl.flock(fd, fcntl.LOCK_EX)\n"
    "open(sys.argv[2], 'w').write('[{\"id\": \"8C1F6E2A-1D3B-4C5D-9E7F-0A1B2C3D4E5F\", \"title\": \"From the app\", \"status\": \"todo\", \"revision\": 1, \"order\": 1}]')\n"
    "print('locked', flush=True)\n"
    "time.sleep(float(sys.argv[3]))\n"), str(TASKS) + ".lock", str(TASKS), "0.6"], stdout=subprocess.PIPE, text=True)
check("the other writer has the lock", holder.stdout.readline().strip() == "locked")
started = time.monotonic()
result = checked(adding, {"tasks": [{"title": "From Hermes"}]})
waited = time.monotonic() - started
holder.wait()
check("the plugin waits for the lock", waited >= 0.3 and len(result["added"]) == 1)
check("and keeps the other writer's task", [i["title"] for i in stored()] == ["From the app", "From Hermes"])
check("after the other writer's order", stored()[1]["order"] == 2)
holder = subprocess.Popen([sys.executable, "-c", (
    "import fcntl, os, sys, time\n"
    "fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)\n"
    "fcntl.flock(fd, fcntl.LOCK_EX)\n"
    "print('locked', flush=True)\n"
    "time.sleep(2)\n"), str(TASKS) + ".lock"], stdout=subprocess.PIPE, text=True)
holder.stdout.readline()
tasks.LOCK_WAIT, wait = 0.2, tasks.LOCK_WAIT
busy = checked(adding, {"tasks": [{"title": "Too soon"}]})
tasks.LOCK_WAIT = wait
holder.kill()
holder.wait()
check("a lock that stays busy is an error, not a write", "busy" in busy.get("error", "") and len(stored()) == 2)
fresh()
errors = []


def writer(n):
    try:
        for k in range(5):
            checked(adding, {"tasks": [{"title": f"Writer {n} task {k}"}]})
    except Exception as error:  # noqa: BLE001
        errors.append(error)


threads = [threading.Thread(target=writer, args=(n,)) for n in range(4)]
for thread in threads:
    thread.start()
for thread in threads:
    thread.join()
final = stored()
check("four writers at once lose nothing", not errors and len(final) == 20 and len({i["id"] for i in final}) == 20)
check("orders stay unique", sorted(i["order"] for i in final) == list(range(1, 21)))
leftovers = [p.name for p in TASKS.parent.iterdir() if p.name.endswith(".tmp")]
check("no temp files left behind", leftovers == [])

# The guard: tasks_add runs without a card in a clean turn, is carded after an outside read, never runs
# from cron or a background job; tasks_remove always shows a card; tasks_list doesn't taint.
fresh()
turn = dict(session_id="tasks-a", task_id="tasks-a", turn_id="t1")
adds = {"tasks": [{"title": "Draft the Common App essay", "status": "in_progress"}]}
check("tasks_list runs", policy.decide("tasks_list", {}, **turn) is None)
check("tasks_add runs with no card in a clean turn", policy.decide("tasks_add", adds, **turn) is None)
check("and then does it", run(adding, adds)["added"][0]["title"] == "Draft the Common App essay")
check("tasks_update runs with no card too", policy.decide("tasks_update", {"changes": [{"task": "Draft the Common App essay", "status": "done"}]}, **turn) is None)
check("tasks_remove always shows a card", (policy.decide("tasks_remove", {"tasks": ["Draft the Common App essay"]}, **turn) or {}).get("action") == "approve")
remove_card = policy.decide("tasks_remove", {"tasks": ["Draft the Common App essay"]}, **turn)
check("the remove card names the task", "Remove “Draft the Common App essay”" in remove_card["message"]
      and "• Draft the Common App essay — " in remove_card["message"])
tainted = dict(session_id="tasks-b", task_id="tasks-b", turn_id="t1")
check("reading email is a read", policy.decide("gmail_search", {"query": "deadlines"}, **tainted) is None)
after_mail = policy.decide("tasks_add", {"tasks": [{"title": "Reply to the admissions office"}]}, **tainted)
check("tasks_add after reading email shows a card", (after_mail or {}).get("action") == "approve"
      and "Heads up: this came after reading email" in after_mail["message"]
      and "Add a task: Reply to the admissions office" in after_mail["message"])
check("a new turn is clean again", policy.decide("tasks_add", {"tasks": [{"title": "Later"}]}, **dict(tainted, turn_id="t2")) is None)
listed_first = dict(session_id="tasks-c", task_id="tasks-c", turn_id="t1")
policy.decide("tasks_list", {}, **listed_first)
check("reading the task list doesn't count as outside content", policy.decide("tasks_add", adds, **listed_first) is None)
cron = policy.decide("tasks_add", adds, task_id="cron:digest:1", session_id="cron:digest:1")
check("cron can't add tasks", (cron or {}).get("action") == "block")
roles = WORK / "home" / "daisy"
roles.mkdir(parents=True, exist_ok=True)
(roles / "roles.json").write_text(json.dumps({"version": 1, "sessions": {"worker-1": "worker"}}))
worker = policy.decide("tasks_add", adds, task_id="worker-1", session_id="worker-1")
check("background jobs can't add tasks", (worker or {}).get("action") == "block" and "background job" in worker["message"])
check("background jobs can read them", policy.decide("tasks_list", {}, task_id="worker-1", session_id="worker-1") is None)
ambiguous = policy.decide("tasks_update", {"changes": [{"task": "Nope", "status": "done"}]}, session_id="tasks-d", task_id="tasks-d")
check("a call that can't run is blocked with the reason", (ambiguous or {}).get("action") == "block"
      and "no task called “Nope”" in ambiguous["message"])

# The todo_list import.
todo = json.loads((FIXTURES / "todo-result.json").read_text())
importer_spec = importlib.util.spec_from_file_location("import_hermes_todos", SCRIPT)
importer = importlib.util.module_from_spec(importer_spec)
importer_spec.loader.exec_module(importer)
for content, todo_status, wanted in [
        ("Harbor 1-exciting topic — needs to get started", "pending", ("Harbor 1-exciting topic", "todo")),
        ("Northfield 1 Leadership — in progress", "pending", ("Northfield 1 Leadership", "in_progress")),
        ("Westbrook 1-leadership — needs review", "pending", ("Westbrook 1-leadership", "needs_review")),
        ("Harbor 2 - community — done", "completed", ("Harbor 2 - community", "done")),
        ("Ridgemont 2 — 150 words, about a hobby", "pending", ("Ridgemont 2 — 150 words, about a hobby", "todo")),
        ("Common App essay – submitted", "pending", ("Common App essay", "submitted")),
        ("Activities list", "completed", ("Activities list", "done")),
        ("Old plan", "cancelled", ("Old plan", "dropped")),
        ("Rec letters", "in_progress", ("Rec letters", "in_progress")),
        ("Plain", "pending", ("Plain", "todo"))]:
    got = importer.split_status(tasks, content, todo_status)
    check(f"import reads {content!r} as {got}", got == wanted)
for case in cases:
    if case["text"].strip() and "leftover" not in case:
        check(f"import uses the same rules for {case['text']!r}",
              importer.split_status(tasks, f"Essay — {case['text']}", "pending") == ("Essay", case["status"]))


def importing(*arguments, env=None):
    environment = dict(os.environ, DAISY_TASKS_FILE=str(WORK / "never-written.json"), **(env or {}))
    return subprocess.run([sys.executable, str(SCRIPT), *arguments], capture_output=True, text=True, env=environment)


target = WORK / "import" / "tasks.json"
dry = importing("--file", str(FIXTURES / "todo-result.json"), "--tasks-file", str(target), "--dry-run")
check("dry run works", dry.returncode == 0 and "Would add 20 tasks" in dry.stdout and "Dry run: nothing was written." in dry.stdout)
check("dry run shows the tree", "  • Northfield University — In progress" in dry.stdout
      and "      • Northfield 1 Leadership — In progress" in dry.stdout and "“College Applications” becomes the project" in dry.stdout)
check("dry run writes nothing", not target.exists() and not target.parent.exists())
real = importing("--file", str(FIXTURES / "todo-result.json"), "--tasks-file", str(target))
check("import works", real.returncode == 0 and "Added 20 tasks" in real.stdout)
imported = tasks.load(target)
named = {item["title"]: item for item in imported}
check("the project root isn't a task", "College Applications" not in named and len(imported) == 20)
check("its subtree gets the project", all(named[t]["project"] == "College Applications" for t in
                                          ("Northfield University", "Northfield 1 Leadership", "Personal statement", "Activities list")))
check("schools are top-level in the project", named["Harbor State"]["parent"] is None and named["Ridgemont"]["parent"] is None)
check("essays sit under their school", named["Northfield 1 Leadership"]["parent"] == named["Northfield University"]["id"]
      and named["Harbor 2 - community"]["parent"] == named["Harbor State"]["id"])
check("statuses come from the text", [named[t]["status"] for t in ("Northfield 1 Leadership", "Northfield 2 Creative side",
                                                                     "Lakeside short answers", "Harbor 2 - community",
                                                                     "Personal statement")]
      == ["in_progress", "todo", "needs_review", "done", "in_progress"])
check("else from the todo", [named[t]["status"] for t in ("Activities list", "Northfield University", "Ridgemont")]
      == ["done", "in_progress", "todo"])
check("text after the dash that isn't a status stays in the title", named["Ridgemont 2 — 150 words, about a hobby"]["status"] == "todo")
check("cancelled is dropped", named["Old idea"]["status"] == "dropped")
check("a lost parent makes it top-level, no project", named["Orphan with a missing parent"]["parent"] is None
      and named["Orphan with a missing parent"]["project"] == "" and named["Orphan with a missing parent"]["status"] == "waiting")
check("todo order is kept", [i["title"] for i in imported][:4] == ["Northfield University", "Northfield 1 Leadership",
                                                                    "Northfield 2 Creative side", "Lakeside College"]
      and [i["order"] for i in imported] == list(range(1, 21)))
check("imported file is 0600", (target.stat().st_mode & 0o777) == 0o600)
check("the default file was never touched", not (WORK / "never-written.json").exists())
twice = importing("--file", str(FIXTURES / "todo-result.json"), "--tasks-file", str(target))
check("running it again adds nothing", twice.returncode == 0 and "Added 0 tasks" in twice.stdout
      and "skipped 20" in twice.stdout and len(tasks.load(target)) == 20)

# From a throwaway state.db, built here with the columns the script reads.
db = WORK / "state.db"
with sqlite3.connect(db) as connection:
    connection.execute("CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, role TEXT NOT NULL, "
                       "content TEXT, tool_call_id TEXT, tool_calls TEXT, tool_name TEXT, timestamp REAL NOT NULL)")
    older = {"todos": [{"id": "1", "content": "Only one — in progress", "status": "in_progress"}], "revision": 1}
    rows = [("20260928_141233_aa11", "user", "add my essays", None, 100.0),
            ("20260928_141233_aa11", "tool", json.dumps(older), "todo_list", 101.0),
            ("20260928_141233_aa11", "tool", json.dumps(todo), "todo_list", 105.0),
            ("20260928_141233_aa11", "tool", "{\"results\": []}", "web_search", 106.0),
            ("20260927_090000_bb22", "tool", json.dumps(older), None, 50.0),
            ("20260927_090500_cc33", "tool", json.dumps(older), "todo_list", 60.0)]
    connection.executemany("INSERT INTO messages (session_id, role, content, tool_name, timestamp) VALUES (?, ?, ?, ?, ?)", rows)
fingerprint = (db.stat().st_mtime_ns, db.read_bytes())
listed_sessions = importing("--sessions", "--db", str(db))
check("--sessions lists sessions with a todo_list, newest first", listed_sessions.returncode == 0
      and [line.split()[0] for line in listed_sessions.stdout.splitlines()] ==
      ["20260928_141233_aa11", "20260927_090500_cc33", "20260927_090000_bb22"]
      and "21 todos  College Applications" in listed_sessions.stdout)
from_db = importing("--session", "20260928_1412", "--db", str(db), "--tasks-file", str(WORK / "db" / "tasks.json"), "--dry-run")
check("the latest todo_list result in the session is used", from_db.returncode == 0 and "Would add 20 tasks" in from_db.stdout
      and "session 20260928_141233_aa11" in from_db.stdout)
content_only = importing("--session", "20260927_0900", "--db", str(db), "--tasks-file", str(WORK / "db" / "tasks.json"), "--dry-run")
check("a result is found by its content too", content_only.returncode == 0 and "Would add 1 task " in content_only.stdout)
several = importing("--session", "20260927", "--db", str(db), "--tasks-file", str(WORK / "db" / "tasks.json"), "--dry-run")
check("a prefix matching two sessions is refused", several.returncode == 1 and "2 sessions start with" in several.stderr)
wildcard = importing("--session", "2026092_", "--db", str(db), "--tasks-file", str(WORK / "db" / "tasks.json"), "--dry-run")
check("_ in a session prefix is literal", wildcard.returncode == 1 and "No todo_list results" in wildcard.stderr)
written = importing("--session", "20260928_141233", "--db", str(db), "--tasks-file", str(WORK / "db" / "tasks.json"))
check("importing from the database writes the tasks", written.returncode == 0 and len(tasks.load(WORK / "db" / "tasks.json")) == 20)
check("the database is only read", (db.stat().st_mtime_ns, db.read_bytes()) == fingerprint)
missing = importing("--session", "x", "--db", str(WORK / "nope.db"), "--tasks-file", str(target), "--dry-run")
check("a missing database is a clear error", missing.returncode == 1 and "No Hermes database" in missing.stderr)

shutil.rmtree(WORK, ignore_errors=True)
print("tasks checks:", "ok" if failures == 0 else f"{failures} failed")
sys.exit(1 if failures else 0)
