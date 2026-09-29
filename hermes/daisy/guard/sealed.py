"""Keeps tools from loosening the guard by rewriting its files.

grants.json (standing OKs) and cron-allow.json (what scheduled runs may do without anyone there) only
change through approval_grant, the app's Permissions list, or the user's own hands. The guard refuses shell and code writes
to them when it can see the path, but code can build the path while it runs. So this wraps every tool
call as tool_execution middleware and compares the two files before and after:

- a grant that appears while a tool other than approval_grant runs, and lasts forever, is taken back out
- a grant that was there before and changed while the tool ran is put back the way it was
- an entry that appears in cron-allow.json while any tool runs is taken back out
- removals stay: revoking in the app's Permissions list mid-call, or a tool deleting a grant, only ever tightens things

New request-only grants are left alone: the app writes those when "Yes to all like this" is tapped,
which can land while another tool of the same turn is running, and a forged one would need that
turn's id, which tools never see."""

from __future__ import annotations

import json
import logging
from typing import Any, Callable, Dict, List, Optional

from . import grants, roles

log = logging.getLogger("daisy.guard")

# Tools that are meant to write grants.json themselves.
WRITERS = {"approval_grant"}


def register(ctx) -> None:
    """Never raises, so it can't take the guard's registration down with it."""
    try:
        ctx.register_middleware("tool_execution", around_tool)
    except Exception as error:
        log.warning("guard file check is off: %s", error)


def around_tool(tool_name: str = "", args: Any = None, next_call: Optional[Callable[..., Any]] = None,
                **_: Any) -> Any:
    if next_call is None:
        return None
    before_grants = _grants() if tool_name not in WRITERS else None
    before_allow = _allow()
    try:
        return next_call()
    finally:
        try:
            if before_grants is not None:
                _undo_grants(before_grants, tool_name)
            _undo_allow(before_allow, tool_name)
        except Exception as error:  # a check that fails must not break the tool's own result
            log.warning("guard file check failed after %s: %s", tool_name, error)


def _key(item: Dict[str, Any]) -> str:
    return json.dumps(item, sort_keys=True, ensure_ascii=False)


def _grants() -> Optional[Dict[str, str]]:
    """Every grant by id, as written; None when the file can't be read (then nothing is compared)."""
    path = grants.grants_file()
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    items = data.get("grants") if isinstance(data, dict) else None
    if not isinstance(items, list):
        return {}
    return {str(item.get("id", "")): _key(item) for item in items if isinstance(item, dict)}


def _undo_grants(before: Optional[Dict[str, str]], tool_name: str) -> None:
    if before is None:
        return
    with grants._locked():
        data = grants._read(grants.grants_file())
        items = grants._listed(data, "grants")
        kept: List[Dict[str, Any]] = []
        undone: List[str] = []
        for item in items:
            grant_id = str(item.get("id", ""))
            if grant_id not in before:
                if item.get("duration") == "forever":
                    undone.append(grant_id or "(no id)")
                    continue
                kept.append(item)
            elif _key(item) != before[grant_id]:
                kept.append(json.loads(before[grant_id]))
                undone.append(grant_id)
            else:
                kept.append(item)
        if undone:
            grants._write(grants.grants_file(), {"version": data.get("version", grants.VERSION), "grants": kept})
            log.warning("%s changed Daisy's standing OKs while it ran; undone: %s", tool_name, ", ".join(undone))


def _allow() -> Optional[List[str]]:
    path = roles.cron_allow_file()
    if not path.exists():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    items = data.get("allow") if isinstance(data, dict) else None
    return [_key(item) for item in items] if isinstance(items, list) else []


def _undo_allow(before: Optional[List[str]], tool_name: str) -> None:
    if before is None:
        return
    path = roles.cron_allow_file()
    after = _allow()
    if after is None or not [entry for entry in after if entry not in before]:
        return
    data = json.loads(path.read_text(encoding="utf-8"))
    data["allow"] = [item for item in data.get("allow", []) if _key(item) in before]
    grants._write(path, data)
    log.warning("%s added to cron-allow.json while it ran; taken back out", tool_name)
