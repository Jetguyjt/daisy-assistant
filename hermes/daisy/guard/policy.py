"""What needs a yes, for one tool call:

1. Typed tools are judged by the risk they declare (registry.py) and nothing else: read runs, anything
   else stops at a card built from the tool's own card(args). Everything else goes through classify.py.
2. Taint (taint.py): after the turn read untrusted content, memory writes and new sites need a card.
3. The caller's role (roles.py): workers only read; cron only reads plus pre-approved actions.
4. A card needs someone to answer it. Where nobody can (yolo, one-shot runs, webhooks) it's blocked,
   and so is a burst of cards in a row.
5. Every card gets its own rule key, so "allow for this session" or "always" can never be reused.
6. A card the user already said yes to ahead of time runs without one (grants.py): only in chat, only
   where someone could have answered it, only for what the grant names, and each one is logged.
7. Every card that does show in a Daisy chat is noted in asks.jsonl (asks.py), for the app's
   Permissions list. Noting it can't change the decision.

Any error in here blocks the call: Hermes would otherwise run the tool as if the guard had said yes."""

from __future__ import annotations

import logging
import os
import threading
import time
import uuid
from collections import OrderedDict, deque
from typing import Any, Deque, Dict, Optional

from .. import registry
from . import asks, grants, roles, taint, targets
from .classify import JAVASCRIPT, classify
from .verdict import Verdict, allow, block, card, read

log = logging.getLogger("daisy.guard")

MAX_CARDS = 5
CARD_WINDOW_SECONDS = 60.0
# Steps a grant lets through in a minute, per session. Past that they're carded again: a grant is for
# a batch of edits, not a runaway loop.
MAX_GRANTED = 30
UNATTENDED_PLATFORMS = ("webhook", "msgraph_webhook", "api_server")
FAILED = "Daisy's guard hit an error, so this was blocked: {error}"
NOBODY = "Blocked by Daisy's guard: {what} needs a yes, but {why}."
TOO_MANY = "Blocked by Daisy's guard: too many approvals in a row, ask the user first before trying more."
# What a typed read tool brings into the turn, going by the words in its name.
# Contacts and confirmed nicknames come from the user's own address book and cards, so a lookup brings in nothing
# from outside (checked first, since "contacts_search" also has "search" in it).
TYPED_READS = (({"contact", "contacts", "alias", "aliases", "nickname", "nicknames"}, ""),
               ({"mail", "gmail", "email", "inbox", "outlook"}, "email"),
               ({"imsg", "message", "messages", "sms", "chat", "chats", "imessage"}, "messages"),
               ({"reminder", "reminders"}, "reminders"),
               ({"doc", "docs", "drive", "sheet", "sheets", "slide", "slides", "file", "files", "note", "notes",
                 "pdf", "document", "documents"}, "documents"),
               ({"calendar", "event", "events", "invite", "invites"}, "calendar events"),
               ({"web", "page", "pages", "tab", "tabs", "chrome", "browser", "url", "feed", "rss", "reader", "site",
                 "search"}, "the web"),
               ({"computer", "screen"}, "the screen"))
TYPED_OPENS = ("open", "navigate", "goto", "visit", "browse")


def on_pre_tool_call(tool_name: str = "", args: Any = None, **hook: Any) -> Optional[Dict[str, str]]:
    """Hermes's pre_tool_call hook. Returns None (go ahead), an approve directive (show a card) or a
    block directive. Never raises."""
    try:
        return decide(tool_name or "", args if isinstance(args, dict) else {}, **hook)
    except Exception as error:  # fail closed: an error must never let the call through
        log.warning("guard error on %s: %s", tool_name, error, exc_info=True)
        return {"action": "block", "message": FAILED.format(error=f"{type(error).__name__}: {error}")}


def decide(tool_name: str, args: Dict[str, Any], task_id: str = "", session_id: str = "", turn_id: str = "",
           **_: Any) -> Optional[Dict[str, str]]:
    task_id, session_id, turn_id = str(task_id or ""), str(session_id or ""), str(turn_id or "")
    session = task_id or session_id or roles.session_env("HERMES_SESSION_KEY") or "default"
    role = roles.role_for(task_id, session_id)
    proposal = None
    if tool_name == grants.TOOL:
        verdict, proposal = ask_for_grant(args)
    else:
        verdict = judge(tool_name, args)
    turn = taint.turn_key(session, turn_id)
    if proposal is not None and proposal["duration"] == "request" and not turn[1]:
        verdict = block(grants.NO_TURN, title=verdict.title)
    verdict = taint.review(turn, verdict)
    verdict = roles.enforce(role, tool_name, args, verdict, task_id)
    carded = False
    if verdict.decision == "card":
        why = nobody_to_ask()
        if why:
            verdict = block(NOBODY.format(what=verdict.title or tool_name, why=why), title=verdict.title)
        elif _granted(role, session, turn[1], tool_name, args, verdict):
            verdict = verdict.but(decision="allow")
        elif not _cards.take(session):
            verdict = block(TOO_MANY, title=verdict.title)
        else:
            carded = True
    taint.record(turn, verdict)
    result = directive(verdict)
    if carded and proposal is not None:
        grants.hold(args, session, turn[1], proposal)
    elif carded:
        _offer(tool_name, args, verdict, session, turn[1], result["message"])
        asks.note(role, tool_name, args, verdict, session, turn[1])
    return result


