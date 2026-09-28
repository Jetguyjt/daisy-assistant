"""iMessage (hermes/daisy/tools/messages.py) against stand-ins: who "Dad" is, every card in full, the argv imsg gets,
what its errors turn into, check() hiding the tool, and what the guard makes of it all. Nothing here sends a message,
runs imsg to send, or reads the real Contacts: imsg and the Contacts helper are both swapped for stand-ins.
Run: python3 hermes/test_daisy_messages.py"""

import importlib.util
import itertools
import json
import logging
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from types import SimpleNamespace

HOME = Path(os.path.realpath(tempfile.mkdtemp(prefix="daisy-messages-")))
FILES = Path(os.path.realpath(tempfile.mkdtemp(prefix="daisy-messages-files-")))  # attachments, outside HERMES_HOME
USER_HOME = Path(os.path.realpath(tempfile.mkdtemp(prefix="daisy-messages-user-")))  # ~ is a stand-in, never the real one
FAKE_IMSG = HOME / "bin" / "imsg"  # check() only needs an executable here; the runner never starts it
os.environ["HERMES_HOME"] = str(HOME)
os.environ["HOME"] = str(USER_HOME)
os.environ["DAISY_SESSION"] = "1"
os.environ["DAISY_IMSG_BIN"] = str(FAKE_IMSG)
os.environ["DAISY_TEST_SECRET"] = "not-a-real-secret-0000"
os.environ["TZ"] = "America/New_York"
time.tzset()
os.environ.pop("DAISY_CONTACTS_BIN", None)
for name in ("HERMES_CRON_SESSION", "HERMES_SESSION_PLATFORM", "HERMES_SESSION_KEY", "HERMES_SESSION_ID",
             "HERMES_SINGLE_QUERY_SESSION", "HERMES_YOLO_MODE"):
    os.environ.pop(name, None)
logging.getLogger("daisy.guard").addHandler(logging.NullHandler())
logging.getLogger("daisy.guard").propagate = False

FIXTURES = Path(__file__).parent / "fixtures" / "apple" / "imsg"


def load():
    for name in [n for n in sys.modules if n == "daisy_plugin" or n.startswith("daisy_plugin.")]:
        del sys.modules[name]
    folder = Path(__file__).parent / "daisy"
    spec = importlib.util.spec_from_file_location("daisy_plugin", folder / "__init__.py",
                                                  submodule_search_locations=[str(folder)])
    module = importlib.util.module_from_spec(spec)
    sys.modules["daisy_plugin"] = module
    spec.loader.exec_module(module)
    return module


failures = 0


def check(label, test):
    """test is a no-argument function; an exception counts as a failure."""
    global failures
    try:
        ok = bool(test())
    except Exception as error:
        ok = False
        label += f"  (raised {type(error).__name__}: {error})"
    if not ok:
        failures += 1
        print("FAIL", label)


def executable(path, text="#!/bin/sh\nexit 3\n"):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(0o755)
    return path


executable(FAKE_IMSG)
plugin = load()
registry = plugin.registry
messages = sys.modules["daisy_plugin.tools.messages"]
contacts = sys.modules["daisy_plugin.tools.contacts"]
apple = sys.modules["daisy_plugin.tools.apple"]
policy = sys.modules["daisy_plugin.guard.policy"]
tool = registry.get("imsg_send")
ids = itertools.count(1)

# Contacts: the real helper is never found or run. The stand-in answers from PEOPLE and records every query.
contacts.INSTALLED = ()
ROBERT = {"name": "Robert Doe", "match": "exact", "phones": [{"label": "mobile", "number": "+1 555 0142"}], "emails": []}
ROBERT_PARTIAL = dict(ROBERT, match="partial")
ROBIN = {"name": "Robin Doe", "match": "partial", "phones": [{"label": "home", "number": "+1 555 0143"}],
         "emails": [{"label": "home", "address": "robin@example.com"}]}
JANE = {"name": "Jane Doe", "match": "nickname", "phones": [{"label": "home", "number": "+1 555 0150"},
                                                             {"label": "mobile", "number": "+1 555 0151"}], "emails": []}
GRANDMA = {"name": "Grandma Doe", "match": "exact", "phones": [{"label": "mobile", "number": "+1 555 0160"},
                                                               {"label": "iPhone", "number": "+1 555 0161"}], "emails": []}
