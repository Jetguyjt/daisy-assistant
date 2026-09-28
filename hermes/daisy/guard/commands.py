"""What a terminal command does, program by program.

- Several commands at once (; && || | &, new lines, $(...), backticks, <(...)) are refused unless every
  one of them only reads this Mac: one card has to show exactly one action.
- The program has to be spelled out. A name that comes from a variable, another command's output or a
  wildcard is refused, and so is eval.
- Known read-only programs pass. Sends, deletes, shares, uploads, posts and calendar changes stop for a
  card that shows the whole command. Where a typed tool does the same job, the shell route is refused
  and the model is pointed at the tool.
- Scripts and code the card can't show (bash x.sh, python3 x.py, ./x) stop for a card.
- Anything else runs in chat. Workers and cron only get the read-only programs (roles.py)."""

from __future__ import annotations

import os
import re
import shlex
from pathlib import PurePosixPath
from typing import Callable, Dict, List, Optional, Sequence, Tuple

from .. import registry
from . import targets
from .code import classify_code
from .shell import Segment, Word, parse
from .verdict import Verdict, allow, block, card, read, worst

MAX_DEPTH = 4
GUARD = "Blocked by Daisy's guard: "
CHAIN = (GUARD + "this runs several commands at once ({how}), and one approval card has to show exactly one "
         "action.{step} Run each step as its own command, with every value written out.")
NAME_FROM = (GUARD + "the program's name comes from {source}, so a card can't show what would run. Write the "
             "command out in full.")
WILDCARD = GUARD + "the program's name has a wildcard in it, so a card can't show what would run. Write it out."
UNREADABLE = GUARD + "couldn't read this command ({why}), so it can't show a card for it. Write it more simply."
NESTED = GUARD + "this command nests shells too deeply to check. Run the inner command directly."
EVAL = (GUARD + "eval builds the command while it runs, so a card can't show it. Run the command directly.")
UNKNOWN_VALUE = (GUARD + "{what} uses a value that's only known when it runs ({values}), so the card can't show "
                 "exactly what goes out. Write the value out.")
USE_TYPED = (GUARD + "use the {tool} tool for this instead of the shell. Its approval card shows every field, so "
             "the user sees exactly what goes out.")
GUARD_FILES = (GUARD + "that touches Daisy's guard settings, which the assistant never changes. Ask the user to "
               "change them.")
OUTPUT_UNKNOWN = GUARD + "the output file comes from a variable, so it can't be checked. Write the file name out."
CANT_SEE = "Daisy can't see what this script does, only that it runs."

# Variables that change which program runs or what it loads (plus anything starting LD_, DYLD_ or GIT_).
EXEC_VARS = {"PATH", "BASH_ENV", "ENV", "PROMPT_COMMAND", "PYTHONPATH", "PYTHONSTARTUP", "PYTHONHOME", "NODE_OPTIONS",
             "NODE_PATH", "PERL5OPT", "PERL5LIB", "PERLLIB", "RUBYOPT", "RUBYLIB", "IFS", "PS4", "SHELLOPTS",
             "BASHOPTS", "PAGER", "MANPAGER", "LESSOPEN", "LESSCLOSE", "EDITOR", "VISUAL", "BROWSER", "ZDOTDIR",
             "CDPATH", "FPATH", "SHELL", "SSH_ASKPASS", "SUDO_ASKPASS", "RUSTC_WRAPPER", "NPM_CONFIG_SCRIPT_SHELL"}


def _exec_var(name: str) -> bool:
    return name in EXEC_VARS or name.startswith(("LD_", "DYLD_", "GIT_"))


SYSTEM_DIRS =("/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/System/", "/opt/homebrew/bin/",
               "/opt/homebrew/sbin/", "/usr/local/bin/", "/usr/local/sbin/")
OPERATOR_NAMES = {";": ";", "&&": "&&", "||": "||", "|": "|", "|&": "|&", "&": "&", "\n": "a new line", "(": "( )",
                  ")": "( )", ";;": ";;", ";&": ";&", ";;&": ";;&"}


def classify_command(command, depth: int = 0) -> Verdict:
    text = command if isinstance(command, str) else str(command or "")
    if not text.strip():
        return read()
    if depth > MAX_DEPTH:
        return block(NESTED, title="Run a command")
    parsed = parse(text)
    if parsed.error:
        return block(UNREADABLE.format(why=parsed.error), title="Run a command")
    env: Dict[str, Optional[str]] = {}
    parts = [_segment(segment, env, depth) for segment in parsed.segments]
    parts += [classify_command(inner, depth + 1) for inner in parsed.substitutions]
    if not parts:
        return read()
    hard = [verdict for verdict in parts if verdict.decision == "block" and verdict.hard]
    if hard:
        return hard[0]
    several = len(parts) > 1 or any(op in ("(", ")") for op in parsed.operators)
    if several:
        # A step that reads the network is fine at the head of a pipe (curl url | jq), but never where
        # other output could reach it (after a |, or anywhere once $(...) is involved).
        fed = [segment.before in ("|", "|&") for segment in parsed.segments] + [True] * len(parsed.substitutions)
        safe = [verdict.decision == "allow" and verdict.read_only and
                (not verdict.network or not (piped or parsed.substitutions))
                for verdict, piped in zip(parts, fed)]
        if all(safe):
            links = tuple(link for verdict in parts for link in verdict.urls)
            navigates = any(verdict.navigates for verdict in parts)
            return Verdict(decision="allow", read_only=True, network=any(verdict.network for verdict in parts),
                           reads=next((verdict.reads for verdict in parts if verdict.reads), ""), urls=links,
                           navigates=navigates, title=next((v.title for v in parts if v.navigates), ""))
        offender = parts[safe.index(False)]
        how = sorted({OPERATOR_NAMES[op] for op in parsed.operators if op in OPERATOR_NAMES})
        if parsed.substitutions:
            how.append("$( )")
        step = f" One step needs a yes on its own: {offender.title}." if offender.title else ""
        return block(CHAIN.format(how=", ".join(how) or "grouped commands", step=step), title="Run several commands")
    verdict = parts[0]
    if verdict.decision == "card":
        shown = "$ " + text.strip()
        verdict = verdict.but(detail=f"{verdict.detail}\n\n{shown}" if verdict.detail else shown)
    return verdict


# One simple command

class Cmd:
    """A command's words once variables are filled in: argv[0] is the program."""

    def __init__(self, argv: List[Tuple[str, bool]], segment: Segment, env: Dict[str, Optional[str]], depth: int):
        self.argv = argv
        self.name = argv[0][0]
        self.base = PurePosixPath(self.name).name.lower() if "/" in self.name else self.name.lower()
        self.args = [text for text, _ in argv[1:]]
        self.segment = segment
        self.env = env
        self.depth = depth

    def shifted(self, count: int) -> Optional["Cmd"]:
        if count >= len(self.argv):
            return None
        return Cmd(self.argv[count:], self.segment, self.env, self.depth)

    def unknown_args(self) -> List[str]:
        return [text for text, exact in self.argv[1:] if not exact]

    def positional(self, value_flags: Sequence[str] = ()) -> List[str]:
        found, skip = [], False
        for index, arg in enumerate(self.args):
            if skip:
                skip = False
                continue
            if arg == "--":
                found.extend(self.args[index + 1:])
                break
            if arg.startswith("-") and len(arg) > 1:
                skip = arg in value_flags
                continue
            found.append(arg)
        return found

    def has(self, *flags: str) -> bool:
        return any(arg in flags or any(arg.startswith(flag + "=") for flag in flags if flag.startswith("--"))
                   for arg in self.args)

    def value(self, *flags: str) -> Optional[str]:
        for index, arg in enumerate(self.args):
            for flag in flags:
                if arg == flag and index + 1 < len(self.args):
                    return self.args[index + 1]
                if flag.startswith("--") and arg.startswith(flag + "="):
                    return arg[len(flag) + 1:]
        return None

    def stdin_text(self) -> Optional[str]:
        for body, _ in self.segment.heredocs:
            return body
        for op, word in self.segment.redirects:
            if op == "<<<" and word is not None:
                return word.text(self.env)[0]
        return None


def _expand(words: List[Word], env: Dict[str, Optional[str]]) -> List[Tuple[str, bool]]:
    out: List[Tuple[str, bool]] = []
    for word in words:
        text, exact = word.text(env)
        if exact and word.unquoted_var:
            out.extend((piece, True) for piece in text.split())
        else:
            out.append((text, exact))
    return out


def _segment(segment: Segment, env: Dict[str, Optional[str]], depth: int) -> Verdict:
    words = segment.words
    assigns = []
    while len(assigns) < len(words):
        found = words[len(assigns)].assignment()
        if found is None:
            break
        assigns.append(found)
    rest = words[len(assigns):]
    exec_vars = [name.rstrip("+") for name, _ in assigns if _exec_var(name.rstrip("+"))]
    if not rest:
        for name, value in assigns:
            text, exact = value.text(env)
            env[name.rstrip("+")] = text if exact and not name.endswith("+") else None
        verdict = read()
        if exec_vars:
            verdict = card("run", "Change how later commands run", f"Sets {', '.join(exec_vars)}.")
        return _redirects(verdict, segment, env, empties=True)
    argv = _expand(rest, env)
    if not argv:
        return _redirects(read(), segment, env, empties=True)
    if rest[0].has_sub or not argv[0][1]:
        source = "another command's output" if rest[0].has_sub else "a variable"
        return block(NAME_FROM.format(source=source), title="Run a command")
    if _wild(rest[0]) or (rest[0].unquoted_var and re.search(r"[*?\[{]", argv[0][0])):
        return block(WILDCARD, title="Run a command")
    command = Cmd(argv, segment, env, depth)
    verdict = _program(command)
    verdict = _redirects(verdict, segment, env, empties=_empties(command))
    if exec_vars:
        verdict = worst(verdict, card("run", "Run a command with a changed environment", f"Sets {', '.join(exec_vars)}."))
    return verdict


def _wild(word: Word) -> bool:
    text = "".join(part[1] for part in word.parts if part[0] == "lit")
    if text in ("[", "[[", "{", "}"):
        return False
    return word.unquoted("*?[") or (word.unquoted("{") and word.unquoted(",."))


def _empties(command: Cmd) -> bool:
    """Commands that write nothing, so `cmd > file` just empties the file."""
    return ((command.base in (":", "true", "false") and not command.args)
            or (command.base == "cat" and command.args == ["/dev/null"])
            or (command.base in ("echo", "printf") and command.args in ([], ["-n"], [""], ["-n", ""])))


