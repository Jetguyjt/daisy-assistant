"""Rules for tools that aren't typed: Hermes's own tools, the terminal, execute_code, MCP servers, the
browser and computer use. Typed tools never come here; policy.py judges them by their declared risk.
This is a check on what a call says it will do, not a sandbox."""

from __future__ import annotations

import json
import re
from typing import Any, Dict, List

from . import targets
from .code import classify_code
from .commands import GUARD, GUARD_FILES, classify_command, on_path
from .verdict import Verdict, allow, block, card, read

JAVASCRIPT = GUARD + "javascript: links run code inside a web page and are never opened."

# Hermes's own tools. Reads bring in content the turn didn't write itself (the value says what).
READS = {
    "web_search": "the web", "web_extract": "the web", "x_search": "the web", "read_file": "files",
    "search_files": "files", "vision_analyze": "an image", "video_analyze": "a video", "browser_snapshot": "the web",
    "browser_get_images": "the web", "browser_vision": "the web", "feishu_doc_read": "a document",
    "feishu_drive_list_comments": "a document", "feishu_drive_list_comment_replies": "a document",
    "read_terminal": "a terminal", "read_window_below": "a window", "kanban_show": "", "kanban_list": "",
    "kanban_attachments": "", "session_search": "", "skills_list": "", "skill_view": "", "todo_list": "",
    "clarify": "", "ha_list_entities": "", "ha_get_state": "", "ha_list_services": "", "spotify_search": "",
    "spotify_devices": "", "yb_query_group_info": "messages", "yb_query_group_members": "",
    "yb_search_sticker": "", "browser_scroll": "", "browser_back": "",
}
SENDS = {"send_message": "Send a message", "yb_send_dm": "Send a direct message", "yb_send_sticker": "Send a sticker",
         "feishu_drive_reply_comment": "Post a comment reply", "feishu_drive_add_comment": "Post a comment",
         "react_to_message": "React to a message"}
RUNS_IN_CHAT = {"write_file", "patch", "image_generate", "video_generate", "text_to_speech", "delegate_task",
                "kanban_complete", "kanban_block", "kanban_request_review", "kanban_request_changes",
                "kanban_heartbeat", "kanban_comment", "kanban_create", "kanban_link", "kanban_unblock",
                "kanban_attach", "kanban_attach_url", "close_terminal", "desktop_preview", "drive_preview",
                "annotate_preview", "focus_pane", "gui_tour", "show_tip", "desktop_project", "spotify_playback",
                "spotify_queue", "spotify_playlists", "spotify_albums", "spotify_library"}


def classify(tool_name: str, args: Dict[str, Any]) -> Verdict:
    """What an untyped tool call does. Never raises for odd arguments; policy.py fails closed if it does."""
    name = tool_name or ""
    args = args if isinstance(args, dict) else {}
    if name == "terminal":
        return _terminal(args)
    if name in ("process_manage", "process"):
        return _process(args)
    if name == "execute_code":
        source = _text(args.get("code"))
        verdict = classify_code(source, "python")
        if not verdict.read_only and targets.guard_path(source):
            return block(GUARD_FILES, title="Change Daisy's guard settings", hard=True)
        return verdict
    if name.startswith("mcp_"):
        return _mcp(name, args)
    if name == "computer_use":
        return _computer(args)
    if name.startswith("browser_"):
        return _browser(name, args)
    if name == "memory":
        return _memory(args)
    if name in ("skill_manage",):
        return _skill(args)
    if name in ("cronjob_manage", "cronjob"):
        return _cronjob(args)
    if name in ("write_file", "patch"):
        return _file_write(args)
    if name in READS:
        return _read_tool(name, args)
    if name in SENDS:
        return card("send-message", SENDS[name], _json(args))
    if name == "ha_call_service":
        what = " ".join(str(args.get(key, "")) for key in ("domain", "service", "entity_id")).strip()
        return card("ui", f"Control Home Assistant: {what}" if what else "Control Home Assistant", _json(args))
    if name in ("discord", "discord_admin"):
        action = str(args.get("action", "")).lower()
        if action.startswith(("fetch", "list", "search", "get", "read")):
            return read(reads="Discord messages")
        return card("send", f"Use Discord: {action or name}", _json(args))
    if name == "setup_mcp":
        return card("settings", "Add a tool server to Hermes", _json(args))
    if name in RUNS_IN_CHAT:
        return allow(reads="a helper's results" if name == "delegate_task" else "")
    return _by_name(name, args, words(name))


def _text(value: Any) -> str:
    return value if isinstance(value, str) else ("" if value is None else str(value))


