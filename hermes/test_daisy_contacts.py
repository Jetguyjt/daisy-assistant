"""Contacts tools: nickname lookup, the alias table, what the model sees, and how the guard treats them.
Nothing here touches the real Contacts: the helper is swapped for a stand-in.
Run: python3 hermes/test_daisy_contacts.py"""

import importlib
import importlib.util
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

HOME = Path(tempfile.mkdtemp(prefix="daisy-contacts-"))
os.environ["HERMES_HOME"] = str(HOME)
os.environ["DAISY_SESSION"] = "1"
os.environ.pop("DAISY_CONTACTS_BIN", None)
for name in ("HERMES_CRON_SESSION", "HERMES_SESSION_PLATFORM", "HERMES_SESSION_KEY", "HERMES_SINGLE_QUERY_SESSION",
             "HERMES_YOLO_MODE"):
    os.environ.pop(name, None)


def load():
    for name in [n for n in sys.modules if n == "daisy_plugin" or n.startswith("daisy_plugin.")]:
        del sys.modules[name]
    folder = Path(__file__).parent / "daisy"
    spec = importlib.util.spec_from_file_location("daisy_plugin", folder / "__init__.py", submodule_search_locations=[str(folder)])
    module = importlib.util.module_from_spec(spec)
    sys.modules["daisy_plugin"] = module
    spec.loader.exec_module(module)
    return module


failures = 0


def check(label, condition):
    global failures
    if not condition:
        failures += 1
        print("FAIL", label)


plugin = load()
contacts = importlib.import_module("daisy_plugin.tools.contacts")
registry = plugin.registry
policy = importlib.import_module("daisy_plugin.guard.policy")
search = registry.get("contacts_search")
save = registry.get("contacts_alias_save")
check("both tools are registered", search is not None and save is not None)
check("search only reads, saving a nickname asks first", search.risk == "read" and save.risk == "write")

ROBERT = {"name": "Robert Lukose", "match": "partial", "phones": [{"label": "mobile", "number": "+1 555 010 4477"}],
          "emails": [{"label": "home", "address": "rob@example.com"}],
          "birthday": "1990-01-01", "note": "gate code 1234", "addresses": [{"street": "1 Main St"}]}
ROBIN = {"name": "Robin Lukose", "match": "partial", "phones": [{"label": "home", "number": "+1 555 010 9000"}], "emails": []}
calls = []


def fake_helper(arguments, timeout=None):
    calls.append(arguments)
    if arguments[:1] == ["search"] and arguments[1].lower().startswith("rob"):
        return json.dumps({"status": "ok", "query": arguments[1], "contacts": [ROBERT, ROBIN]})
    return json.dumps({"status": "ok", "query": arguments[1], "contacts": []})


contacts.runner = fake_helper


def run(tool, args):
    return json.loads(registry.handler_for(tool)(args))


# "Text Bubba": nothing saved yet, so Contacts is searched and Daisy has to ask.
first = run(search, {"query": "Rob"})
check("the helper is asked for the name", calls[-1] == ["search", "Rob"])
check("matches come back", [c["name"] for c in first["contacts"]] == ["Robert Lukose", "Robin Lukose"])
check("only names, phone numbers and email addresses reach the model",
      set(first["contacts"][0]) == {"name", "match", "phones", "emails"} and "gate code" not in json.dumps(first))
check("an unconfirmed match says to ask first", first["source"] == "contacts" and "contacts_alias_save" in first["next"]
      and "ask" in first["next"])
none = run(search, {"query": "Bubba"})
check("no match says so", none["contacts"] == [] and "No contact matches" in none["next"])
check("an empty query is refused without asking the helper", "error" in run(search, {"query": "  "}) and calls[-1] == ["search", "Bubba"])

# The user says yes: saving the nickname is a card with the exact contact on it.
bubba = {"nickname": "Bubba", "name": "Robert Lukose", "phone": "+1 555 010 4477"}
title, detail = save.card_parts(bubba)
check("the card title names the nickname and the contact", title == "Remember “Bubba” means Robert Lukose (+1 555 010 4477)")
check("the card shows exactly what's saved", detail == "Nickname: Bubba\nContact: Robert Lukose\nPhone: +1 555 010 4477")
long_name = "Robert " + "Very" * 25 + " Lukose"
check("the card never shortens a long name", long_name in "\n".join(save.card_parts({**bubba, "name": long_name})))

saved = run(save, bubba)
check("saving works", saved["saved"] is True and saved["name"] == "Robert Lukose")
aliases = HOME / "daisy" / "aliases.json"
check("the alias table is private", stat.S_IMODE(aliases.stat().st_mode) == 0o600)
table = json.loads(aliases.read_text())
check("the alias table has the nickname", table["version"] == 1 and table["aliases"]["bubba"]["phone"] == "+1 555 010 4477")
check("no temporary files are left", not [p for p in aliases.parent.iterdir() if p.name.endswith(".tmp")])

# Next time it resolves directly, whatever the spelling, without asking Contacts.
asked = len(calls)
for spelling in ("Bubba", "bubba", "“Bubba”", "my Bubba", "  BUBBA "):
    again = run(search, {"query": spelling})
    check(f"{spelling!r} resolves from the saved nickname", again["source"] == "saved nickname"
          and again["contacts"][0]["name"] == "Robert Lukose" and again["contacts"][0]["phones"][0]["number"] == "+1 555 010 4477")