def _redirects(verdict: Verdict, segment: Segment, env: Dict[str, Optional[str]], empties: bool) -> Verdict:
    for op, word in segment.redirects:
        target, exact = word.text(env) if word is not None else ("", False)
        target = target.strip()
        if op in (">&", "<&") and (target.isdigit() or target == "-"):
            continue
        if target.startswith(("/dev/tcp/", "/dev/udp/")):
            verdict = worst(verdict, card("send", "Send data over a raw network connection", network=True))
            continue
        if op in ("<", "<<<"):
            continue
        if target in ("/dev/null", "/dev/stdout", "/dev/stderr", "/dev/tty", "/dev/fd/1", "/dev/fd/2"):
            continue
        if not exact:
            return worst(verdict, block(OUTPUT_UNKNOWN, title="Write a file"))
        if targets.guard_path(target):
            return block(GUARD_FILES, title="Change Daisy's guard settings", hard=True)
        verdict = _write_target(verdict, target)
        if empties and op in (">", ">|", "&>"):
            verdict = worst(verdict, card("delete", f"Empty {_short(target)}"))
        elif verdict.decision == "allow":
            verdict = verdict.but(read_only=False)
    return verdict


def _write_target(verdict: Verdict, target: str) -> Verdict:
    """What writing to target adds: Hermes settings need a card, instructions persist, programs on the
    PATH could replace a command."""
    if targets.settings_path(target):
        return worst(verdict, card("settings", "Change Hermes settings"))
    if targets.startup_path(target):
        return worst(verdict, card("run", f"Change {_short(target)}, which runs commands later"))
    if on_path(target):
        return worst(verdict, card("run", f"Put a program in {_short(str(PurePosixPath(target).parent))}"))
    if targets.instructions_path(target) and verdict.decision == "allow":
        return verdict.but(persists=True, read_only=False, title=verdict.title or "Change Daisy's instructions")
    return verdict


def on_path(target: str) -> bool:
    """Inside a folder on the PATH, where a new file could stand in for a real command."""
    home = os.environ.get("HOME", "")
    path = target.replace("~", home, 1) if target.startswith("~") else target
    folders = [p for p in os.environ.get("PATH", "").split(":") if p.startswith("/")]
    folders += ["/opt/homebrew/bin", "/usr/local/bin", f"{home}/.local/bin", f"{home}/bin"]
    return any(path.startswith(folder.rstrip("/") + "/") for folder in folders if folder not in ("/", ""))


def _short(path: str) -> str:
    name = PurePosixPath(path.rstrip("/")).name
    return name or path


# Programs

Rule = Callable[[Cmd], Verdict]
RULES: Dict[str, Rule] = {}


def rule(*names: str):
    def register(function: Rule) -> Rule:
        for name in names:
            RULES[name] = function
        return function
    return register


# Programs whose arguments are files they write, delete or change.
WRITERS = {"cp", "mv", "ln", "install", "ditto", "tee", "touch", "mkdir", "chmod", "chown", "chgrp", "chflags", "rm",
           "rmdir", "unlink", "srm", "shred", "trash", "trash-put", "gio", "dd", "truncate", "sed", "gsed", "rsync",
           "curl", "wget", "xattr", "plutil", "defaults", "sqlite3", "patch", "unzip", "tar"}


def _program(command: Cmd) -> Verdict:
    verdict = _program_only(command)
    if verdict.decision == "block" or verdict.read_only:
        return verdict
    if any(targets.guard_path(arg) for arg in command.args):
        return block(GUARD_FILES, title="Change Daisy's guard settings", hard=True)
    if command.base in WRITERS:
        for arg in command.args:
            if not arg.startswith("-"):
                verdict = _write_target(verdict, arg)
    return verdict


def _program_only(command: Cmd) -> Verdict:
    if command.depth > MAX_DEPTH:
        return block(NESTED, title="Run a command")
    name, base = command.name, command.base
    if base.startswith("!") and len(base) > 1:
        return card("run", "Rerun an earlier command")
    if "/" in name and (not name.startswith(SYSTEM_DIRS) or ".." in name.split("/")):
        if base in SCRIPT_RULES:
            return SCRIPT_RULES[base](command)
        if _trusted_script(name):
            return _unknown(command)
        return card("run", f"Run {name}", CANT_SEE)
    found = RULES.get(base)
    if found is not None:
        return found(command)
    if re.fullmatch(r"python[0-9.]*|pypy[0-9.]*", base):
        return _python(command)
    if base in READ_ONLY:
        check = READ_ONLY[base]
        if check is None or check(command):
            return read(reads="files" if base in CONTENT else "")
        return allow()
    return _unknown(command)


def _trusted_script(path: str) -> bool:
    """Scripts that ship with Hermes or its installed skills (not ones written this session elsewhere)."""
    home = os.environ.get("HOME", "")
    full = path.replace("~", home, 1) if path.startswith("~") else path
    roots = [str(targets.hermes_home() / "skills"), f"{home}/.hermes/skills", f"{home}/.hermes/hermes-agent"]
    return ".." not in full.split("/") and any(full.startswith(root.rstrip("/") + "/") for root in roots)


def _typed_instead(names: Sequence[str]) -> Optional[str]:
    """A registered typed tool that does this job, when Daisy is the one running (typed tools only
    exist in Daisy sessions)."""
    from . import roles
    if not roles.DAISY_PROCESS:
        return None
    for name in names:
        tool = registry.get(name)
        if tool is None or tool.risk == "read":
            continue
        try:
            available = tool.check() if tool.check else True
        except Exception:
            available = False
        if available:
            return name
    return None


def _risky(command: Optional[Cmd], rule_name: str, title: str, typed: Sequence[str] = (), **fields) -> Verdict:
    """A card for a send/delete/share, unless a typed tool does the job or a value is only known at run time."""
    tool = _typed_instead(typed)
    if tool:
        return block(USE_TYPED.format(tool=tool), title=title)
    unknown = command.unknown_args() if command is not None else []
    if unknown:
        return block(UNKNOWN_VALUE.format(what=title, values=", ".join(unknown[:3])), title=title)
    return card(rule_name, title, **fields)


# Shell structure: keywords, wrappers and builtins

@rule("}", "fi", "done", "esac", "for", "case", "in", "select", "then", "do", "else", "true", "false", ":", "cd",
      "pushd", "popd", "dirs", "wait", "jobs", "help", "exit", "return", "break", "continue", "shift", "getopts",
      "let", "unset", "set", "shopt", "history")
def _harmless(command: Cmd) -> Verdict:
    if command.base in ("then", "do", "else") and command.args:
        return _inner(command, 1)
    return read()


@rule("{", "if", "elif", "while", "until", "!", "time", "nohup", "chronic", "unbuffer", "builtin")
def _keyword(command: Cmd) -> Verdict:
    skip = 1
    if command.base == "time":
        while skip < len(command.argv) and command.argv[skip][0] in ("-p", "-l", "-h"):
            skip += 1
    return _inner(command, skip, default=read())


def _inner(command: Cmd, skip: int, default: Optional[Verdict] = None) -> Verdict:
    inner = command.shifted(skip)
    if inner is None:
        return default if default is not None else read()
    if not inner.argv[0][1]:
        return block(NAME_FROM.format(source="a variable"), title="Run a command")
    if re.search(r"[*?\[]", inner.name) and inner.name not in ("[", "[["):
        return block(WILDCARD, title="Run a command")
    return _program(inner)


def _skip_options(command: Cmd, with_value: Sequence[str] = (), attached: Sequence[str] = (),
                  numeric: bool = False) -> int:
    """Index of the first word after a wrapper's own options."""
    index = 1
    while index < len(command.argv):
        arg = command.argv[index][0]
        if arg == "--":
            return index + 1
        if not arg.startswith("-") or arg == "-":
            return index
        name = arg.split("=", 1)[0]
        if name in with_value and "=" not in arg:
            index += 2
            continue
        if numeric and re.fullmatch(r"-\d+", arg):
            index += 1
            continue
        if any(arg.startswith(prefix) and len(arg) > len(prefix) for prefix in attached):
            index += 1
            continue
        index += 1
    return index


@rule("function")
def _function(command: Cmd) -> Verdict:
    skip = 2
    while skip < len(command.argv) and command.argv[skip][0] in ("{", "()"):
        skip += 1
    return _inner(command, skip)


@rule("coproc")
def _coproc(command: Cmd) -> Verdict:
    return card("run", "Start a background command", CANT_SEE)


@rule("command")
def _command(command: Cmd) -> Verdict:
    if command.has("-v", "-V"):
        return read()
    return _inner(command, _skip_options(command))


@rule("exec")
def _exec(command: Cmd) -> Verdict:
    return _inner(command, _skip_options(command, with_value=("-a",)))


@rule("env")
def _env(command: Cmd) -> Verdict:
    index = 1
    changed = []
    while index < len(command.argv):
        arg = command.argv[index][0]
        if arg in ("-u", "--unset", "-P", "-C", "--chdir"):
            index += 2
        elif arg in ("-S", "--split-string") or arg.startswith(("-S", "--split-string=")):
            text = arg.split("=", 1)[1] if arg.startswith("--split-string=") else (
                arg[2:] if arg.startswith("-S") and len(arg) > 2 else
                (command.argv[index + 1][0] if index + 1 < len(command.argv) else ""))
            return classify_command(text, command.depth + 1).but(detail="")
        elif arg.startswith("-"):
            index += 1
        elif re.match(r"[A-Za-z_][A-Za-z0-9_]*=", arg):
            changed.append(arg.split("=", 1)[0])
            index += 1
        else:
            break
    verdict = _inner(command, index, default=read())
    risky = [name for name in changed if _exec_var(name)]
    if risky:
        verdict = worst(verdict, card("run", "Run a command with a changed environment", f"Sets {', '.join(risky)}."))
    return verdict


@rule("nice")
def _nice(command: Cmd) -> Verdict:
    return _inner(command, _skip_options(command, with_value=("-n", "--adjustment"), numeric=True))


@rule("timeout", "gtimeout")
def _timeout(command: Cmd) -> Verdict:
    index = _skip_options(command, with_value=("-s", "--signal", "-k", "--kill-after"))
    return _inner(command, index + 1)


@rule("caffeinate")
def _caffeinate(command: Cmd) -> Verdict:
    return _inner(command, _skip_options(command, with_value=("-t", "-w")), default=allow())


@rule("sudo", "doas")
def _sudo(command: Cmd) -> Verdict:
    index = _skip_options(command, with_value=("-u", "-g", "-p", "-C", "-h", "-D", "-R", "-T", "-U", "--user",
                                               "--group", "--prompt", "--close-from", "--host", "--chdir",
                                               "--chroot", "--command-timeout", "--other-user"))
    if command.has("-e", "--edit"):
        return allow(title="Edit a file as the administrator")
    if index >= len(command.argv):
        if command.has("-i", "-s", "--login", "--shell"):
            return card("run", "Start an administrator shell", CANT_SEE)
        return allow()
    return _inner(command, index).but(read_only=False)


