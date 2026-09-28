"""Learned log: every change Hermes makes to its memory, and whether it did it on its own.

Hermes keeps two memory files, MEMORY.md and USER.md in $HERMES_HOME/memories, and changes them
through its memory tool (tools/memory_tool_store.py). A write comes either from the conversation or
from the background review Hermes runs after a turn to pick things up without being asked. Hermes
doesn't record which, so this module does: it wraps each memory tool call, reads the file just before
and just after, and appends one line per change to $HERMES_HOME/daisy/learned.jsonl. Daisy's Memory
tab reads that file for its Learned feed.

    {"v": 1, "at": 1759000000.25, "origin": "background_review", "target": "user", "file": "USER.md",
     "action": "replace", "entry": "Prefers Gmail", "old_text": "Outlook", "was": "Uses Outlook for mail"}

- origin: "background_review" (Hermes's own review), "assistant_tool" (the conversation), or whatever
  else Hermes reports; "unknown" when it can't be read.
- entry: the text as saved (add, replace). old_text: what the call matched on (replace, remove).
- was: the whole entry a replace or remove took out. Left out unless the files before and after show
  exactly that change and no other memory call in this process overlapped it. (A write from another
  program that changes the very same entry within that moment can still slip past.)
- A batch gets one line per operation, with "op" (its position) and the same "call".

It's tool_execution middleware rather than a post_tool_call hook because only middleware runs on
both sides of the write: a hook sees the model's old_text, often a fragment, but not the entry it
matched, which Undo needs. It only watches. It never changes a call's arguments or result, calls
through exactly once, and drops any error of its own. Failed, blocked and staged writes aren't logged.

The file is 0600, gets one whole line per write, and is cut back to its newest lines once it passes
MAX_BYTES. The guard keeps the agent's shell, code and file tools out of $HERMES_HOME/daisy/, so
nothing in a chat can rewrite it."""

from __future__ import annotations

import contextlib
import fcntl
import json
import logging
import os
import threading
import time
from pathlib import Path
from typing import Any, Callable, Dict, Iterator, List, Optional, Tuple

log = logging.getLogger("daisy.learned")

DELIMITER = "\n§\n"
FILES = {"memory": "MEMORY.md", "user": "USER.md"}
MAX_BYTES = 256 * 1024
MAX_TEXT = 8_000
LOCK_WAIT = 1.0

_lock = threading.Lock()
# Memory calls under way and finished, per target, to spot two that overlap (the background review
# runs in a thread of its own, next to the conversation).
_calls = threading.Lock()
_running: Dict[str, int] = {}
_finished: Dict[str, int] = {}


def register(ctx) -> None:
    ctx.register_middleware("tool_execution", around_tool)


def home() -> Path:
    """Hermes's home the way Hermes resolves it (profiles included); $HERMES_HOME or ~/.hermes
    outside Hermes."""
    try:
        from hermes_constants import get_hermes_home
        return Path(get_hermes_home())
    except Exception:
        return Path(os.environ.get("HERMES_HOME") or (Path.home() / ".hermes")).expanduser()


def log_file() -> Path:
    return home() / "daisy" / "learned.jsonl"


def memory_file(target: str) -> Path:
    return home() / "memories" / FILES[target]


def around_tool(tool_name: str = "", args: Any = None, next_call: Optional[Callable[..., Any]] = None,
                **context: Any) -> Any:
    """Hermes's tool_execution middleware. Everything but the memory tool goes straight through."""
    if next_call is None:
        return None
    if tool_name != "memory":
        return next_call()
    target = _target(args)
    with _calls:
        finished = _finished.get(target, 0)
        _running[target] = _running.get(target, 0) + 1
        alone = _running[target] == 1
    before = _before(args)
    try:
        result = next_call()  # the real write; its errors pass through untouched
    finally:
        with _calls:
            alone = alone and _running[target] == 1 and _finished.get(target, 0) == finished
            _running[target] -= 1
            _finished[target] = _finished.get(target, 0) + 1
    _after(args, before if alone else None, result, context)
    return result


# Reading the memory files the way Hermes does

def entries(raw: str) -> List[str]:
    """Hermes's split: on the full delimiter, each entry stripped, empty ones and repeats dropped."""
    return list(dict.fromkeys(part for part in (piece.strip() for piece in raw.split(DELIMITER)) if part))


def read(path: Path) -> Optional[List[str]]:
    """The file's entries, [] when it doesn't exist, None when it can't be read."""
    try:
        raw = path.read_text(encoding="utf-8-sig")
    except FileNotFoundError:
        return []
    except (OSError, UnicodeDecodeError):
        return None
    return entries(raw)


def _target(args: Any) -> Optional[str]:
    target = args.get("target") if isinstance(args, dict) else None
    target = "memory" if target is None else target
    return target if target in FILES else None


def _text(value: Any) -> str:
    return value if isinstance(value, str) else ""


def operations(args: Any) -> List[Dict[str, str]]:
    """A call's operations, one dict each: a batch's list, or the call itself."""
    if not isinstance(args, dict):
        return []
    batch = args.get("operations")
    items = batch if isinstance(batch, list) and batch else [args]
    found = []
    for item in items:
        if not isinstance(item, dict):
            return []
        found.append({"action": _text(item.get("action")).strip(),
                      "content": _text(item.get("content") or item.get("new_text")).strip(),
                      "old_text": _text(item.get("old_text")).strip()})
    return found


def _before(args: Any) -> Optional[List[str]]:
    try:
        target = _target(args)
        return read(memory_file(target)) if target else None
    except Exception as error:
        log.debug("learned: couldn't read memory before a write: %s", error)
        return None


