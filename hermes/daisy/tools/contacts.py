"""Contacts: who "Bubba" is.

"Text Bubba" goes like this. contacts_search checks the nicknames the user has confirmed before
($HERMES_HOME/daisy/aliases.json), then the Mac's Contacts through the daisy-contacts helper. The
first time, Daisy asks "Robert Lukose?"; after a yes, contacts_alias_save remembers it (that save is
a card), and from then on the nickname resolves directly. Sending still shows its own card every time.

The helper is a small Swift program that uses CNContactStore and prints JSON with names, phone numbers
and email addresses only. It lives in Daisy.app (Contents/MacOS/daisy-contacts); $DAISY_CONTACTS_BIN
points somewhere else. Contacts permission belongs to Daisy: hermes-acp is started by Daisy.app, so
macOS asks "Daisy would like to access your contacts" the first time a lookup runs. Run from Terminal,
the prompt names Terminal instead.

aliases.json, written only by contacts_alias_save (atomically, 0600):
    {"version": 1, "aliases": {"bubba": {"nickname": "Bubba", "name": "Robert Lukose",
                                         "phone": "+1 555 010 4477", "email": "", "saved": 1759000000}}}
The guard keeps the agent's shell and file tools out of $HERMES_HOME/daisy/, so a nickname can only
change through that card."""

from __future__ import annotations

import contextlib
import fcntl
import json
import os
import re
import subprocess
import threading
import time
from pathlib import Path
from typing import Any, Callable, Dict, Iterator, List, Optional

from .. import registry
from ..guard import targets

HELPER_ENV = "DAISY_CONTACTS_BIN"
INSTALLED = ("~/Applications/Daisy.app/Contents/MacOS/daisy-contacts",
             "/Applications/Daisy.app/Contents/MacOS/daisy-contacts")
# Long enough for the user to answer the Contacts permission prompt the first time.
TIMEOUT = 45.0
MAX_CONTACTS = 8
MAX_HANDLES = 6

_lock = threading.Lock()


class HelperMissing(Exception):
    pass


def helper() -> Optional[str]:
    """Where daisy-contacts is: $DAISY_CONTACTS_BIN, else inside the installed Daisy.app."""
    for candidate in [os.environ.get(HELPER_ENV, "")] + list(INSTALLED):
        path = os.path.expanduser(candidate.strip()) if candidate else ""
        if path and os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None


def _run_helper(arguments: List[str], timeout: float = TIMEOUT) -> str:
    path = helper()
    if path is None:
        raise HelperMissing()
    finished = subprocess.run([path, *arguments], capture_output=True, text=True, timeout=timeout,
                              check=False, stdin=subprocess.DEVNULL)
    return finished.stdout


# Swapped out by the tests, so nothing there touches the real Contacts.
runner: Callable[..., str] = _run_helper


# Nicknames

def aliases_file() -> Path:
    return targets.hermes_home() / "daisy" / "aliases.json"


def nickname_key(text: str) -> str:
    """"Bubba", " bubba ", "“Bubba”" and "my Bubba" are one nickname."""
    words = re.sub(r"[\"'“”‘’`.,!?:;]+", " ", str(text or "")).casefold().split()
    if len(words) > 1 and words[0] == "my":
        words = words[1:]
    return " ".join(words)


