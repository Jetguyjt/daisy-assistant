"""Pattern rules for untyped tools (terminal, execute_code, MCP): what needs a yes before it runs.
This is a check on commands, not a sandbox."""

from __future__ import annotations

import re
import shlex
from typing import Any, Dict, Optional, Tuple


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
            return ("daisy.mcp." + tool_name, f"Run {tool_name} — " + _excerpt(str(args)))
        if re.search(r"(^|_)(create|update|patch|move)_?(event|events|calendar)", name):
            return ("daisy.calendar-change", "Change your calendar — " + _excerpt(str(args)))
    return None


def classify_command(command: str) -> Optional[Tuple[str, str]]:
    low = command.lower()
    tokens = _tokens(command)
    if re.search(r"\bimsg\b", low) and re.search(r"\bsend\b", low):
        to = _flag(tokens, "--to", "-t", "--recipient") or "someone"
        body = _flag(tokens, "--text", "-m", "--message", "--body")
        return ("daisy.send-message", f"Send an iMessage to {to}" + (f" — “{body}”" if body else " — " + _excerpt(command)))
    if "osascript" in low and re.search(r'application\s+"?(messages|mail)"?', low) and re.search(r"\bsend\b", low):
        app = "Mail" if re.search(r'application\s+"?mail"?', low) else "Messages"
        return ("daisy.send-message", f"Send with {app} — " + _excerpt(command))
    if re.search(r"\bhimalaya\b", low) and re.search(r"\b(send|reply|forward)\b", low):
        return ("daisy.send-email", "Send an email — " + _excerpt(command))
    if re.search(r"\bgmail\b", low) and re.search(r"\b(send|reply|forward)\b|\+send\b", low):
        return ("daisy.send-email", "Send an email — " + _excerpt(command))
    if re.search(r"\bcalendar\b", low) and _CALENDAR_WRITE.search(low):
        return ("daisy.calendar-change", "Change your calendar — " + _excerpt(command))
    if re.search(r"\b(remindctl|memo)\b", low) and re.search(r"\b(delete|remove|rm)\b", low):
        return ("daisy.delete", "Delete a reminder or note — " + _excerpt(command))
    if re.search(r"\bgh\s+(issue|pr|release|gist|repo)\s+(create|comment|edit|close|merge|delete|review)\b", low):
        return ("daisy.post", "Post to GitHub — " + _excerpt(command))
    if _DELETE.search(low) or re.search(r"\bfind\b.*\s-delete\b", low) or _CODE_DELETE.search(command):
        return ("daisy.delete", "Delete files — " + _excerpt(command))
    return None
