"""The approval guard: decides which tool calls run, which stop at a card, and which are refused.

policy.py puts it together; classify.py, commands.py (the shell) and code.py read what a call does;
roles.py and taint.py narrow it by who is calling and what the turn has read."""

from .classify import classify
from .commands import classify_command
from .policy import decide, on_pre_tool_call
from .verdict import Verdict

__all__ = ["Verdict", "classify", "classify_command", "decide", "on_pre_tool_call"]