@rule("xargs")
def _xargs(command: Cmd) -> Verdict:
    index = _skip_options(command, with_value=("-n", "-L", "-I", "-P", "-s", "-E", "-d", "-a", "-J", "-R", "-S",
                                               "--max-args", "--max-lines", "--replace", "--max-procs",
                                               "--max-chars", "--eof", "--delimiter", "--arg-file"),
                          attached=("-i", "-e", "-l"))
    return _inner(command, index, default=read())


@rule("stdbuf")
def _stdbuf(command: Cmd) -> Verdict:
    return _inner(command, _skip_options(command, with_value=("-i", "-o", "-e")))


@rule("ionice")
def _ionice(command: Cmd) -> Verdict:
    return _inner(command, _skip_options(command, with_value=("-c", "-n", "-p")))


@rule("arch")
def _arch(command: Cmd) -> Verdict:
    return _inner(command, _skip_options(command, with_value=("-arch", "-d", "-e")))


@rule("taskpolicy")
def _taskpolicy(command: Cmd) -> Verdict:
    return _inner(command, _skip_options(command, with_value=("-c", "-d", "-g", "-t", "-l", "-p")))


@rule("script")
def _script(command: Cmd) -> Verdict:
    index = _skip_options(command, with_value=("-t", "-T"))
    return _inner(command, index + 1, default=allow())


@rule("watch")
def _watch(command: Cmd) -> Verdict:
    index = _skip_options(command, with_value=("-n", "--interval", "-q", "--equexit"))
    words = [text for text, _ in command.argv[index:]]
    if not words:
        return read()
    if command.has("-x", "--exec"):
        return _inner(command, index)
    return classify_command(" ".join(words), command.depth + 1).but(detail="")


@rule("eval")
def _eval(command: Cmd) -> Verdict:
    return block(EVAL, title="Run a command built at run time")


@rule("source", ".")
def _source(command: Cmd) -> Verdict:
    target = command.args[0] if command.args else "a file"
    return card("run", f"Run the commands in {target}", CANT_SEE)


@rule("alias")
def _alias(command: Cmd) -> Verdict:
    if any("=" in arg for arg in command.args):
        return card("run", "Define a shell alias", "An alias makes a command name run something else.")
    return read()


@rule("trap")
def _trap(command: Cmd) -> Verdict:
    if not command.args or command.has("-l", "-p"):
        return read()
    return card("run", "Set a command to run later (trap)", CANT_SEE)


@rule("hash")
def _hash(command: Cmd) -> Verdict:
    return card("run", "Point a command name at another program") if command.has("-p") else read()


@rule("fc", "r")
def _rerun(command: Cmd) -> Verdict:
    if command.base == "fc" and command.has("-l"):
        return read()
    return card("run", "Rerun an earlier command", "The card can't show which command that is.")


@rule("enable")
def _enable(command: Cmd) -> Verdict:
    return card("run", "Load a shell builtin", CANT_SEE) if command.has("-f") else allow()


@rule("export", "declare", "typeset", "local", "readonly")
def _declare(command: Cmd) -> Verdict:
    risky = []
    for text, exact in command.argv[1:]:
        match = re.match(r"([A-Za-z_][A-Za-z0-9_]*)(\+?)=(.*)", text, re.S)
        if match:
            command.env[match.group(1)] = match.group(3) if exact and not match.group(2) else None
            if _exec_var(match.group(1)):
                risky.append(match.group(1))
        elif _exec_var(text):
            risky.append(text)
    if risky:
        return card("run", "Change how later commands run", f"Sets {', '.join(risky)}.")
    return read()


INSTALLS = "Installing runs the package's own setup code, which the card can't show."


@rule("umask", "ulimit", "read", "kill", "killall", "pkill", "disown", "bg", "fg", "pbcopy", "say", "afplay",
      "touch", "mkdir", "chmod", "chown", "chgrp", "chflags", "ln", "install", "ditto", "tee", "screencapture",
      "sips", "textutil", "defaults", "brew", "pip", "pip3", "gem", "open-with")
def _changes(command: Cmd) -> Verdict:
    first = command.args[:1]
    if command.base == "defaults" and first in (["read"], ["read-type"], ["domains"], ["find"], ["help"]):
        return read()
    if command.base == "defaults" and any(arg.lower() in ("loginhook", "logouthook") for arg in command.args):
        return card("run", "Set a command to run at login", CANT_SEE)
    if command.base in ("brew", "pip", "pip3", "gem") and first in (
            ["list"], ["info"], ["search"], ["outdated"], ["deps"], ["leaves"], ["config"], ["--version"], ["doctor"],
            ["show"], ["freeze"], ["env"]):
        return read()
    installs = first in (["install"], ["reinstall"], ["upgrade"], ["tap"]) or (command.base == "gem" and first == ["update"])
    if command.base in ("brew", "pip", "pip3", "gem") and installs:
        what = " ".join(command.positional()[1:3]) or "packages"
        return card("run", f"Install {what} with {command.base}", INSTALLS)
    if command.base == "textutil" and command.has("-info"):
        return read(reads="files")
    return allow()


# Shells and interpreters

SHELLS = {"sh", "bash", "zsh", "dash", "ksh", "mksh", "fish", "csh", "tcsh", "posh", "yash"}


@rule(*SHELLS)
def _shell(command: Cmd) -> Verdict:
    letters = ""
    index = 1
    while index < len(command.argv):
        arg = command.argv[index][0]
        if arg in ("-o", "+o", "-O", "+O", "--rcfile", "--init-file"):
            index += 2
            continue
        if arg == "--":
            index += 1
            break
        if arg.startswith("--"):
            if arg in ("--version", "--help"):
                return read()
            index += 1
            continue
        if arg.startswith(("-", "+")) and len(arg) > 1:
            letters += arg[1:]
            index += 1
            continue
        break
    rest = [text for text, _ in command.argv[index:]]
    if "c" in letters:
        if not rest:
            return block(UNREADABLE.format(why="-c without a command"), title="Run a command")
        if not command.argv[index][1]:
            return block(NAME_FROM.format(source="a variable"), title="Run a command")
        return classify_command(rest[0], command.depth + 1).but(detail="")
    if "n" in letters and "c" not in letters:
        return read()
    if rest:
        return _script_file(command, index)
    body = command.stdin_text()
    if body is not None:
        return classify_command(body, command.depth + 1).but(detail="")
    return card("run", "Start a shell that reads commands from input", CANT_SEE)


def _script_file(command: Cmd, index: int) -> Verdict:
    path = command.argv[index][0]
    base = PurePosixPath(path).name.lower()
    if base in SCRIPT_RULES:
        return SCRIPT_RULES[base](command.shifted(index))
    if not command.argv[index][1]:
        return block(NAME_FROM.format(source="a variable"), title="Run a script")
    if _trusted_script(path):
        return _unknown(command.shifted(index))
    return card("run", f"Run the script {path}", CANT_SEE)


def _python(command: Cmd) -> Verdict:
    index = 1
    while index < len(command.argv):
        arg = command.argv[index][0]
        if arg in ("-V", "--version", "-h", "--help") and len(command.argv) == 2:
            return read()
        if arg == "-c":
            if index + 1 >= len(command.argv):
                return block(UNREADABLE.format(why="-c without code"), title="Run Python code")
            return classify_code(command.argv[index + 1][0], "python").but(detail="")
        if arg.startswith("-c") and len(arg) > 2:
            return classify_code(arg[2:], "python").but(detail="")
        if arg == "-m":
            module = command.argv[index + 1][0] if index + 1 < len(command.argv) else ""
            return _python_module(module, command.shifted(index + 1))
        if arg in ("-W", "-X", "-Q"):
            index += 2
            continue
        if arg == "-" or not arg.startswith("-"):
            break
        index += 1
    if index >= len(command.argv) or command.argv[index][0] == "-":
        body = command.stdin_text()
        if body is not None:
            return classify_code(body, "python").but(detail="")
        return card("run", "Start Python reading code from input", CANT_SEE)
    return _script_file(command, index)


def _python_module(module: str, rest: Optional[Cmd]) -> Verdict:
    root = module.split(".")[0]
    if module in ("json.tool", "calendar", "timeit", "this", "platform", "sysconfig", "site", "uuid", "tokenize",
                  "dis", "unicodedata", "base64"):
        return allow()
    if module == "pip" and rest is not None and rest.positional()[:1] in (["install"], ["download"], ["wheel"]):
        return card("run", f"Install {' '.join(rest.positional()[1:3]) or 'packages'} with pip", INSTALLS)
    if module in ("pip", "venv", "ensurepip", "compileall", "py_compile", "zipfile", "tarfile"):
        return allow()
    if module == "webbrowser":
        links = [arg for arg in (rest.args if rest else []) if not arg.startswith("-")]
        return allow(navigates=True, urls=tuple(links), title="Open a page")
    if module in ("http.server", "SimpleHTTPServer", "pydoc"):
        return card("share", "Share this folder over the network")
    if root in ("smtpd", "aiosmtpd", "smtplib"):
        return card("send", f"Run the Python module {module}")
    return card("run", f"Run the Python module {module}", CANT_SEE)


INLINE_CODE = {
    "node": ("javascript", ("-e", "--eval", "-p", "--print")), "bun": ("javascript", ("-e", "--eval")),
    "deno": ("javascript", ()), "tsx": ("javascript", ("-e", "--eval")), "ts-node": ("javascript", ("-e", "--eval")),
    "ruby": ("ruby", ("-e",)), "perl": ("perl", ("-e", "-E")), "php": ("php", ("-r",)), "lua": ("code", ("-e",)),
    "luajit": ("code", ("-e",)), "rscript": ("code", ("-e",)), "julia": ("code", ("-e", "--eval")),
    "swift": ("code", ()), "java": ("code", ()), "groovy": ("code", ("-e",)), "kotlin": ("code", ()),
    "scala": ("code", ("-e",)), "elixir": ("code", ("-e",)), "jshell": ("code", ()), "irb": ("ruby", ()),
    "pwsh": ("code", ("-c", "-command", "-Command")), "powershell": ("code", ("-c", "-command", "-Command")),
}


@rule(*INLINE_CODE)
def _interpreter(command: Cmd) -> Verdict:
    language, code_flags = INLINE_CODE[command.base]
    if command.base in ("pwsh", "powershell") and any(arg.lower().startswith("-e") and arg.lower() in
                                                     ("-e", "-ec", "-encodedcommand") for arg in command.args):
        return block(GUARD + "encoded commands can't be shown on a card. Run the command as plain text.",
                     title="Run PowerShell")
    if command.args in (["--version"], ["-v"], ["-V"], ["--help"], ["-h"]):
        return read()
    if command.base == "deno" and command.args[:1] == ["eval"] and len(command.args) > 1:
        return classify_code(command.args[1], language).but(detail="")
    if command.base in ("deno", "bun") and command.args[:1] in (["run"], ["x"], ["test"], ["task"]):
        target = command.args[1] if len(command.args) > 1 else "a script"
        return card("run", f"Run {target}", CANT_SEE)
    if command.base == "bun" and command.args[:1] in (["install"], ["i"], ["add"], ["update"]):
        return card("run", f"Install {' '.join(command.args[1:3]) or 'the project packages'} with bun", INSTALLS)
    if command.base == "bun" and command.args[:1] in (["remove"], ["pm"], ["outdated"]):
        return allow()
    for index, arg in enumerate(command.args):
        if arg in code_flags and index + 1 < len(command.args):
            return classify_code(command.args[index + 1], language).but(detail="")
        if arg.startswith("-"):
            continue
        return _script_file(command, index + 1)
    body = command.stdin_text()
    if body is not None:
        return classify_code(body, language).but(detail="")
    return card("run", f"Start {command.base} reading code from input", CANT_SEE)