def load_aliases() -> Dict[str, Dict[str, Any]]:
    try:
        data = json.loads(aliases_file().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    found = data.get("aliases") if isinstance(data, dict) else None
    if not isinstance(found, dict):
        return {}
    return {key: value for key, value in found.items()
            if isinstance(key, str) and isinstance(value, dict) and isinstance(value.get("name"), str)}


@contextlib.contextmanager
def _file_lock(path: Path) -> Iterator[None]:
    fd = os.open(path.with_name(path.name + ".lock"), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        deadline = time.monotonic() + 2.0
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("the nickname list is busy; try again")
                time.sleep(0.02)
        try:
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def save_alias(alias: Dict[str, Any]) -> None:
    path = aliases_file()
    with _lock:
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with _file_lock(path):
            aliases = load_aliases()
            aliases[nickname_key(alias["nickname"])] = alias
            body = json.dumps({"version": 1, "aliases": aliases}, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
            temporary = path.with_name(f".{path.name}.{os.getpid()}.{threading.get_ident()}.tmp")
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            try:
                os.write(fd, body.encode("utf-8"))
                os.fsync(fd)
            finally:
                os.close(fd)
            os.replace(temporary, path)


# Contacts results: names, phone numbers and email addresses, nothing else

def _clip(value: Any, limit: int) -> str:
    return " ".join(str(value).split())[:limit] if isinstance(value, (str, int, float)) else ""


def _handles(items: Any, field: str, limit: int) -> List[Dict[str, str]]:
    found = []
    for item in items if isinstance(items, list) else []:
        if isinstance(item, dict) and _clip(item.get(field), limit):
            found.append({"label": _clip(item.get("label"), 40), field: _clip(item.get(field), limit)})
    return found[:MAX_HANDLES]


def contact(raw: Any) -> Optional[Dict[str, Any]]:
    """One contact as the model sees it; any other field the helper sends is dropped here."""
    if not isinstance(raw, dict) or not _clip(raw.get("name"), 200):
        return None
    return {"name": _clip(raw.get("name"), 200), "match": _clip(raw.get("match"), 20),
            "phones": _handles(raw.get("phones"), "number", 60),
            "emails": _handles(raw.get("emails"), "address", 254)}


# The tools

ASK_FIRST = ("Not a saved nickname. Unless the user said a full name that matches exactly one contact, ask "
             "which person they mean before sending anything (for example: \"Robert Lukose?\"). Once they "
             "confirm, save what they called them with contacts_alias_save so next time it resolves directly.")
NONE_FOUND = "No contact matches. Ask the user who they mean, or for a phone number or email address."
SAVED = "A nickname the user confirmed before: use this contact. Sending still shows the user a card."
DENIED = ("Daisy isn't allowed to read Contacts. The user can turn Daisy on in System Settings → Privacy & "
          "Security → Contacts, or give you the number or email address instead.")


def search(args: Dict[str, Any]) -> Dict[str, Any]:
    query = " ".join(str(args.get("query") or "").split())
    if not query or len(query) > 100:
        return {"error": "query must be a name, nickname, phone number or email address, 1 to 100 characters."}
    saved = load_aliases().get(nickname_key(query))
    if saved:
        found = {"name": _clip(saved.get("name"), 200), "match": "nickname",
                 "phones": [{"label": "saved", "number": _clip(saved.get("phone"), 60)}] if saved.get("phone") else [],
                 "emails": [{"label": "saved", "address": _clip(saved.get("email"), 254)}] if saved.get("email") else []}
        return {"query": query, "source": "saved nickname", "contacts": [found], "next": SAVED}
    try:
        output = runner(["search", query])
    except HelperMissing:
        return {"error": "Contacts lookup isn't set up on this Mac (daisy-contacts wasn't found). "
                         "Ask the user for the phone number or email address."}
    except subprocess.TimeoutExpired:
        return {"error": "Contacts didn't answer in time. If macOS is asking for permission, the user needs to "
                         "answer that first; then try again."}
    try:
        data = json.loads(output)
    except (TypeError, ValueError):
        return {"error": "The Contacts helper returned something unreadable."}
    status = data.get("status") if isinstance(data, dict) else None
    if status in ("denied", "restricted"):
        return {"error": DENIED}
    if status != "ok":
        message = _clip(data.get("message"), 300) if isinstance(data, dict) else ""
        return {"error": "Contacts lookup failed" + (f": {message}" if message else ".")}
    found = [item for item in (contact(raw) for raw in data.get("contacts") or []) if item][:MAX_CONTACTS]
    return {"query": query, "source": "contacts", "contacts": found, "next": ASK_FIRST if found else NONE_FOUND}


PHONE = re.compile(r"^\+?[0-9][0-9 ().\-]{2,38}$")
EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def _alias(args: Dict[str, Any]) -> Dict[str, str]:
    return {"nickname": " ".join(str(args.get("nickname") or "").split()),
            "name": " ".join(str(args.get("name") or "").split()),
            "phone": " ".join(str(args.get("phone") or "").split()),
            "email": "".join(str(args.get("email") or "").split())}


def _where(alias: Dict[str, Any]) -> str:
    return " · ".join(value for value in (alias.get("phone"), alias.get("email")) if value)


def alias_card(args: Dict[str, Any]) -> str:
    alias = _alias(args)
    where = _where(alias)
    lines = [f"Remember “{alias['nickname']}” means {alias['name']}" + (f" ({where})" if where else ""),
             f"Nickname: {alias['nickname']}", f"Contact: {alias['name']}"]
    if alias["phone"]:
        lines.append(f"Phone: {alias['phone']}")
    if alias["email"]:
        lines.append(f"Email: {alias['email']}")
    earlier = load_aliases().get(nickname_key(alias["nickname"]))
    if earlier and (earlier.get("name"), earlier.get("phone") or "", earlier.get("email") or "") != (
            alias["name"], alias["phone"], alias["email"]):
        lines.append(f"Replaces: {earlier.get('name')}" + (f" ({_where(earlier)})" if _where(earlier) else ""))
    return "\n".join(lines)


def alias_save(args: Dict[str, Any]) -> Dict[str, Any]:
    alias = _alias(args)
    if not 0 < len(alias["nickname"]) <= 60 or not nickname_key(alias["nickname"]):
        return {"error": "nickname must be 1 to 60 characters."}
    if not 0 < len(alias["name"]) <= 120:
        return {"error": "name must be the contact's name, 1 to 120 characters."}
    if not alias["phone"] and not alias["email"]:
        return {"error": "give the phone number or email address the user confirmed."}
    if alias["phone"] and (not PHONE.match(alias["phone"]) or sum(ch.isdigit() for ch in alias["phone"]) < 3):
        return {"error": "phone doesn't look like a phone number."}
    if alias["email"] and (len(alias["email"]) > 254 or not EMAIL.match(alias["email"])):
        return {"error": "email doesn't look like an email address."}
    save_alias({**alias, "saved": int(time.time())})
    return {"saved": True, **alias}


registry.add(registry.TypedTool(
    name="contacts_search",
    description=("Find who the user means by a name or nickname (\"Bubba\", \"Mom\", \"Robert\"), or whose number "
                 "or email this is, before texting, calling or emailing them. Checks the nicknames the user has "
                 "confirmed before, then the Mac's Contacts. Returns names, phone numbers and email addresses "
                 "only. If the answer isn't a saved nickname, confirm with the user which person they mean "
                 "before sending anything, then save it with contacts_alias_save."),
    parameters={"type": "object", "properties": {
        "query": {"type": "string", "description": "The name or nickname exactly as the user said it, or a phone number or email address."}},
        "required": ["query"]},
    risk="read",
    card=lambda args: f"Look up “{args.get('query', '')}” in Contacts",
    run=search,
    emoji="📇"))

registry.add(registry.TypedTool(
    name="contacts_alias_save",
    description=("Remember that a nickname means one contact, once the user has confirmed who they meant "
                 "(\"Robert Lukose?\" \"Yes.\"). After this, contacts_search resolves the nickname directly. Use "
                 "the contact's name and the phone number or email address you'll send to, exactly as "
                 "contacts_search returned them. The user sees a card before it's saved."),
    parameters={"type": "object", "properties": {
        "nickname": {"type": "string", "description": "What the user called them, e.g. \"Bubba\"."},
        "name": {"type": "string", "description": "The contact's full name from contacts_search."},
        "phone": {"type": "string", "description": "The number to use for this nickname, if any."},
        "email": {"type": "string", "description": "The email address to use for this nickname, if any."}},
        "required": ["nickname", "name"]},
    risk="write",
    card=alias_card,
    run=alias_save,
    emoji="📇"))
