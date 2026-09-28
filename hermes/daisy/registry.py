"""Typed tools: the contract for anything risky Daisy can do.

Every risky action (send, share, delete, a calendar write, UI control) is a typed tool instead of a
shell command. Each tool declares:

- name: snake_case, unique ("gmail_send")
- description and parameters: what the model sees (JSON schema, type "object")
- risk: "read" | "write" | "send" | "delete" | "share" | "ui"
- card(args): the full approval text, never truncated. The first line is the title ("Send an email
  to Dad"); everything after it is the exact content: every recipient, Cc, Bcc, attachment, body.
- run(args): does the work and returns something JSON-able (or a string)

The guard decides from this metadata alone; it never parses these tools' arguments. Feature code
adds tools by creating a module in tools/ that calls `add(TypedTool(...))` at import time; the
tools package imports every module in it, so nobody edits a shared list.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional, Tuple

RISKS = ("read", "write", "send", "delete", "share", "ui")


@dataclass(frozen=True)
class TypedTool:
    name: str
    description: str
    parameters: Dict[str, Any]
    risk: str
    card: Callable[[Dict[str, Any]], str]
    run: Callable[[Dict[str, Any]], Any]
    toolset: str = "hermes-acp"
    emoji: str = ""
    check: Optional[Callable[[], bool]] = field(default=None)

    @property
    def schema(self) -> Dict[str, Any]:
        return {"name": self.name, "description": self.description, "parameters": self.parameters}

    def card_parts(self, args: Dict[str, Any]) -> Tuple[str, str]:
        """(title, detail) from card(args): first line, then the rest in full."""
        text = str(self.card(args or {})).strip()
        title, _, detail = text.partition("\n")
        return title.strip(), detail.strip()


_TOOLS: Dict[str, TypedTool] = {}


def add(tool: TypedTool) -> TypedTool:
    if tool.risk not in RISKS:
        raise ValueError(f"{tool.name}: risk must be one of {RISKS}, not {tool.risk!r}")
    if not tool.name or tool.name != tool.name.lower() or " " in tool.name:
        raise ValueError(f"typed tool names are snake_case: {tool.name!r}")
    if tool.name in _TOOLS and _TOOLS[tool.name] is not tool:
        raise ValueError(f"typed tool {tool.name!r} is already registered")
    if tool.parameters.get("type") != "object":
        raise ValueError(f"{tool.name}: parameters must be a JSON schema of type object")
    _TOOLS[tool.name] = tool
    return tool


def get(name: str) -> Optional[TypedTool]:
    return _TOOLS.get(name)


def all_tools() -> List[TypedTool]:
    return list(_TOOLS.values())


def handler_for(tool: TypedTool) -> Callable[..., str]:
    """Hermes calls handlers as handler(args, **kwargs) and wants a string back."""
    def handle(args: dict, **_: Any) -> str:
        try:
            result = tool.run(args or {})
        except Exception as error:  # the model gets the failure as data, never a crash
            return json.dumps({"error": f"{type(error).__name__}: {error}"})
        return result if isinstance(result, str) else json.dumps(result, default=str)
    return handle


def register_all(ctx) -> None:
    for tool in all_tools():
        ctx.register_tool(name=tool.name, toolset=tool.toolset, schema=tool.schema, handler=handler_for(tool),
                          check_fn=tool.check, description=tool.description, emoji=tool.emoji)
