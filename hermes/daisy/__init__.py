"""Daisy client plugin for Hermes: the Daisy persona, typed tools for risky actions, and a
yes-first gate in front of them.

Hermes asks before dangerous shell commands and file edits, but a message, an email or a calendar
change can go out through a skill's CLI with no prompt. The guard closes that gap in every Hermes
process (Daisy, CLI, gateway, cron): it escalates those calls to Hermes's own approval gate, which
reaches Daisy over ACP as a permission request and shows up as a card with the exact content.
Denied, timed out or unanswered means blocked, and so does an error inside the guard. The persona
and the typed tools are only for sessions Daisy starts (DAISY_SESSION=1).

Layout: persona.py (who Daisy is), registry.py (the typed-tool contract), guard/ (what needs a
yes), tools/ (one file per tool family).
"""

from __future__ import annotations

import os

from . import learned, registry, tools  # noqa: F401  (importing tools fills the registry)
from .guard import classify, classify_command, on_pre_tool_call, sealed
from .persona import PERSONA, persona_section

ACTIVE = os.environ.get("DAISY_SESSION") == "1"

# Earlier names, kept for the tests and anything that imported them.
_persona = persona_section
_on_pre_tool_call = on_pre_tool_call


def register(ctx) -> None:
    # The guard runs in every Hermes process (Daisy, CLI, gateway, cron) and blocks if it fails.
    # The persona and the typed tools are Daisy's alone.
    ctx.register_hook("pre_tool_call", on_pre_tool_call)
    learned.register(ctx)  # logs each memory write and who made it, for the Learned feed
    sealed.register(ctx)   # undoes a tool quietly loosening grants.json or cron-allow.json
    if not ACTIVE:
        return
    ctx.register_system_prompt_section("daisy-persona", persona_section, max_chars=4000)
    registry.register_all(ctx)