COACH = {"name": "Coach Example", "match": "exact", "phones": [], "emails": [{"label": "work", "address": "coach@example.com"}]}
SAM = {"name": "Sam Example", "match": "exact", "phones": [], "emails": []}
PAT = {"name": "Pat Sample", "match": "exact", "phones": [{"label": "work", "number": "+1 555 0170 ext. 2"}], "emails": []}
DASHES = {"name": "Dana Sample", "match": "exact", "phones": [{"label": "mobile", "number": "+1" + chr(0xA0) + "555" + chr(0x2011) + "0180"}], "emails": []}
TWINS = [dict(ROBERT, name="Alex Doe"), dict(ROBERT, name="Alex Doe", phones=[{"label": "mobile", "number": "+1 555 0190"}])]
PEOPLE = {"robert doe": [ROBERT], "rob": [ROBERT_PARTIAL, ROBIN], "robin": [ROBIN], "mom": [JANE], "grandma": [GRANDMA],
          "coach": [COACH], "sam": [SAM], "pat": [PAT], "dana": [DASHES], "alex doe": TWINS,
          "the doe family": [dict(ROBIN, name=f"Doe {n}") for n in range(8)]}
queries = []


def helper(arguments, timeout=None):
    queries.append(arguments)
    return json.dumps({"status": "ok", "query": arguments[1], "contacts": PEOPLE.get(arguments[1].casefold(), [])})


contacts.runner = helper
aliases = HOME / "daisy" / "aliases.json"


def save_aliases(table):
    aliases.parent.mkdir(parents=True, exist_ok=True)
    aliases.write_text(json.dumps({"version": 1, "aliases": table}))


DAD = {"nickname": "Dad", "name": "Robert Doe", "phone": "+1 555 0100", "email": "", "saved": 1759000000}
BUBBA = {"nickname": "Bubba", "name": "Robin Doe", "phone": "", "email": "robin@example.com", "saved": 1759000000}
save_aliases({"dad": DAD, "bubba": BUBBA})


class Fake:
    """Stands in for messages.runner: records every call and answers with (code, out, err), or raises."""

    def __init__(self):
        self.calls = []
        self.answer = (0, (FIXTURES / "sent.json").read_text(), "")

    def __call__(self, argv, env, timeout):
        self.calls.append(SimpleNamespace(argv=list(argv), env=dict(env), timeout=timeout))
        if isinstance(self.answer, BaseException):
            raise self.answer
        return self.answer


fake = Fake()
messages.runner = fake
IMSG = str(FAKE_IMSG)


def card(args):
    title, detail = tool.card_parts(args)
    return title + "\n" + detail


def refused(args):
    try:
        tool.card(args)
    except registry.Refused as refusal:
        return str(refusal)
    return None


def send(args):
    """One send the way Hermes makes it: the guard's hook first (which builds the card), then the handler."""
    session = f"send-{next(ids)}"
    directive = policy.decide("imsg_send", args, task_id=session, session_id=session, turn_id="t1")
    result = json.loads(registry.handler_for(tool)(args))
    return directive, result


def fx(name):
    return (FIXTURES / name).read_text()


# The contract.
check("imsg_send is registered as a send", lambda: tool is not None and tool.risk == "send")
check("it goes to Daisy's toolset", lambda: tool.toolset == "hermes-acp" and tool.emoji == "💬")
check("its parameters are an object: to and text required", lambda: tool.parameters["type"] == "object"
      and tool.parameters["required"] == ["to", "text"]
      and set(tool.parameters["properties"]) == {"to", "text", "attachment", "service"})
check("the description says the card is the confirmation", lambda: "approval card" in tool.description
      and "don't ask for confirmation" in tool.description)
check("check() is imsg being there", lambda: tool.check is messages.available and tool.check())

