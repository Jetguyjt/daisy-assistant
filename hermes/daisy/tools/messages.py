"""iMessage as a typed tool: imsg_send ("text Dad I'm on my way").

How it sends:
- imsg (brew install steipete/tap/imsg) drives Messages through AppleScript. It runs as an argv list, never a
  shell, through `runner`, which the tests swap out. Every value goes in as --flag=value, so a message that
  starts with a dash, or is exactly --help, is still the message (imsg prints its help if it sees a bare
  --help anywhere).
- Who "Dad" is comes from contacts.py: a saved nickname first, then Contacts through daisy-contacts. A name
  that matches nobody, several people, or a person with several numbers is refused before any card, with
  who it could be, so Daisy asks instead of guessing. A phone number or email address goes as written.
  imsg only ever gets a number or an address, never a name, so it never looks anyone up on its own.
- The card shows who, the exact number or address, the service, any attachment's path and size, and the
  whole message with its line breaks. run() sends exactly what that card showed (see apple.Shown).
- A send that may have gone out is never retried: the answer says to check Messages first. "Sent" means
  Messages took it, not that it was delivered.

There's no reading. Listing chats or history means imsg reading ~/Library/Messages/chat.db, which needs Full
Disk Access for Daisy, and that would give the agent's shell every file on the Mac too. Sending text doesn't
need it. Attachments do: imsg copies the file into ~/Library/Messages/Attachments before sending it.

macOS asks "Daisy wants access to control Messages" (Automation) the first time a text goes out.
"""

from __future__ import annotations

import os
import re
import stat
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

from .. import registry
from ..guard import targets
from . import apple, contacts
from .apple import (Problem, answering, cards, child_env, clip, has_hidden, last_json, only, refusing, shown,
                    text_arg, text_block)

IMSG_ENV = "DAISY_IMSG_BIN"
SERVICES = ("auto", "imessage", "sms")
TEXT_LIMIT = 20_000
ATTACH_LIMIT = 100 * 1024 * 1024
# imsg gives Messages 150 seconds (the first send waits on the Automation prompt), then watches up to 8
# more for the message to show up.
SEND_TIMEOUT = 180.0

MISSING = ("imsg isn't installed, so Daisy can't send texts yet. The user can install it with: "
           "brew install steipete/tap/imsg")
MAYBE_SENT = ("Messages may or may not have sent this. Don't send it again: tell the user to check Messages first, so "
              "it doesn't go twice.")
NOT_ALLOWED = ("Daisy isn't allowed to control Messages, so nothing was sent. The user can turn on Messages under "
               "Daisy in System Settings → Privacy & Security → Automation, then try again.")
CANT_REACH = ("Messages couldn't send to {handle} over {service}, so nothing was sent. Either Messages isn't signed in "
              "on this Mac, or that number or address can't get {service}{sms}. Check the number with the user.")
NEEDS_DISK = ("Nothing was sent. Sending a file needs Full Disk Access for Daisy: imsg copies it into Messages' "
              "attachments folder first, which macOS protects. The user can send the text on its own, or turn Daisy "
              "on in System Settings → Privacy & Security → Full Disk Access (that opens every file on the Mac to "
              "Daisy's agent too).")
CANT_READ = ("Nothing was sent. Daisy isn't allowed to read {file}: macOS protects Desktop, Documents and Downloads "
             "until the user allows Daisy in System Settings → Privacy & Security → Files and Folders.")
SENT = "Messages took it. That means it went out, not that it was delivered or read."
COUNTS = {2: "Two", 3: "Three", 4: "Four", 5: "Five", 6: "Six", 7: "Seven", 8: "Eight"}
MOBILE = ("mobile", "iphone", "cell", "cell phone")

_PHONE = re.compile(r"^\+?[0-9(][0-9 ().\-]{3,38}$")  # what imsg itself takes as a number, not a name
# Typographic dashes and spaces that turn up in numbers copied into Contacts.
_DASHES = re.compile("[%s]" % "".join(map(chr, (*range(0x2010, 0x2016), 0x2212, 0xFE63, 0xFF0D))))
_SPACES = re.compile("[%s]" % "".join(map(chr, (0xA0, 0x2007, 0x202F))))