def _json(args: Dict[str, Any]) -> str:
    try:
        return json.dumps(args, indent=2, ensure_ascii=False, sort_keys=True, default=str)
    except (TypeError, ValueError):
        return str(args)


def words(text: str) -> List[str]:
    """camelCase, snake_case and kebab-case split into lower-case words."""
    spaced = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", text or "")
    spaced = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1 \2", spaced)
    return [word.lower() for word in re.split(r"[^A-Za-z0-9]+", spaced) if word]


# Shell and processes

def _terminal(args: Dict[str, Any]) -> Verdict:
    command = _text(args.get("command") or args.get("cmd") or args.get("input") or "")
    workdir = _text(args.get("workdir") or args.get("cwd") or "")
    verdict = classify_command(command)
    if workdir and targets.guard_path(workdir + "/") and not verdict.read_only:
        return block(GUARD_FILES, title="Change Daisy's guard settings", hard=True)
    return verdict


def _process(args: Dict[str, Any]) -> Verdict:
    action = str(args.get("action", "")).lower()
    if action in ("list", "poll", "log", "wait", ""):
        return read(reads="a program's output" if action in ("poll", "log", "wait") else "")
    if action in ("write", "submit"):
        return card("run", "Type into a running program", "Input:\n\n" + _text(args.get("data")))
    return allow()


# Files, memory, skills and schedules

def _file_write(args: Dict[str, Any]) -> Verdict:
    path = _text(args.get("path") or args.get("file_path") or "")
    if targets.guard_path(path):
        return block(GUARD_FILES, title="Change Daisy's guard settings", hard=True)
    if targets.settings_path(path):
        return card("settings", "Change Hermes settings", f"File: {path}")
    if targets.startup_path(path):
        return card("run", f"Change {path.rsplit('/', 1)[-1]}, which runs commands later", f"File: {path}")
    if on_path(path):
        return card("run", f"Put a program in {path.rsplit('/', 1)[0]}", f"File: {path}")
    if targets.instructions_path(path):
        return allow(persists=True, title="Change Daisy's instructions", rule="memory", detail=f"File: {path}")
    return allow()


def _memory(args: Dict[str, Any]) -> Verdict:
    operations = args.get("operations") if isinstance(args.get("operations"), list) else [args]
    lines = []
    for operation in operations:
        if not isinstance(operation, dict):
            continue
        action = str(operation.get("action", args.get("action", ""))).lower()
        content = _text(operation.get("content") or operation.get("new_text") or "")
        old = _text(operation.get("old_text") or "")
        where = str(args.get("target", "memory"))
        if action == "remove":
            lines.append(f"Remove from {where}: {old}")
        elif action == "replace":
            lines.append(f"Replace in {where}: {old}\nwith: {content}")
        else:
            lines.append(f"Add to {where}: {content}")
    return allow(persists=True, rule="memory", title="Save to memory", detail="\n\n".join(lines))


def _skill(args: Dict[str, Any]) -> Verdict:
    action = str(args.get("action", "")).lower()
    name = _text(args.get("name"))
    return allow(persists=True, rule="skill", title=f"Change the skill “{name}”" if name else "Change a skill",
                 detail=_json(args)) if action else read()


def _cronjob(args: Dict[str, Any]) -> Verdict:
    action = str(args.get("action", "")).lower()
    if action in ("list", "get", "status", "show", "runs", "logs", "history", ""):
        return read()
    return card("run", "Change scheduled jobs", _json(args), persists=True)


def _read_tool(name: str, args: Dict[str, Any]) -> Verdict:
    links = [link for link in targets.link_values(args) if re.match(r"^[a-z][a-z0-9+.-]*://", link, re.I)]
    if name in ("web_extract", "vision_analyze", "video_analyze") and targets.script_urls(args):
        return block(JAVASCRIPT, title="Open a javascript: link", hard=True)
    return read(reads=READS[name], urls=tuple(links), network=name in ("web_search", "web_extract", "x_search"))


# Browser, computer use and MCP servers

def _navigation(links: List[str], reads: str = "the web", read_only: bool = True) -> Verdict:
    if not links:
        return allow(navigates=True, read_only=read_only, reads=reads, title="Open a page")
    for link in links:
        if targets.script_url(link):
            return block(JAVASCRIPT, title="Open a javascript: link", hard=True)
    site = targets.host(links[0]) or "a page"
    return Verdict(decision="allow", read_only=read_only, network=True, reads=reads, urls=tuple(links),
                   navigates=True, title=f"Open {site}")