check("a saved nickname doesn't touch Contacts", len(calls) == asked)

# Changing a nickname shows what it replaces.
_, changed = save.card_parts({"nickname": "bubba", "name": "Robin Lukose", "phone": "+1 555 010 9000"})
check("a new contact for a saved nickname says what it replaces", changed.endswith("Replaces: Robert Lukose (+1 555 010 4477)"))
_, same = save.card_parts(bubba)
check("saving the same thing again replaces nothing", "Replaces" not in same)

# Bad input is refused and nothing is written.
before = aliases.read_text()
for bad in ({"nickname": "Bubba", "name": "Robert Lukose"},
            {"nickname": "Bubba", "name": "Robert Lukose", "phone": "call me"},
            {"nickname": "Bubba", "name": "Robert Lukose", "email": "not an email"},
            {"nickname": "", "name": "Robert Lukose", "phone": "+1 555 010 4477"},
            {"nickname": "x" * 61, "name": "Robert Lukose", "phone": "+1 555 010 4477"},
            {"nickname": "Bubba", "name": "", "phone": "+1 555 010 4477"}):
    check(f"refuses {bad}", "error" in run(save, bad))
check("refused saves change nothing", aliases.read_text() == before)
check("an email-only nickname is fine", run(save, {"nickname": "Work Rob", "name": "Robert Lukose",
                                                    "email": "rob@example.com"})["saved"] is True)

# A broken alias table counts as empty rather than failing the lookup.
aliases.write_text("{ half written")
check("a broken alias table falls back to Contacts", run(search, {"query": "Bubba"})["source"] == "contacts")
aliases.write_text(before)


# The helper's own answers.
def answering(payload):
    def fake(arguments, timeout=None):
        if isinstance(payload, Exception):
            raise payload
        return payload
    return fake


contacts.runner = answering(json.dumps({"status": "denied"}))
check("no permission says where to turn it on", "Privacy & Security → Contacts" in run(search, {"query": "Sam"})["error"])
contacts.runner = answering(subprocess.TimeoutExpired(["daisy-contacts"], 45))
check("a helper that never answers times out", "didn't answer in time" in run(search, {"query": "Sam"})["error"])
contacts.runner = answering(contacts.HelperMissing())
check("a missing helper says so", "isn't set up" in run(search, {"query": "Sam"})["error"])
contacts.runner = answering("not json")
check("garbage from the helper is an error", "unreadable" in run(search, {"query": "Sam"})["error"])
contacts.runner = answering(json.dumps({"status": "error", "message": "store failed"}))
check("a helper error is passed on", run(search, {"query": "Sam"})["error"] == "Contacts lookup failed: store failed")
contacts.runner = fake_helper

# Finding the helper: $DAISY_CONTACTS_BIN first, and only a real executable counts.
fake_bin = HOME / "daisy-contacts"
fake_bin.write_text("#!/bin/sh\necho '{\"status\":\"ok\",\"contacts\":[]}'\n")
os.environ["DAISY_CONTACTS_BIN"] = str(fake_bin)
check("a helper that isn't executable doesn't count", contacts.helper() != str(fake_bin))
fake_bin.chmod(0o755)
check("DAISY_CONTACTS_BIN is used", contacts.helper() == str(fake_bin))
check("the default runner runs the helper", json.loads(contacts._run_helper(["search", "x"])) == {"status": "ok", "contacts": []})
os.environ["DAISY_CONTACTS_BIN"] = str(HOME / "missing")
if contacts.helper() is None:
    try:
        contacts._run_helper(["search", "x"])
        check("a missing helper raises", False)
    except contacts.HelperMissing:
        pass
os.environ.pop("DAISY_CONTACTS_BIN")

# The guard: lookups run, a nickname save is a card with the exact contact, workers can't save.
check("contacts_search runs without a card", policy.decide("contacts_search", {"query": "Bubba"},
                                                             session_id="g-1", task_id="g-1", turn_id="t1") is None)
card = policy.decide("contacts_alias_save", bubba, session_id="g-2", task_id="g-2", turn_id="t1")
check("saving a nickname stops at a card", card and card["action"] == "approve")
check("the card text is the tool's own, in full", card and card["message"] ==
      "Remember “Bubba” means Robert Lukose (+1 555 010 4477) — Nickname: Bubba\nContact: Robert Lukose\nPhone: +1 555 010 4477")
second = policy.decide("contacts_alias_save", bubba, session_id="g-3", task_id="g-3", turn_id="t1")
check("each save gets its own rule key", card and second and card["rule_key"] != second["rule_key"])
(HOME / "daisy" / "roles.json").write_text(json.dumps({"version": 1, "sessions": {"w-1": "worker"}}))
worker = policy.decide("contacts_alias_save", bubba, session_id="w-1", task_id="w-1", turn_id="t1")
check("a background job can't save a nickname", worker and worker["action"] == "block")
check("a background job can still look someone up",
      policy.decide("contacts_search", {"query": "Bubba"}, session_id="w-1", task_id="w-1", turn_id="t1") is None)
(HOME / "daisy" / "roles.json").unlink()
check("the agent can't edit the alias table from a shell",
      plugin.classify("terminal", {"command": "echo '{}' > ~/.hermes/daisy/aliases.json"}).decision == "block")

shutil.rmtree(HOME, ignore_errors=True)
print("contacts checks:", "ok" if failures == 0 else f"{failures} failed")
sys.exit(1 if failures else 0)
