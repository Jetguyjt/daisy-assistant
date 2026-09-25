"""Jarvis client plugin for Hermes: the Jarvis persona, and a yes-first gate for outgoing actions.

Hermes asks before dangerous shell commands and file edits, but a message, an email or a
calendar change can go out through a skill's CLI with no prompt. When Hermes runs under Jarvis
(JARVIS_SESSION=1), matching tool calls are escalated to Hermes's own approval gate, which
reaches Jarvis over ACP as a permission request and shows up as a card with the exact content.
Denied, timed out or unanswered means blocked. Everything else passes through untouched.

This is a pattern check on commands, not a sandbox: it catches the ways the bundled skills send
and delete, and code that goes around them is still covered by Hermes's own dangerous-command
rules only.
"""

from __future__ import annotations

import os
import re
import shlex
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

ACTIVE = os.environ.get("JARVIS_SESSION") == "1"

PERSONA = """You are speaking through Jarvis, the user's assistant app on their Mac. In this app you go by Jarvis.

How to sound:
- Concise, confident, conversational. Lead with the answer; one or two sentences unless asked for more.
- Don't narrate tools or process ("I accessed your calendar and found..."). Say what you found or did.
- Answers are often read aloud: plain sentences, no headings, tables, bullet lists or emoji unless asked or showing code. Say times and names the way a person would.
- If something is ambiguous, ask one short question.

Working on the Mac:
- Questions about the user's files, schedule, messages or projects need a lookup, not a guess.
- For files, search locally and report the few best matches with their folders. Don't dump listings.
- Pass along only what the task needs: a filename or a short excerpt, not whole folders or long files.
- Sending a message or email, deleting anything, changing a calendar event, posting or buying: don't ask for confirmation in chat, even if a skill says to. Go ahead with the step; Jarvis stops it at an approval card showing the user the exact content, and that card is the confirmation. If they decline, drop it and say so in a few words.

Memory:
- Keep durable facts the user states or clearly implies: preferences, people and how they relate ("Dad" and his contact), ongoing projects, routines, school context, and what their shorthand means.
- Don't keep one-off requests or computer activity. When the user says "remember", save it and confirm in a few words."""


def _persona(_info: Any = None) -> str:
    """The Jarvis persona, or the user's own from $HERMES_HOME/jarvis-persona.md."""
    home = Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")
    try:
        text = (home / "jarvis-persona.md").read_text(encoding="utf-8").strip()
        if text:
            return text[:3900]
    except OSError:
        pass
    return PERSONA


def _tokens(command: str) -> list[str]:
    try:
        return shlex.split(command)
    except ValueError:
        return command.split()


def _flag(tokens: list[str], *names: str) -> Optional[str]:
    """Value of the first matching flag, as `--to x` or `--to=x`."""
    for index, token in enumerate(tokens):
        for name in names:
            if token == name and index + 1 < len(tokens):
                return tokens[index + 1]
            if token.startswith(name + "="):
                return token[len(name) + 1:]
    return None


def _excerpt(text: str, limit: int = 400) -> str:
    text = " ".join(text.split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


_DELETE = re.compile(r"(^|[;&|(]\s*|\b(?:sudo|xargs|exec)\s+)(rm|rmdir|trash|unlink|srm|shred)\b")
_CODE_DELETE = re.compile(r"\b(os\.remove|os\.unlink|os\.rmdir|shutil\.rmtree|send2trash)\s*\(|\.unlink\s*\(")
_CALENDAR_WRITE = re.compile(r"\b(insert|create|update|patch|delete|remove|move|quickadd|import)\b|\+(insert|create|update|delete)\b")


def classify(tool_name: str, args: Dict[str, Any]) -> Optional[Tuple[str, str]]:
    """(rule key, "What happens — exact content") for calls that need a yes, else None."""
    if tool_name in ("terminal", "process", "process_manage", "execute_code"):
        text = str(args.get("command") or args.get("code") or args.get("input") or "")
        return classify_command(text) if text.strip() else None
    if tool_name.startswith("mcp_"):
        name = tool_name.lower()
        if re.search(r"(^|_)(send|reply|forward|post|publish|delete|remove|trash|purchase|buy|pay)(_|$)", name):
            return ("jarvis.mcp." + tool_name, f"Run {tool_name} — " + _excerpt(str(args)))
        if re.search(r"(^|_)(create|update|patch|move)_?(event|events|calendar)", name):
            return ("jarvis.calendar-change", "Change your calendar — " + _excerpt(str(args)))
    return None


def classify_command(command: str) -> Optional[Tuple[str, str]]:
    low = command.lower()
    tokens = _tokens(command)
    if re.search(r"\bimsg\b", low) and re.search(r"\bsend\b", low):
        to = _flag(tokens, "--to", "-t", "--recipient") or "someone"
        body = _flag(tokens, "--text", "-m", "--message", "--body")
        return ("jarvis.send-message", f"Send an iMessage to {to}" + (f" — “{body}”" if body else " — " + _excerpt(command)))
    if "osascript" in low and re.search(r'application\s+"?(messages|mail)"?', low) and re.search(r"\bsend\b", low):
        app = "Mail" if re.search(r'application\s+"?mail"?', low) else "Messages"
        return ("jarvis.send-message", f"Send with {app} — " + _excerpt(command))
    if re.search(r"\bhimalaya\b", low) and re.search(r"\b(send|reply|forward)\b", low):
        return ("jarvis.send-email", "Send an email — " + _excerpt(command))
    if re.search(r"\bgmail\b", low) and re.search(r"\b(send|reply|forward)\b|\+send\b", low):
        return ("jarvis.send-email", "Send an email — " + _excerpt(command))
    if re.search(r"\bcalendar\b", low) and _CALENDAR_WRITE.search(low):
        return ("jarvis.calendar-change", "Change your calendar — " + _excerpt(command))
    if re.search(r"\b(remindctl|memo)\b", low) and re.search(r"\b(delete|remove|rm)\b", low):
        return ("jarvis.delete", "Delete a reminder or note — " + _excerpt(command))
    if re.search(r"\bgh\s+(issue|pr|release|gist|repo)\s+(create|comment|edit|close|merge|delete|review)\b", low):
        return ("jarvis.post", "Post to GitHub — " + _excerpt(command))
    if _DELETE.search(low) or re.search(r"\bfind\b.*\s-delete\b", low) or _CODE_DELETE.search(command):
        return ("jarvis.delete", "Delete files — " + _excerpt(command))
    return None


def _on_pre_tool_call(tool_name: str = "", args: Any = None, **_: Any) -> Optional[Dict[str, str]]:
    found = classify(tool_name or "", args if isinstance(args, dict) else {})
    if not found:
        return None
    rule_key, description = found
    return {"action": "approve", "message": description, "rule_key": rule_key}


def register(ctx) -> None:
    if not ACTIVE:
        return
    ctx.register_system_prompt_section("jarvis-persona", _persona, max_chars=4000)
    ctx.register_hook("pre_tool_call", _on_pre_tool_call)
