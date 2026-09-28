"""Paths and links the guard treats specially.

- Daisy's guard settings ($HERMES_HOME/daisy/, the installed plugin): the assistant never changes them.
- Hermes settings (config.yaml, .env, other plugins): changes need a card.
- Instructions that outlive a turn (memories, skills, SOUL.md, the Daisy persona): like memory writes,
  they need a card once the turn has read untrusted content.
- Script links (javascript:, vbscript:): never opened, anywhere."""

from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Any, List
from urllib.parse import urlsplit


def hermes_home() -> Path:
    return Path(os.environ.get("HERMES_HOME") or (Path.home() / ".hermes")).expanduser()


_END = r"(?:/|$|[\s\"'`;|&)<>])"


def _home_prefix() -> str:
    """Ways a command can spell Hermes's home: ~/.hermes, $HOME/.hermes, $HERMES_HOME, ${HERMES_HOME},
    ${HERMES_HOME:-...}, or the real path."""
    spellings = [r"\.hermes\}?", r"hermes_home\}?"]
    real = str(hermes_home()).rstrip("/")
    if real:
        spellings.append(re.escape(real.lower()))
    return "(?:" + "|".join(spellings) + ")/+"


def _matches(text: str, tail: str) -> bool:
    return bool(re.search(_home_prefix() + tail, (text or "").lower()))


def guard_path(text: str) -> bool:
    """Mentions Daisy's guard settings or the installed plugin."""
    low = (text or "").lower()
    return "cron-allow.json" in low or _matches(low, r"(?:daisy|plugins/+daisy)" + _END)


def settings_path(text: str) -> bool:
    return _matches(text, r"(?:config\.ya?ml|\.env|auth\.json|plugins)" + _END)


def instructions_path(text: str) -> bool:
    return _matches(text, r"(?:memories|skills|soul\.md|daisy-persona\.md)" + _END)


_STARTUP = re.compile(
    r"(^|/)\.(zshrc|zshenv|zprofile|zlogin|zlogout|bashrc|bash_profile|bash_login|bash_logout|profile|inputrc|"
    r"gitconfig|npmrc|yarnrc|curlrc|wgetrc|netrc|pythonrc|lesskey|editrc|tmux\.conf|vimrc|exrc)" + _END + r"|"
    r"/\.ssh/|/library/launch(agents|daemons)/|/\.config/(fish|git|zsh)/|/library/startupitems/|"
    r"/\.git/hooks/|/\.git/config" + _END + r"|(sitecustomize|usercustomize)\.py" + _END + r"|/site-packages/[^/]*\.pth" + _END)


def startup_path(text: str) -> bool:
    """Files whose contents run later on their own: shell startup files, launch agents, ssh and git config."""
    return bool(_STARTUP.search((text or "").lower()))


_SCRIPT_SCHEMES = ("javascript:", "vbscript:", "livescript:")
_IGNORED_IN_URLS = "".join(chr(code) for code in range(33))


def script_url(value: str) -> bool:
    """A javascript:/vbscript: link, including the spellings browsers still accept (leading spaces,
    tabs or newlines inside the scheme, any case)."""
    if not isinstance(value, str):
        return False
    cleaned = re.sub(r"[\t\n\r]", "", value).lstrip(_IGNORED_IN_URLS).lower()
    return cleaned.startswith(_SCRIPT_SCHEMES)


def urlish_key(key: str) -> bool:
    key = (key or "").lower()
    return key in ("url", "uri", "href", "link", "links", "location", "address", "page", "src", "target",
                   "destination", "redirect") or key.endswith(("url", "uri", "href", "link", "urls", "links"))


def script_urls(args: Any, everywhere: bool = False) -> List[str]:
    """Script links in a tool's arguments: under link-like keys, or in every string when the tool itself
    opens pages."""
    found: List[str] = []

    def walk(value: Any, key: str, depth: int) -> None:
        if depth > 20:
            return
        if isinstance(value, dict):
            for inner_key, inner in value.items():
                walk(inner, str(inner_key), depth + 1)
        elif isinstance(value, (list, tuple)):
            for inner in value:
                walk(inner, key, depth + 1)
        elif isinstance(value, str) and (everywhere or urlish_key(key)) and script_url(value):
            found.append(value)

    walk(args, "", 0)
    return found


def link_values(args: Any) -> List[str]:
    """Strings under link-like keys (url, urls, href...)."""
    found: List[str] = []

    def walk(value: Any, key: str, depth: int) -> None:
        if depth > 20:
            return
        if isinstance(value, dict):
            for inner_key, inner in value.items():
                walk(inner, str(inner_key), depth + 1)
        elif isinstance(value, (list, tuple)):
            for inner in value:
                walk(inner, key, depth + 1)
        elif isinstance(value, str) and urlish_key(key) and value.strip():
            found.append(value.strip())

    walk(args, "", 0)
    return found


def host(url: str) -> str:
    """The site a link points at, lower case, without www."""
    text = (url or "").strip()
    if not re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*://", text):
        text = "http://" + text
    try:
        name = urlsplit(text).hostname or ""
    except ValueError:
        return ""
    name = name.lower().rstrip(".")
    return name[4:] if name.startswith("www.") else name


URL_IN_TEXT = re.compile(r"https?://[^\s'\"<>`]+", re.I)
