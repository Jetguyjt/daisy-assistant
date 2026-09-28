"""What a piece of code can do: start other programs, send data, delete files, drive the Mac's UI.

Python is read with ast, so imports and aliases are followed (from os import remove as r). Code
that builds names at run time (exec, eval, getattr, __import__) can't be checked and stops for a card.
Other languages, and Python that doesn't parse, fall back to patterns. Plain math and text code
passes; code that only uses a few pure modules is "pure" and is the only code workers and cron run."""

from __future__ import annotations

import ast
import re
from typing import Dict, List, Optional, Set

from .verdict import Verdict, allow, card, read

PURE_MODULES = {
    "math", "cmath", "statistics", "decimal", "fractions", "numbers", "random", "datetime", "time", "calendar",
    "zoneinfo", "json", "re", "string", "textwrap", "unicodedata", "itertools", "functools", "operator",
    "collections", "heapq", "bisect", "array", "copy", "pprint", "reprlib", "enum", "dataclasses", "typing",
    "abc", "contextlib", "hashlib", "hmac", "base64", "binascii", "uuid", "secrets", "difflib", "fnmatch",
    "struct", "html", "csv", "graphlib", "ipaddress", "colorsys", "__future__",
    # Tool calls made from code go through the guard one by one, with the same role.
    "hermes_tools",
}
DYNAMIC_NAMES = {"exec", "eval", "compile", "__import__", "getattr", "setattr", "delattr", "globals", "locals",
                 "vars", "breakpoint", "__builtins__", "__loader__", "__spec__"}

# Dotted names by what they do. A trailing "*" matches any continuation (os.exec* is os.execv, os.execl...).
RUNS = ["subprocess", "os.system", "os.popen", "os.exec*", "os.spawn*", "os.posix_spawn*", "os.fork*",
        "os.startfile", "pty", "asyncio.create_subprocess_exec", "asyncio.create_subprocess_shell", "commands",
        "pexpect", "sh", "plumbum", "ctypes", "cffi", "importlib", "runpy", "code", "codeop", "marshal",
        "pickle.load", "pickle.loads", "dill", "shelve", "sys.modules", "builtins", "multiprocessing.Process",
        "Foundation.NSAppleScript", "Foundation.NSTask", "objc"]
SENDS = ["smtplib", "imaplib", "poplib", "ftplib", "telnetlib", "socket", "ssl", "http.client", "xmlrpc",
         "requests.post", "requests.put", "requests.patch", "requests.delete", "requests.request",
         "httpx.post", "httpx.put", "httpx.patch", "httpx.delete", "httpx.request", "httpx.stream", "aiohttp",
         "urllib3", "websocket", "websockets", "paramiko", "fabric", "boto3", "botocore", "google.cloud",
         "googleapiclient", "twilio", "slack_sdk", "slack", "tweepy", "discord", "telegram", "pywhatkit",
         "yagmail", "sendgrid", "mailjet_rest", "exchangelib", "O365"]
DELETES = ["os.remove", "os.unlink", "os.rmdir", "os.removedirs", "os.truncate", "shutil.rmtree", "send2trash"]
DRIVES_UI = ["pyautogui", "pynput", "keyboard", "mouse", "Quartz", "AppKit", "Cocoa", "ScriptingBridge", "appscript",
             "applescript", "osascript", "webbrowser"]
WRITES = ["shutil", "os.rename", "os.replace", "os.mkdir", "os.makedirs", "os.chmod", "os.chown", "os.symlink",
          "os.link", "os.utime", "os.mkfifo", "sqlite3", "tempfile"]
HTTP_LIBRARIES = ("requests", "httpx", "aiohttp", "urllib3")


def _matches(name: str, patterns: List[str]) -> bool:
    for pattern in patterns:
        if pattern.endswith("*"):
            if name.startswith(pattern[:-1]):
                return True
        elif name == pattern or name.startswith(pattern + "."):
            return True
    return False


