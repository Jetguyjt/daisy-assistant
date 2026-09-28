"""Chrome: the user's own signed-in browser. List the open tabs, switch to one, open a page (or
switch to a tab that's already on it).

Tabs are read and switched through Chrome's AppleScript dictionary with one fixed JavaScript for
Automation script (osascript -l JavaScript). It gets a single JSON argument, and all that ever goes in
it is Chrome's own window and tab ids: the model's text stays in Python. The script only reads windows
and tabs (ids, titles, URLs, which tab is showing) and sets the active tab, the window order and
activate. Chrome's "Allow JavaScript from Apple Events" stays off, so nothing here runs inside a page.
New tabs open with `open -b com.google.Chrome <url>`, the same way a link from another app does, which
needs no Automation permission and starts Chrome when it's closed.

Private (incognito) windows are counted but never listed or touched. Every outside call goes through
`runner`, so the tests swap in a fake and never reach Chrome."""

from __future__ import annotations

import functools
import json
import os
import re
import subprocess
import sys
from typing import Any, Callable, Dict, List, Optional, Tuple
from urllib.parse import quote, urlsplit, urlunsplit

from .. import registry

CHROME = "com.google.Chrome"
OSASCRIPT = "/usr/bin/osascript"
OPEN = "/usr/bin/open"
APPS = ("/Applications/Google Chrome.app", "~/Applications/Google Chrome.app")
TIMEOUT = 8.0
TITLE_LIMIT = 300      # characters of a tab title
URL_LIMIT = 2000       # characters of a tab address read from Chrome (a data: URL can be megabytes)
SHOWN_URL_LIMIT = 500  # characters of an address in the tab list
MAX_TABS = 150         # tabs listed at most; the rest are counted
MAX_OPEN_URL = 8192
# Sites that live at another address: a gmail.com tab never exists, it's always mail.google.com.
SAME_SITE = {"gmail.com": "mail.google.com"}

SLOW = ("Chrome didn't answer within {seconds:g} seconds. If macOS is asking whether Daisy can control "
        "Chrome, click Allow, then try again.")
NOT_ALLOWED = ("macOS hasn't let Daisy control Chrome. Turn it on in System Settings → Privacy & Security "
               "→ Automation (Google Chrome under Daisy), then try again.")
PRIVATE = "That's a private (incognito) window. Daisy leaves those alone."
ERRORS = {
    -1743: NOT_ALLOWED,
    -1744: NOT_ALLOWED,
    -600: "Chrome isn't running.",
    -609: "Chrome closed while Daisy was talking to it.",
    -1712: "Chrome didn't answer in time.",
    -1728: "That tab or window isn't there any more. Check the tabs again.",
}

# Chrome's tabs as JSON, and switching to one. Fixed text: every value arrives in argv[0] as JSON.
SCRIPT = r"""
function run(argv) {
    var request = JSON.parse(argv[0]);
    var chrome = Application("com.google.Chrome");
    if (!chrome.running()) return reply({running: false});
    var result;
    if (request.action === "list") result = list(chrome, request);
    else if (request.action === "focus") result = focus(chrome, request);
    else throw new Error("Unknown action: " + request.action);
    result.running = true;
    return reply(result);
}

// Every window, front to back. Normal windows come with their tabs; private ones are only counted.
function list(chrome, request) {
    var windows = chrome.windows;
    var ids = windows.id();
    var shown = [];
    if (ids.length === 0) return {windows: shown};
    var modes = windows.mode();
    var active = windows.activeTabIndex();
    var tabIds = windows.tabs.id();
    var titles = windows.tabs.title();
    var urls = windows.tabs.url();
    var columns = [modes, active, tabIds, titles, urls];
    for (var c = 0; c < columns.length; c++) {
        if (columns[c].length !== ids.length) return {moved: true};
    }
    for (var i = 0; i < ids.length; i++) {
        if (String(modes[i]).toLowerCase() !== "normal") {
            shown.push({index: i + 1, private: true});
            continue;
        }
        var tabs = [];
        var count = Math.min(tabIds[i].length, titles[i].length, urls[i].length);
        for (var j = 0; j < count; j++) {
            tabs.push({id: tabIds[i][j], title: text(titles[i][j], request.title_limit),
                       url: text(urls[i][j], request.url_limit)});
        }
        shown.push({index: i + 1, id: ids[i], active: active[i], tabs: tabs});
    }
    return {windows: shown};
}

// Shows one tab, found by Chrome's own window and tab ids, and brings its window to the front.
function focus(chrome, request) {
    var windows = chrome.windows;
    var i = windows.id().indexOf(request.window_id);
    if (i < 0) return {missing: true};
    var win = windows[i];
    if (win.id() !== request.window_id) return {moved: true};
    if (String(win.mode()).toLowerCase() !== "normal") return {private: true};
    var j = win.tabs.id().indexOf(request.tab_id);
    if (j < 0) return {missing: true};
    win.activeTabIndex = j + 1;
    var tab = win.tabs[j];
    var shown = {tab: j + 1, title: text(tab.title(), request.title_limit), url: text(tab.url(), request.url_limit)};
    try {
        if (win.minimized()) win.minimized = false;
    } catch (error) {}
    // win is "window number i", so it points somewhere else once this one moves to the front.
    win.index = 1;
    chrome.activate();
    shown.window = 1;
    return shown;
}

function text(value, limit) {
    var s = value === null || value === undefined ? "" : String(value);
    if (s.length <= limit) return s;
    var end = limit;
    var code = s.charCodeAt(end - 1);
    if (code >= 0xD800 && code <= 0xDBFF) end -= 1;
    return s.slice(0, end) + "\u2026";
}

// JSON with everything past plain ASCII escaped, so osascript's output encoding never matters.
function reply(value) {
    return JSON.stringify(value).replace(/[\u007f-\uffff]/g, function (c) {
        return "\\u" + ("0000" + c.charCodeAt(0).toString(16)).slice(-4);
    });
}
"""


class ChromeError(Exception):
    """A plain sentence for the model, handed back as {"error": ...}."""


def _run(argv: List[str], timeout: float) -> Tuple[int, str, str]:
    done = subprocess.run(argv, capture_output=True, text=True, encoding="utf-8", errors="replace",
                          timeout=timeout, stdin=subprocess.DEVNULL, check=False)
    return done.returncode, done.stdout, done.stderr


# runner(argv, timeout) -> (exit code, stdout, stderr). Raises subprocess.TimeoutExpired when slow.
runner: Callable[[List[str], float], Tuple[int, str, str]] = _run


def available() -> bool:
    """Only on a Mac with Chrome installed."""
    if sys.platform != "darwin" or not os.path.exists(OSASCRIPT):
        return False
    return any(os.path.isdir(os.path.expanduser(path)) for path in APPS)


# --- talking to Chrome -------------------------------------------------------------------------

def _call(argv: List[str]) -> Tuple[int, str, str]:
    try:
        return runner(argv, TIMEOUT)
    except subprocess.TimeoutExpired:
        raise ChromeError(SLOW.format(seconds=TIMEOUT)) from None
    except OSError as error:
        raise ChromeError(f"Couldn't run {os.path.basename(argv[0])}: {error.strerror or error}") from None


def _explain(stderr: str) -> str:
    """osascript's error ("execution error: Error: ... (-1743)") as a sentence."""
    text = " ".join((stderr or "").split())
    found = re.search(r"\((-?\d+)\)$", text)
    code = int(found.group(1)) if found else None
    if code in ERRORS:
        return ERRORS[code]
    if re.search(r"can.t be found", text, re.I):
        return "Google Chrome isn't installed."
    detail = re.sub(r"^.*?execution error:\s*", "", text)
    detail = re.sub(r"^(?:Error:\s*)+", "", detail)
    return f"Chrome didn't do it: {detail[:300]}" if detail else "Chrome didn't do it."


def _script(action: str, **values: Any) -> Dict[str, Any]:
    request = dict(values, action=action, title_limit=TITLE_LIMIT, url_limit=URL_LIMIT)
    # One JSON argument that always starts with "{", so osascript never mistakes it for an option.
    code, out, err = _call([OSASCRIPT, "-l", "JavaScript", "-e", SCRIPT, json.dumps(request)])
    if code != 0:
        raise ChromeError(_explain(err))
    try:
        data = json.loads((out or "").strip() or "null")
    except ValueError:
        data = None
    if not isinstance(data, dict):
        raise ChromeError("Chrome sent back something Daisy couldn't read.")
    return data


def _open_new(url: str) -> None:
    code, _, err = _call([OPEN, "-b", CHROME, url])
    if code != 0:
        text = " ".join((err or "").split())
        if "unable to find application" in text.lower():
            raise ChromeError("Google Chrome isn't installed.")
        raise ChromeError(f"Chrome couldn't open it: {text[:300]}" if text else "Chrome couldn't open it.")


# --- tidying what comes back ---------------------------------------------------------------------

_CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")


def _whole(value: Any) -> str:
    """A string with any half emoji (a lone surrogate) swapped for U+FFFD, so it always encodes."""
    return str(value if value is not None else "").encode("utf-16", "surrogatepass").decode("utf-16", "replace")


def _cut(text: str, limit: int) -> str:
    return text if len(text) <= limit else text[:limit - 1] + "…"


def _title(value: Any) -> str:
    """One line: tabs, newlines and control characters become single spaces."""
    return _cut(" ".join(_CONTROL.sub(" ", _whole(value)).split()), TITLE_LIMIT)


def _address(value: Any, limit: int = URL_LIMIT) -> str:
    return _cut(_CONTROL.sub("", _whole(value)).strip(), limit)


def _number(value: Any, name: str) -> Optional[int]:
    if value is None or value == "":
        return None
    if isinstance(value, bool):
        raise ChromeError(f"{name} has to be a number from chrome_tabs.")
    try:
        number = float(value)
    except (TypeError, ValueError):
        raise ChromeError(f"{name} has to be a number from chrome_tabs.") from None
    if not number.is_integer() or number < 1:
        raise ChromeError(f"{name} numbers start at 1 and are whole numbers.")
    return int(number)


def _flag(value: Any) -> bool:
    if isinstance(value, str):
        return value.strip().lower() in ("true", "yes", "1")
    return value is True or (type(value) is int and value == 1)


def _tabs() -> Dict[str, Any]:
    """{"running", "windows": [{"window", "id", "active", "tabs": [{"tab", "id", "title", "url"}]}],
    "private": [window numbers]}"""
    for _ in range(2):  # once more if a window opened or closed halfway through reading
        data = _script("list")
        if not data.get("moved"):
            break
    else:
        raise ChromeError("Chrome's windows kept changing while Daisy read them. Try again.")
    if not data.get("running"):
        return {"running": False, "windows": [], "private": []}
    windows: List[Dict[str, Any]] = []
    private: List[int] = []
    for window in data.get("windows") or []:
        if not isinstance(window, dict) or not isinstance(window.get("index"), int):
            continue
        if window.get("private") or not isinstance(window.get("tabs"), list):
            private.append(window["index"])
            continue
        tabs = [{"tab": number, "id": tab.get("id"), "title": _title(tab.get("title")), "url": _address(tab.get("url"))}
                for number, tab in enumerate(window["tabs"], 1) if isinstance(tab, dict)]
        windows.append({"window": window["index"], "id": window.get("id"), "active": window.get("active"), "tabs": tabs})
    return {"running": True, "windows": windows, "private": private}


# --- addresses ------------------------------------------------------------------------------------

_SCHEME = re.compile(r"^([a-zA-Z][a-zA-Z0-9+.-]*):")
_IGNORED = "".join(chr(code) for code in range(33))  # what browsers skip at the start and end of an address
_KEEP = "!#$&'()*+,/:;=?@-._~%"


def _escape(part: str) -> str:
    """Percent-escapes what can't stand in an address (spaces, quotes, accents), keeping existing escapes."""
    return quote(re.sub(r"%(?![0-9A-Fa-f]{2})", "%25", part), safe=_KEEP)


def _checked_url(raw: Any) -> str:
    """An http(s) address Chrome can open, or a ChromeError saying why not."""
    if not isinstance(raw, str) or not raw.strip():
        raise ChromeError("Give chrome_open an http or https address.")
    # Browsers drop tabs and newlines anywhere in an address and skip spaces and control characters
    # around it, so a scheme can't hide behind them here either.
    text = re.sub(r"[\t\n\r]", "", raw).strip(_IGNORED)
    if len(text) > MAX_OPEN_URL:
        raise ChromeError("That address is too long to open.")
    if text.startswith("//"):
        text = "https:" + text
    scheme = _SCHEME.match(text)
    if scheme is None or "." in scheme.group(1):  # "mail.google.com" or "example.com:8080/x"
        text = "https://" + text
    elif scheme.group(1).lower() not in ("http", "https"):
        raise ChromeError(f"chrome_open only opens http and https addresses, not {scheme.group(1).lower()}: links.")
    try:
        parts = urlsplit(text)
        host, port = parts.hostname or "", parts.port
    except ValueError:
        raise ChromeError("That isn't a web address Chrome can open.") from None
    if "@" in parts.netloc:
        raise ChromeError("Addresses with a name or password before the site aren't opened: they can hide "
                          "where the link really goes.")
    try:
        host = host if host.isascii() else host.encode("idna").decode("ascii")
    except UnicodeError:
        raise ChromeError("That site name isn't valid.") from None
    host = host.lower()
    if not re.fullmatch(r"[a-z0-9._-]+|[0-9a-f:.]+", host):
        raise ChromeError("That address has no site in it Chrome can open.")
    netloc = (f"[{host}]" if ":" in host else host) + (f":{port}" if port else "")
    try:
        return urlunsplit((parts.scheme.lower(), netloc, _escape(parts.path) or "/", _escape(parts.query),
                           _escape(parts.fragment)))
    except UnicodeError:
        raise ChromeError("That address has characters Chrome can't open.") from None


def _site(host: str) -> str:
    host = (host or "").lower().rstrip(".")
    host = host[4:] if host.startswith("www.") else host
    return SAME_SITE.get(host, host)


def _key(url: str) -> Tuple[str, str]:
    """(site, page) for comparing addresses: no scheme, www, #fragment or trailing slash."""
    text = (url or "").strip()
    if not _SCHEME.match(text) or "." in text.split(":", 1)[0]:
        text = "https://" + text
    try:
        parts = urlsplit(text)
        host = parts.hostname or ""
    except ValueError:
        return "", ""
    return _site(host), parts.path.rstrip("/") + (f"?{parts.query}" if parts.query else "")


def _wanted(url: str) -> Tuple[str, str, bool]:
    """(site, page, cut): what a chrome_focus url or a reuse points at. cut is set when the address
    came from the tab list with its end cut off ("…")."""
    text = (url or "").strip()
    cut = text.endswith("…")
    site, page = _key(text.rstrip("…"))
    return site, page, cut


def _covers(wanted: Tuple[str, str, bool], url: str) -> bool:
    """Whether a tab showing url will do: any tab on the site for a site's main address (or a bare
    site like mail.google.com), otherwise that page or one below it. A search is only ever itself."""
    site, page, cut = wanted
    tab_site, tab_page = _key(url)
    if not site or site != tab_site:
        return False
    if not page or tab_page == page:
        return True
    if cut:
        return tab_page.startswith(page)
    return "?" not in page and (tab_page.startswith(page + "/") or tab_page.startswith(page + "?"))


def _best(state: Dict[str, Any], url: str) -> Optional[Tuple[Dict[str, Any], Dict[str, Any]]]:
    """The open tab that best matches url: the same page first, then the tab a window is showing,
    then the front-most window and the leftmost tab."""
    wanted = _wanted(url)
    found = []
    for window in state["windows"]:
        for tab in window["tabs"]:
            if _covers(wanted, tab["url"]):
                rank = (_key(tab["url"])[1] != wanted[1], tab["tab"] != window.get("active"), window["window"], tab["tab"])
                found.append((rank, window, tab))
    if not found:
        return None
    _, window, tab = min(found, key=lambda item: item[0])
    return window, tab


def _switch(window: Dict[str, Any], tab: Dict[str, Any]) -> Dict[str, Any]:
    data = _script("focus", window_id=window["id"], tab_id=tab["id"])
    if not data.get("running"):
        raise ChromeError("Chrome closed before Daisy could switch tabs.")
    if data.get("private"):
        raise ChromeError(PRIVATE)
    if data.get("missing") or data.get("moved"):
        raise ChromeError("That tab just closed or moved. Check the tabs again.")
    return {"switched": True, "window": 1, "tab": data.get("tab") or tab["tab"],
            "title": _title(data.get("title")), "url": _address(data.get("url"), SHOWN_URL_LIMIT)}


# --- the tools --------------------------------------------------------------------------------------

def _plain(run: Callable[[Dict[str, Any]], Dict[str, Any]]) -> Callable[[Dict[str, Any]], Dict[str, Any]]:
    """Expected failures go back as {"error": "<sentence>"}; anything else is left to the registry."""
    @functools.wraps(run)
    def wrapped(args: Dict[str, Any]) -> Dict[str, Any]:
        try:
            return run(args)
        except ChromeError as error:
            return {"error": str(error)}
    return wrapped


def list_tabs(args: Dict[str, Any]) -> Dict[str, Any]:
    query = " ".join(str(args.get("query") or "").split())
    state = _tabs()
    if not state["running"]:
        return {"running": False, "message": "Chrome isn't open, so there are no tabs."}
    rows = [{"window": window["window"], "tab": tab["tab"], "title": tab["title"],
             "url": _cut(tab["url"], SHOWN_URL_LIMIT), "active": tab["tab"] == window.get("active")}
            for window in state["windows"] for tab in window["tabs"]]
    result: Dict[str, Any] = {"running": True, "windows": len(state["windows"]), "total_tabs": len(rows)}
    if query:
        low = query.lower()
        rows = [row for row in rows if low in f"{row['title']} {row['url']}".lower()]
        result["matching"] = len(rows)
    result["tabs"] = rows[:MAX_TABS]
    if len(rows) > MAX_TABS:
        result["not_shown"] = len(rows) - MAX_TABS
        result["note"] = "Only the first tabs are listed. Pass query to find a particular one."
    if state["private"]:
        result["private_windows"] = len(state["private"])
    return result


def focus_tab(args: Dict[str, Any]) -> Dict[str, Any]:
    window_number, tab_number = _number(args.get("window"), "window"), _number(args.get("tab"), "tab")
    url = str(args.get("url") or "").strip()
    if not url and (window_number is None or tab_number is None):
        raise ChromeError("Say which tab: window and tab from chrome_tabs, or a url.")
    state = _tabs()
    if not state["running"]:
        raise ChromeError("Chrome isn't open, so there's no tab to switch to.")
    if window_number in state["private"]:
        raise ChromeError(PRIVATE)
    target = None
    if window_number is not None and tab_number is not None:
        window = next((w for w in state["windows"] if w["window"] == window_number), None)
        tab = next((t for t in window["tabs"] if t["tab"] == tab_number), None) if window else None
        if tab is not None and (not url or _covers(_wanted(url), tab["url"])):
            target = (window, tab)
        elif not url:
            raise ChromeError(f"There's no tab {tab_number} in window {window_number} now. Check chrome_tabs again.")
    if target is None:  # just a url, or the tab moved: find it by address
        target = _best(state, url)
        if target is None:
            raise ChromeError(f"None of the open tabs is on {url}.")
    return _switch(*target)


def open_page(args: Dict[str, Any]) -> Dict[str, Any]:
    url = _checked_url(args.get("url"))
    note = ""
    if _flag(args.get("reuse")):
        try:
            state = _tabs()
            found = _best(state, url) if state["running"] else None
            if found:
                return _switch(*found)
        except ChromeError as error:
            note = f"Opened a new tab instead of switching to an open one: {error}"
    _open_new(url)
    result: Dict[str, Any] = {"opened": True, "url": url}
    if note:
        result["note"] = note
    return result


# --- cards (the guard shows one when a turn that read untrusted content opens a page) ----------------

def _host_of(value: Any) -> str:
    try:
        return _key(re.sub(r"[\t\n\r]", "", str(value or "")).strip(_IGNORED))[0]
    except Exception:
        return ""


def _tabs_card(args: Dict[str, Any]) -> str:
    query = " ".join(str(args.get("query") or "").split())
    detail = f"Only tabs matching: {query}" if query else "Every open tab's title and address. Private windows are left out."
    return f"Check your Chrome tabs\n{detail}"


def _focus_card(args: Dict[str, Any]) -> str:
    lines = ["Switch to a Chrome tab"]
    where = ", ".join(f"{label} {args[key]}" for key, label in (("window", "window"), ("tab", "tab"))
                      if args.get(key) is not None)
    if where:
        lines.append(where[0].upper() + where[1:])
    if args.get("url"):
        lines.append(str(args.get("url")))
    return "\n".join(lines)


def _open_card(args: Dict[str, Any]) -> str:
    raw = args.get("url")
    try:
        url = _checked_url(raw)  # what would really open
    except ChromeError:
        url = str(raw if raw is not None else "")
    site = _host_of(url) or "a page"
    title = f"Switch to {site} in Chrome, or open it" if _flag(args.get("reuse")) else f"Open {site} in Chrome"
    return f"{title}\n{url}"


registry.add(registry.TypedTool(
    name="chrome_tabs",
    description=("List the tabs open in the user's own Chrome (their real, signed-in browser): window and tab "
                 "numbers, title, address, and which tab each window is showing. Window 1 is the front window. "
                 "Private windows are counted, not listed. Doesn't start Chrome if it's closed. To bring up a site "
                 "like Gmail, call chrome_open with reuse=true instead of listing first."),
    parameters={"type": "object", "properties": {
        "query": {"type": "string", "description": "Only tabs whose title or address contains this, any case "
                                                   "(\"gmail\", \"docs.google.com\"). Leave out to list every tab."}}},
    risk="read", card=_tabs_card, run=_plain(list_tabs), check=available))

registry.add(registry.TypedTool(
    name="chrome_focus",
    description=("Switch the user's Chrome to one of their open tabs and bring Chrome to the front. Pass window "
                 "and tab from chrome_tabs plus that tab's url, so a tab that moved is still found; or just a url "
                 "or site (mail.google.com) to switch to the best open tab there. Only changes which tab is showing."),
    parameters={"type": "object", "properties": {
        "window": {"type": "integer", "description": "Window number from chrome_tabs."},
        "tab": {"type": "integer", "description": "Tab number in that window from chrome_tabs."},
        "url": {"type": "string", "description": "The tab's address from chrome_tabs, or a site like mail.google.com."}}},
    risk="read", card=_focus_card, run=_plain(focus_tab), check=available))

registry.add(registry.TypedTool(
    name="chrome_open",
    description=("Open a web page in the user's own Chrome in a new tab and bring Chrome to the front (starts "
                 "Chrome if it's closed). reuse=true switches to a tab already there instead: any tab on the site "
                 "for a site's main address, the same page for a longer one. \"Check my email\" is one call, "
                 "chrome_open(url=\"https://mail.google.com/\", reuse=true). A Google search the user wants to see "
                 "is https://www.google.com/search?q=<url-encoded words>. Only http and https addresses."),
    parameters={"type": "object", "properties": {
        "url": {"type": "string", "description": "An http or https address."},
        "reuse": {"type": "boolean", "description": "Switch to a tab already open there instead of opening "
                                                    "another. For sites where any tab will do (Gmail, Calendar); "
                                                    "leave it off for searches."}},
              "required": ["url"]},
    risk="read", card=_open_card, run=_plain(open_page), check=available))