# check(): hidden until imsg is installed.
FAKE_IMSG.unlink()
check("no imsg, no tool", lambda: not tool.check())
executable(FAKE_IMSG).chmod(0o644)
check("an imsg that can't run doesn't count", lambda: not tool.check())
FAKE_IMSG.chmod(0o755)
check("an executable imsg counts", lambda: tool.check())
os.environ.pop("DAISY_IMSG_BIN")
saved_path, saved_brew = os.environ.get("PATH", ""), apple.HOMEBREW
os.environ["PATH"] = str(HOME / "empty")
apple.HOMEBREW = (str(HOME / "empty"),)
check("without DAISY_IMSG_BIN, an imsg on neither the PATH nor Homebrew's folders doesn't count", lambda: not tool.check())
brew = executable(HOME / "brew" / "imsg")
apple.HOMEBREW = (str(brew.parent),)
check("Homebrew's folder is searched even when the PATH is short (an app started from the Dock)",
      lambda: messages.imsg_path() == str(brew))
os.environ["PATH"], apple.HOMEBREW = saved_path, saved_brew
os.environ["DAISY_IMSG_BIN"] = IMSG

# Who "to" means. Saved nicknames first, and they never touch Contacts.
asked = len(queries)
check("a saved nickname resolves", lambda: card({"to": "Dad", "text": "I'm on my way"}) == (
    "Send an iMessage to Dad\n"
    "To: +1 555 0100\n"
    "Who: Robert Doe, your saved nickname “Dad”\n"
    "Service: automatic: iMessage, or SMS if Messages can't reach them on iMessage\n"
    "Attachment: none\n"
    "Message:\n"
    "I'm on my way"))
check("any spelling of a saved nickname works", lambda: card({"to": "my dad", "text": "hi"}).startswith(
    "Send an iMessage to Dad\nTo: +1 555 0100\n"))
check("a nickname saved with only an email address sends there", lambda: card({"to": "Bubba", "text": "yo"}).split("\n")[:4] == [
    "Send an iMessage to Bubba", "To: robin@example.com", "Who: Robin Doe, your saved nickname “Bubba”",
    "Service: iMessage (an email address only works with iMessage)"])
check("saved nicknames never ask Contacts", lambda: len(queries) == asked)

# Then Contacts: one person, by their whole name or their contact card's nickname.
check("a full name that matches one contact resolves", lambda: card({"to": "Robert Doe", "text": "hi"}) == (
    "Send an iMessage to Robert Doe\n"
    "To: +1 555 0142\n"
    "Who: Robert Doe in Contacts (mobile)\n"
    "Service: automatic: iMessage, or SMS if Messages can't reach them on iMessage\n"
    "Attachment: none\n"
    "Message:\n"
    "hi"))
check("Contacts was asked for exactly what the user said", lambda: queries[-1] == ["search", "Robert Doe"])
check("a contact card's nickname resolves, to the one mobile number among several",
      lambda: card({"to": "Mom", "text": "hi"}).split("\n")[:3] == [
          "Send an iMessage to Jane Doe", "To: +1 555 0151", "Who: Jane Doe in Contacts (mobile)"])
check("an email-only contact gets it by email", lambda: card({"to": "Coach", "text": "hi"}).split("\n")[1] == "To: coach@example.com")
check("typographic spaces and dashes in a Contacts number become plain ones",
      lambda: card({"to": "Dana", "text": "hi"}).split("\n")[1] == "To: +1 555-0180")

# Anything else is refused before a card, with who it could be, and never guessed.
check("an ambiguous name lists everyone it could be", lambda: refused({"to": "Rob", "text": "hi"}) == (
    "Two people match “Rob”: Robert Doe (mobile +1 555 0142); Robin Doe (home +1 555 0143, robin@example.com). "
    "Ask the user which one they mean. Nothing was sent."))
check("one partial match still asks first", lambda: refused({"to": "Robin", "text": "hi"}) == (
    "“Robin” isn't a saved nickname or anyone's full name in Contacts. The closest match is Robin Doe (home +1 555 "
    "0143, robin@example.com). Ask the user if that's who they mean; after a yes, save the nickname with "
    "contacts_alias_save, or send to the number. Nothing was sent."))
check("an unknown name says so", lambda: refused({"to": "Uncle Bob", "text": "hi"}) == (
    "No contact matches “Uncle Bob”. Ask the user who they mean, or for a phone number or email address. "
    "Nothing was sent."))
check("two contacts with the very same name are refused", lambda: refused({"to": "Alex Doe", "text": "hi"}).startswith(
    "Two people in Contacts are called “Alex Doe”: Alex Doe (mobile +1 555 0142); Alex Doe (mobile +1 555 0190)."))
check("a crowd is counted", lambda: refused({"to": "the Doe family", "text": "hi"}).startswith("Eight people match"))
check("two mobile numbers for one person are the user's call", lambda: refused({"to": "Grandma", "text": "hi"}) == (
    "Grandma Doe has 2 numbers: mobile +1 555 0160, iPhone +1 555 0161. Ask the user which one to text. "
    "Nothing was sent."))
check("a contact with no number or email is refused", lambda: refused({"to": "Sam", "text": "hi"}) == (
    "Sam Example has no phone number or email address in Contacts. Ask the user for one. Nothing was sent."))
check("a number imsg would read as a name is refused", lambda: refused({"to": "Pat", "text": "hi"}) == (
    "Pat Sample's number is written in a way Daisy can't send to safely ('+1 555 0170 ext. 2'). Ask the user for "
    "the number. Nothing was sent."))
check("a leading-dash 'name' is just a name nobody has", lambda: refused({"to": "--help", "text": "hi"}).startswith(
    "No contact matches “--help”."))


def helper_says(payload):
    def fake_helper(arguments, timeout=None):
        if isinstance(payload, BaseException):
            raise payload
        return payload
    return fake_helper


contacts.runner = helper_says(contacts.HelperMissing())
check("no Contacts helper: names can't be looked up, and it says so", lambda: refused({"to": "Robert Doe", "text": "hi"}) == (
    "“Robert Doe” isn't a saved nickname, and Contacts can't be searched right now: Contacts lookup isn't set up on "
    "this Mac (daisy-contacts wasn't found). Ask the user for the phone number or email address."))
check("...but saved nicknames still work", lambda: card({"to": "Dad", "text": "hi"}).startswith("Send an iMessage to Dad"))
contacts.runner = helper_says(json.dumps({"status": "denied"}))
check("Contacts permission off says where to turn it on",
      lambda: "Privacy & Security → Contacts" in refused({"to": "Robert Doe", "text": "hi"}))
contacts.runner = helper_says(subprocess.TimeoutExpired(["daisy-contacts"], 45))
check("a Contacts helper that never answers is refused", lambda: "didn't answer in time" in refused({"to": "Robert Doe", "text": "hi"}))
contacts.runner = helper

# Numbers and email addresses go as written; a matching saved nickname is named on the card.
asked = len(queries)
check("a number that's a saved nickname's says whose it is", lambda: card({"to": "+1 555 0100", "text": "hi"}).split("\n")[:3] == [
    "Send an iMessage to +1 555 0100", "To: +1 555 0100", "Who: the number as written (Robert Doe, saved as “Dad”)"])
check("an unknown number is sent as written", lambda: card({"to": "+44 20 7946 0000", "text": "hi"}).split("\n")[:3] == [
    "Send an iMessage to +44 20 7946 0000", "To: +44 20 7946 0000", "Who: the number as written, not looked up"])
check("a number with no country code says it's read as a US number",
      lambda: card({"to": "(555) 010-0100", "text": "hi"}).split("\n")[1] ==
      "To: (555) 010-0100 (no country code, so it's read as a US number)")
check("an email address is sent as written", lambda: card({"to": "someone@example.com", "text": "hi"}).split("\n")[:4] == [
    "Send an iMessage to someone@example.com", "To: someone@example.com", "Who: the address as written, not looked up",
    "Service: iMessage (an email address only works with iMessage)"])
check("numbers and addresses never ask Contacts", lambda: len(queries) == asked)

# Services.
check("SMS says so, in the title too", lambda: card({"to": "Dad", "text": "hi", "service": "sms"}).split("\n")[0:4:3] == [
    "Send an SMS to Dad", "Service: SMS (a green-bubble text, sent through the user's iPhone)"])
check("iMessage only says so", lambda: "Service: iMessage only" in card({"to": "Dad", "text": "hi", "service": "iMessage"}))
check("SMS to an email address is refused", lambda: refused({"to": "Bubba", "text": "hi", "service": "sms"}) == (
    "SMS needs a phone number, and Bubba would get this at an email address (robin@example.com). "
    "Use service auto or imessage."))
check("an unknown service is refused", lambda: refused({"to": "Dad", "text": "hi", "service": "whatsapp"}) ==
      "service has to be one of: auto, imessage, sms")