def _browser(name: str, args: Dict[str, Any]) -> Verdict:
    """Hermes's own browser (browser_*)."""
    if targets.script_urls(args, everywhere=name == "browser_navigate"):
        return block(JAVASCRIPT, title="Open a javascript: link", hard=True)
    if name == "browser_navigate":
        return _navigation([_text(args.get("url"))] if args.get("url") else [])
    if name in READS:
        return _read_tool(name, args)
    if name == "browser_console":
        if _text(args.get("expression")).strip():
            return card("ui", "Run JavaScript on a web page", _text(args.get("expression")))
        return read(reads="the web")
    if name == "browser_click":
        return card("ui", "Click on a web page", _json(args))
    if name == "browser_type":
        return card("ui", f"Type on a web page: “{_text(args.get('text'))}”", _json(args))
    if name == "browser_press":
        return card("ui", f"Press {_text(args.get('key')) or 'a key'} on a web page", _json(args))
    if name == "browser_dialog":
        if str(args.get("action", "")).lower() == "dismiss":
            return allow()
        return card("ui", "Answer a dialog on a web page", _json(args))
    if name == "browser_cdp":
        return card("ui", f"Send a raw browser command ({_text(args.get('method'))})", _json(args))
    if name == "browser_exec":
        return card("ui", "Let the browser agent take over", _json(args))
    return card("ui", f"Use the browser ({name})", _json(args))


SAFE_KEYS = {"up", "down", "left", "right", "tab", "shift+tab", "escape", "esc", "pageup", "pagedown", "page_up",
             "page_down", "home", "end", "arrowup", "arrowdown", "arrowleft", "arrowright"}


def _computer(args: Dict[str, Any]) -> Verdict:
    action = str(args.get("action", "")).strip().lower()
    app = _text(args.get("app")) or "the front app"
    if action in ("capture", "wait", "list_apps", "list_windows", "zoom", "screenshot", "get_window_state"):
        return read(reads="the screen")
    if action in ("scroll", "focus_app", "move", "mouse_move"):
        return allow()
    if action in ("type", "set_value"):
        text = _text(args.get("text") if action == "type" else args.get("value"))
        return card("ui", f"Type into {app}: “{text}”", _json(args))
    if action == "key":
        keys = _text(args.get("keys")).strip().lower().replace(" ", "")
        if keys in SAFE_KEYS:
            return allow()
        return card("ui", f"Press {_text(args.get('keys')) or 'a key'} in {app}", _json(args))
    what = {"click": "Click", "double_click": "Double-click", "right_click": "Right-click",
            "middle_click": "Middle-click", "drag": "Drag"}.get(action, f"Use the computer ({action or 'unknown'})")
    return card("ui", f"{what} in {app}", _json(args))


BROWSER_SERVERS = {"chrome", "devtools", "browser", "playwright", "puppeteer", "selenium", "browserbase", "stagehand",
                   "browsermcp"}
SEND_WORDS = {"send", "reply", "forward", "post", "publish", "tweet", "retweet", "toot", "dm", "invite", "submit",
              "broadcast", "respond", "rsvp", "pay", "purchase", "buy", "checkout", "transfer", "donate", "comment"}
DELETE_WORDS = {"delete", "remove", "trash", "destroy", "purge", "erase", "wipe", "drop", "unlink", "rm", "del",
                "clear", "empty", "expunge", "revoke"}
SHARE_WORDS = {"share", "upload", "unshare", "permission", "permissions", "grant", "attach"}
WRITE_WORDS = {"create", "insert", "update", "patch", "modify", "edit", "set", "add", "write", "append", "put", "rename",
               "move", "copy", "label", "mark", "star", "archive", "apply", "merge", "close", "assign", "enable",
               "disable", "install", "run", "execute", "exec", "call", "invoke", "trigger", "start", "stop", "restart",
               "click", "fill", "press", "type", "drag", "evaluate", "eval", "import", "save", "store", "change",
               "make", "new", "schedule", "cancel", "accept", "decline", "approve", "reject", "lock", "unlock", "turn",
               "toggle", "play", "pause", "skip", "resume", "draft", "reorder", "sort", "batch", "quick", "handle",
               "select", "upsert", "sync", "restore", "reset", "hover", "key", "keyboard", "mouse", "script", "form",
               "input", "emulate", "resize", "tap", "swipe", "scroll"}