runner: Callable[..., Any] = apple.run_process  # the tests swap in a stand-in


def imsg_path() -> Optional[str]:
    return apple.locate("imsg", IMSG_ENV)


def available() -> bool:
    return imsg_path() is not None


# Who it goes to

@dataclass(frozen=True)
class Recipient:
    said: str      # what the card calls them: the nickname, the contact's name, or the handle itself
    handle: str    # exactly what imsg gets as --to
    kind: str      # "phone" or "email"
    who: str       # the card's Who line


def handle_kind(text: str) -> str:
    """"phone" or "email" when imsg takes text as a handle rather than a name to look up; else ""."""
    digits = sum(char.isdigit() for char in text)
    if _PHONE.match(text) and 5 <= digits <= 15:
        return "phone"
    if len(text) <= 254 and contacts.EMAIL.match(text):
        return "email"
    return ""


def tidy(handle: str) -> str:
    """A number from Contacts with typographic dashes or spaces, in plain ASCII."""
    return " ".join(_SPACES.sub(" ", _DASHES.sub("-", handle or "")).split())


def _count(number: int) -> str:
    return COUNTS.get(number, str(number))


def _handles(person: Dict[str, Any], limit: int = 3) -> str:
    found = [" ".join(part for part in (item.get("label", ""), item.get("number", "")) if part)
             for item in person.get("phones") or []]
    found += [item.get("address", "") for item in person.get("emails") or [] if item.get("address")]
    extra = len(found) - limit
    return ", ".join(found[:limit]) + (f" and {extra} more" if extra > 0 else "") if found else "no number or email"


def _people(people: List[Dict[str, Any]]) -> str:
    return "; ".join(f"{person.get('name')} ({_handles(person)})" for person in people)


def _pick(person: Dict[str, Any]) -> Tuple[str, str, str]:
    """(handle, kind, label) for one contact: its one number, its one mobile number among several, else its
    one email address. Anything more than that is the user's call."""
    name = person.get("name") or "That contact"
    phones = [(tidy(item.get("number", "")), item.get("label", "")) for item in person.get("phones") or []
              if item.get("number")]
    emails = [(item.get("address", ""), item.get("label", "")) for item in person.get("emails") or []
              if item.get("address")]
    if len(phones) > 1:
        mobile = [phone for phone in phones if phone[1].casefold() in MOBILE]
        if len(mobile) != 1:
            listed = ", ".join(" ".join(part for part in (label, number) if part) for number, label in phones)
            raise Problem(f"{name} has {len(phones)} numbers: {listed}. Ask the user which one to text. "
                          "Nothing was sent.")
        phones = mobile
    if phones:
        handle, label = phones[0]
    elif len(emails) == 1:
        handle, label = emails[0]
    elif emails:
        raise Problem(f"{name} has {len(emails)} email addresses and no phone number: "
                      f"{', '.join(address for address, _ in emails)}. Ask the user which one. Nothing was sent.")
    else:
        raise Problem(f"{name} has no phone number or email address in Contacts. Ask the user for one. "
                      "Nothing was sent.")
    kind = handle_kind(handle)
    if not kind:
        raise Problem(f"{name}'s number is written in a way Daisy can't send to safely ({handle!r}). Ask the user for "
                      "the number. Nothing was sent.")
    return handle, kind, label


def _saved_as(handle: str, kind: str) -> str:
    """The saved nickname with this exact number or address, for the card; "" if none."""
    def digits(text: str) -> str:
        return "".join(char for char in text if char.isdigit())[-10:]
    for alias in contacts.load_aliases().values():
        if kind == "email" and str(alias.get("email") or "").casefold() == handle.casefold():
            return f"{alias.get('name')}, saved as “{alias.get('nickname')}”"
        if kind == "phone" and len(digits(handle)) >= 7 and digits(str(alias.get("phone") or "")) == digits(handle):
            return f"{alias.get('name')}, saved as “{alias.get('nickname')}”"
    return ""