@rule("npx", "bunx", "pnpx", "uvx", "pipx", "make", "gmake", "just", "task", "gradle", "gradlew", "mvn", "ninja",
      "rake", "tox", "nox", "pytest", "automator", "at", "batch", "osacompile")
def _runs_code(command: Cmd) -> Verdict:
    if command.args in (["--version"], ["-v"], ["--help"], ["-h"]) or command.base == "pipx" and command.args[:1] == ["list"]:
        return read()
    what = " ".join([command.base] + command.args[:2])
    return card("run", f"Run {what}", CANT_SEE)


@rule("npm", "yarn", "pnpm", "cargo", "go", "uv", "poetry", "pdm", "hatch", "bundle", "docker", "podman", "kubectl")
def _project_tool(command: Cmd) -> Verdict:
    sub = command.positional()[:1]
    sub = sub[0].lower() if sub else ""
    if not sub and command.base in ("yarn", "pnpm", "bundle") and not command.args:
        return card("run", f"Install the project's packages with {command.base}", INSTALLS)
    if not sub or sub in ("--version", "version", "help", "ls", "list", "view", "info", "outdated", "env", "ps",
                          "images", "logs", "inspect", "get", "describe", "config", "why", "search", "show", "tree"):
        return read()
    if sub in ("publish", "push", "release", "deploy"):
        return _risky(command, "post", f"Publish with {command.base}")
    if sub in ("rm", "rmi", "remove", "delete", "prune", "uninstall", "unpublish", "purge"):
        return _risky(command, "delete", f"Delete with {command.base} {sub}")
    words = [word.lower() for word in command.positional()]
    installs = sub in ("install", "add", "i", "ci", "update", "upgrade", "sync") or words[:2] in (
        ["pip", "install"], ["tool", "install"], ["pip", "sync"])
    if installs and command.base not in ("go", "docker", "podman", "kubectl"):
        what = " ".join(words[1:3]) or "the project's packages"
        return card("run", f"Install {what} with {command.base}", INSTALLS)
    if sub in ("install", "init", "new", "fetch", "pull", "lock", "fmt", "check", "clippy", "vet", "mod", "get", "venv",
               "pip", "cache", "tidy", "download"):
        return allow()
    return card("run", f"Run {command.base} {sub}", CANT_SEE)


# Deleting and writing files

@rule("rm", "rmdir", "unlink", "srm", "shred", "trash", "trash-put", "gio", "gvfs-trash")
def _delete(command: Cmd) -> Verdict:
    if command.base == "gio" and command.args[:1] not in (["trash"], ["remove"], ["rm"]):
        return allow()
    items = command.positional()
    if command.base == "gio":
        items = items[1:]
    if any(targets.guard_path(item) for item in items):
        return block(GUARD_FILES, title="Change Daisy's guard settings", hard=True)
    what = _short(items[0]) if len(items) == 1 else (f"{len(items)} items" if items else "files")
    title = f"Delete {what}" if command.base != "rmdir" else f"Delete the folder {what}"
    return _risky(command, "delete", title)


@rule("mv")
def _move(command: Cmd) -> Verdict:
    items = command.positional(value_flags=("-t", "--target-directory", "-S", "--suffix"))
    if not items:
        return allow()
    destination = command.value("-t", "--target-directory") or items[-1]
    if re.search(r"(^|/)\.Trash(es)?(/|$)", destination) or destination == "/dev/null":
        return _risky(command, "delete", "Move to the Trash" if destination != "/dev/null" else "Delete by moving to /dev/null")
    return allow()


@rule("cp")
def _copy(command: Cmd) -> Verdict:
    items = command.positional(value_flags=("-t", "--target-directory", "-S", "--suffix"))
    if items[:1] == ["/dev/null"] and len(items) > 1:
        return _risky(command, "delete", f"Empty {_short(items[-1])}")
    return allow()


@rule("dd")
def _dd(command: Cmd) -> Verdict:
    output = next((arg[3:] for arg in command.args if arg.startswith("of=")), None)
    if output and output != "/dev/null":
        return _risky(command, "delete", f"Overwrite {_short(output)}")
    return allow()


@rule("truncate")
def _truncate(command: Cmd) -> Verdict:
    items = command.positional(value_flags=("-s", "--size", "-r", "--reference"))
    return _risky(command, "delete", f"Empty or shorten {_short(items[0]) if items else 'a file'}")


@rule("find")
def _find(command: Cmd) -> Verdict:
    args = command.args
    verdict = read()
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == "-delete":
            verdict = worst(verdict, _risky(command, "delete", "Delete the files find matches"))
        elif arg in ("-exec", "-execdir", "-ok", "-okdir"):
            end = index + 1
            while end < len(args) and args[end] not in (";", "+"):
                end += 1
            embedded = command.argv[index + 2:end + 1]
            embedded = [(text, exact) for text, exact in embedded if text not in (";", "+")]
            if embedded:
                if not embedded[0][1] or re.search(r"[*?\[]", embedded[0][0]):
                    return block(NAME_FROM.format(source="a variable or wildcard"), title="Run a command")
                inner = _program(Cmd(embedded, command.segment, command.env, command.depth + 1))
                if inner.decision == "card" and inner.rule == "delete":
                    inner = inner.but(title="Delete the files find matches")
                verdict = worst(verdict, inner)
            index = end
        elif arg in ("-fprint", "-fprint0", "-fprintf", "-fls"):
            verdict = worst(verdict, allow())
        index += 1
    return verdict


@rule("rsync")
def _rsync(command: Cmd) -> Verdict:
    if any(arg.startswith(("--delete", "--del", "--remove-source-files")) for arg in command.args):
        return _risky(command, "delete", "Delete files with rsync")
    remote = [arg for arg in command.positional(value_flags=("-e", "--rsh", "--exclude", "--include", "--filter",
                                                             "-f", "--files-from", "--log-file", "--port"))
              if re.match(r"^([\w.+-]+@)?[\w.-]+:(?!//)", arg) or arg.startswith("rsync://")]
    if remote:
        host = re.sub(r"^([\w.+-]+@)?([\w.-]+):.*$", r"\2", remote[0]).replace("rsync://", "").split("/")[0]
        return _risky(command, "share", f"Copy files to or from {host}")
    return allow()


@rule("diskutil")
def _diskutil(command: Cmd) -> Verdict:
    words = [arg.lower() for arg in command.args]
    if words[:1] in (["list"], ["info"], ["activity"]) or words[:2] in (["apfs", "list"],):
        return read()
    erase = {"erasedisk", "erasevolume", "zerodisk", "randomdisk", "secureerase", "partitiondisk", "deletevolume",
             "reformat", "splitpartition", "mergepartitions", "resizevolume"}
    if any(word in erase for word in words):
        return _risky(command, "delete", "Erase or repartition a disk")
    return allow()


@rule("tmutil")
def _tmutil(command: Cmd) -> Verdict:
    if command.args[:1] and command.args[0].lower().startswith("delete"):
        return _risky(command, "delete", "Delete Time Machine backups")
    if command.args[:1] in (["listbackups"], ["latestbackup"], ["status"], ["destinationinfo"]):
        return read()
    return allow()


@rule("security")
def _security(command: Cmd) -> Verdict:
    if command.args[:1] and command.args[0].startswith("delete"):
        return _risky(command, "delete", "Delete a keychain item")
    return allow()


@rule("sqlite3")
def _sqlite(command: Cmd) -> Verdict:
    text = " ".join(command.args[1:]) + "\n" + (command.stdin_text() or "")
    low = text.lower()
    if re.search(r"(^|\n|;)\s*\.(shell|system)\b", low):
        return card("run", "Run a command from sqlite3", CANT_SEE)
    if re.search(r"\b(delete|drop|truncate)\b", low):
        return _risky(command, "delete", "Delete data from a database")
    if re.search(r"\b(update|insert|replace|alter|create|attach|vacuum)\b|(^|\n)\s*\.(output|once|import|save|backup|restore)\b", low):
        return allow()
    if len(command.args) >= 2 or command.stdin_text() is not None:
        return read(reads="a database")
    return allow()


# Version control and GitHub

GIT_VALUE_OPTIONS = ("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--exec-path",
                     "--super-prefix", "--list-cmds")
GIT_READ = {"status", "log", "diff", "show", "rev-parse", "ls-files", "ls-tree", "blame", "grep", "describe",
            "shortlog", "cat-file", "whatchanged", "show-ref", "for-each-ref", "name-rev", "merge-base", "rev-list",
            "count-objects", "check-ignore", "check-attr", "var", "help", "version", "annotate", "cherry",
            "diff-tree", "diff-files", "diff-index", "range-diff", "verify-commit", "verify-tag", "fsck"}
DANGEROUS_GIT_CONFIG = re.compile(r"^(alias\.|core\.(sshcommand|pager|editor|hookspath|fsmonitor|gitproxy|askpass)|"
                                  r".*\.(command|textconv|clean|smudge|process)$|credential\.helper|"
                                  r"sequence\.editor|diff\.external|uploadpack\.|receivepack\.)", re.I)