def classify_code(source: str, language: str = "python") -> Verdict:
    source = source or ""
    if not source.strip():
        return read()
    if language == "python":
        try:
            tree = ast.parse(source)
        except (SyntaxError, ValueError, RecursionError, MemoryError):
            tree = None
        if tree is not None:
            return _python(tree, source)
    return _patterns(source, language)


def _shown(source: str, language: str) -> str:
    return f"{language.capitalize() if language != 'python' else 'Python'} code:\n\n{source.strip()}"


def _verdict(found: Dict[str, List[str]], dynamic: List[str], source: str, language: str, pure: bool) -> Verdict:
    shown = _shown(source, language)
    if dynamic:
        return card("run", "Run code that builds what it runs at run time", shown)
    if found["run"]:
        return card("run", "Run code that starts other programs", shown)
    if found["send"]:
        return card("send", "Send data from code", shown)
    if found["delete"]:
        return card("delete", "Delete files from code", shown)
    if found["ui"]:
        return card("ui", "Control the Mac from code", shown)
    if pure:
        return read()
    if found["write"]:
        # Code can write any path, spelled any way, so a file it writes counts like a memory write:
        # fine in a clean turn, a card once the turn has read untrusted content.
        return allow(reads="what the code read", persists=True, rule="write", title="Run code that writes files",
                     detail=shown)
    return allow(reads="what the code read")


def _python(tree: ast.AST, source: str) -> Verdict:
    aliases: Dict[str, str] = {}
    modules: Set[str] = set()
    dynamic: List[str] = []
    found: Dict[str, List[str]] = {"run": [], "send": [], "delete": [], "ui": [], "write": [], "read": []}
    imported: List[str] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                modules.add(alias.name.split(".")[0])
                imported.append(alias.name)
                if alias.asname:
                    aliases[alias.asname] = alias.name
                else:
                    root = alias.name.split(".")[0]
                    aliases[root] = root
        elif isinstance(node, ast.ImportFrom):
            module = node.module or ""
            modules.add(module.split(".")[0] if module else ".")
            for alias in node.names:
                if alias.name == "*":
                    dynamic.append(f"from {module} import *")
                else:
                    aliases[alias.asname or alias.name] = f"{module}.{alias.name}" if module else alias.name
                    imported.append(f"{module}.{alias.name}" if module else alias.name)
    # Importing something that sends, deletes or runs programs is enough: what it's then called is easy to hide.
    for name in imported:
        for kind, patterns in (("run", RUNS), ("send", SENDS), ("delete", DELETES), ("ui", DRIVES_UI)):
            if _matches(name, patterns):
                found[kind].append(name)

    def dotted(node: ast.AST) -> Optional[str]:
        """The imported thing a name or attribute refers to (os.remove), or None for local names."""
        if isinstance(node, ast.Name):
            return aliases.get(node.id)
        if isinstance(node, ast.Attribute):
            base = dotted(node.value)
            return f"{base}.{node.attr}" if base else None
        return None

    http = bool(modules & set(HTTP_LIBRARIES))
    names_used = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Name):
            names_used.add(node.id)
            if node.id in DYNAMIC_NAMES and node.id not in aliases:
                dynamic.append(node.id)
        if isinstance(node, ast.Attribute):
            if node.attr.startswith("__") and node.attr.endswith("__"):
                dynamic.append(node.attr)
            if node.attr in ("unlink", "rmdir"):
                found["delete"].append(node.attr)
            if node.attr in ("write_text", "write_bytes", "touch", "mkdir", "rename", "symlink_to", "hardlink_to",
                             "chmod"):
                found["write"].append(node.attr)
            if node.attr in ("read_text", "read_bytes"):
                found["read"].append(node.attr)
            if http and node.attr in ("post", "put", "patch", "delete", "request", "send"):
                found["send"].append(node.attr)
        if isinstance(node, (ast.Name, ast.Attribute)):
            name = dotted(node)
            if name:
                for kind, patterns in (("run", RUNS), ("send", SENDS), ("delete", DELETES), ("ui", DRIVES_UI),
                                       ("write", WRITES)):
                    if _matches(name, patterns):
                        found[kind].append(name)
        if isinstance(node, ast.Call):
            name = dotted(node.func) or (node.func.id if isinstance(node.func, ast.Name) else "")
            for keyword in node.keywords:
                if keyword.arg == "files":
                    found["send"].append("files=")
                if keyword.arg in ("data", "json") and name.startswith(("urllib.request", "requests", "httpx")):
                    found["send"].append(f"{name}({keyword.arg}=)")
            if name.startswith("urllib.request.urlopen") and len(node.args) > 1:
                found["send"].append(name)
            if name in ("open", "io.open", "codecs.open", "os.open", "os.fdopen") or name.endswith(".open"):
                mode = ""
                if len(node.args) > 1 and isinstance(node.args[1], ast.Constant):
                    mode = str(node.args[1].value)
                for keyword in node.keywords:
                    if keyword.arg in ("mode", "flags") and isinstance(keyword.value, ast.Constant):
                        mode = str(keyword.value.value)
                if any(flag in mode for flag in "wax+") or name == "os.open":
                    found["write"].append("open")
                else:
                    found["read"].append("open")
            elif name.startswith(("urllib.request", "requests.get", "httpx.get")):
                found["read"].append(name)

    pure = (not dynamic and not any(found.values()) and "open" not in names_used
            and all(module in PURE_MODULES for module in modules))
    return _verdict(found, dynamic, source, "python", pure)