def recipient(value: str) -> Recipient:
    """Who "to" means, exactly. Raises Problem, with who it could be, when that isn't one number or address."""
    kind = handle_kind(value)
    if kind:
        saved = _saved_as(value, kind)
        where = "number" if kind == "phone" else "address"
        return Recipient(value, value, kind, f"the {where} as written" + (f" ({saved})" if saved else ", not looked up"))
    found = contacts.search({"query": value})
    if "error" in found:
        raise Problem(f"“{value}” isn't a saved nickname, and Contacts can't be searched right now: {found['error']}")
    people = [person for person in found.get("contacts") or [] if isinstance(person, dict)]
    if found.get("source") == "saved nickname" and people:
        saved = contacts.load_aliases().get(contacts.nickname_key(value)) or {}
        nickname = " ".join(str(saved.get("nickname") or value).split())
        handle, kind, _ = _pick(people[0])
        return Recipient(nickname, handle, kind, f"{people[0].get('name')}, your saved nickname “{nickname}”")
    strong = [person for person in people if person.get("match") in ("exact", "nickname")]
    if len(strong) == 1:
        handle, kind, label = _pick(strong[0])
        return Recipient(strong[0].get("name") or value, handle, kind,
                         f"{strong[0].get('name')} in Contacts" + (f" ({label})" if label else ""))
    if len(strong) > 1:
        raise Problem(f"{_count(len(strong))} people in Contacts are called “{value}”: {_people(strong)}. Ask the user "
                      "which one they mean. Nothing was sent.")
    if not people:
        raise Problem(f"No contact matches “{value}”. Ask the user who they mean, or for a phone number or email "
                      "address. Nothing was sent.")
    if len(people) == 1:
        raise Problem(f"“{value}” isn't a saved nickname or anyone's full name in Contacts. The closest match is "
                      f"{_people(people)}. Ask the user if that's who they mean; after a yes, save the nickname with "
                      "contacts_alias_save, or send to the number. Nothing was sent.")
    raise Problem(f"{_count(len(people))} people match “{value}”: {_people(people)}. Ask the user which one they "
                  "mean. Nothing was sent.")


# The attachment

@dataclass(frozen=True)
class Attachment:
    given: str     # as the model wrote it
    path: str      # the real file imsg gets, symlinks resolved (imsg won't follow them)
    size: int
    changed: int   # modification time, so a file swapped after the card is caught


_PRIVATE_NAMES = {".env", "auth.json", "google_token.json", "google_client_secret.json", ".netrc", ".pypirc",
                  "credentials.json", "token.json", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "chat.db"}


def _private(path: Path) -> str:
    """Why a file must never go out in a text, or "" if it can."""
    home = Path.home()
    for folder in (targets.hermes_home(), home / ".ssh", home / ".codex", home / ".aws", home / ".gnupg",
                   home / ".config" / "gcloud", home / "Library" / "Keychains", home / "Library" / "Messages",
                   home / "Library" / "Mail", home / "Library" / "Cookies", home / "Library" / "Safari"):
        for base in {folder, Path(os.path.realpath(folder))}:
            if path == base or base in path.parents:
                return "it's in a folder that holds keys, sign-ins or other apps' private data"
    name = path.name.lower()
    if name in _PRIVATE_NAMES or name.startswith(".env.") or name.endswith(".pem") or \
            ("client_secret" in name and name.endswith(".json")):
        return "it looks like a key or sign-in file"
    return ""


def size_text(size: int) -> str:
    if size < 1024:
        return f"{size} bytes"
    if size < 1024 * 1024:
        return f"{size / 1024:.0f} KB"
    return f"{size / 1024 / 1024:.1f} MB"


