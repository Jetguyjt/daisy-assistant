#!/usr/bin/env python3
"""Moves a task list Hermes kept in its todo_list into Daisy's Tasks tab.

Before the tasks tools existed, asking Daisy to add tasks put them in Hermes's todo_list, a scratch plan
that never reaches the app, with the real status tacked onto the text ("Yale 1 — needs to get started").
This reads that list, from a saved todo_list result or from Hermes's state.db (opened read-only), and adds
it to tasks.json with the same lock and atomic write the app and the plugin use:

- the status comes from the text after " — " when that reads as a status (the same rules as the app);
  otherwise from the todo's own status, and the title stays whole
- nesting stays; a top-level item with subtasks ("College Applications") becomes their project
- anything already there (same title under the same parent) is skipped, so running it twice is safe

Run:
    python3 scripts/import-hermes-todos.py --sessions
    python3 scripts/import-hermes-todos.py --session 20260928_1412 --dry-run
    python3 scripts/import-hermes-todos.py --file todo-result.json --tasks-file /tmp/tasks.json
The tasks file is $DAISY_TASKS_FILE, else ~/Library/Application Support/Daisy/tasks.json; state.db is
$HERMES_HOME/state.db, else ~/.hermes/state.db.
"""

from __future__ import annotations

import argparse
import importlib
import importlib.util
import json
import os
import sqlite3
import sys
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import quote

REPO = Path(__file__).resolve().parent.parent
TODO_STATUS = {"pending": "todo", "in_progress": "in_progress", "completed": "done", "cancelled": "dropped"}
SEPARATORS = (" — ", " – ")


class Failed(Exception):
    pass


def load_tasks_module():
    """hermes/daisy/tools/tasks.py, loaded the way Hermes loads the plugin, so the status rules, the lock
    and the file format are the plugin's own."""
    folder = REPO / "hermes" / "daisy"
    spec = importlib.util.spec_from_file_location("daisy_plugin", folder / "__init__.py",
                                                  submodule_search_locations=[str(folder)])
    module = importlib.util.module_from_spec(spec)
    sys.modules["daisy_plugin"] = module
    spec.loader.exec_module(module)
    return importlib.import_module("daisy_plugin.tools.tasks")


# Where the todos come from

def todos_in(data: Any) -> Optional[List[Any]]:
    if isinstance(data, dict) and isinstance(data.get("todos"), list):
        return data["todos"]
    if isinstance(data, list):
        return data
    return None


def from_file(path: Path) -> List[Any]:
    try:
        found = todos_in(json.loads(path.read_text(encoding="utf-8")))
    except (OSError, ValueError) as error:
        raise Failed(f"Can't read {path}: {error}")
    if found is None:
        raise Failed(f"{path} isn't a todo_list result (no todos list in it).")
    return found


def default_db() -> Path:
    return Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes") / "state.db"


TODO_ROWS = ("SELECT session_id, content, timestamp FROM messages WHERE session_id LIKE ? ESCAPE '\\' AND role = 'tool' "
             "AND (tool_name = 'todo_list' OR ltrim(content) LIKE '{\"todos\"%') ORDER BY timestamp DESC, id DESC")


def read_db(db: Path, prefix: str) -> List[Tuple[str, str, float]]:
    """Every todo_list result in sessions whose id starts with `prefix`, newest first. Read-only."""
    if not db.is_file():
        raise Failed(f"No Hermes database at {db}.")
    pattern = prefix.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
    connection = None
    try:
        connection = sqlite3.connect(f"file:{quote(str(db))}?mode=ro", uri=True)
        return connection.execute(TODO_ROWS, (pattern,)).fetchall()
    except sqlite3.Error as error:
        raise Failed(f"Can't read {db}: {error}")
    finally:
        if connection is not None:
            connection.close()


def list_sessions(db: Path) -> List[str]:
    """The sessions that have a todo_list, newest first: id, when, how many todos, and the first one."""
    lines, seen = [], set()
    for session_id, content, stamp in read_db(db, ""):
        if session_id in seen:
            continue
        seen.add(session_id)
        try:
            todos = todos_in(json.loads(content or "")) or []
        except ValueError:
            todos = []
        first = str(todos[0].get("content", "")) if todos and isinstance(todos[0], dict) else ""
        when = datetime.fromtimestamp(float(stamp or 0)).strftime("%Y-%m-%d %H:%M")
        lines.append(f"{session_id}  {when}  {len(todos)} todos  {first[:60]}")
        if len(lines) == 20:
            break
    return lines