def judge(tool_name: str, args: Dict[str, Any]) -> Verdict:
    tool = registry.get(tool_name)
    if tool is None:
        return classify(tool_name, args)
    words = set(tool_name.lower().split("_"))
    opens = bool(words & set(TYPED_OPENS))
    if targets.script_urls(args, everywhere=opens):
        return block(JAVASCRIPT, title="Open a javascript: link", hard=True)
    if tool.risk == "read":
        reads = next((label for names, label in TYPED_READS if words & names), "")
        if not opens:
            return read(reads=reads)
        title, detail = _card_parts(tool, args)
        return read(reads=reads, navigates=True, title=title, detail=detail)
    try:
        title, detail = tool.card_parts(args)
    except registry.Refused as refusal:
        return block(str(refusal), title=f"Use {tool.name}")
    if tool.risk == "own":
        # Daisy's own records (the task list): runs like a memory save, carded once the turn has
        # read outside content, and never from a background job or cron.
        return allow(rule=tool.name, title=title or f"Use {tool.name}", detail=detail, persists=True)
    return card(tool.name, title or f"Use {tool.name}", detail)


def ask_for_grant(args: Dict[str, Any]):
    """approval_grant: always a card (its own text, never a grant), or refused with what to fix."""
    try:
        proposal = grants.plan(args)
    except registry.Refused as refusal:
        return block(str(refusal), title="Ask for a standing OK"), None
    title, detail = grants.card_parts(proposal)
    return card("grant", title, detail), proposal


def _granted(role: str, session: str, turn: str, tool_name: str, args: Dict[str, Any], verdict: Verdict) -> bool:
    """True when a live grant covers this card, the minute's allowance isn't used up, and the log line is
    written. A grant that can't be logged isn't used."""
    grant = grants.covering(role, session, turn, tool_name, args, verdict)
    if grant is None or not _granted_calls.take(session):
        return False
    try:
        grants.ran(grant, session, turn, tool_name, verdict)
    except Exception as error:
        log.warning("couldn't log a call under a grant, so it gets its card: %s", error)
        return False
    return True


def _offer(tool_name: str, args: Dict[str, Any], verdict: Verdict, session: str, turn: str, message: str) -> None:
    """Notes a grantable card for the app's "Yes to all like this". Without it the card is just a card."""
    try:
        grants.offer(tool_name, args, verdict, session, turn, message)
    except Exception as error:
        log.warning("couldn't note a grant offer: %s", error)


def _card_parts(tool, args: Dict[str, Any]):
    try:
        return tool.card_parts(args)
    except Exception:
        return f"Use {tool.name}", ""


def directive(verdict: Verdict) -> Optional[Dict[str, str]]:
    if verdict.decision == "allow":
        return None
    if verdict.decision == "block":
        return {"action": "block", "message": verdict.message or f"Blocked by Daisy's guard: {verdict.title}."}
    title = " ".join((verdict.title or "Approve this step").split()).replace(" — ", " - ")
    message = f"{title} — {verdict.detail}" if verdict.detail else title
    # A fresh rule key per call, so an approval can never be reused for a different call.
    return {"action": "approve", "message": message,
            "rule_key": f"daisy.{verdict.rule or 'action'}.{uuid.uuid4().hex}"}


def nobody_to_ask() -> str:
    """Why a card can't reach a person right now, or "" when it can."""
    if _yolo():
        return "approvals are switched off (yolo), and Daisy never lets this through without a yes"
    if roles.session_env("HERMES_SINGLE_QUERY_SESSION").strip().lower() in roles.TRUE:
        return "this is a one-shot run with nobody there to approve it"
    platform = roles.session_env("HERMES_SESSION_PLATFORM").strip().lower()
    if platform in UNATTENDED_PLATFORMS:
        return f"this session runs on {platform}, where nobody can approve it"
    return ""


def _yolo() -> bool:
    try:
        from tools.approval import _yolo_active
    except Exception:
        return os.environ.get("HERMES_YOLO_MODE", "").strip().lower() in roles.TRUE
    try:
        return bool(_yolo_active())
    except Exception:
        return True


class _CardLimit:
    """At most `limit` per session in CARD_WINDOW_SECONDS: cards, or steps run under a grant."""

    def __init__(self, limit: int = MAX_CARDS):
        self.limit = limit
        self.lock = threading.Lock()
        self.sessions: "OrderedDict[str, Deque[float]]" = OrderedDict()

    def take(self, session: str) -> bool:
        now = time.monotonic()
        with self.lock:
            stamps = self.sessions.pop(session, None) or deque()
            while stamps and now - stamps[0] > CARD_WINDOW_SECONDS:
                stamps.popleft()
            allowed = len(stamps) < self.limit
            if allowed:
                stamps.append(now)
            self.sessions[session] = stamps
            while len(self.sessions) > 256:
                self.sessions.popitem(last=False)
            return allowed


_cards = _CardLimit()
_granted_calls = _CardLimit(MAX_GRANTED)
