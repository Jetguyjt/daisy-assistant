"""What Daisy had to ask: one line in $HERMES_HOME/daisy/asks.jsonl for every card the guard shows in a
Daisy chat. The app's Permissions list is built from it, so what shows up there is whatever Daisy
actually needed a yes for, not a fixed list.

A line:
    {"at": 1790000000.0, "session": "acp-1", "tool": "docs_write", "title": "Add text to the end of ...",
     "risk": "write", "grantable": true, "scope": "docs_write"}
- risk: a typed tool's declared risk, or the guard's rule for anything else ("run", "send-email").
- scope: what a grant would have to name to cover it, the way grants.call_scope scopes it: the typed or
  MCP tool's name, "<tool>@<app>" for clicking and typing in one app (plus "app", as it was typed), or
  "script:<real path>" (plus "script"). Only there when grantable.
- why and reason: when no grant can cover it, a short code and one line for the app ("send", "Sends
  always ask"), from grants.why_not.

Private (0600), appended to, and capped: past MAX_BYTES it's cut to its newest half. Writing it never
blocks the call or breaks the hook: a lock that stays busy is skipped, and any error is logged and
dropped. approval_grant cards aren't noted: that card is the yes for a grant, not a kind of step."""

from __future__ import annotations

import fcntl
import json
import logging
import os
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Dict, Iterator

from .. import registry
from . import grants, roles
from .verdict import Verdict

log = logging.getLogger("daisy.guard")

MAX_BYTES = 512 * 1024
MAX_TITLE = 160
LOCK_WAIT = 0.05


def asks_file() -> Path:
    return grants.folder() / "asks.jsonl"


def lock_file() -> Path:
    return grants.folder() / ".asks.lock"


def note(role: str, tool_name: str, args: Dict[str, Any], verdict: Verdict, session: str, turn: str) -> None:
    """Called once the guard has decided to show a card. Only a Daisy chat turn counts (a session and a
    turn id, like the offers for "Yes to all like this"). Never raises."""
    try:
        if role != "chat" or not roles.DAISY_PROCESS or not session or not turn or tool_name == grants.TOOL:
            return
        _append(line(tool_name, args if isinstance(args, dict) else {}, verdict, session))
    except Exception as error:
        log.warning("couldn't note what was asked: %s", error)


def line(tool_name: str, args: Dict[str, Any], verdict: Verdict, session: str) -> str:
    title = " ".join((verdict.title or tool_name).split())
    if len(title) > MAX_TITLE:
        title = title[:MAX_TITLE - 1].rstrip() + "…"
    tool = registry.get(tool_name)
    entry: Dict[str, Any] = {"at": round(time.time(), 3), "session": session, "tool": tool_name, "title": title,
                             "risk": tool.risk if tool is not None else (verdict.rule or "")}
    call = grants.call_scope(tool_name, args, verdict)
    entry["grantable"] = call is not None
    if call is not None:
        entry["scope"] = call.key
        if call.app:
            entry["app"] = " ".join(str(args.get("app") or "").split())[:60]
        if call.script:
            entry["script"] = call.script
    else:
        entry["why"], entry["reason"] = grants.why_not(tool_name, args, verdict)
    return json.dumps(entry, ensure_ascii=False) + "\n"


@contextmanager
def _maybe_locked() -> Iterator[bool]:
    """The asks lock if it comes free within LOCK_WAIT, else go on without it (and don't trim)."""
    handle = os.open(lock_file(), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    held = False
    try:
        deadline = time.monotonic() + LOCK_WAIT
        while True:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                held = True
                break
            except BlockingIOError:
                if time.monotonic() > deadline:
                    break
                time.sleep(0.005)
        yield held
    finally:
        if held:
            fcntl.flock(handle, fcntl.LOCK_UN)
        os.close(handle)


def _append(text: str) -> None:
    grants.folder().mkdir(mode=0o700, parents=True, exist_ok=True)
    path = asks_file()
    with _maybe_locked() as held:
        handle = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
        try:
            if os.fstat(handle).st_mode & 0o077:
                os.fchmod(handle, 0o600)
            os.write(handle, text.encode("utf-8"))
            size = os.fstat(handle).st_size
        finally:
            os.close(handle)
        if held and size > MAX_BYTES:
            _trim(path)


def _trim(path: Path) -> None:
    """Keeps the newest half of the lines, through a temp file and a rename."""
    lines = path.read_bytes().splitlines(keepends=True)
    kept = lines[len(lines) // 2:]
    temporary = path.parent / f".{path.name}.{uuid.uuid4().hex}.tmp"
    handle = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(handle, "wb") as out:
            out.writelines(kept)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise
