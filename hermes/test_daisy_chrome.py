"""The Chrome tools: what goes to osascript, what comes back from Chrome, and how the guard treats each
tool. Nothing here reaches the real Chrome: every call goes to a fake runner, and the tab script itself
runs in JavaScriptCore (jsc) against a pretend Chrome when jsc is there.
Run: python3 hermes/test_daisy_chrome.py"""

import importlib.util
import itertools
import json
import logging
import os
import shutil
import subprocess
import sys
import tempfile
import types
from pathlib import Path

HOME = Path(tempfile.mkdtemp(prefix="daisy-chrome-"))
os.environ["HERMES_HOME"] = str(HOME)
for name in ("HERMES_CRON_SESSION", "HERMES_SESSION_PLATFORM", "HERMES_SESSION_KEY", "HERMES_SESSION_ID",
             "HERMES_SINGLE_QUERY_SESSION", "HERMES_YOLO_MODE", "DAISY_CHROME_DEVTOOLS"):
    os.environ.pop(name, None)
logging.getLogger("daisy.guard").addHandler(logging.NullHandler())
logging.getLogger("daisy.guard").propagate = False
REPO = Path(__file__).resolve().parent.parent
JSC = "/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc"


def load(active: bool):
    """Loads hermes/daisy as a package, the way Hermes does, with DAISY_SESSION set or not."""
    if active:
        os.environ["DAISY_SESSION"] = "1"
    else:
        os.environ.pop("DAISY_SESSION", None)
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


class Recorder:
    def __init__(self):
        self.tools = []

    def register_system_prompt_section(self, *a, **k):
        pass

    def register_hook(self, *a, **k):
        pass

    def register_tool(self, name, toolset, schema, handler, **kwargs):
        self.tools.append((name, toolset, kwargs.get("check_fn")))


plugin = load(active=True)
registry = plugin.registry
chrome = sys.modules["daisy_plugin.tools.chrome"]
policy = sys.modules["daisy_plugin.guard.policy"]


def refuse(*args, **kwargs):
    raise AssertionError("a test tried to start a real process")


# A safety net: if anything slipped past the fake runner it fails here instead of reaching Chrome.
chrome.subprocess = types.SimpleNamespace(run=refuse, TimeoutExpired=subprocess.TimeoutExpired, DEVNULL=subprocess.DEVNULL)


class Fake:
    """Stands in for osascript and open: records every argv and plays back canned replies."""

    def __init__(self, *replies):
        self.replies = list(replies)
        self.calls = []
        self.timeouts = []

    def __call__(self, argv, timeout):
        self.calls.append(list(argv))
        self.timeouts.append(timeout)
        reply = self.replies.pop(0) if self.replies else (0, "", "")
        if isinstance(reply, BaseException):
            raise reply
        return reply


def use(*replies):
    fake = Fake(*replies)
    chrome.runner = fake
    return fake


def out(value):
    """What the tab script prints: JSON with everything past ASCII escaped, like its reply()."""
    return (0, json.dumps(value) + "\n", "")


def listing(*windows):
    return out({"running": True, "windows": list(windows)})


def window(index, wid, active, *tabs):
    return {"index": index, "id": wid, "active": active, "tabs": [{"id": i, "title": t, "url": u} for i, t, u in tabs]}


def private(index):
    return {"index": index, "private": True}


def switched(tab, title, url):
    return out({"running": True, "window": 1, "tab": tab, "title": title, "url": url})


def call(name, args):
    """One call through the handler Hermes gets, decoded."""
    return json.loads(registry.handler_for(registry.get(name))(args))


def request(argv):
    try:
        return json.loads(argv[-1])
    except ValueError:
        return {}


def osascripts(fake):
    return [c for c in fake.calls if c[0] == chrome.OSASCRIPT]


def opens(fake):
    return [c for c in fake.calls if c[0] == chrome.OPEN]


NOT_RUNNING = out({"running": False})
INBOX = "https://mail.google.com/mail/u/0/#inbox"
FRONT = window(1, 101, 1, (11, "weather - Google Search", "https://www.google.com/search?q=weather"))
BACK = window(2, 202, 3, (21, "Calendar", "https://calendar.google.com/calendar/u/0/r/week"),
              (22, "Essay draft - Google Docs", "https://docs.google.com/document/d/abc123/edit"),
              (23, "Inbox (3) - josh@example.com - Gmail", INBOX))

# --- registration -------------------------------------------------------------------------------
names = ("chrome_tabs", "chrome_focus", "chrome_open")
for name in names:
    tool = registry.get(name)
    check(f"{name} is registered", tool is not None)
    if tool is None:
        continue
    check(f"{name} is a read", tool.risk == "read")
    check(f"{name} goes into hermes-acp", tool.toolset == "hermes-acp")
    check(f"{name} takes an object", tool.parameters.get("type") == "object")
    check(f"{name} is hidden where Chrome can't work", tool.check is chrome.available)
    check(f"{name} has a description", len(tool.description) > 40)
check("chrome_open needs a url", registry.get("chrome_open").parameters.get("required") == ["url"])
recorder = Recorder()
plugin.register(recorder)
check("Daisy sessions get the three tools in hermes-acp",
      {(n, "hermes-acp", chrome.available) for n in names} <= set(recorder.tools))

real_apps = chrome.APPS
chrome.APPS = (str(HOME / "Nowhere" / "Google Chrome.app"),)
check("hidden without Chrome installed", chrome.available() is False)
(HOME / "Google Chrome.app").mkdir()
chrome.APPS = (str(HOME / "Google Chrome.app"),)
check("shown with Chrome on a Mac", chrome.available() == (sys.platform == "darwin" and os.path.exists(chrome.OSASCRIPT)))
chrome.APPS = real_apps

# --- what goes to osascript ----------------------------------------------------------------------
fake = use(listing(FRONT))
call("chrome_tabs", {})
argv = fake.calls[0]
check("chrome_tabs runs osascript's JavaScript", argv[:4] == [chrome.OSASCRIPT, "-l", "JavaScript", "-e"])
check("with the fixed script", argv[4] == chrome.SCRIPT)
check("and one JSON argument", len(argv) == 6 and request(argv) == {
    "action": "list", "title_limit": chrome.TITLE_LIMIT, "url_limit": chrome.URL_LIMIT})
check("that can't pass for an option", argv[5].startswith("{"))
check("script and argument are plain ASCII, so osascript's argv encoding never matters", argv[4].isascii() and argv[5].isascii())
check("the runner gets a few seconds", fake.timeouts == [chrome.TIMEOUT] and 2 <= chrome.TIMEOUT <= 10)
lowered = chrome.SCRIPT.lower()
check("the script never runs anything inside a page", "execute" not in lowered and "javascript" not in lowered)
check("the script never reaches the shell", "shell" not in lowered and "doshellscript" not in lowered)
check("the script only talks to Chrome", chrome.SCRIPT.count("Application(") == 1 and 'Application("com.google.Chrome")' in chrome.SCRIPT)
check("the script never makes or closes anything", all(word not in lowered for word in ("make(", "close(", "delete(", "push(tabs", "reload(", ".url =")))

# Values never become code: the model's strings stay in Python, and osascript only ever gets Chrome's own ids.
HOSTILE = ['"); Application("Finder").delete(Path("/")); ("',
           '" & (do shell script "rm -rf ~") & "',
           "'; var x = Application.currentApplication(); x.includeStandardAdditions = true; '",
           "${HOME}`id`$(id) | cat /etc/passwd",
           "\u202e\u0000\n\t😀 \\u0022 */ /*"]
for text in HOSTILE:
    fake = use(listing(FRONT, BACK), switched(3, "Inbox", INBOX), (0, "", ""))
    call("chrome_tabs", {"query": text})
    call("chrome_focus", {"window": 2, "tab": 3, "url": INBOX + text})
    call("chrome_open", {"url": "https://example.com/?q=" + text, "reuse": True})
    scripts = osascripts(fake)
    check(f"the script text never changes: {text!r}", all(c[4] == chrome.SCRIPT for c in scripts))
    check(f"a hostile value never reaches osascript: {text!r}", all(text not in part for c in scripts for part in c))
    for c in scripts:
        check(f"osascript only gets ids and limits: {text!r}",
              set(request(c)) <= {"action", "title_limit", "url_limit", "window_id", "tab_id"}
              and all(isinstance(v, int) for k, v in request(c).items() if k != "action"))
hostile_open = use((0, "", ""))
opened = call("chrome_open", {"url": 'https://example.com/?q="; do shell script "rm -rf ~" & `id` $(id) <b>'})
check("a new tab gets one argument, escaped", hostile_open.calls == [[chrome.OPEN, "-b", chrome.CHROME,
      "https://example.com/?q=%22;%20do%20shell%20script%20%22rm%20-rf%20~%22%20&%20%60id%60%20$(id)%20%3Cb%3E"]])
check("and says what it opened", opened.get("opened") is True and opened["url"].startswith("https://example.com/?q=%22"))

# --- reading what Chrome sends back ---------------------------------------------------------------
titles = {
    "tabs": ("Budget\t2026\tQ3", "Budget 2026 Q3"),
    "commas": ("Pens, paper, and ink", "Pens, paper, and ink"),
    "quotes": ('He said "hi" & \'bye\' \\ /', 'He said "hi" & \'bye\' \\ /'),
    "newlines": ("Line one\nLine two\r\nLine three", "Line one Line two Line three"),
    "emoji": ("Party 🎉 time 👩‍👩‍👧", "Party 🎉 time 👩‍👩‍👧"),
    "accents": ("Crème brûlée — 東京", "Crème brûlée — 東京"),
    "control characters": ("Red\x1b[31m text\x00", "Red [31m text"),
    "line separators": ("a\u2028b\u2029c", "a b c"),
    "half an emoji": ("cut \ud83d", "cut \ufffd"),
    "nothing": (None, ""),
}
tabs = [(100 + n, raw, f"https://example.com/{n}") for n, (raw, _) in enumerate(titles.values())]
fake = use(listing(window(1, 101, 2, *tabs)))
handled = registry.handler_for(registry.get("chrome_tabs"))({})
result = json.loads(handled)
check("the reply is plain JSON that encodes", handled.encode("utf-8") and result["running"] is True)
shown = {row["url"]: row["title"] for row in result["tabs"]}
for n, (label, (_, wanted)) in enumerate(titles.items()):
    check(f"a title with {label} comes through as one clean line", shown.get(f"https://example.com/{n}") == wanted)
check("each tab has its window and tab number", [(r["window"], r["tab"]) for r in result["tabs"]] == [(1, n) for n in range(1, len(titles) + 1)])
check("the showing tab is marked", [r["active"] for r in result["tabs"]][:3] == [False, True, False])
check("and the totals", result["windows"] == 1 and result["total_tabs"] == len(titles))

long_title, long_url = "T" * 5000, "data:text/html," + "A" * 1_000_000
use(listing(window(1, 101, 1, (11, long_title, long_url))))
row = call("chrome_tabs", {})["tabs"][0]
check("very long titles are cut", len(row["title"]) == chrome.TITLE_LIMIT and row["title"].endswith("…"))
check("very long addresses are cut", len(row["url"]) == chrome.SHOWN_URL_LIMIT and row["url"].endswith("…"))

many = [(1000 + n, f"Tab {n}", f"https://example.com/{n}") for n in range(chrome.MAX_TABS + 20)]
use(listing(window(1, 101, 1, *many)))
crowded = call("chrome_tabs", {})
check("a crowded Chrome lists the first tabs and counts the rest",
      len(crowded["tabs"]) == chrome.MAX_TABS and crowded["not_shown"] == 20 and "query" in crowded["note"])
use(listing(FRONT, private(2), BACK))
found = call("chrome_tabs", {"query": "  GMAIL "})
check("query narrows by title or address, any case",
      [(r["window"], r["tab"]) for r in found["tabs"]] == [(2, 3)] and found["matching"] == 1 and found["total_tabs"] == 4)
check("private windows are counted, not listed", found["private_windows"] == 1)

use(out({"running": True, "moved": True}), listing(FRONT))
check("a window closing mid-read is read again", call("chrome_tabs", {})["total_tabs"] == 1)
use(out({"running": True, "moved": True}), out({"running": True, "moved": True}))
check("but not forever", "kept changing" in call("chrome_tabs", {}).get("error", ""))
use((0, "not json\n", ""))
check("garbage from osascript is an error", "couldn't read" in call("chrome_tabs", {}).get("error", ""))
use(out(["not", "an", "object"]))
check("so is the wrong shape", "couldn't read" in call("chrome_tabs", {}).get("error", ""))
use(out({"running": True, "windows": [{"index": "one"}, {"id": 5}, {"index": 3, "id": 9, "active": 1, "tabs": "nope"},
                                      window(4, 44, 1, (1, "Kept", "https://example.com/"))]}))
odd = call("chrome_tabs", {})
check("odd windows are skipped, and never listed", [r["title"] for r in odd["tabs"]] == ["Kept"] and odd["private_windows"] == 1)

# --- Chrome not running ---------------------------------------------------------------------------
fake = use(NOT_RUNNING)
check("chrome_tabs says plainly that Chrome is closed",
      call("chrome_tabs", {}) == {"running": False, "message": "Chrome isn't open, so there are no tabs."})
check("and doesn't start it", len(fake.calls) == 1 and fake.calls[0][0] == chrome.OSASCRIPT)
fake = use(NOT_RUNNING)
check("chrome_focus says so too", "isn't open" in call("chrome_focus", {"url": "mail.google.com"}).get("error", ""))
check("without starting it", not opens(fake))
fake = use(NOT_RUNNING, (0, "", ""))
started = call("chrome_open", {"url": "https://mail.google.com/", "reuse": True})
check("chrome_open starts Chrome with the page", opens(fake) == [[chrome.OPEN, "-b", chrome.CHROME, "https://mail.google.com/"]]
      and started == {"opened": True, "url": "https://mail.google.com/"})

# --- errors ---------------------------------------------------------------------------------------
fake = use(subprocess.TimeoutExpired(["osascript"], chrome.TIMEOUT))
slow = call("chrome_tabs", {})
check("a slow Chrome is a plain error", "didn't answer within 8 seconds" in slow.get("error", "") and "Allow" in slow["error"])
for stderr, words in [
        ("0:0: execution error: Not authorized to send Apple events to Google Chrome. (-1743)", "Automation"),
        ("execution error: Error: Error: Application isn't running. (-600)", "isn't running"),
        ("execution error: Error: Error: Can't get object. (-1728)", "isn't there any more"),
        ("execution error: Error: Error: Application can't be found. (-2700)", "isn't installed"),
        ("execution error: Error: Error: Application can\u2019t be found. (-2700)", "isn't installed"),
        ("execution error: Error: TypeError: undefined is not an object (-2700)", "Chrome didn't do it: TypeError"),
        ("", "Chrome didn't do it.")]:
    use((1, "", stderr + "\n"))
    check(f"osascript error {stderr[-8:]!r} reads plainly", words in call("chrome_tabs", {}).get("error", ""))
use(OSError(2, "No such file or directory"))
check("a missing osascript is an error, not a crash", "Couldn't run osascript" in call("chrome_tabs", {}).get("error", ""))
use((1, "", "Unable to find application with bundle identifier com.google.Chrome.\n"))
check("opening without Chrome installed says so", call("chrome_open", {"url": "https://example.com"}).get("error") == "Google Chrome isn't installed.")
use((1, "", "LSOpenURLsWithRole() failed with error -600 for the URL https://example.com/.\n"))
check("other open failures come through", "Chrome couldn't open it: LSOpenURLsWithRole()" in call("chrome_open", {"url": "https://example.com"}).get("error", ""))

# --- addresses chrome_open won't open -------------------------------------------------------------
refused = ["javascript:alert(1)", "JavaScript:alert(document.cookie)", "  javascript:alert(1)", "java\tscript:alert(1)",
           "\njavascript:alert(1)", "\x00javascript:alert(1)", "vbscript:msgbox(1)", "file:///etc/passwd", "FILE:///Users",
           "data:text/html,<script>alert(1)</script>", "chrome://settings", "chrome-extension://abc/popup.html",
           "about:blank", "mailto:someone@example.com", "sms:+15550100", "view-source:https://example.com",
           "ftp://example.com/", "blob:https://example.com/uuid", "intent://x#Intent;end", "tel:5550100",
           "https://mail.google.com@evil.example/", "https://user:pass@example.com/", "https://", "https:///path",
           "http://exa mple.com/", "https://example.com:99999/", "https://ex\\ample.com/", "", "   ", None, 42, ["https://x.com"],
           "https://example.com/" + "a" * 9000]
for bad in refused:
    fake = use()
    result = call("chrome_open", {"url": bad})
    check(f"chrome_open refuses {str(bad)[:40]!r}", "error" in result and not fake.calls)
for scheme in ("javascript", "file", "data", "chrome"):
    message = call("chrome_open", {"url": f"{scheme}:whatever"}).get("error", "")
    check(f"the {scheme}: refusal is clear", "only opens http and https" in message and f"{scheme}:" in message)

for given, opened_as in [
        ("https://www.google.com/search?q=cheap flights to NYC", "https://www.google.com/search?q=cheap%20flights%20to%20NYC"),
        ("https://www.google.com/search?q=cheap+flights", "https://www.google.com/search?q=cheap+flights"),
        ("mail.google.com", "https://mail.google.com/"),
        ("HTTPS://Mail.Google.com", "https://mail.google.com/"),
        ("  https://example.com/a b?c=d e#f g  ", "https://example.com/a%20b?c=d%20e#f%20g"),
        ("https://bücher.de/straße", "https://xn--bcher-kva.de/stra%C3%9Fe"),
        ("https://example.com/100%", "https://example.com/100%25"),
        ("https://example.com/already%20escaped", "https://example.com/already%20escaped"),
        ("//example.com/x", "https://example.com/x"),
        ("http://localhost:3000/app", "http://localhost:3000/app"),
        ("example.com:8080/x", "https://example.com:8080/x"),
        ("https://exa\nmple.com/pa\tth", "https://example.com/path"),
        ("http://[::1]:8080/", "http://[::1]:8080/")]:
    fake = use((0, "", ""))
    result = call("chrome_open", {"url": given})
    check(f"chrome_open opens {given!r} as {opened_as!r}",
          fake.calls == [[chrome.OPEN, "-b", chrome.CHROME, opened_as]] and result == {"opened": True, "url": opened_as})

# --- reuse ----------------------------------------------------------------------------------------
fake = use(listing(FRONT, BACK), switched(3, "Inbox (3) - josh@example.com - Gmail", INBOX))
reused = call("chrome_open", {"url": "https://mail.google.com/", "reuse": True})
check("reuse switches to the open Gmail tab", len(fake.calls) == 2 and request(fake.calls[1]) == {
    "action": "focus", "window_id": 202, "tab_id": 23, "title_limit": chrome.TITLE_LIMIT, "url_limit": chrome.URL_LIMIT})
check("without opening another", not opens(fake))
check("and says where it went", reused == {"switched": True, "window": 1, "tab": 3,
                                           "title": "Inbox (3) - josh@example.com - Gmail", "url": INBOX})
fake = use(listing(FRONT, BACK), switched(3, "Inbox", INBOX))
call("chrome_open", {"url": "https://www.gmail.com", "reuse": "true"})
check("gmail.com means the mail.google.com tab", request(fake.calls[1]).get("tab_id") == 23 and not opens(fake))
fake = use((0, "", ""))
call("chrome_open", {"url": "https://mail.google.com/"})
check("without reuse there's no looking, just a new tab", fake.calls == [[chrome.OPEN, "-b", chrome.CHROME, "https://mail.google.com/"]])
fake = use(listing(FRONT), (0, "", ""))
call("chrome_open", {"url": "https://mail.google.com/", "reuse": True})
check("reuse with nothing open on the site opens a new tab", len(osascripts(fake)) == 1 and len(opens(fake)) == 1)
fake = use(listing(FRONT, BACK), (0, "", ""))
call("chrome_open", {"url": "https://www.google.com/search?q=cheap%20flights", "reuse": True})
check("a different search isn't reused", len(osascripts(fake)) == 1 and len(opens(fake)) == 1)
fake = use(listing(FRONT, BACK), switched(1, "weather", "https://www.google.com/search?q=weather"))
call("chrome_open", {"url": "https://google.com/search?q=weather", "reuse": True})
check("the same search is", request(fake.calls[1]).get("tab_id") == 11 and not opens(fake))
fake = use(listing(FRONT, BACK), (0, "", ""))
call("chrome_open", {"url": "https://docs.google.com/document/d/other/edit", "reuse": True})
check("another doc on the same site isn't reused", len(osascripts(fake)) == 1 and len(opens(fake)) == 1)
fake = use(listing(FRONT, BACK), switched(2, "Essay", "https://docs.google.com/document/d/abc123/edit"))
call("chrome_open", {"url": "https://docs.google.com/document/d/abc123", "reuse": True})
check("the same doc is, a page below", request(fake.calls[1]).get("tab_id") == 22)
fake = use(listing(FRONT, BACK), switched(1, "Calendar", "https://calendar.google.com/calendar/u/0/r/week"))
call("chrome_open", {"url": "https://calendar.google.com/", "reuse": True})
check("any Calendar tab will do for Calendar", request(fake.calls[1]).get("tab_id") == 21)
two = window(1, 101, 2, (11, "Gmail (old)", "https://mail.google.com/mail/u/0/#label/x"), (12, "News", "https://news.example/"))
fake = use(listing(two, BACK), switched(3, "Inbox", INBOX))
call("chrome_open", {"url": "https://mail.google.com/", "reuse": True})
check("a tab that's showing wins over one in a nearer window", request(fake.calls[1]).get("tab_id") == 23)
fake = use(listing(two, BACK), switched(3, "Inbox", INBOX))
call("chrome_open", {"url": "https://mail.google.com/mail/u/0/#label/x", "reuse": True})
check("a #fragment doesn't make another page (Gmail changes it all the time)", request(fake.calls[1]).get("tab_id") == 23)
thread = window(1, 101, 1, (11, "A thread - Gmail", "https://mail.google.com/mail/u/0/thread/abc"))
quiet = window(2, 202, 1, (21, "Calendar", "https://calendar.google.com/"), (23, "Inbox - Gmail", "https://mail.google.com/mail/u/0/"))
fake = use(listing(thread, quiet), switched(2, "Inbox - Gmail", "https://mail.google.com/mail/u/0/"))
call("chrome_open", {"url": "https://mail.google.com/mail/u/0", "reuse": True})
check("the exact page wins over a showing tab below it", request(fake.calls[1]).get("tab_id") == 23)
fake = use(listing(private(1), FRONT), (0, "", ""))
call("chrome_open", {"url": "https://mail.google.com/", "reuse": True})
check("a private window's tabs are never reused", len(opens(fake)) == 1 and len(osascripts(fake)) == 1)
fake = use((1, "", "execution error: Not authorized to send Apple events to Google Chrome. (-1743)\n"), (0, "", ""))
denied = call("chrome_open", {"url": "https://mail.google.com/", "reuse": True})
check("without Automation it still opens Gmail", len(opens(fake)) == 1 and denied.get("opened") is True)
check("and says why it couldn't switch", "Automation" in denied.get("note", ""))
fake = use(listing(FRONT, BACK), out({"running": True, "missing": True}), (0, "", ""))
gone = call("chrome_open", {"url": "https://mail.google.com/", "reuse": True})
check("a tab that closed in between gets a new one", len(opens(fake)) == 1 and "closed or moved" in gone.get("note", ""))

# --- chrome_focus -------------------------------------------------------------------------------
fake = use(listing(FRONT, BACK), switched(3, "Inbox", INBOX))
focused = call("chrome_focus", {"window": 2, "tab": 3})
check("focus by window and tab", request(fake.calls[1])["window_id"] == 202 and request(fake.calls[1])["tab_id"] == 23)
check("and it's in front now", focused["switched"] is True and focused["window"] == 1)
fake = use(listing(FRONT, BACK), switched(3, "Inbox", INBOX))
call("chrome_focus", {"window": "2", "tab": 3.0, "url": "https://mail.google.com/mail/u/0/#label/other"})
check("numbers as text work, and the site double-checks the tab", request(fake.calls[1])["tab_id"] == 23)
fake = use(listing(FRONT, BACK), switched(3, "Inbox", INBOX))
call("chrome_focus", {"window": 2, "tab": 1, "url": INBOX})
check("a tab that moved is found by its address", request(fake.calls[1])["tab_id"] == 23)
fake = use(listing(FRONT, BACK), switched(3, "Inbox", INBOX))
call("chrome_focus", {"url": "mail.google.com"})
check("focus by site alone", request(fake.calls[1])["tab_id"] == 23)
fake = use(listing(FRONT, BACK), switched(2, "Essay", "https://docs.google.com/document/d/abc123/edit"))
call("chrome_focus", {"url": "https://docs.google.com/document/d/abc…"})
check("an address cut short in the list still finds its tab", request(fake.calls[1])["tab_id"] == 22)
fake = use(listing(FRONT, BACK))
check("no match is a plain error", "None of the open tabs" in call("chrome_focus", {"url": "https://nope.example/"}).get("error", "")
      and len(fake.calls) == 1)
fake = use(listing(FRONT, BACK))
check("a tab that isn't there, with no address to go on", "no tab 9 in window 2" in call("chrome_focus", {"window": 2, "tab": 9}).get("error", "")
      and len(fake.calls) == 1)
fake = use(listing(private(1), window(2, 202, 1, (21, "Mine", "https://example.com/"))))
check("a private window can't be focused", call("chrome_focus", {"window": 1, "tab": 1}).get("error") == chrome.PRIVATE
      and len(fake.calls) == 1)
fake = use(listing(FRONT), out({"running": True, "private": True}))
check("nor slipped past the list", call("chrome_focus", {"window": 1, "tab": 1}).get("error") == chrome.PRIVATE)
for args in ({}, {"window": 2}, {"tab": 1}):
    fake = use()
    check(f"focus needs a tab: {args}", "Say which tab" in call("chrome_focus", args).get("error", "") and not fake.calls)
for bad in ({"window": "two", "tab": 1}, {"window": 0, "tab": 1}, {"window": True, "tab": 1}, {"window": 1, "tab": 1.5}):
    fake = use()
    check(f"focus refuses {bad}", "error" in call("chrome_focus", bad) and not fake.calls)

# --- cards --------------------------------------------------------------------------------------
open_tool, focus_tool, tabs_tool = (registry.get(n) for n in ("chrome_open", "chrome_focus", "chrome_tabs"))
check("chrome_open's card names the site", open_tool.card_parts({"url": "https://evil.example/?d=grades"})
      == ("Open evil.example in Chrome", "https://evil.example/?d=grades"))
check("with reuse it says it may switch", open_tool.card_parts({"url": "https://mail.google.com/", "reuse": True})
      == ("Switch to mail.google.com in Chrome, or open it", "https://mail.google.com/"))
huge = "https://example.com/?q=" + "x" * 10000 + "END"
check("the card is never cut", open_tool.card_parts({"url": huge})[1] == huge)
check("a newline can't fake the site in the title", open_tool.card_parts({"url": "https://mail.google.com\n.evil.example/"})[0]
      == "Open mail.google.com.evil.example in Chrome")
check("odd arguments still make a card", open_tool.card_parts({"url": 42})[0].startswith("Open ") and open_tool.card_parts({})[0] == "Open a page in Chrome")
check("the card shows the address that would really open", open_tool.card_parts({"url": "example.com/a b"})
      == ("Open example.com in Chrome", "https://example.com/a%20b"))
check("an address it won't open is shown as given", open_tool.card_parts({"url": "file:///etc/passwd"})[1] == "file:///etc/passwd")
check("chrome_focus's card", focus_tool.card_parts({"window": 2, "tab": 3, "url": INBOX}) == ("Switch to a Chrome tab", f"Window 2, tab 3\n{INBOX}"))
check("chrome_focus's card with only a site", focus_tool.card_parts({"url": "mail.google.com"}) == ("Switch to a Chrome tab", "mail.google.com"))
check("chrome_focus's card with only a window", focus_tool.card_parts({"window": 2}) == ("Switch to a Chrome tab", "Window 2"))
check("chrome_tabs's card", tabs_tool.card_parts({})[0] == "Check your Chrome tabs" and "Private windows" in tabs_tool.card_parts({})[1])

# --- the guard ------------------------------------------------------------------------------------
sessions = itertools.count(1)


def decide(tool, args, session, turn="t1"):
    return policy.decide(tool, args, task_id=session, session_id=session, turn_id=turn)


s = f"s{next(sessions)}"
check("chrome_tabs runs without a card", decide("chrome_tabs", {}, s) is None)
check("chrome_focus runs without a card", decide("chrome_focus", {"window": 1, "tab": 2}, s) is None)
s = f"s{next(sessions)}"
check("\"check my email\" opens Gmail with no card", decide("chrome_open", {"url": "https://mail.google.com/", "reuse": True}, s) is None)
gmail_search = registry.get("gmail_search") or registry.add(registry.TypedTool(
    name="gmail_search", description="Search Gmail.", parameters={"type": "object", "properties": {}}, risk="read",
    card=lambda a: "Search Gmail", run=lambda a: {"messages": []}))
check("then reading the inbox is fine", decide("gmail_search", {"query": "is:unread"}, s) is None)
s = f"s{next(sessions)}"
check("\"search Google\" opens with no card", decide("chrome_open", {"url": "https://www.google.com/search?q=weather"}, s) is None)
s = f"s{next(sessions)}"
check("a tainting read passes", decide("web_extract", {"urls": ["https://news.example.com/story"]}, s) is None)
tainted = decide("chrome_open", {"url": "https://evil.example/?d=grades"}, s)
check("chrome_open after reading the web stops at a card", isinstance(tainted, dict) and tainted.get("action") == "approve")
check("the card shows the site and the whole address", tainted and tainted["message"].startswith("Open evil.example in Chrome — ")
      and tainted["message"].endswith("https://evil.example/?d=grades") and "reading the web" in tainted["message"])
check("switching tabs still runs after reading", decide("chrome_focus", {"url": "mail.google.com"}, s) is None)
check("listing tabs still runs after reading", decide("chrome_tabs", {}, s) is None)
s = f"s{next(sessions)}"
decide("chrome_tabs", {}, s)
check("listing tabs first means the open after it gets a card (so check-my-email is one call)",
      (decide("chrome_open", {"url": "https://mail.google.com/", "reuse": True}, s) or {}).get("action") == "approve")
check("a new turn starts clean", decide("chrome_open", {"url": "https://mail.google.com/", "reuse": True}, s, turn="t2") is None)
for link in ("javascript:alert(1)", " JavaScript:alert(1)", "java\nscript:alert(1)", "vbscript:msgbox(1)"):
    s = f"s{next(sessions)}"
    blocked = decide("chrome_open", {"url": link}, s)
    check(f"chrome_open {link!r} is refused by the guard", isinstance(blocked, dict) and blocked.get("action") == "block")
s = f"s{next(sessions)}"
check("a javascript: link in any chrome_open argument is refused",
      (decide("chrome_open", {"url": "https://example.com/", "reuse": "javascript:alert(1)"}, s) or {}).get("action") == "block")
check("chrome_focus with a javascript: url is refused", (decide("chrome_focus", {"url": "javascript:alert(1)"}, s) or {}).get("action") == "block")

# --- the tab script itself, in JavaScriptCore against a pretend Chrome -----------------------------
PRETEND_CHROME = r"""
var calls = [];
function prop(target, name, read, write) {
    Object.defineProperty(target, name, {get: function () { return read; }, set: write});
}
function indexed(target, make) {
    return new Proxy(target, {get: function (inner, key) {
        if (typeof key === "string" && /^\d+$/.test(key)) return make(Number(key));
        return inner[key];
    }});
}
function every(read) { return function () { return STATE.windows.map(read); }; }
function at(position) {
    var found = STATE.windows[position];
    if (!found) throw new Error("Can't get window " + (position + 1) + ". (-1728)");
    return found;
}
// "window n" and "tab n of window n" are positions, looked up again on every use, like the real thing.
function windowAt(position) {
    function tabAt(j) {
        function tab() { var found = at(position).tabs[j]; if (!found) throw new Error("Can't get tab. (-1728)"); return found; }
        return {id: function () { return tab().id; }, title: function () { return tab().title; }, url: function () { return tab().url; }};
    }
    var spec = {
        id: function () { return at(position).id; },
        mode: function () { return at(position).mode; },
        tabs: indexed({
            id: function () { return at(position).tabs.map(function (t) { return t.id; }); },
            title: function () { return at(position).tabs.map(function (t) { return t.title; }); },
            url: function () { return at(position).tabs.map(function (t) { return t.url; }); }
        }, tabAt)
    };
    prop(spec, "activeTabIndex", function () { return at(position).active; },
         function (value) { calls.push(["activeTabIndex", at(position).id, value]); at(position).active = value; });
    prop(spec, "minimized", function () { return !!at(position).minimized; },
         function (value) { calls.push(["minimized", at(position).id, value]); at(position).minimized = value; });
    prop(spec, "index", function () { return position + 1; }, function (value) {
        var moving = at(position);
        calls.push(["index", moving.id, value]);
        STATE.windows.splice(position, 1);
        STATE.windows.splice(value - 1, 0, moving);
    });
    return spec;
}
function Application(name) {
    if (name !== "com.google.Chrome") throw new Error("Application can't be found. (-2700)");
    var app = {
        running: function () { return STATE.running; },
        activate: function () { calls.push(["activate"]); }
    };
    Object.defineProperty(app, "windows", {get: function () {
        if (!STATE.running) calls.push(["started Chrome"]);
        return indexed({
            id: every(function (w) { return w.id; }),
            mode: every(function (w) { return w.mode; }),
            activeTabIndex: every(function (w) { return w.active; }),
            tabs: {
                id: every(function (w) { return w.tabs.map(function (t) { return t.id; }); }),
                title: every(function (w) { return w.tabs.map(function (t) { return t.title; }); }),
                url: every(function (w) { return w.tabs.map(function (t) { return t.url; }); })
            }
        }, windowAt);
    }});
    return app;
}
"""


def in_jsc(state, ask):
    """Runs the tab script once in jsc: (its reply decoded, what it did to the pretend Chrome, windows after)."""
    source = (f"var STATE = {json.dumps(state)};\n{PRETEND_CHROME}\n{chrome.SCRIPT}\n"
              f"var answer = run([{json.dumps(json.dumps(ask))}]);\n"
              "print(reply({answer: answer, calls: calls, order: STATE.windows.map(function (w) { return w.id; })}));\n")
    path = HOME / "tab-script.js"
    path.write_text(source, encoding="utf-8")
    done = subprocess.run([JSC, str(path)], capture_output=True, text=True, timeout=30)
    if done.returncode != 0:
        return {"failed": done.stdout + done.stderr}, [], []
    printed = json.loads(done.stdout)
    check("the script's reply is plain ASCII", printed["answer"].isascii())
    return json.loads(printed["answer"]), printed["calls"], printed["order"]


if os.path.exists(JSC):
    def pretend():
        return {"running": True, "windows": [
            {"id": 101, "mode": "normal", "active": 2, "tabs": [
                {"id": 11, "title": 'Inbox 😀 "quoted"\nnext\tline', "url": INBOX},
                {"id": 12, "title": "Docs", "url": "https://docs.google.com/"}]},
            {"id": 202, "mode": "incognito", "active": 1, "tabs": [
                {"id": 21, "title": "SECRET PRIVATE TITLE", "url": "https://secret.example/private"}]},
            {"id": 303, "mode": "normal", "active": 1, "minimized": True, "tabs": [
                {"id": 31, "title": "x" * 299 + "😀", "url": "data:text/html," + "A" * 5000}]}]}

    limits = {"title_limit": 300, "url_limit": 2000}
    answer, did, order = in_jsc(pretend(), dict(limits, action="list"))
    windows = answer.get("windows") or []
    check("jsc: the list has every window front to back", [w.get("index") for w in windows] == [1, 2, 3])
    check("jsc: normal windows come with their tabs", windows[:1] and windows[0].get("id") == 101 and windows[0].get("active") == 2
          and [t["id"] for t in windows[0]["tabs"]] == [11, 12])
    check("jsc: titles come back exactly", windows[:1] and windows[0]["tabs"][0]["title"] == 'Inbox 😀 "quoted"\nnext\tline')
    check("jsc: a private window is only a number", len(windows) > 1 and windows[1] == {"index": 2, "private": True}
          and "SECRET" not in json.dumps(answer) and "secret.example" not in json.dumps(answer))
    cut = windows[2]["tabs"][0] if len(windows) > 2 else {}
    check("jsc: long titles are cut without splitting an emoji", cut.get("title") == "x" * 299 + "…")
    check("jsc: long addresses are cut", len(cut.get("url", "")) == 2001 and cut["url"].endswith("…"))
    check("jsc: listing changes nothing", did == [] and order == [101, 202, 303] and answer.get("running") is True)

    answer, did, order = in_jsc(pretend(), dict(limits, action="focus", window_id=303, tab_id=31))
    check("jsc: focus shows the tab and says which", answer.get("window") == 1 and answer.get("tab") == 1
          and answer.get("title") == "x" * 299 + "…")
    check("jsc: focus un-minimizes, brings the window forward, then Chrome",
          did == [["activeTabIndex", 303, 1], ["minimized", 303, False], ["index", 303, 1], ["activate"]])
    check("jsc: the window is in front afterwards", order == [303, 101, 202])
    answer, did, order = in_jsc(pretend(), dict(limits, action="focus", window_id=101, tab_id=12))
    check("jsc: focus on a background tab of the front window", answer.get("tab") == 2 and answer.get("title") == "Docs"
          and did == [["activeTabIndex", 101, 2], ["index", 101, 1], ["activate"]])
    answer, did, _ = in_jsc(pretend(), dict(limits, action="focus", window_id=202, tab_id=21))
    check("jsc: a private window is never touched", answer == {"private": True, "running": True} and did == [])
    answer, did, _ = in_jsc(pretend(), dict(limits, action="focus", window_id=101, tab_id=99))
    check("jsc: a tab that's gone", answer == {"missing": True, "running": True} and did == [])
    answer, did, _ = in_jsc(pretend(), dict(limits, action="focus", window_id=999, tab_id=11))
    check("jsc: a window that's gone", answer == {"missing": True, "running": True} and did == [])
    answer, did, _ = in_jsc({"running": False, "windows": []}, dict(limits, action="list"))
    check("jsc: a closed Chrome stays closed", answer == {"running": False} and did == [])
    answer, did, _ = in_jsc({"running": True, "windows": []}, dict(limits, action="list"))
    check("jsc: no windows at all", answer == {"windows": [], "running": True})
    answer, _, _ = in_jsc(pretend(), dict(limits, action="close"))
    check("jsc: an unknown action is an error", "failed" in answer and "Unknown action" in answer["failed"])
else:
    print("  (no jsc here, so the tab script's own checks were skipped)")

# --- the setup fragments --------------------------------------------------------------------------
STUB_HERMES = r'''#!/usr/bin/env python3
"""Stands in for `hermes config get/set`, keeping values in a JSON file."""
import json, os, sys
store = os.environ["STUB_STORE"]
values = json.load(open(store)) if os.path.exists(store) else {}
args = sys.argv[1:]
if args[:2] == ["config", "get"]:
    as_json = "--json" in args
    key = [a for a in args[2:] if a != "--json"][0]
    if key not in values:
        sys.exit(1)
    value = values[key]
    print(json.dumps(value, ensure_ascii=False) if as_json else ("true" if value is True else value if isinstance(value, str) else json.dumps(value)))
elif args[:2] == ["config", "set"]:
    raw = args[3]
    values[args[2]] = json.loads(raw) if raw[:1] in "[{" else True if raw == "true" else raw
    json.dump(values, open(store, "w"))
else:
    sys.exit(2)
'''
FRAGMENT_SHELL = r'''
set -euo pipefail
BACKED_UP=0
backup_config() { BACKED_UP=1; }
config_set() {  # the same as in scripts/setup-hermes.sh
  local current
  current="$("$HERMES" config get "$1" 2>/dev/null || true)"
  if [ "$current" != "$2" ]; then
    backup_config
    "$HERMES" config set "$1" "$2" >/dev/null
    echo "  set $1 = $2"
  fi
}
source "$FRAGMENT"
'''


def fragment(name, home, **env):
    stub = home / "hermes-stub"
    stub.write_text(STUB_HERMES)
    stub.chmod(0o755)
    variables = dict(os.environ, HERMES_HOME=str(home), REPO_DIR=str(REPO), HERMES=str(stub),
                     STUB_STORE=str(home / "stub-config.json"), FRAGMENT=str(REPO / "scripts" / "hermes.d" / name), **env)
    done = subprocess.run(["bash", "-c", FRAGMENT_SHELL], capture_output=True, text=True, env=variables, timeout=60)
    return done.returncode, done.stdout, done.stderr


if shutil.which("bash") and shutil.which("rsync"):
    home = Path(tempfile.mkdtemp(prefix="daisy-chrome-setup-"))
    code, printed, errors = fragment("30-chrome.sh", home)
    installed = home / "skills" / "apple" / "daisy-chrome" / "SKILL.md"
    check(f"30-chrome.sh installs the skill ({errors.strip()})", code == 0 and installed.exists()
          and installed.read_bytes() == (REPO / "hermes" / "skills" / "daisy-chrome" / "SKILL.md").read_bytes())
    check("and says so", "installed skill apple/daisy-chrome" in printed)
    code, printed, _ = fragment("30-chrome.sh", home)
    check("running it again changes nothing", code == 0 and printed == "")
    installed.write_text("edited by Hermes\n")
    (installed.parent / "stray.md").write_text("x")
    code, printed, _ = fragment("30-chrome.sh", home)
    check("the repo copy wins over edits", code == 0 and "installed" in printed and installed.read_bytes()
          == (REPO / "hermes" / "skills" / "daisy-chrome" / "SKILL.md").read_bytes() and not (installed.parent / "stray.md").exists())

    code, printed, _ = fragment("31-chrome-devtools.sh", home)
    check("chrome-devtools-mcp stays off by default", code == 0 and printed == "" and not (home / "stub-config.json").exists())
    code, printed, errors = fragment("31-chrome-devtools.sh", home, DAISY_CHROME_DEVTOOLS="1")
    saved = json.loads((home / "stub-config.json").read_text()) if (home / "stub-config.json").exists() else {}
    check(f"DAISY_CHROME_DEVTOOLS=1 adds the MCP server ({errors.strip()})", code == 0
          and saved.get("mcp_servers.chrome_devtools.command") == "npx"
          and "--autoConnect" in saved.get("mcp_servers.chrome_devtools.args", [])
          and "--no-javascript-evaluation" in saved.get("mcp_servers.chrome_devtools.args", [])
          and saved.get("mcp_servers.chrome_devtools.enabled") is True)
    code, printed, _ = fragment("31-chrome-devtools.sh", home, DAISY_CHROME_DEVTOOLS="1")
    check("and a second run changes nothing", code == 0 and printed == "")
    shutil.rmtree(home, ignore_errors=True)
else:
    print("  (no bash or rsync here, so the setup fragment checks were skipped)")

# --- outside Daisy sessions ------------------------------------------------------------------------
idle = Recorder()
load(active=False).register(idle)
check("outside Daisy the Chrome tools aren't offered", not any(name in names for name, _, _ in idle.tools))

shutil.rmtree(HOME, ignore_errors=True)
print("chrome checks:", "ok" if failures == 0 else f"{failures} failed")
sys.exit(1 if failures else 0)