def from_db(db: Path, session: str) -> Tuple[List[Any], str, float]:
    """The latest todo_list result in the session whose id starts with `session`."""
    rows = read_db(db, session)
    sessions = []
    for session_id, _, _ in rows:
        if session_id not in sessions:
            sessions.append(session_id)
    if not sessions:
        raise Failed(f"No todo_list results in a session starting with {session!r}.")
    if len(sessions) > 1:
        raise Failed(f"{len(sessions)} sessions start with {session!r}: {', '.join(sessions[:8])}. Give more of the id.")
    for session_id, content, stamp in rows:
        try:
            found = todos_in(json.loads(content or ""))
        except ValueError:
            continue
        if found is not None:
            return found, session_id, float(stamp or 0)
    raise Failed(f"The todo_list results in {sessions[0]} couldn't be read.")


# Turning todos into tasks

def split_status(tasks, content: str, todo_status: str) -> Tuple[str, str]:
    """(title, status) for one todo. "Yale 1 — needs to get started" is ("Yale 1", "todo"); text after the
    dash that doesn't read as a status stays in the title, and the todo's own status is used."""
    content = " ".join(content.split())
    for separator in SEPARATORS:
        head, found, tail = content.rpartition(separator)
        if not found:
            continue
        status, leftover = tasks.read_status(tail)
        if head.strip() and tail.strip() and leftover is None:
            return head.strip(), status
        break
    return content, TODO_STATUS.get(todo_status.strip().lower(), "todo")


def clean(raw: List[Any]) -> List[Dict[str, Any]]:
    todos, seen = [], set()
    for entry in raw:
        if not isinstance(entry, dict):
            continue
        todo_id = str(entry.get("id") or "").strip()
        content = str(entry.get("content") or "").strip()
        if not todo_id or not content or todo_id in seen:
            continue
        seen.add(todo_id)
        parent = str(entry.get("parent") or "").strip() or None
        todos.append({"id": todo_id, "content": content, "status": str(entry.get("status") or ""), "parent": parent})
    ids = {todo["id"] for todo in todos}
    by_id = {todo["id"]: todo for todo in todos}
    for todo in todos:  # a missing parent or a loop makes it top-level, like Hermes does
        node, path = todo["parent"], {todo["id"]}
        while node is not None:
            if node not in ids or node in path:
                todo["parent"] = None
                break
            path.add(node)
            node = by_id[node]["parent"]
    return todos


def plan(tasks, todos: List[Dict[str, Any]], existing: List[Dict[str, Any]]):
    """(new tasks, skipped titles, project names). New tasks already have their ids and parents."""
    index = tasks.Index(existing)
    by_id = {todo["id"]: todo for todo in todos}
    has_children = {todo["parent"] for todo in todos if todo["parent"]}
    projects = {todo["id"]: split_status(tasks, todo["content"], todo["status"])[0]
                for todo in todos if todo["parent"] is None and todo["id"] in has_children}

    def depth(todo):
        count, node = 0, todo["parent"]
        while node:
            count, node = count + 1, by_id[node]["parent"]
        return count

    def project_of(todo):
        node = todo
        while node["parent"]:
            node = by_id[node["parent"]]
        return projects.get(node["id"], "")

    order = max([item["order"] for item in existing] + [0])
    position = {todo["id"]: n for n, todo in enumerate(todos)}
    placed: Dict[str, str] = {}  # todo id -> task id (new or already there)
    fresh_children: Dict[Optional[str], List[Dict[str, Any]]] = {}
    added, skipped, origin = [], [], {}
    stamp = tasks.now()
    for todo in sorted(todos, key=depth):  # parents first; sorted() keeps list order within a depth
        if todo["id"] in projects:
            continue
        title, status = split_status(tasks, todo["content"], todo["status"])
        notes = ""
        if len(title) > tasks.TITLE_LIMIT:
            title, notes = title[:tasks.TITLE_LIMIT - 1].rstrip() + "…", todo["content"]
        parent = placed.get(todo["parent"]) if todo["parent"] and todo["parent"] not in projects else None
        key = tasks._key(title)
        match = next((item for item in index.children.get(parent, []) + fresh_children.get(parent, [])
                      if tasks._key(item["title"]) == key), None)
        if match:
            placed[todo["id"]] = match["id"]
            skipped.append(title)
            continue
        item = {"id": str(uuid.uuid4()).upper(), "title": title, "project": project_of(todo), "parent": parent,
                "due": "", "status": status, "notes": notes, "revision": 1, "order": 0, "updatedAt": stamp}
        placed[todo["id"]] = item["id"]
        origin[item["id"]] = position[todo["id"]]
        fresh_children.setdefault(parent, []).append(item)
        added.append(item)
    # The Tasks tab keeps the todo list's own order.
    added.sort(key=lambda item: origin[item["id"]])
    for n, item in enumerate(added):
        item["order"] = order + n + 1
    return added, skipped, list(projects.values())