READ_WORDS = {"get", "list", "search", "find", "read", "fetch", "query", "lookup", "look", "view", "show", "describe",
              "count", "check", "download", "export", "retrieve", "inspect", "status", "info", "summarize", "snapshot",
              "screenshot", "take", "wait", "preview", "resolve", "validate", "analyze", "whoami", "me", "profile",
              "ping", "health", "resource", "resources", "prompt", "prompts", "console", "messages", "network",
              "performance", "trace", "insight", "diff", "compare", "history", "log", "logs", "stats", "usage"}
CALENDAR_WORDS = {"calendar", "calendars", "event", "events", "gcal", "meeting", "meetings", "appointment", "rsvp"}


def _mcp_parts(name: str) -> tuple:
    """(server words, tool words) from mcp__server__tool, or (words, words) from mcp_server_tool."""
    if name.startswith("mcp__"):
        server, _, tool = name[len("mcp__"):].partition("__")
        if tool:
            return words(server), words(tool)
    everything = words(name[len("mcp_"):])
    return everything, everything


def _reads_label(server: List[str]) -> str:
    found = set(server)
    if found & {"gmail", "mail", "email", "outlook", "imap", "inbox"}:
        return "email"
    if found & {"slack", "discord", "imessage", "messages", "telegram", "whatsapp", "signal", "sms"}:
        return "messages"
    if found & {"gdrive", "drive", "docs", "sheets", "notion", "dropbox", "box", "onedrive", "files", "filesystem"}:
        return "documents"
    if found & (BROWSER_SERVERS | {"web", "fetch", "search", "brave", "firecrawl", "exa", "tavily"}):
        return "the web"
    label = " ".join(server) if server else "an MCP server"
    return f"the {label} server" if server else label


# What a browser server (chrome-devtools, playwright...) can do to a signed-in page.
BROWSER_ACTIONS = {"click", "fill", "press", "type", "key", "keyboard", "evaluate", "eval", "script", "drag",
                   "upload", "dialog", "handle", "submit", "form", "input", "file", "tap", "swipe", "mouse", "execute",
                   "run", "set", "cookie", "cookies", "storage", "install", "extension"}


def _mcp(name: str, args: Dict[str, Any]) -> Verdict:
    verdict = _mcp_rules(name, args)
    if not verdict.read_only and verdict.decision != "block" and targets.guard_path(_json(args)):
        return block(GUARD_FILES, title="Change Daisy's guard settings", hard=True)
    return verdict


def _mcp_rules(name: str, args: Dict[str, Any]) -> Verdict:
    server, tool = _mcp_parts(name)
    found = set(tool)
    detail = f"{name}\n\n{_json(args)}"
    browser = bool(set(server) & BROWSER_SERVERS)
    navigation = bool(found & {"navigate", "goto", "open", "visit"}) or (
        bool(found & {"new"}) and bool(found & {"page", "tab", "window"}))
    if targets.script_urls(args, everywhere=navigation or browser):
        return block(JAVASCRIPT, title="Open a javascript: link", hard=True)
    if navigation and not found & (SEND_WORDS | DELETE_WORDS | SHARE_WORDS):
        links = targets.link_values(args)
        return _navigation(links, reads=_reads_label(server), read_only=not browser)
    if browser:
        if found & BROWSER_ACTIONS:
            return card("ui", f"Use the browser: {' '.join(tool)}", detail)
        if found & READ_WORDS:
            return read(reads="the web")
        return allow()
    if found & SEND_WORDS:
        return card("send", f"Send with {name}", detail)
    if found & DELETE_WORDS:
        return card("delete", f"Delete with {name}", detail)
    if found & SHARE_WORDS:
        return card("share", f"Share or upload with {name}", detail)
    if (found | set(server)) & CALENDAR_WORDS and found & WRITE_WORDS:
        return card("calendar", f"Change your calendar ({name})", detail)
    if found & WRITE_WORDS:
        return card("write", f"Run {name}", detail)
    if found & READ_WORDS:
        return read(reads=_reads_label(server))
    return card("write", f"Run {name}", detail)


def _by_name(name: str, args: Dict[str, Any], found_words: List[str]) -> Verdict:
    """A tool the guard has no rule for, judged by the words in its name."""
    found = set(found_words)
    if targets.script_urls(args):
        return block(JAVASCRIPT, title="Open a javascript: link", hard=True)
    if found & SEND_WORDS:
        return card("send", f"Send with {name}", _json(args))
    if found & DELETE_WORDS:
        return card("delete", f"Delete with {name}", _json(args))
    if found & SHARE_WORDS:
        return card("share", f"Share or upload with {name}", _json(args))
    if found_words and found_words[0] in READ_WORDS:
        return read()
    if found & WRITE_WORDS:
        return card("write", f"Run {name}", _json(args))
    return allow()