_PATTERNS = {
    "run": r"child_process|execSync|spawnSync|\bspawn\b|execFile|\bexec\b|\beval\b|new\s+Function|"
           r"\bFunction\s*\(|vm\.run|\bsystem\b|%x\{|IO\.popen|Open3|Kernel\.|\bqx\b|\bfork\b|"
           r"shell_exec|passthru|proc_open|\bpopen\b|Runtime\.getRuntime|ProcessBuilder|os\.system|subprocess|"
           r"__import__|importlib|Deno\.(run|Command)|Bun\.spawn|doShellScript|do shell script|"
           r"\bopen\s*\(?[^;)]*[\"']\s*\||\bopen\s*\(?[^;)]*,\s*[\"'][|-]",
    "send": r"smtplib|sendmail|nodemailer|axios\.(post|put|patch|delete)|method\s*:\s*['\"](POST|PUT|PATCH|DELETE)|"
            r"XMLHttpRequest|https?\.request|\bnet\.(connect|createConnection)|\bdgram\b|WebSocket|Net::SMTP|"
            r"Net::HTTP|LWP::|HTTP::Tiny|curl_exec|\bmail\s*\(|IO::Socket|TCPSocket|UDPSocket|Socket\.|"
            r"requests\.(post|put|patch|delete)|\.send\s*\(|FormData|multipart",
    "delete": r"unlinkSync|rmSync|rmdirSync|\bfs(\.promises)?\.(rm|unlink|rmdir)\b|FileUtils\.(rm|remove)|"
              r"File\.(delete|unlink)|Dir\.(delete|rmdir|unlink)|\bunlink\b|\brmdir\b|rmtree|os\.remove|os\.unlink|"
              r"send2trash|trashItem|removeItem|Deno\.remove",
    "ui": r"robotjs|nut-js|@nut-tree|CGEvent|osascript|pyautogui|System Events|keystroke|Application\(",
}


def _patterns(source: str, language: str) -> Verdict:
    found: Dict[str, List[str]] = {"run": [], "send": [], "delete": [], "ui": [], "write": [], "read": []}
    for kind, pattern in _PATTERNS.items():
        match = re.search(pattern, source)
        if match:
            found[kind].append(match.group(0))
    if language in ("ruby", "perl", "php", "shell") and re.search(r"`[^`]+`", source):
        found["run"].append("backticks")
    return _verdict(found, [], source, language, pure=False)