def show(tasks, added: List[Dict[str, Any]], existing: List[Dict[str, Any]]) -> List[str]:
    lines = []
    by_id = {item["id"]: item for item in existing}
    kids: Dict[Optional[str], List[Dict[str, Any]]] = {}
    new_ids = {item["id"] for item in added}
    for item in added:
        kids.setdefault(item["parent"] if item["parent"] in new_ids else None, []).append(item)

    def walk(item, depth, project):
        extra = []
        if item["project"] and item["project"] != project:
            extra.append(f"project {item['project']}")
        if item["parent"] and item["parent"] not in new_ids:
            extra.append(f"under {by_id[item['parent']]['title']} (already there)")
        lines.append("    " * depth + f"• {item['title']} — {tasks.status_name(item['status'])}"
                     + (f" · {' · '.join(extra)}" if extra else ""))
        for child in kids.get(item["id"], []):
            walk(child, depth + 1, item["project"])

    for item in kids.get(None, []):
        walk(item, 0, None)
    return lines


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Add a Hermes todo_list to Daisy's tasks.")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--file", type=Path, help="a saved todo_list result (JSON with a todos list)")
    source.add_argument("--session", help="the start of a Hermes session id; its latest todo_list result is used")
    source.add_argument("--sessions", action="store_true", help="list the sessions that have a todo_list, and stop")
    parser.add_argument("--db", type=Path, default=None, help="Hermes's state.db (read-only)")
    parser.add_argument("--tasks-file", type=Path, default=None, help="Daisy's tasks.json")
    parser.add_argument("--dry-run", action="store_true", help="show what would be added and write nothing")
    options = parser.parse_args(argv)
    tasks = load_tasks_module()
    target = (options.tasks_file.expanduser() if options.tasks_file else tasks.tasks_file()).resolve()
    try:
        if options.sessions:
            found = list_sessions((options.db or default_db()).expanduser())
            print("\n".join(found) if found else "No todo_list results in any session.")
            return 0
        if options.file:
            raw, where = from_file(options.file.expanduser()), str(options.file)
        else:
            raw, session, stamp = from_db((options.db or default_db()).expanduser(), options.session)
            when = datetime.fromtimestamp(stamp).strftime("%Y-%m-%d %H:%M") if stamp else "unknown time"
            where = f"session {session} (todo_list result from {when})"
        todos = clean(raw)
        if not todos:
            raise Failed("That todo_list is empty.")
        if options.dry_run:
            existing = tasks.load(target)
            added, skipped, projects = plan(tasks, todos, existing)
        else:
            with tasks.locked(target):
                file_raw = tasks.load_raw(target)
                existing = [item for item in (tasks.view(entry) for entry in file_raw) if item]
                added, skipped, projects = plan(tasks, todos, existing)
                if len(existing) + len(added) > tasks.MAX_TASKS:
                    raise Failed(f"That would take the list past {tasks.MAX_TASKS:,} tasks.")
                if added:
                    tasks.save(target, file_raw, {}, set(), added)
    except (Failed, tasks.Problem) as error:
        print(f"import-hermes-todos: {error}", file=sys.stderr)
        return 1
    print(f"From {where}: {len(todos)} todos.")
    for project in projects:
        print(f"“{project}” becomes the project for everything under it.")
    verb = "Would add" if options.dry_run else "Added"
    print(f"{verb} {len(added)} task{'s' if len(added) != 1 else ''} to {target}" + (":" if added else "."))
    for line in show(tasks, added, existing):
        print("  " + line)
    if skipped:
        print(f"Already there, skipped {len(skipped)}: " + ", ".join(skipped))
    if options.dry_run:
        print("Dry run: nothing was written.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