@rule("git")
def _git(command: Cmd) -> Verdict:
    index = 1
    while index < len(command.argv):
        arg = command.argv[index][0]
        name, _, value = arg.partition("=")
        if arg == "-c" and index + 1 < len(command.argv):
            if DANGEROUS_GIT_CONFIG.match(command.argv[index + 1][0].split("=", 1)[0]):
                return card("run", "Run git with a custom command", CANT_SEE)
            index += 2
            continue
        if name in ("--exec-path", "--config-env") and value:
            return card("run", "Run git with a custom command", CANT_SEE)
        if arg in GIT_VALUE_OPTIONS:
            index += 2
            continue
        if arg.startswith("-"):
            index += 1
            continue
        break
    if index >= len(command.argv):
        return read()
    sub = command.argv[index][0].lower()
    rest = [text for text, _ in command.argv[index + 1:]]
    flags = set(rest)
    if sub in GIT_READ:
        if any(arg.startswith(("--open-files-in-pager", "-O")) for arg in rest):
            return card("run", "Run git with a custom pager command", CANT_SEE)
        if any(arg.startswith("--output") or arg in ("--ext-diff",) for arg in rest):
            return allow()
        return read(reads="files" if sub in ("show", "diff", "log", "blame", "grep", "cat-file") else "")
    if sub == "branch":
        if flags & {"-d", "-D", "--delete"}:
            return _risky(command, "delete", "Delete a git branch")
        if not [arg for arg in rest if not arg.startswith("-")] or flags & {"--list", "-l", "-a", "-r", "-v", "-vv",
                                                                             "--show-current", "--contains"}:
            return read()
        return allow()
    if sub == "tag":
        if flags & {"-d", "--delete"}:
            return _risky(command, "delete", "Delete a git tag")
        return read() if not rest or flags & {"-l", "--list"} else allow()
    if sub == "remote":
        return read() if not rest or rest[:1] in (["-v"], ["show"], ["get-url"]) else allow()
    if sub == "stash":
        if rest[:1] in (["drop"], ["clear"]):
            return _risky(command, "delete", "Delete stashed changes")
        return read() if rest[:1] in (["list"], ["show"]) else allow()
    if sub == "config":
        keys = [arg for arg in rest if not arg.startswith("-")]
        if flags & {"--get", "--get-all", "--list", "-l", "--get-regexp", "--show-origin"} or not keys:
            return read()
        if keys and DANGEROUS_GIT_CONFIG.match(keys[0]):
            return card("run", "Set git to run a custom command", CANT_SEE)
        return allow()
    if sub in ("worktree", "reflog", "notes", "submodule") and rest[:1] in (["list"], ["show"], []):
        return read()
    if sub == "push":
        remote = next((arg for arg in rest if not arg.startswith("-")), "the remote")
        return _risky(command, "post", f"Push to {remote}")
    if sub in ("send-email", "imap-send", "request-pull"):
        return _risky(command, "send-email", "Send email with git")
    if sub in ("clean", "rm"):
        return _risky(command, "delete", "Delete files with git" if sub == "rm" else "Delete untracked files")
    if sub == "reset" and "--hard" in flags or sub == "restore" and "--staged" not in flags:
        return _risky(command, "delete", "Discard uncommitted changes")
    if sub in ("checkout", "switch") and (flags & {"-f", "--force", "--", "."} or "--discard-changes" in flags):
        return _risky(command, "delete", "Discard uncommitted changes")
    if sub in ("filter-branch", "filter-repo", "update-ref") or sub == "reflog" and rest[:1] in (["expire"], ["delete"]):
        return _risky(command, "delete", "Rewrite or delete git history")
    if sub in ("clone", "fetch", "pull", "ls-remote", "archive", "submodule"):
        links = tuple(arg for arg in rest if re.match(r"^(https?|git|ssh)://|^[\w.+-]+@[\w.-]+:", arg))
        return Verdict(decision="allow", network=True, urls=links, navigates=bool(links),
                       read_only=sub == "ls-remote", title=f"Fetch from {targets.host(links[0])}" if links else "")
    return allow()


GH_READ = {("issue", "list"), ("issue", "view"), ("issue", "status"), ("pr", "list"), ("pr", "view"), ("pr", "status"),
           ("pr", "diff"), ("pr", "checks"), ("repo", "view"), ("repo", "list"), ("release", "list"),
           ("release", "view"), ("gist", "list"), ("gist", "view"), ("run", "list"), ("run", "view"), ("run", "watch"),
           ("workflow", "list"), ("workflow", "view"), ("label", "list"), ("auth", "status"), ("search", ""),
           ("status", ""), ("org", "list"), ("cache", "list"), ("secret", "list"), ("variable", "list"),
           ("codespace", "list"), ("project", "list"), ("project", "view"), ("ruleset", "list"), ("ruleset", "view")}


@rule("gh")
def _gh(command: Cmd) -> Verdict:
    words = command.positional(value_flags=("-R", "--repo", "-X", "--method", "-f", "-F", "--field", "--raw-field",
                                            "-H", "--header", "--input", "-q", "--jq", "-t", "--template"))
    if not words or words[0] in ("--version", "help", "version"):
        return read()
    first = words[0]
    second = words[1] if len(words) > 1 else ""
    if first == "api":
        method = (command.value("-X", "--method") or "GET").upper()
        if command.has("-f", "-F", "--field", "--raw-field", "--input") and not command.has("-X", "--method"):
            method = "POST"
        if method == "GET":
            return read(reads="GitHub", network=True)
        return _risky(command, "post", f"Send a {method} request to GitHub")
    if (first, second) in GH_READ or (first, "") in GH_READ:
        return read(reads="GitHub", network=True)
    if first in ("browse",) or (first, second) in (("repo", "clone"), ("release", "download"), ("gist", "clone"),
                                                    ("run", "download"), ("pr", "checkout"), ("repo", "sync")):
        return allow()
    if first in ("repo", "release", "gist", "run", "label", "secret", "variable", "cache", "codespace", "ssh-key",
                 "gpg-key", "ruleset", "project") and second in ("delete", "rm", "remove"):
        return _risky(command, "delete", f"Delete a GitHub {first}")
    if first == "auth" and second == "token":
        return allow()
    return _risky(command, "post", f"Post to GitHub ({first} {second})".replace(" )", ")"))


# Network

CURL_VALUE_SHORT = "AbcCdDeEFHKmorTuUwxXyYzQPt"
CURL_VALUE_LONG = {"--data", "--data-ascii", "--data-binary", "--data-raw", "--data-urlencode", "--json", "--form",
                   "--form-string", "--header", "--user-agent", "--referer", "--cookie", "--cookie-jar", "--output",
                   "--upload-file", "--user", "--proxy", "--request", "--max-time", "--connect-timeout", "--retry",
                   "--retry-delay", "--retry-max-time", "--config", "--url", "--write-out", "--range", "--cert", "--key",
                   "--cacert", "--capath", "--resolve", "--connect-to", "--interface", "--dns-servers", "--limit-rate",
                   "--max-filesize", "--mail-from", "--mail-rcpt", "--mail-auth", "--oauth2-bearer", "--proto",
                   "--proto-redir", "--expect100-timeout", "--output-dir", "--quote", "--variable", "--aws-sigv4",
                   "--local-port", "--speed-limit", "--speed-time", "--time-cond", "--trace", "--trace-ascii",
                   "--stderr", "--dump-header", "--etag-save", "--etag-compare", "--noproxy", "--preproxy",
                   "--proxy-user", "--socks5", "--socks5-hostname", "--socks4", "--socks4a", "--unix-socket",
                   "--doh-url", "--max-redirs", "--parallel-max", "--rate", "--netrc-file", "--keepalive-time"}
CURL_SENDS = {"-d", "--data", "--data-ascii", "--data-binary", "--data-raw", "--data-urlencode", "--json", "-F",
              "--form", "--form-string", "-T", "--upload-file", "--mail-rcpt", "--mail-from", "-K", "--config",
              "-Q", "--quote", "--variable"}
CURL_WRITES = {"-o", "-O", "-D", "-c", "--output", "--remote-name", "--remote-name-all", "--output-dir",
               "--dump-header", "--cookie-jar", "--trace", "--trace-ascii", "--etag-save"}


@rule("curl")
def _curl(command: Cmd) -> Verdict:
    args = command.args
    links: List[str] = []
    sends: List[str] = []
    method = ""
    writes = False
    index = 0
    while index < len(args):
        arg = args[index]
        following = args[index + 1] if index + 1 < len(args) else ""
        if arg == "--":
            links.extend(args[index + 1:])
            break
        if arg.startswith("--"):
            name, eq, value = arg.partition("=")
            if name in CURL_SENDS:
                sends.append(name)
            if name in CURL_WRITES:
                writes = True
            if name == "--request":
                method = value if eq else following
            if name == "--url":
                links.append(value if eq else following)
            index += 2 if (not eq and name in CURL_VALUE_LONG) else 1
            continue
        if arg.startswith("-") and len(arg) > 1:
            for position, letter in enumerate(arg[1:], start=1):
                flag = "-" + letter
                if flag in CURL_SENDS:
                    sends.append(flag)
                if flag in CURL_WRITES:
                    writes = True
                if letter in CURL_VALUE_SHORT:
                    attached = arg[position + 1:]
                    if letter == "X":
                        method = attached or following
                    if not attached:
                        index += 1
                    break
            index += 1
            continue
        links.append(arg)
        index += 1
    return _fetch(command, links, sends, method, writes, "curl")


WGET_VALUE = {"-O", "-o", "-a", "-P", "-U", "-e", "-i", "-B", "-t", "-T", "-w", "-Q", "-l", "-A", "-R", "-D", "-I",
              "-X", "--header", "--user", "--password", "--output-document", "--output-file", "--append-output",
              "--directory-prefix", "--user-agent", "--execute", "--input-file", "--base", "--tries", "--timeout",
              "--wait", "--quota", "--level", "--accept", "--reject", "--domains", "--include-directories",
              "--exclude-directories", "--method", "--post-data", "--post-file", "--body-data", "--body-file",
              "--config", "--load-cookies", "--save-cookies", "--referer", "--limit-rate", "--http-user",
              "--http-password"}


@rule("wget")
def _wget(command: Cmd) -> Verdict:
    sends = [arg.split("=")[0] for arg in command.args
             if arg.split("=")[0] in ("--post-data", "--post-file", "--body-data", "--body-file", "-e", "--execute",
                                      "--config")]
    method = command.value("--method") or ""
    stdout = command.value("-O", "--output-document") == "-" or "-O-" in command.args or command.has("--spider")
    links = command.positional(value_flags=tuple(WGET_VALUE))
    if command.has("-i", "--input-file"):
        links = []
    return _fetch(command, links, sends, method, not stdout, "wget")


@rule("http", "https", "xh", "xhs")
def _httpie(command: Cmd) -> Verdict:
    words = command.positional(value_flags=("-a", "--auth", "-o", "--output", "--session", "--session-read-only",
                                            "--verify", "--cert", "--cert-key", "--proxy", "--timeout", "-A",
                                            "--auth-type", "--print", "-p", "--pretty", "-s", "--style"))
    methods = {"GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"}
    method = ""
    if words and words[0].upper() in methods:
        method, words = words[0].upper(), words[1:]
    link, items = (words[0], words[1:]) if words else ("", [])
    data = [item for item in items if not re.match(r"^[^=:]+==", item) and not re.match(r"^[^:=@]+:(?!=)", item)
            and re.search(r"=|@", item)]
    sends = ["items"] if data or command.has("-f", "--form", "--multipart") else []
    if command.base.startswith("https") and link and "://" not in link:
        link = "https://" + link
    return _fetch(command, [link] if link else [], sends, method, command.has("-d", "--download", "-o", "--output"),
                  command.base)