# The message, never shortened, line breaks and all.
FAMILY = chr(0x200D).join((chr(0x1F468), chr(0x1F469), chr(0x1F467)))  # one emoji, held together by zero-width joiners
long_text = "Line one\n\nLine three says “hi” & 'bye' 😀 " + FAMILY + "\n" + "x" * 5000 + " END"
check("the whole message is on the card, every line", lambda: card({"to": "Dad", "text": long_text}).endswith(
    "Message (4 lines):\n" + long_text))
check("leading and trailing blank lines are trimmed off what's sent and shown",
      lambda: card({"to": "Dad", "text": "\n\n  hi there \n\n"}).endswith("Message:\nhi there"))
check("Windows line breaks count as line breaks", lambda: card({"to": "Dad", "text": "a\r\nb"}).endswith("Message (2 lines):\na\nb"))
check("invisible or reordering characters are shown, not hidden",
      lambda: card({"to": "Dad", "text": "pay " + chr(0x202E) + "me" + chr(0x200B) + " back"}).endswith("Message:\npay [U+202E]me[U+200B] back"))
check("control characters are refused", lambda: refused({"to": "Dad", "text": "ring \x07"}) == "text can't contain control characters")
check("a line break in to is refused", lambda: "control characters" in refused({"to": "Dad\n+1 555 0199", "text": "hi"}))
check("an invisible character in to is refused", lambda: "invisible" in refused({"to": "D" + chr(0x200B) + "ad", "text": "hi"}))
check("nothing to send is refused", lambda: refused({"to": "Dad", "text": "  "}) ==
      "There's nothing to send: give text, an attachment, or both.")
check("an argument the tool doesn't take is refused, not ignored", lambda: refused({"to": "Dad", "text": "hi", "file": "/x"}) ==
      "imsg_send doesn't take file. It takes: to, text, attachment, service.")
check("a message that's too long is refused", lambda: "too long" in refused({"to": "Dad", "text": "x" * 20001}))

# Attachments: the path and size, and the real file when a link points somewhere else.
photo = FILES / "photo.jpg"
photo.write_bytes(b"\xff\xd8" + b"0" * 2_300_000)
linked = FILES / "latest.jpg"
linked.symlink_to(photo)
check("an attachment shows its path and size", lambda: card({"to": "Dad", "text": "look", "attachment": str(photo)}).split("\n")[4] ==
      f"Attachment: {photo} (2.2 MB)")
check("a link shows the real file it sends", lambda: card({"to": "Dad", "text": "", "attachment": str(linked)}).split("\n")[4:] == [
    f"Attachment: {linked} (2.2 MB, really {photo})", "Message: none (just the attachment)"])
(FILES / "id_ed25519").write_text("key")
(FILES / ".env.local").write_text("KEY=1")
(HOME / "notes.txt").write_text("in hermes home")
(FILES / "folder").mkdir()
sparse = FILES / "huge.mov"
with open(sparse, "wb") as handle:
    handle.truncate(100 * 1024 * 1024 + 1)
for label, path, expected in [
    ("a missing file", FILES / "nope.jpg", f"attachment: there's no file at {FILES / 'nope.jpg'}"),
    ("a folder", FILES / "folder", f"attachment: {FILES / 'folder'} isn't a file"),
    ("a key", FILES / "id_ed25519", f"Daisy won't send {FILES / 'id_ed25519'}, because it looks like a key or sign-in file."),
    ("an env file", FILES / ".env.local", f"Daisy won't send {FILES / '.env.local'}, because it looks like a key or sign-in file."),
    ("anything in Hermes's home", HOME / "notes.txt", f"Daisy won't send {HOME / 'notes.txt'}, because it's in a folder "
                                                      "that holds keys, sign-ins or other apps' private data."),
    ("a file over 100 MB", sparse, f"attachment: {sparse} is 100.0 MB; Messages takes up to 100.0 MB"),
    ("a relative path", "photo.jpg", "attachment: use the file's full path, starting with / or ~ (not 'photo.jpg')"),
]:
    check(f"refuses {label} as an attachment", lambda path=path, expected=expected: refused(
        {"to": "Dad", "text": "hi", "attachment": str(path)}) == expected)
