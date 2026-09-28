"""What needs a yes. Typed tools are judged by the risk they declare (see registry.py); everything
else goes through the command rules in classify.py. Per-role allowlists (roles.py) and taint
tracking (taint.py) plug in here."""

from __future__ import annotations

import uuid
from typing import Any, Dict, Optional

from .. import registry
from .classify import classify


def decide(tool_name: str, args: Dict[str, Any]) -> Optional[Dict[str, str]]:
    tool = registry.get(tool_name)
    if tool is not None:
        if tool.risk == "read":
            return None
        title, detail = tool.card_parts(args)
        message = f"{title} — {detail}" if detail else title
        # A fresh rule key per call, so an approval can never be reused for a different call.
        return {"action": "approve", "message": message, "rule_key": f"daisy.{tool.name}.{uuid.uuid4().hex}"}
    found = classify(tool_name, args)
    if not found:
        return None
    rule_key, description = found
    return {"action": "approve", "message": description, "rule_key": rule_key}


def on_pre_tool_call(tool_name: str = "", args: Any = None, **_: Any) -> Optional[Dict[str, str]]:
    return decide(tool_name or "", args if isinstance(args, dict) else {})