def _fetch(command: Cmd, links: List[str], sends: List[str], method: str, writes: bool, tool: str) -> Verdict:
    links = [link for link in links if link]
    hosts = [targets.host(link) for link in links]
    where = next((host for host in hosts if host), "a server")
    plain = all(re.match(r"^(https?|file)://", link, re.I) or "://" not in link for link in links)
    method = (method or "").upper()
    if sends or method not in ("", "GET", "HEAD", "OPTIONS") or not plain:
        uploads = any(flag in ("-F", "--form", "--form-string", "-T", "--upload-file", "--post-file", "--body-file")
                      for flag in sends) or any("@" in arg for arg in command.args if not arg.startswith("-"))
        title = f"Upload a file to {where}" if uploads else f"Send data to {where}"
        return _risky(command, "upload" if uploads else "send", title, network=True, urls=tuple(links))
    return Verdict(decision="allow", read_only=not writes, network=True, reads="the web", urls=tuple(links),
                   navigates=True, title=f"Fetch {where}")


@rule("dig", "nslookup", "host", "ping", "ping6", "traceroute", "whois", "mtr", "nc", "ncat", "netcat", "socat",
      "telnet", "ssh", "scp", "sftp", "ftp", "lftp", "mosquitto_pub", "websocat", "aria2c", "lynx", "w3m", "links")
def _network(command: Cmd) -> Verdict:
    words = command.positional(value_flags=("-p", "-P", "-i", "-o", "-F", "-J", "-L", "-R", "-D", "-W", "-l", "-c",
                                            "-t", "-b", "-e", "-m", "-q", "-s", "-w", "-h", "-u", "-x", "-X", "-T"))
    remote = next((match.group(2) for match in (re.match(r"^([\w.+-]+@)?([\w.-]+):", word) for word in words)
                   if match), "")
    where = remote or next((targets.host(word) for word in words if targets.host(word)), "a server")
    if command.base in ("dig", "nslookup", "host", "ping", "ping6", "traceroute", "whois", "mtr"):
        return Verdict(decision="allow", read_only=True, network=True, urls=tuple(words[:1]), navigates=True,
                       title=f"Look up {where}")
    if command.base in ("aria2c", "lynx", "w3m", "links"):
        return Verdict(decision="allow", network=True, reads="the web", urls=tuple(words), navigates=True,
                       title=f"Fetch {where}")
    if command.base == "ssh":
        return _risky(command, "run", f"Connect to {where} over SSH", detail=CANT_SEE, network=True)
    if command.base in ("scp", "sftp", "ftp", "lftp"):
        return _risky(command, "share", f"Copy files to or from {where}", network=True)
    return _risky(command, "send", f"Open a raw network connection to {where}", network=True)


CLOUD_READERS = ("describe", "list", "get", "ls", "lsd", "lsl", "lsf", "lsjson", "cat", "du", "stat", "size", "about",
                 "info", "show", "check", "tree", "md5sum", "whoami", "status", "logs")
CLOUD_DELETES = ("rm", "rb", "delete", "purge", "deletefile", "rmdir", "destroy", "remove")
CLOUD_WRITES = ("cp", "mv", "sync", "copy", "move", "copyto", "moveto", "rcat", "deploy", "publish", "upload", "put",
                "create", "update", "set", "apply", "mb", "mkdir", "acl", "iam", "rsync", "mount", "serve", "ch")


@rule("aws", "gsutil", "gcloud", "rclone", "az", "firebase", "vercel", "netlify", "wrangler", "heroku", "fly",
      "flyctl", "twine")
def _cloud(command: Cmd) -> Verdict:
    words = [word.lower() for word in command.positional()]
    first = words[:3]
    if command.base == "vercel" and (not words or words[0] in ("deploy", "--prod")):
        return _risky(command, "post", "Deploy with vercel", network=True)
    if not words or any(word in ("--version", "version", "help", "--help") for word in first):
        return read()
    if any(word in CLOUD_DELETES or word.startswith("delete") for word in first):
        return _risky(command, "delete", f"Delete with {command.base}", network=True)
    if any(word.startswith(CLOUD_READERS) for word in first) and not any(
            word in CLOUD_WRITES or word.startswith(("put", "create", "update", "set")) for word in first):
        return read(reads="a cloud service", network=True)
    return _risky(command, "share", f"Change or upload with {command.base} {' '.join(words[:2])}".strip(), network=True)


# Opening things on the Mac

MESSAGE_SCHEMES = ("mailto", "sms", "imessage", "tel", "facetime", "facetime-audio", "callto", "skype", "whatsapp",
                   "tg", "slack")
RUNNABLE = (".command", ".sh", ".tool", ".app", ".workflow", ".scpt", ".applescript", ".scptd", ".terminal", ".pkg",
            ".mpkg", ".action", ".shortcut", ".py", ".rb", ".pl", ".jar", ".js", ".zsh", ".bash")