check("Messages' own folder is off limits", lambda: "private data" in refused(
    {"to": "Dad", "text": "hi", "attachment": "~/Library/Messages/chat.db"}))

# The argv imsg gets: --flag=value for every value, so nothing in the message can turn into an option.
fake.calls.clear()
directive, result = send({"to": "Dad", "text": "I'm on my way"})
check("the guard stops a send at a card", lambda: directive and directive["action"] == "approve")
check("after the card it sends", lambda: result == {"status": "sent", "to": "Dad", "handle": "+1 555 0100", "service": "auto",
                                                    "note": messages.SENT})
check("imsg gets the resolved number, the text and --json", lambda: fake.calls[-1].argv == [
    IMSG, "send", "--to=+1 555 0100", "--text=I'm on my way", "--service=auto", "--json"])
check("it waits long enough for the Automation prompt", lambda: fake.calls[-1].timeout == messages.SEND_TIMEOUT >= 160)
check("imsg gets no secrets from Hermes's environment", lambda: "DAISY_TEST_SECRET" not in fake.calls[-1].env
      and set(fake.calls[-1].env) <= set(apple.ENV_KEPT) | {"PATH"} and fake.calls[-1].env["PATH"] == apple.CHILD_PATH)
for label, text in [("--help", "--help"), ("a dash and a letter", "-n hi"), ("a fake --to", "--to=+1 555 0199"),
                    ("quotes and a dollar sign", "it's \"$HOME\" `ls`"), ("emoji", "😀👍🏽 🇺🇸"),
                    ("several lines", "one\ntwo\n\nfour"), ("just --", "--")]:
    send({"to": "Dad", "text": text})
    check(f"{label} stays the message", lambda text=text: fake.calls[-1].argv == [
        IMSG, "send", "--to=+1 555 0100", f"--text={text}", "--service=auto", "--json"])
send({"to": "-5550100@example.com", "text": "hi"})
check("an address starting with a dash stays the address", lambda: fake.calls[-1].argv[2] == "--to=-5550100@example.com")
send({"to": "Dad", "text": "look", "attachment": str(linked), "service": "imessage"})
check("an attachment goes by its real path (imsg won't follow links)", lambda: fake.calls[-1].argv == [
    IMSG, "send", "--to=+1 555 0100", "--text=look", f"--file={photo}", "--service=imessage", "--json"])
send({"to": "Dad", "text": "", "attachment": str(photo)})
check("an attachment alone sends no --text", lambda: fake.calls[-1].argv == [
    IMSG, "send", "--to=+1 555 0100", f"--file={photo}", "--service=auto", "--json"])
check("every argument is one argv item, never a shell line", lambda: all(isinstance(part, str) for call in fake.calls
                                                                          for part in call.argv))

# What imsg's answers turn into.
fake.answer = (0, "sent\n", "")
check("plain 'sent' counts as sent", lambda: send({"to": "Dad", "text": "a"})[1]["status"] == "sent")
fake.answer = (0, "", "")
check("no answer at all is 'maybe sent', never 'sent'", lambda: send({"to": "Dad", "text": "b"})[1] == {"error": messages.MAYBE_SENT})
for name, service, expected in [
    ("automation_denied.txt", "auto", messages.NOT_ALLOWED),
    ("unknown_handle.txt", "auto", "Messages couldn't send to +1 555 0100 over iMessage, so nothing was sent. Either "
                                   "Messages isn't signed in on this Mac, or that number or address can't get iMessage. "
                                   "Check the number with the user."),
    ("no_sms_service.txt", "sms", "Messages couldn't send to +1 555 0100 over SMS, so nothing was sent. Either Messages "
                                  "isn't signed in on this Mac, or that number or address can't get SMS (SMS also needs "
                                  "an iPhone that forwards texts to this Mac). Check the number with the user."),
    ("not_running.txt", "auto", "Messages didn't send it (AppleScript error -600). Nothing went out."),
    ("unconfirmed.txt", "auto", messages.MAYBE_SENT),
    ("osascript_timeout.txt", "auto", messages.MAYBE_SENT),
    ("attachment_not_found.txt", "auto", f"The attachment isn't there anymore ({photo}). Nothing was sent."),
    ("attachment_symlink.txt", "auto", "imsg couldn't open the attachment, so nothing was sent: AppleScript failed: "
                                       "Could not securely open attachment at /private/tmp/daisy-files/photo.jpg: Too "
                                       "many levels of symbolic links"),
    ("attachment_not_permitted.txt", "auto", messages.CANT_READ.format(file=photo)),
    ("attachment_staging.txt", "auto", messages.NEEDS_DISK),
    ("other_error.txt", "auto", "imsg stopped with an error: Invalid chat target: Messages database unavailable. Check "
                                "Messages before trying again."),
]:
    fake.answer = (1, "", fx(name))
    check(f"imsg's {name} becomes a plain sentence", lambda service=service, expected=expected: send(
        {"to": "Dad", "text": "hi", "service": service, "attachment": str(photo)})[1] == {"error": expected})