def attachment_arg(args: Dict[str, Any]) -> Optional[Attachment]:
    given = text_arg(args, "attachment", limit=1024)
    if not given:
        return None
    if has_hidden(given):
        raise Problem(f"attachment: {given!r} has invisible characters in it")
    expanded = os.path.expanduser(given)
    if not expanded.startswith("/"):
        raise Problem(f"attachment: use the file's full path, starting with / or ~ (not {given!r})")
    lexical = Path(os.path.normpath(expanded))
    why = _private(lexical)  # checked before anything touches the path
    real = Path(os.path.realpath(lexical)) if not why else lexical
    why = why or _private(real)
    if why:
        raise Problem(f"Daisy won't send {given}, because {why}.")
    try:
        info = real.stat()
    except PermissionError:
        raise Problem(CANT_READ.format(file=given)) from None
    except OSError:
        raise Problem(f"attachment: there's no file at {given}") from None
    if not stat.S_ISREG(info.st_mode):
        raise Problem(f"attachment: {given} isn't a file")
    if info.st_size > ATTACH_LIMIT:
        raise Problem(f"attachment: {given} is {size_text(info.st_size)}; Messages takes up to {size_text(ATTACH_LIMIT)}")
    return Attachment(given, str(real), info.st_size, info.st_mtime_ns)


# The card and the send

@dataclass(frozen=True)
class Text:
    to: Recipient
    service: str
    text: str
    attachment: Optional[Attachment]


def plan(args: Dict[str, Any]) -> Text:
    only(args, ("to", "text", "attachment", "service"), "imsg_send")
    value = " ".join(text_arg(args, "to", limit=200).split())
    if not value:
        raise Problem("to is missing: a name, nickname, phone number or email address.")
    if has_hidden(value):
        raise Problem(f"to: {value!r} has invisible characters in it")
    service = text_arg(args, "service", limit=10).lower() or "auto"
    if service not in SERVICES:
        raise Problem(f"service has to be one of: {', '.join(SERVICES)}")
    text = text_arg(args, "text", limit=TEXT_LIMIT, lines=True)
    attachment = attachment_arg(args)
    if not text and attachment is None:
        raise Problem("There's nothing to send: give text, an attachment, or both.")
    to = recipient(value)
    if service == "sms" and to.kind == "email":
        raise Problem(f"SMS needs a phone number, and {to.said} would get this at an email address ({to.handle}). "
                      "Use service auto or imessage.")
    return Text(to, service, text, attachment)


def service_line(text: Text) -> str:
    if text.service == "sms":
        return "Service: SMS (a green-bubble text, sent through the user's iPhone)"
    if text.service == "imessage":
        return "Service: iMessage only"
    if text.to.kind == "email":
        return "Service: iMessage (an email address only works with iMessage)"
    return "Service: automatic: iMessage, or SMS if Messages can't reach them on iMessage"


def send_card(args: Dict[str, Any]) -> str:
    text = plan(args)
    cards.note("imsg_send", args, text)
    to = text.to
    country = (" (no country code, so it's read as a US number)"
               if to.kind == "phone" and not to.handle.startswith("+") else "")
    lines = [f"Send {'an SMS' if text.service == 'sms' else 'an iMessage'} to {shown(to.said)}",
             f"To: {shown(to.handle)}{country}", f"Who: {shown(to.who)}", service_line(text)]
    if text.attachment:
        file = text.attachment
        really = "" if os.path.normpath(os.path.expanduser(file.given)) == file.path else f", really {file.path}"
        lines.append(f"Attachment: {shown(file.given)} ({size_text(file.size)}{really})")
    else:
        lines.append("Attachment: none")
    return "\n".join([*lines, *text_block("Message", text.text, "none (just the attachment)")])