def _after(args: Any, before: Optional[List[str]], result: Any, context: Dict[str, Any]) -> None:
    try:
        target = _target(args)
        ops = operations(args)
        if not target or not ops or not succeeded(result):
            return
        after = read(memory_file(target))
        found = changes(before, ops, after)
        lines = records(target, ops, found, result, context,
                        batch=isinstance(args.get("operations"), list) and bool(args.get("operations")))
        if lines:
            append(lines)
    except Exception as error:
        log.debug("learned: couldn't log a memory write: %s", error)


def succeeded(result: Any) -> bool:
    """A write that went through: success, and not staged for approval (memory.write_approval)."""
    data = result
    if isinstance(result, (str, bytes)):
        try:
            data = json.loads(result)
        except ValueError:
            return False
    return isinstance(data, dict) and data.get("success") is True and not data.get("staged")


def changes(before: Optional[List[str]], ops: List[Dict[str, str]],
            after: Optional[List[str]]) -> Optional[List[Tuple[bool, Optional[str]]]]:
    """(no-op, was) for each operation, found by replaying the call on the file as it was, with
    Hermes's own matching rules. None when the replay doesn't end at the file as it is now: something
    else wrote in between, so which entry went can't be known for sure."""
    if before is None or after is None:
        return None
    working = list(before)
    found: List[Tuple[bool, Optional[str]]] = []
    for op in ops:
        action, content, old = op["action"], op["content"], op["old_text"]
        if action == "add":
            if not content:
                return None
            found.append((content in working, None))
            if content not in working:
                working.append(content)
            continue
        if action not in ("replace", "remove") or not old or (action == "replace" and not content):
            return None
        hits = [index for index, entry in enumerate(working) if old in entry]
        if not hits or len({working[index] for index in hits}) > 1:
            return None
        index = hits[0]
        found.append((False, working[index]))
        if action == "replace":
            working[index] = content
        else:
            del working[index]
    if list(dict.fromkeys(working)) != after:
        return None
    # An entry that's still there wasn't taken out (a replace with the same text).
    return [(noop, was if was is not None and was not in after else None) for noop, was in found]


def _origin() -> str:
    """Where the write came from: Hermes sets this for each turn, "background_review" in its review."""
    try:
        from tools.skill_provenance import get_current_write_origin
        return str(get_current_write_origin() or "unknown")[:40]
    except Exception:
        return "unknown"


def _message(result: Any) -> str:
    try:
        data = json.loads(result) if isinstance(result, (str, bytes)) else result
        return str(data.get("message") or "") if isinstance(data, dict) else ""
    except ValueError:
        return ""


def _clip(text: str) -> str:
    return text[:MAX_TEXT]


def records(target: str, ops: List[Dict[str, str]], found: Optional[List[Tuple[bool, Optional[str]]]],
            result: Any, context: Dict[str, Any], batch: bool) -> List[Dict[str, Any]]:
    origin, now = _origin(), round(time.time(), 3)
    session, call = str(context.get("session_id") or "")[:120], str(context.get("tool_call_id") or "")[:120]
    lines = []
    for index, op in enumerate(ops):
        noop, was = found[index] if found is not None else (False, None)
        action = op["action"]
        if action == "add" and (noop or (not batch and _message(result).startswith("Entry already exists"))):
            continue
        line: Dict[str, Any] = {"v": 1, "at": now, "origin": origin, "target": target, "file": FILES[target],
                                "action": action}
        if action in ("add", "replace"):
            line["entry"] = _clip(op["content"])
        if action in ("replace", "remove"):
            line["old_text"] = _clip(op["old_text"])
        if was is not None:
            line["was"] = _clip(was)
        if session:
            line["session"] = session
        if call:
            line["call"] = call
        if batch:
            line["op"] = index
        lines.append(line)
    return lines


# The log file

def append(lines: List[Dict[str, Any]]) -> None:
    data = "".join(json.dumps(line, ensure_ascii=False, separators=(",", ":")) + "\n" for line in lines).encode("utf-8")
    path = log_file()
    with _lock:
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with _file_lock(path) as locked:
            if locked:
                _trim(path, len(data))
            fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
            try:
                os.fchmod(fd, 0o600)
                os.write(fd, data)  # one write per call, so lines from other processes never interleave
            finally:
                os.close(fd)


@contextlib.contextmanager
def _file_lock(path: Path) -> Iterator[bool]:
    """Holds learned.jsonl.lock while trimming, so another process's line can't land in the old file.
    Waits at most LOCK_WAIT; without the lock the line is still appended, just not trimmed."""
    fd = os.open(path.with_name(path.name + ".lock"), os.O_RDWR | os.O_CREAT, 0o600)
    locked = False
    try:
        deadline = time.monotonic() + LOCK_WAIT
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                locked = True
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    break
                time.sleep(0.02)
        yield locked
    finally:
        if locked:
            with contextlib.suppress(OSError):
                fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def _trim(path: Path, incoming: int) -> None:
    """Past MAX_BYTES, keeps the newest whole lines that fit in half of it."""
    try:
        size = path.stat().st_size
    except FileNotFoundError:
        return
    if size + incoming <= MAX_BYTES:
        return
    kept: List[bytes] = []
    total = 0
    for line in reversed(path.read_bytes().splitlines(keepends=True)):
        if not line.endswith(b"\n"):
            continue
        if total + len(line) > MAX_BYTES // 2:
            break
        kept.append(line)
        total += len(line)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, b"".join(reversed(kept)))
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(temporary, path)