fake.answer = subprocess.TimeoutExpired(["imsg"], 180)
check("a send that times out may have gone, so it's never 'sent' and never retried",
      lambda: send({"to": "Dad", "text": "c"})[1] == {"error": messages.MAYBE_SENT} and "Don't send it again" in messages.MAYBE_SENT)
fake.answer = OSError("Exec format error")
check("an imsg that can't start says nothing was sent", lambda: send({"to": "Dad", "text": "d"})[1] == {
    "error": "imsg couldn't start (Exec format error). Nothing was sent."})
fake.answer = (0, fx("sent.json"), "")
tool.card({"to": "Dad", "text": "e"})
FAKE_IMSG.unlink()
check("imsg gone by the time it runs says how to install it",
      lambda: json.loads(registry.handler_for(tool)({"to": "Dad", "text": "e"})) == {"error": messages.MISSING})
executable(FAKE_IMSG)

# It only sends what a card showed, exactly as the card showed it.
fake.calls.clear()
check("no card, no send", lambda: json.loads(registry.handler_for(tool)({"to": "Dad", "text": "unseen"})) == {
    "error": apple.NOT_SHOWN} and not fake.calls)
tool.card({"to": "Dad", "text": "once"})
first = json.loads(registry.handler_for(tool)({"to": "Dad", "text": "once"}))
again = json.loads(registry.handler_for(tool)({"to": "Dad", "text": "once"}))
check("one card is one send", lambda: first["status"] == "sent" and again == {"error": apple.NOT_SHOWN} and len(fake.calls) == 1)
tool.card({"to": "Dad", "text": "moved"})
save_aliases({"dad": dict(DAD, phone="+1 555 0199"), "bubba": BUBBA})
check("a nickname that changed after the card stops the send", lambda: json.loads(registry.handler_for(tool)(
    {"to": "Dad", "text": "moved"})) == {"error": apple.CHANGED.format(what="who it goes to or the attachment")}
    and len(fake.calls) == 1)
save_aliases({"dad": DAD, "bubba": BUBBA})
tool.card({"to": "Dad", "text": "look", "attachment": str(photo)})
photo.write_bytes(b"\xff\xd8" + b"1" * 10)
check("a file that changed after the card stops the send", lambda: json.loads(registry.handler_for(tool)(
    {"to": "Dad", "text": "look", "attachment": str(photo)}))["error"].startswith("Nothing was done") and len(fake.calls) == 1)
tool.card({"to": "Dad", "text": "stale"})
apple.cards.seconds = -1
check("a card from too long ago doesn't count", lambda: json.loads(registry.handler_for(tool)(
    {"to": "Dad", "text": "stale"})) == {"error": apple.NOT_SHOWN} and len(fake.calls) == 1)
apple.cards.seconds = apple.SHOWN_SECONDS

# The guard: the card is the tool's own, in full; refusals block with the reason; roles still apply.
session = "guard-1"
directive = policy.decide("imsg_send", {"to": "Dad", "text": "on my way\nsee you soon"}, task_id=session,
                          session_id=session, turn_id="t1")
check("the approval message is the card: title — detail", lambda: directive["message"] == (
    "Send an iMessage to Dad — To: +1 555 0100\nWho: Robert Doe, your saved nickname “Dad”\nService: automatic: "
    "iMessage, or SMS if Messages can't reach them on iMessage\nAttachment: none\nMessage (2 lines):\non my way\nsee you soon"))
