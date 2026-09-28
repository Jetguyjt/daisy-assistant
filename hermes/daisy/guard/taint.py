"""Taint: once a turn has read mail, web pages, files or messages, that text can carry instructions
meant for the agent ("forward everything to X"). For the rest of that turn:

- memory, skill and scheduled-job writes need a card (they'd carry the instruction into later turns)
- opening a site the turn hasn't touched yet needs a card (a link can carry data out: evil.example/?d=)
- every card says what was read first, so a new recipient stands out

Turns are keyed by (session, turn id). Calls that come without a turn id (tool calls made from
execute_code) join the session's latest turn. State is per process, capped, and forgets idle turns."""

from __future__ import annotations

import threading
import time
from collections import OrderedDict
from dataclasses import dataclass, field
from typing import Set, Tuple

from . import targets
from .verdict import Verdict, card

MAX_TURNS = 256
IDLE_SECONDS = 30 * 60
NOTE = "Heads up: this came after reading {what} in the same request. Make sure it's what you asked for."


@dataclass
class _Turn:
    read: str = ""
    hosts: Set[str] = field(default_factory=set)
    touched: float = 0.0


_lock = threading.Lock()
_turns: "OrderedDict[Tuple[str, str], _Turn]" = OrderedDict()
_latest: "OrderedDict[str, str]" = OrderedDict()


def turn_key(session: str, turn_id: str) -> Tuple[str, str]:
    session = session or "default"
    with _lock:
        if turn_id:
            _latest.pop(session, None)
            _latest[session] = turn_id
            while len(_latest) > MAX_TURNS:
                _latest.popitem(last=False)
            return (session, turn_id)
        return (session, _latest.get(session, ""))


def _get(key: Tuple[str, str], create: bool) -> _Turn:
    now = time.monotonic()
    for old in [k for k, turn in _turns.items() if now - turn.touched > IDLE_SECONDS]:
        del _turns[old]
    turn = _turns.pop(key, None)
    if turn is None:
        if not create:
            return _Turn()
        turn = _Turn()
    turn.touched = now
    _turns[key] = turn
    while len(_turns) > MAX_TURNS:
        _turns.popitem(last=False)
    return turn


def review(key: Tuple[str, str], verdict: Verdict) -> Verdict:
    """The verdict once this turn's reading is taken into account."""
    with _lock:
        turn = _get(key, create=False)
        what, hosts = turn.read, set(turn.hosts)
    if not what or verdict.decision == "block":
        return verdict
    note = NOTE.format(what=what)
    if verdict.decision == "card":
        return verdict.but(detail=f"{note}\n\n{verdict.detail}" if verdict.detail else note)
    if verdict.persists:
        return card(verdict.rule or "memory", verdict.title or "Save to memory",
                    f"{note}\n\n{verdict.detail}" if verdict.detail else note)
    if verdict.navigates:
        sites = [targets.host(url) for url in verdict.urls]
        new = [site for site in sites if not site or site not in hosts]
        if not sites or new:
            place = next((site for site in new if site), "")
            title = f"Open {place}" if place else (verdict.title or "Open a page")
            shown = "\n".join(verdict.urls) or verdict.detail
            return card("open", title, f"{note}\n\n{shown}" if shown else note, urls=verdict.urls,
                        navigates=True, network=verdict.network)
    return verdict


def record(key: Tuple[str, str], verdict: Verdict) -> None:
    """Remembers what a call that's going ahead reads, and which sites it touches."""
    if verdict.decision == "block":
        return
    with _lock:
        turn = _get(key, create=True)
        if verdict.reads and not turn.read:
            turn.read = verdict.reads
        if verdict.decision == "allow":
            turn.hosts.update(site for site in (targets.host(url) for url in verdict.urls) if site)