@rule("open", "xdg-open")
def _open(command: Cmd) -> Verdict:
    args = command.args
    app = (command.value("-a", "-b") or "").lower()
    links: List[str] = []
    files: List[str] = []
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == "--args":
            break
        if arg in ("-a", "-b", "-s", "--env", "--stdin", "--stdout", "--stderr", "-i", "-o"):
            index += 2
            continue
        if arg in ("-u", "--url") and index + 1 < len(args):
            links.append(args[index + 1])
            index += 2
            continue
        if arg.startswith("-"):
            index += 1
            continue
        (links if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", arg) and not arg.startswith("/") else files).append(arg)
        index += 1
    for link in links:
        if targets.script_url(link):
            return block(GUARD + "javascript: links run code inside a web page and are never opened.",
                         title="Open a javascript: link", hard=True)
    for link in links:
        scheme = link.split(":", 1)[0].lower()
        if scheme in MESSAGE_SCHEMES:
            to = re.sub(r"^[a-z-]+:(//)?", "", link, flags=re.I).split("?")[0] or "someone"
            return _risky(command, "send", f"Open a new message to {to}")
        if scheme in ("shortcuts", "x-callback-url") or "run-shortcut" in link:
            return _risky(command, "run", "Run a Shortcut", detail=CANT_SEE)
    for path in files:
        if path.lower().rstrip("/").endswith(RUNNABLE) or app in ("terminal", "iterm", "iterm2", "script editor"):
            return card("run", f"Open {_short(path)}, which runs code", CANT_SEE)
    web = [link for link in links if re.match(r"^https?://", link, re.I)]
    if web:
        return allow(navigates=True, urls=tuple(web), title=f"Open {targets.host(web[0]) or 'a page'}")
    return allow()


# cua-driver drives other apps straight through macOS and skips computer_use's hard-blocks (log out,
# empty trash...). Its own status is fine to read; everything else goes through computer_act.
CUA_DRIVER_READS = {"manifest", "doctor", "status", "check-update", "help"}


@rule("cua-driver")
def _cua_driver(command: Cmd) -> Verdict:
    words = [word.lower() for word in command.positional()]
    if not command.args or command.has("--version", "-V", "--help", "-h") or (words and words[0] in CUA_DRIVER_READS) \
            or words[:2] == ["permissions", "status"]:
        return read()
    tool = _typed_instead(("computer_act",))
    if tool:
        return block(USE_TYPED.format(tool=tool), title="Control another app")
    return card("ui", "Control another app with cua-driver", " ".join([command.name, *command.args]))


@rule("osascript")
def _osascript(command: Cmd) -> Verdict:
    scripts = []
    language = "applescript"
    index = 0
    args = command.args
    while index < len(args):
        arg = args[index]
        if arg == "-e" and index + 1 < len(args):
            scripts.append(args[index + 1])
            index += 2
            continue
        if arg == "-l" and index + 1 < len(args):
            language = args[index + 1].lower()
            index += 2
            continue
        if arg.startswith("-"):
            index += 1
            continue
        if not scripts:
            if arg == "-":
                break
            return card("run", f"Run the AppleScript file {arg}", CANT_SEE)
        break
    if not scripts:
        body = command.stdin_text()
        if body is None:
            return card("run", "Run AppleScript from input", CANT_SEE)
        scripts.append(body)
    return applescript("\n".join(scripts), javascript=language.startswith("javascript"), command=command)


def applescript(script: str, javascript: bool = False, command: Optional[Cmd] = None) -> Verdict:
    """What an AppleScript (or JavaScript for Automation) snippet does."""
    low = script.lower()
    if re.search(r"[\"']\s*(javascript|vbscript)\s*:", low):
        return block(GUARD + "javascript: links run code inside a web page and are never opened.",
                     title="Open a javascript: link", hard=True)
    app = r"(?:application|app)\s*(?:id\s*)?\(?\s*[\"']"
    messages = re.search(app + r"(messages|com\.apple\.(mobilesms|ichat))[\"']", low)
    mail = re.search(app + r"(mail|com\.apple\.mail|microsoft outlook|outlook)[\"']", low)
    if (messages or mail) and re.search(r"\bsend\b", low):
        what = "Send with Messages" if messages else "Send with Mail"
        return _risky(command, "send-message" if messages else "send-email", what) if command else card("send", what)
    if re.search(r"do\s+shell\s+script|doshellscript|\bdo\s+script\b|\.doscript\s*\(|write\s+text\b|"
                 r"run\s+script|load\s+script|objc\.import|\$\.ns(task|applescript|workspace)", low):
        return card("run", "Run commands from AppleScript", CANT_SEE)
    if re.search(r"\bopen\b", low) and re.search(r"\.(command|sh|tool|app|pkg|mpkg|workflow|scpt|terminal)\b", low):
        return card("run", "Open something that runs code, from AppleScript", CANT_SEE)
    if re.search(r"login\s+item|loginitems", low):
        return card("run", "Add something that runs at login", CANT_SEE)
    if re.search(r"execute\b[^\n]*javascript|do\s+javascript|\.execute\s*\(", low):
        return card("ui", "Run JavaScript in a browser tab")
    if re.search(r"\bkeystroke\b|\bkey\s+code\b|\bclick\b|perform\s+action|\.keystroke\s*\(|\.click\s*\(", low):
        return card("ui", "Type or click in another app")
    if re.search(r"\bdelete\b|empty\s+(the\s+)?trash|move\b[^\n]*\bto\s+(the\s+)?trash|\.delete\s*\(", low):
        return card("delete", "Delete with AppleScript")
    if re.search(app + r"(calendar|ical)[\"']", low) and re.search(r"\bmake\b|\bset\b|\.make\s*\(", low):
        return card("calendar", "Change your calendar")
    links = targets.URL_IN_TEXT.findall(script)
    reads = ""
    if re.search(app + r"(mail|messages|notes|google chrome|safari|arc|reminders|calendar|contacts)", low):
        reads = "an app's content"
    if re.search(r"open\s+location|\.openlocation\s*\(|set\s+url\b|\.url\s*=", low) and links:
        return allow(navigates=True, urls=tuple(links), reads=reads, title=f"Open {targets.host(links[0]) or 'a page'}")
    return allow(reads=reads)


# Messages, mail, reminders, notes, shortcuts

@rule("imsg")
def _imsg(command: Cmd) -> Verdict:
    words = command.positional(value_flags=("--to", "-t", "--text", "-m", "--message", "--file", "-f", "--service",
                                            "--chat", "--chat-id", "--limit", "-n", "--handle"))
    sub = words[0].lower() if words else ""
    if not command.args or sub in ("chats", "history", "watch", "search", "contacts", "list", "read", "help") or \
            command.has("--help", "-h", "--version"):
        return read(reads="messages")
    if sub == "send":
        to = command.value("--to", "-t", "--recipient", "--handle") or "someone"
        return _risky(command, "send-message", f"Send an iMessage to {to}", ("imsg_send",))
    return _risky(command, "send-message", f"Run imsg {sub}".strip())


@rule("mail", "mailx", "s-nail", "sendmail", "msmtp", "ssmtp", "mutt", "neomutt", "swaks", "mpack", "mailsend")
def _mail(command: Cmd) -> Verdict:
    if command.base in ("mail", "mailx", "s-nail", "mutt", "neomutt") and not command.args:
        return read(reads="email") if command.base.startswith("mail") else allow()
    words = command.positional(value_flags=("-s", "-a", "-c", "-b", "-r", "-f", "-S", "-q", "-F", "-e", "-i", "-x"))
    to = ", ".join(words) or "someone"
    return _risky(command, "send-email", f"Send an email to {to}", ("gmail_send",))


@rule("himalaya")
def _himalaya(command: Cmd) -> Verdict:
    words = [word.lower() for word in command.positional(value_flags=("-a", "--account", "-c", "--config", "-f",
                                                                      "--folder", "-o", "--output", "-s", "--page-size",
                                                                      "-p", "--page"))]
    if any(word in ("send", "reply", "forward", "write") for word in words):
        return _risky(command, "send-email", "Send an email with himalaya", ("gmail_send",))
    if any(word in ("delete", "remove", "move", "expunge", "purge", "copy", "flag") for word in words):
        return _risky(command, "delete", "Delete or move email with himalaya")
    if not words or any(word in ("list", "read", "search", "envelope", "export", "folder", "account", "attachment",
                                 "thread", "help") for word in words):
        return read(reads="email", network=True)
    return _risky(command, "send-email", f"Run himalaya {' '.join(words[:2])}")


@rule("remindctl")
def _remindctl(command: Cmd) -> Verdict:
    sub = command.positional()[:1]
    sub = sub[0].lower() if sub else ""
    if sub in ("delete", "remove", "rm", "clear", "purge"):
        return _risky(command, "delete", "Delete a reminder")
    if sub in ("", "list", "show", "lists", "today", "overdue", "upcoming", "search", "get", "help") or command.has("--help"):
        return read(reads="reminders")
    return allow()


@rule("memo")
def _memo(command: Cmd) -> Verdict:
    words = [arg.lower() for arg in command.args]
    if any(word in ("-d", "--delete", "delete", "remove", "rm") for word in words):
        return _risky(command, "delete", "Delete a note")
    if any(word in ("-a", "--add", "-e", "--edit", "-m", "--move", "add", "edit", "move") for word in words):
        return allow()
    return read(reads="notes")


@rule("shortcuts")
def _shortcuts(command: Cmd) -> Verdict:
    sub = command.args[0].lower() if command.args else ""
    if sub == "run":
        name = command.args[1] if len(command.args) > 1 else "a Shortcut"
        return _risky(command, "run", f"Run the Shortcut “{name}”", detail=CANT_SEE)
    return read() if sub in ("", "list", "view", "help") else allow()


@rule("crontab")
def _crontab(command: Cmd) -> Verdict:
    if command.has("-l"):
        return read()
    if command.has("-r"):
        return _risky(command, "delete", "Delete your scheduled commands (crontab)")
    return card("run", "Change your scheduled commands (crontab)", CANT_SEE)


@rule("launchctl")
def _launchctl(command: Cmd) -> Verdict:
    sub = command.args[0].lower() if command.args else ""
    if sub in ("", "list", "print", "print-disabled", "blame", "dumpstate", "help", "version", "managerpid"):
        return read()
    if sub in ("load", "bootstrap", "submit", "enable", "kickstart", "start", "asuser", "bsexec"):
        return card("run", "Start a background service", CANT_SEE)
    return allow()


@rule("hermes")
def _hermes(command: Cmd) -> Verdict:
    words = [arg.lower() for arg in command.args]
    if any(word in ("--yolo", "-z") for word in words):
        return block(GUARD + "that turns approvals off, which Daisy never does.", title="Turn approvals off", hard=True)
    positional = [word for word in words if not word.startswith("-")]
    if positional[:1] == ["plugins"] and any(word in ("disable", "remove", "uninstall", "rm") for word in positional[1:2]):
        return block(GUARD + "that would switch off Daisy's guard. Ask the user to do it themselves.",
                     title="Switch off Daisy's guard", hard=True)
    if positional[:1] in (["plugins"], ["config"], ["setup"], ["tools"], ["auth"], ["model"]) and positional[1:2] and \
            positional[1] not in ("list", "show", "get", "status", "doctor", "path"):
        return card("settings", "Change Hermes settings")
    if positional[:1] == ["cron"] and positional[1:2] and positional[1] not in ("list", "status", "show"):
        return card("run", "Change scheduled jobs")
    return allow()


# Google Workspace (the google-workspace skill's google_api.py, and the gws CLI)

GOOGLE_READ = {
    "gmail": {"search", "get", "labels", "list", "read", "thread", "threads", "history", "profile", "attachments"},
    "calendar": {"list", "get", "freebusy", "calendars", "search", "events"},
    "drive": {"search", "get", "list", "info", "permissions", "about"},
    "contacts": {"list", "search", "get"},
    "sheets": {"get", "read", "list", "info", "metadata"},
    "docs": {"get", "read", "list", "export"},
    "slides": {"get", "read", "list"},
}
GOOGLE_RISK = {
    "gmail": {"send": ("send-email", "Send an email", ("gmail_send",)),
              "reply": ("send-email", "Reply to an email", ("gmail_reply", "gmail_send")),
              "forward": ("send-email", "Forward an email", ("gmail_forward", "gmail_send")),
              "draft": ("write", "Save an email draft", ("gmail_draft",)),
              "modify": ("write", "Change your email (labels, archive or trash)", ("gmail_modify",)),
              "trash": ("delete", "Move email to the trash", ("gmail_modify", "gmail_delete")),
              "delete": ("delete", "Delete email", ("gmail_delete", "gmail_modify")),
              "archive": ("write", "Archive email", ("gmail_modify",))},
    "calendar": {"*": ("calendar", "Change your calendar", ("calendar_write",)),
                 "delete": ("calendar", "Delete a calendar event", ("calendar_write", "calendar_delete"))},
    "drive": {"upload": ("upload", "Upload a file to Google Drive", ("drive_upload",)),
              "share": ("share", "Share a Google Drive file", ("drive_share",)),
              "delete": ("delete", "Delete a Google Drive file", ("drive_delete",)),
              "trash": ("delete", "Move a Google Drive file to the trash", ("drive_delete",)),
              "*": ("write", "Change Google Drive", ("drive_write",))},
    "sheets": {"*": ("write", "Change a Google Sheet", ("sheets_write",))},
    "docs": {"*": ("write", "Change a Google Doc", ("docs_write",))},
    "slides": {"*": ("write", "Change Google Slides", ("slides_write",))},
    "contacts": {"*": ("write", "Change your contacts", ("contacts_write",))},
}


def _google_api(command: Cmd) -> Verdict:
    """python3 .../google_api.py <service> <action> ...; command.argv[0] is the script."""
    if command is None:
        return card("write", "Run a Google command")
    words = command.positional(value_flags=("--to", "--cc", "--bcc", "--subject", "--body", "--from", "--max",
                                            "--start", "--end", "--summary", "--location", "--attendees", "--email",
                                            "--role", "--type", "--domain", "--name", "--parent", "--output",
                                            "--export-mime", "--values", "--text", "--title", "--sheet-name",
                                            "--add-labels", "--remove-labels", "--attach", "--file", "--html-file",
                                            "--calendar", "--description", "--query"))
    if command.has("--help", "-h") or not words:
        return read()
    service = words[0].lower()
    action = words[1].lower() if len(words) > 1 else ""
    if action in GOOGLE_READ.get(service, set()):
        return read(reads=f"Google {service.capitalize()}", network=True)
    if service == "drive" and action == "download":
        return allow(reads="Google Drive", network=True)
    risk = GOOGLE_RISK.get(service, {})
    rule_name, title, typed = risk.get(action) or risk.get("*") or ("write", f"Run a Google {service} command", ())
    to = command.value("--to", "--email")
    if service == "gmail" and action in ("send", "forward") and to:
        title = f"{title} to {to}"
    if service == "drive" and action == "share":
        who = "anyone with the link" if (command.value("--type") or "").lower() == "anyone" else (to or "someone")
        title = f"{title} with {who}"
    return _risky(command, rule_name, title, typed, network=True)


@rule("gws")
def _gws(command: Cmd) -> Verdict:
    words = command.positional(value_flags=("--params", "--json", "--format", "--fields", "--output", "-o", "--upload",
                                            "--page-limit", "--api-version"))
    if not words or command.has("--help", "-h"):
        return read()
    service = words[0].lower()
    method = words[-1].lower() if len(words) > 1 else ""
    resources = [word.lower() for word in words[1:-1]]
    readers = ("list", "get", "search", "export", "query", "batchget", "getprofile", "freebusy")
    if method in readers or method.startswith("list"):
        return read(reads=f"Google {service.capitalize()}", network=True)
    if service == "gmail" and method == "send":
        return _risky(command, "send-email", "Send an email", ("gmail_send",), network=True)
    if service == "drive" and "permissions" in resources:
        return _risky(command, "share", "Share a Google Drive file", ("drive_share",), network=True)
    if method in ("delete", "emptytrash", "trash", "batchdelete"):
        typed = {"drive": ("drive_delete",), "calendar": ("calendar_write",)}.get(service, ())
        rule_name = "calendar" if service == "calendar" else "delete"
        return _risky(command, rule_name, f"Delete in Google {service.capitalize()}", typed, network=True)
    if service == "calendar":
        return _risky(command, "calendar", "Change your calendar", ("calendar_write",), network=True)
    typed = {"drive": ("drive_write", "drive_upload"), "sheets": ("sheets_write",), "docs": ("docs_write",),
             "gmail": ("gmail_modify",)}.get(service, ())
    return _risky(command, "write", f"Change Google {service.capitalize()} ({method})", typed, network=True)


SCRIPT_RULES: Dict[str, Callable[[Cmd], Verdict]] = {"google_api.py": _google_api, "gws_bridge.py": _gws}
# ~/.local/bin/cua-driver and the one inside CuaDriver.app get the same rule as the bare name.
SCRIPT_RULES["cua-driver"] = _cua_driver
RULES["google_api.py"] = _google_api


# Read-only programs

def _no(*flags: str) -> Callable[[Cmd], bool]:
    def check(command: Cmd) -> bool:
        for arg in command.args:
            for flag in flags:
                if arg == flag or (flag.startswith("--") and arg.startswith(flag + "=")):
                    return False
                if len(flag) == 2 and flag.startswith("-") and arg.startswith("-") and not arg.startswith("--") \
                        and flag[1] in arg[1:]:
                    return False
        return True
    return check


@rule("sed", "gsed")
def _sed(command: Cmd) -> Verdict:
    if command.has("-f", "--file") or any(arg.startswith("-f") and len(arg) > 2 for arg in command.args):
        return card("run", "Run a sed script file", CANT_SEE)
    scripts = [command.args[index + 1] for index, arg in enumerate(command.args[:-1]) if arg in ("-e", "--expression")]
    if not scripts:
        scripts = [arg for arg in command.args if not arg.startswith("-")][:1]
    for script in scripts:
        if re.search(r"(^|[;{}\n])\s*[0-9,$/!]*\s*e\b", script) or re.search(r"s(.).*?\1.*?\1[gpiImMw0-9]*e", script):
            return card("run", "Run commands from sed", CANT_SEE)
    writes = any(re.search(r"(^|[;{}\n])\s*[0-9,$/!]*\s*[wW]\b", script) or
                 re.search(r"s(.).*?\1.*?\1[gpiImM0-9]*w", script) for script in scripts)
    if writes or not _no("-i", "-I", "--in-place")(command):
        return allow()
    return read(reads="files")


@rule("awk", "gawk", "nawk", "mawk")
def _awk(command: Cmd) -> Verdict:
    if command.has("-f", "--file") or any(arg.startswith("-f") and len(arg) > 2 for arg in command.args):
        return card("run", "Run an awk script file", CANT_SEE)
    program = next((arg for arg in command.args if not arg.startswith("-")), "")
    if re.search(r"\bsystem\s*\(|\|\s*getline|\|&|\bprint[^;}]*\||\bprintf[^;}]*\|", program):
        return card("run", "Run commands from awk", CANT_SEE)
    if re.search(r"[^>]>[^=>]|>>", program):
        return allow()
    return read(reads="files")


@rule("vi", "vim", "nvim", "view", "ex", "ed", "emacs", "emacsclient", "parallel", "expect", "screen", "tmux", "su",
      "runuser", "chroot", "strace", "dtruss", "ltrace", "lldb", "gdb", "ssh-agent", "flock", "setsid", "busybox",
      "toybox", "entr", "fswatch")
def _runs_other_commands(command: Cmd) -> Verdict:
    if command.args in (["--version"], ["-v"], ["--help"], ["-h"]) or (command.base == "tmux" and command.args[:1] in
                                                                         (["ls"], ["list-sessions"])):
        return read()
    return card("run", f"Run {command.base}, which can run other commands", CANT_SEE)


@rule("tar", "bsdtar", "gtar", "zip", "unzip")
def _archive(command: Cmd) -> Verdict:
    runs = ("--to-command", "--use-compress-program", "--checkpoint-action", "--info-script", "--new-volume-script",
            "-I", "-F", "-TT", "--unzip-command")
    if any(arg == flag or arg.startswith(flag + "=") for arg in command.args for flag in runs):
        return card("run", f"Run {command.base} with a helper command", CANT_SEE)
    if command.base == "unzip" and (command.has("-l", "-v", "-t") or command.has("-p")):
        return read(reads="files")
    if command.base in ("tar", "bsdtar", "gtar") and any(re.fullmatch(r"-?[a-zA-Z]*t[a-zA-Z]*", arg) and "c" not in arg
                                                          and "x" not in arg for arg in command.args[:1]):
        return read()
    return allow()


@rule("openssl")
def _openssl(command: Cmd) -> Verdict:
    sub = command.args[0].lower() if command.args else ""
    if sub in ("s_client", "s_server", "s_time", "ocsp"):
        return _risky(command, "send", "Open an encrypted network connection with openssl", network=True)
    return allow()


@rule("ngrok", "cloudflared", "lt", "localtunnel", "bore", "frpc", "sharing", "tailscale")
def _expose(command: Cmd) -> Verdict:
    if command.args[:1] in (["status"], ["list"], ["--version"], ["version"], ["-l"]):
        return read()
    return _risky(command, "share", f"Share this Mac over the network with {command.base}", network=True)


@rule("terminal-notifier")
def _notifier(command: Cmd) -> Verdict:
    if command.has("-execute"):
        return card("run", "Run a command from a notification", CANT_SEE)
    return allow()


@rule("man", "rg", "sort")
def _reader_with_helper(command: Cmd) -> Verdict:
    """Readers with an option that runs another program (a pager, a preprocessor, a compressor)."""
    helpers = {"man": ("-P", "--pager", "-H", "--html"), "rg": ("--pre",),
               "sort": ("--compress-program",)}[command.base]
    if any(arg == flag or arg.startswith(flag + "=") or (len(flag) == 2 and arg.startswith(flag) and len(arg) > 2)
           for arg in command.args for flag in helpers):
        return card("run", f"Run {command.base} with a helper program", CANT_SEE)
    if command.base == "sort" and not _no("-o", "--output")(command):
        return allow()
    return read(reads="" if command.base == "man" else "files")


@rule("fd", "fdfind")
def _fd(command: Cmd) -> Verdict:
    for index, arg in enumerate(command.args):
        if arg in ("-x", "-X", "--exec", "--exec-batch"):
            embedded = [(text, exact) for text, exact in command.argv[index + 2:] if text not in (";",)]
            if not embedded:
                return read()
            if not embedded[0][1] or re.search(r"[*?\[]", embedded[0][0]):
                return block(NAME_FROM.format(source="a variable or wildcard"), title="Run a command")
            return worst(read(), _program(Cmd(embedded, command.segment, command.env, command.depth + 1)))
    return read()


@rule("icalbuddy")
def _icalbuddy(command: Cmd) -> Verdict:
    return read(reads="calendar events")


def _positional_at_most(count: int, value_flags: Sequence[str] = ()) -> Callable[[Cmd], bool]:
    return lambda command: len(command.positional(value_flags)) <= count


def _date(command: Cmd) -> bool:
    return _no("-s", "--set")(command) and all(arg.startswith(("+", "-")) for arg in command.args)


def _sysctl(command: Cmd) -> bool:
    return _no("-w")(command) and not any("=" in arg for arg in command.args)


def _first_is(*words: str) -> Callable[[Cmd], bool]:
    return lambda command: bool(command.args) and command.args[0] in words


READ_ONLY: Dict[str, Optional[Callable[[Cmd], bool]]] = {
    name: None for name in (
        "ls", "cat", "head", "tail", "less", "more", "grep", "egrep", "fgrep", "zgrep", "wc", "du", "df", "stat", "pwd",
        "echo", "printf", "basename", "dirname", "realpath", "readlink", "whoami", "id", "groups", "uname", "sw_vers",
        "uptime", "cal", "which", "whereis", "type", "cut", "tr", "column", "nl", "fold", "fmt", "rev", "tac",
        "comm", "diff", "cmp", "paste", "join", "expand", "unexpand", "seq", "jq", "md5", "shasum", "sha1sum",
        "sha256sum", "md5sum", "cksum", "od", "hexdump", "strings", "mdfind", "mdls", "locate", "test", "[", "[[",
        "printenv", "sleep", "ps", "pgrep", "lsof", "vm_stat", "iostat", "system_profiler", "ioreg", "pbpaste",
        "netstat", "bat", "ag", "yes", "nproc", "lsappinfo", "tty", "locale", "getconf", "zcat", "gzcat",
        "bzcat", "xzcat", "zless", "look", "iconv", "numfmt", "factor", "units", "expr", "tput")
}
READ_ONLY.update({
    "uniq": _positional_at_most(1, ("-f", "-s", "-w")),
    "date": _date,
    "hostname": lambda command: not command.positional(),
    "sysctl": _sysctl,
    "pmset": _first_is("-g"),
    "plutil": _first_is("-p", "-lint", "-help", "-type"),
    "xattr": _no("-w", "-d", "-c"),
    "top": lambda command: "-l" in command.args,
    "xxd": _no("-r"),
    "base64": _no("-o", "--output"),
    "tree": _no("-o"),
    "file": _no("-C"),
    "ifconfig": lambda command: len(command.positional()) <= 1,
})
# Programs that print what's inside files: after one runs, the turn has read file content.
CONTENT = {"cat", "head", "tail", "less", "more", "grep", "egrep", "fgrep", "zgrep", "rg", "ag", "awk", "gawk",
           "nawk", "sed", "gsed", "strings", "xxd", "od", "hexdump", "bat", "jq", "diff", "comm", "cut", "sort",
           "uniq", "nl", "tac", "rev", "fold", "fmt", "column", "paste", "join", "pbpaste", "zcat", "gzcat", "bzcat",
           "xzcat", "zless", "iconv", "look"}


# Anything else

SEND_WORDS = {"send", "reply", "forward", "post", "publish", "tweet", "toot", "dm", "invite", "upload", "share",
              "deploy", "submit", "broadcast", "pay", "purchase", "buy", "transfer", "donate", "text"}
NAME_SEND_WORDS = SEND_WORDS | {"mail", "email", "sendmail", "sms", "imessage", "message", "messages"}
DELETE_WORDS = {"delete", "del", "remove", "rm", "trash", "purge", "erase", "wipe", "destroy", "drop", "unlink",
                "shred", "expunge"}


def _words(text: str) -> List[str]:
    spaced = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", text)
    return [word.lower() for word in re.split(r"[^A-Za-z0-9]+", spaced) if word]


def _unknown(command: Cmd) -> Verdict:
    """A program the guard has no rule for: its name and first words decide if it looks like a send or
    a delete; otherwise it runs in chat (and is blocked for workers and cron)."""
    stem = PurePosixPath(command.name).stem
    name_words = set(_words(stem))
    arg_words: List[str] = []
    for arg in command.positional()[:3]:
        arg_words.extend(_words(arg))
    arg_words.extend(word for arg in command.args if arg.startswith("--") for word in _words(arg.split("=")[0]))
    sends_by_name = name_words & NAME_SEND_WORDS or any(
        word.startswith(("mail", "email", "send", "sms", "imessage", "tweet", "upload")) for word in name_words)
    if sends_by_name or set(arg_words) & (SEND_WORDS - {"text"}):
        return _risky(command, "send", f"Run {stem} (it looks like it sends something)")
    if name_words & DELETE_WORDS or set(arg_words) & DELETE_WORDS:
        return _risky(command, "delete", f"Run {stem} (it looks like it deletes something)")
    return allow()


def same_command(first: str, second: str) -> bool:
    """True when two commands have the same words (spacing and quoting aside)."""
    try:
        return shlex.split(first) == shlex.split(second)
    except ValueError:
        return first.split() == second.split()