again = policy.decide("imsg_send", {"to": "Dad", "text": "on my way\nsee you soon"}, task_id="guard-2",
                      session_id="guard-2", turn_id="t1")
check("each card has its own rule key", lambda: directive["rule_key"] != again["rule_key"]
      and directive["rule_key"].startswith("daisy.imsg_send."))
blocked = policy.decide("imsg_send", {"to": "Rob", "text": "hi"}, task_id="guard-3", session_id="guard-3", turn_id="t1")
check("an ambiguous name is blocked with who it could be, not carded", lambda: blocked["action"] == "block"
      and blocked["message"].startswith("Two people match “Rob”"))
(HOME / "daisy" / "roles.json").write_text(json.dumps({"version": 1, "sessions": {"worker-1": "worker"}}))
check("a background job can't text", lambda: policy.decide("imsg_send", {"to": "Dad", "text": "hi"}, task_id="worker-1",
                                                          session_id="worker-1", turn_id="t1")["action"] == "block")
(HOME / "daisy" / "roles.json").unlink()
os.environ["HERMES_CRON_SESSION"] = "1"
check("cron can't text without a pre-approval", lambda: policy.decide("imsg_send", {"to": "+1 555 0100", "text": "digest"},
                                                                     task_id="cron:digest:1")["action"] == "block")
(HOME / "daisy" / "cron-allow.json").write_text(json.dumps({"version": 1, "allow": [
    {"tool": "imsg_send", "args": {"to": "+1 555 0100"}, "free": ["text"]}]}))
check("a pre-approved cron text to a fixed number runs", lambda: policy.decide(
    "imsg_send", {"to": "+1 555 0100", "text": "digest"}, task_id="cron:digest:2") is None)
check("...and sends what the guard's card planned, though nobody saw that card", lambda: json.loads(
    registry.handler_for(tool)({"to": "+1 555 0100", "text": "digest"}))["status"] == "sent")
os.environ.pop("HERMES_CRON_SESSION")
(HOME / "daisy" / "cron-allow.json").unlink()

# The shell route: once imsg_send is available, `imsg send` from the terminal is refused and points here.
shell = plugin.classify("terminal", {"command": "imsg send --to +15550100 --text hi"})
check("imsg send from the shell points at imsg_send", lambda: shell.decision == "block" and "imsg_send" in shell.message)
os.environ["DAISY_IMSG_BIN"] = str(HOME / "missing")
unavailable = plugin.classify("terminal", {"command": "imsg send --to +15550100 --text hi"})
check("with imsg_send hidden, the shell route is a card instead", lambda: unavailable.decision == "card"
      and unavailable.rule == "send-message")
os.environ["DAISY_IMSG_BIN"] = IMSG

# The registry hands Hermes the tool with its check.
class Recorder:
    def __init__(self):
        self.tools = {}

    def register_system_prompt_section(self, *a, **k):
        pass

    def register_hook(self, *a, **k):
        pass

    def register_middleware(self, *a, **k):
        pass

    def register_tool(self, name, toolset, schema, handler, **kwargs):
        self.tools[name] = (toolset, schema, kwargs)


recorder = Recorder()
plugin.register(recorder)
check("imsg_send registers into hermes-acp with its check", lambda: recorder.tools["imsg_send"][0] == "hermes-acp"
      and recorder.tools["imsg_send"][2]["check_fn"] is messages.available)

# The real imsg's own help, if it's installed (help only; nothing is sent): the flags Daisy uses are still there.
REAL = shutil.which("imsg", path=os.pathsep.join([os.environ.get("PATH", ""), *apple.HOMEBREW]))
if REAL:
    shown_help = subprocess.run([REAL, "send", "--help"], capture_output=True, text=True, timeout=30,
                                stdin=subprocess.DEVNULL).stdout
    for flag in ("--to <value>", "--text <value>", "--file <value>", "--service <value>", "--json"):
        check(f"the installed imsg still takes {flag.split()[0]}", lambda flag=flag: flag in shown_help)

shutil.rmtree(HOME, ignore_errors=True)
shutil.rmtree(FILES, ignore_errors=True)
shutil.rmtree(USER_HOME, ignore_errors=True)
print("messages checks:", "ok" if failures == 0 else f"{failures} failed")
sys.exit(1 if failures else 0)