def explain(output: str, text: Text) -> str:
    """A plain sentence for a failed imsg send, from what it printed."""
    flat = " ".join((output or "").split())
    low = flat.lower()
    if "(may_have_completed)" in low or "(still_in_flight)" in low:
        return MAYBE_SENT
    if "(not_started)" in low:
        number = re.search(r"applescript error (-?\d+)", low)
        code = number.group(1) if number else ""
        if code == "-1743":
            return NOT_ALLOWED
        if code in ("-1728", "-1719", "-1700"):
            service = "SMS" if text.service == "sms" else "iMessage"
            sms = " (SMS also needs an iPhone that forwards texts to this Mac)" if service == "SMS" else ""
            return CANT_REACH.format(handle=text.to.handle, service=service, sms=sms)
        return f"Messages didn't send it (AppleScript error {code or 'unknown'}). Nothing went out."
    file = text.attachment.given if text.attachment else "the attachment"
    if "attachment not found" in low:
        return f"The attachment isn't there anymore ({file}). Nothing was sent."
    if "securely open attachment" in low:
        if "not permitted" in low or "permission denied" in low:
            return CANT_READ.format(file=file)
        return f"imsg couldn't open the attachment, so nothing was sent: {clip(flat, 300)}"
    if "could not create staged attachment" in low or ("permission" in low and "attachments" in low):
        return NEEDS_DISK
    last = [line.strip() for line in (output or "").splitlines() if line.strip()]
    return (f"imsg stopped with an error: {clip(last[-1] if last else 'no details', 300)}. Check Messages before "
            "trying again.")


def send_run(args: Dict[str, Any]) -> Dict[str, Any]:
    text = plan(args)
    refused = cards.take("imsg_send", args, text, "who it goes to or the attachment")
    if refused:
        return {"error": refused}
    path = imsg_path()
    if path is None:
        return {"error": MISSING}
    argv = [path, "send", f"--to={text.to.handle}"]
    if text.text:
        argv.append(f"--text={text.text}")
    if text.attachment:
        argv.append(f"--file={text.attachment.path}")
    argv += [f"--service={text.service}", "--json"]
    try:
        code, out, err = runner(argv, child_env(), SEND_TIMEOUT)
    except subprocess.TimeoutExpired:
        return {"error": MAYBE_SENT}
    except OSError as error:
        return {"error": f"imsg couldn't start ({error}). Nothing was sent."}
    if code != 0:
        return {"error": explain(err or out, text)}
    data = last_json(out)
    if not (isinstance(data, dict) and data.get("status") == "sent") and out.strip() != "sent":
        return {"error": MAYBE_SENT}
    return {"status": "sent", "to": text.to.said, "handle": text.to.handle, "service": text.service, "note": SENT}


registry.add(registry.TypedTool(
    name="imsg_send",
    description=("Send an iMessage or SMS from the user's Messages app. to is who: a saved nickname or name exactly as "
                 "the user said it (\"Dad\", \"Bubba\", \"Robert Lukose\"), or a phone number or email address. Names "
                 "go through saved nicknames, then Contacts; if one matches nobody, several people or several numbers, "
                 "the call is refused with who it could be, so ask the user and try again (and save the nickname with "
                 "contacts_alias_save once they say who). text is the message exactly as it should arrive; line breaks "
                 "are kept. attachment is the full path of one file, and only works if Daisy has Full Disk Access. The "
                 "user sees the exact number, the service and the whole message on an approval card before it goes, "
                 "so don't ask for confirmation in chat. If it says it may or may not have gone out, don't send it "
                 "again: tell the user to check Messages."),
    parameters={"type": "object", "properties": {
        "to": {"type": "string",
               "description": "Who: a nickname or name as the user said it, or a phone number or email address."},
        "text": {"type": "string", "description": "The message, exactly as it should arrive."},
        "attachment": {"type": "string", "description": "Full path of one local file to send with it."},
        "service": {"type": "string", "enum": list(SERVICES),
                    "description": "auto (default): iMessage, or SMS when Messages can't reach them on iMessage."}},
        "required": ["to", "text"]},
    risk="send",
    card=refusing(send_card),
    run=answering(send_run),
    check=available,
    emoji="💬"))
