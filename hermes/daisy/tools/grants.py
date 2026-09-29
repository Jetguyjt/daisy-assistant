"""approval_grant: how Daisy asks for a standing OK, once the user has said outright that she can do
something without asking ("go ahead and edit all of them, don't ask me each time").

The guard always cards it, and that card is the user's yes: it names exactly what runs without a card,
for how long, and what still asks. The guard holds the grant as pending when it shows the card, and
run() here, which Hermes only calls after the card was approved, turns on exactly that one. Called
without that card, it does nothing. The rules for what a grant covers are in guard/grants.py.

Risk "share": handing out a yes is the one thing no grant ever covers, so it sits with the risks
grants never touch."""

from __future__ import annotations

from typing import Any, Dict

from .. import registry
from ..guard import grants, roles

NOT_CARDED = ("Nothing was granted: a standing OK only starts once its approval card was approved, and no card "
              "showed this call. Call it again so the card comes up.")

DESCRIPTION = (
    "Ask the user for a standing OK, only when they've said outright that you can do something without asking "
    "(\"edit all of them, don't ask me each time\"). Never on your own initiative. Scope it to exactly what they "
    "said: the tools that do it (docs_write, notes_append, reminders_add...), scripts to run (a script file or "
    "its folder, as they are now), or clicking and typing in one app (computer_act with app). Sends, shares and "
    "deletes can't be granted and keep their card every time. duration is request (the default: until this "
    "request is done) or forever, only when they said from now on, always or every time. The user sees a card "
    "with exactly what's covered first.")

PARAMETERS = {
    "type": "object",
    "properties": {
        "what": {"type": "string", "description": "What the user said you can do without asking, in their own words."},
        "tools": {"type": "array", "items": {"type": "string"},
                  "description": "Exactly the tools this covers, by name. Only tools that edit or add things."},
        "app": {"type": "string", "description": "With computer_act: the one app you may click and type in."},
        "scripts": {"type": "string",
                    "description": "Full path of a script, or a folder of scripts, the user said you can run without "
                                   "asking. Covered as they are now; a changed or new script asks again."},
        "duration": {"type": "string", "enum": ["request", "forever"],
                     "description": "request (default): until this request is done. forever: only when the user "
                                    "said from now on, always or every time."},
    },
    "required": ["what"],
}


def _card(args: Dict[str, Any]) -> str:
    return grants.card_text(args if isinstance(args, dict) else {})


def _run(args: Dict[str, Any]) -> Any:
    session = roles.session_env("HERMES_SESSION_KEY") or "default"
    grant = grants.activate(args if isinstance(args, dict) else {}, session)
    if grant is None:
        return {"error": NOT_CARDED}
    until = ("until this request is done" if grant["duration"] == "request"
             else "from now on, until the user turns it off in Setup")
    return {"granted": True, "id": grant["id"], "until": until, "covers": grant["covers"],
            "note": "Sends, shares, deletes and anything not listed still get their card."}


registry.add(registry.TypedTool(
    name=grants.TOOL, description=DESCRIPTION, parameters=PARAMETERS, risk="share", card=_card, run=_run,
    emoji="✋"))
