"""Splits a shell command the way bash will: quotes, escapes, $'...', variables, $(...) and backticks,
pipes and chains, redirections and heredocs. What each piece does is decided in commands.py.

This is a reader for the guard, not a shell. When it can't follow something it says so (error), and
the guard blocks rather than guess."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
ASSIGNMENT = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)(\+?)=")
SPECIAL = set("@*#?$!-0123456789")
OPERATORS = ("&&", "||", ";;&", ";;", ";&", "|&", "&>>", "&>", ">>", ">|", ">&", "<&", "<>", "<<<", "<<-", "<<",
             ";", "&", "|", "(", ")", "<", ">")
REDIRECTS = {"&>>", "&>", ">>", ">|", ">&", "<&", "<>", "<<<", "<<-", "<<", "<", ">"}
# Environment variables a value can come from without the card hiding anything the user can't picture.
KNOWN = ("HOME", "USER", "LOGNAME", "TMPDIR", "HERMES_HOME")


@dataclass
class Word:
    """One shell word as a list of parts: ("lit", text, quoted), ("var", name, inner, quoted),
    ("sub", command) or ("arith", expression)."""
    parts: List[tuple] = field(default_factory=list)
    raw: str = ""

    def lit(self, text: str, quoted: bool) -> None:
        if self.parts and self.parts[-1][0] == "lit" and self.parts[-1][2] == quoted:
            self.parts[-1] = ("lit", self.parts[-1][1] + text, quoted)
        else:
            self.parts.append(("lit", text, quoted))

    @property
    def has_sub(self) -> bool:
        return any(part[0] in ("sub", "arith") for part in self.parts)

    @property
    def unquoted_var(self) -> bool:
        return any(part[0] == "var" and not part[3] for part in self.parts)

    def text(self, env: Dict[str, Optional[str]]) -> Tuple[str, bool]:
        """(text, exact): exact is False when part of it is only known at run time."""
        out, exact = [], True
        for part in self.parts:
            if part[0] == "lit":
                out.append(part[1])
            elif part[0] == "var":
                value = resolve(part[1], part[2], env)
                if value is None:
                    exact = False
                    out.append("$" + part[1])
                else:
                    out.append(value)
            else:
                exact = False
                out.append("$(" + part[1] + ")")
        return "".join(out), exact

    def unquoted(self, characters: str) -> bool:
        return any(part[0] == "lit" and not part[2] and any(c in part[1] for c in characters) for part in self.parts)

    def assignment(self) -> Optional[Tuple[str, "Word"]]:
        """NAME=value as (name, value word), when this word is an assignment."""
        if not self.parts or self.parts[0][0] != "lit" or self.parts[0][2]:
            return None
        match = ASSIGNMENT.match(self.parts[0][1])
        if not match:
            return None
        value = Word(raw=self.raw[match.end():])
        rest = self.parts[0][1][match.end():]
        if rest:
            value.parts.append(("lit", rest, False))
        value.parts.extend(self.parts[1:])
        return (match.group(1) + ("+" if match.group(2) else ""), value)


@dataclass
class Segment:
    """One simple command: its words, redirections and heredoc bodies."""
    words: List[Word] = field(default_factory=list)
    redirects: List[Tuple[str, Optional[Word]]] = field(default_factory=list)
    heredocs: List[Tuple[str, bool]] = field(default_factory=list)
    before: str = ""
    after: str = ""


@dataclass
class Parsed:
    segments: List[Segment]
    substitutions: List[str]
    operators: List[str]
    error: str = ""


def resolve(name: str, inner: str, env: Dict[str, Optional[str]]) -> Optional[str]:
    """A variable's value when it's known before the command runs, else None. Only $NAME, ${NAME} and
    ${NAME:-default} are followed; any other ${...} form changes the value and counts as unknown."""
    def known(key: str) -> Optional[str]:
        if key in env:
            return env[key]
        if key in KNOWN and key in _environ():
            return _environ()[key]
        return None

    if not inner or inner == name:
        return known(name)
    match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*):?-(.*)", inner, re.S)
    if not match or match.group(1) != name:
        return None
    value = known(name)
    if value:
        return value
    default = match.group(2)
    if "`" in default or "$(" in default:
        return None

    def swap(found):
        key = found.group(1) or found.group(2)
        found_value = known(key)
        return found_value if found_value is not None else found.group(0)

    default = re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)", swap, default)
    if "$" in default:
        return None
    if default.startswith("~"):
        default = _environ().get("HOME", "~") + default[1:]
    return default


def _environ():
    import os
    return os.environ


def parse(text: str) -> Parsed:
    return _Parser(text).run()


def substitutions_in(text: str) -> List[str]:
    """Commands run by $(...) and backticks inside text that the shell expands (a heredoc body)."""
    parser = _Parser(text)
    found: List[str] = []
    while parser.i < parser.n:
        c = parser.s[parser.i]
        if c == "\\":
            parser.i += 2
        elif c == "`":
            parser.backtick()
        elif c == "$":
            parser.dollar(quoted=True)
        else:
            parser.i += 1
    found.extend(parser.subs)
    if parser.error:
        found.append(text)
    return found


class _Parser:
    def __init__(self, text: str):
        self.s = text or ""
        self.i = 0
        self.n = len(self.s)
        self.segments: List[Segment] = []
        self.subs: List[str] = []
        self.ops: List[str] = []
        self.error = ""
        self.segment = Segment()
        self.word: Optional[Word] = None
        self.word_start = 0
        self.redirect: Optional[str] = None
        self.heredoc_op: Optional[str] = None
        self.pending: List[Tuple[Segment, str, bool, bool]] = []

    def fail(self, why: str) -> None:
        if not self.error:
            self.error = why

    # Words

    def start(self) -> Word:
        if self.word is None:
            self.word = Word()
            self.word_start = self.i
        return self.word

    def lit(self, text: str, quoted: bool) -> None:
        self.start().lit(text, quoted)

    def part(self, part: tuple) -> None:
        self.start().parts.append(part)

    def end_word(self) -> None:
        word = self.word
        if word is None:
            return
        word.raw = self.s[self.word_start:self.i]
        self.word = None
        if self.redirect is not None:
            self.segment.redirects.append((self.redirect, word))
            self.redirect = None
        elif self.heredoc_op is not None:
            delimiter = "".join(part[1] for part in word.parts if part[0] == "lit")
            expands = not any(part[0] == "lit" and part[2] for part in word.parts)
            self.pending.append((self.segment, delimiter, self.heredoc_op == "<<-", expands))
            self.heredoc_op = None
        else:
            self.segment.words.append(word)

    def end_segment(self, op: str) -> None:
        if self.redirect is not None or self.heredoc_op is not None:
            self.fail("a redirection with nothing after it")
            self.redirect = self.heredoc_op = None
        segment = self.segment
        if segment.words or segment.redirects or segment.heredocs:
            segment.after = op
            self.segments.append(segment)
        if op:
            self.ops.append(op)
        self.segment = Segment(before=op)

    # The main loop

    def run(self) -> Parsed:
        while self.i < self.n:
            c = self.s[self.i]
            if c in " \t":
                self.end_word()
                self.i += 1
            elif c == "\n":
                self.end_word()
                self.end_segment("\n")
                self.i += 1
                self.read_heredocs()
            elif c == "#" and self.word is None:
                end = self.s.find("\n", self.i)
                self.i = self.n if end < 0 else end
            elif c == "\\":
                if self.s.startswith("\\\n", self.i):
                    self.i += 2
                elif self.i + 1 < self.n:
                    self.lit(self.s[self.i + 1], True)
                    self.i += 2
                else:
                    self.lit("\\", True)
                    self.i += 1
            elif c == "'":
                end = self.s.find("'", self.i + 1)
                if end < 0:
                    self.fail("an unclosed quote")
                    end = self.n
                self.lit(self.s[self.i + 1:end], True)
                self.i = end + 1
            elif c == '"':
                self.double_quoted()
            elif c == "`":
                self.backtick()
            elif c == "$":
                self.dollar(quoted=False)
            elif c in "<>" and self.s.startswith("(", self.i + 1):
                inner, end = self.balanced(self.i + 1, "(", ")")
                self.subs.append(inner)
                self.part(("sub", inner))
                self.i = end
            elif c in ";&|()<>":
                self.operator()
            else:
                self.lit(c, False)
                self.i += 1
        self.end_word()
        self.end_segment("")
        if self.pending:
            for segment, _, _, _ in self.pending:
                segment.heredocs.append(("", False))
            self.pending = []
        return Parsed(self.segments, self.subs, [op for op in self.ops if op], self.error)

    def operator(self) -> None:
        op = next(candidate for candidate in OPERATORS if self.s.startswith(candidate, self.i))
        if op in REDIRECTS:
            word = self.word
            if (word is not None and len(word.parts) == 1 and word.parts[0][0] == "lit" and not word.parts[0][2]
                    and word.parts[0][1].isdigit()):
                self.word = None
            else:
                self.end_word()
            self.i += len(op)
            if op in ("<<", "<<-"):
                self.heredoc_op = op
            else:
                self.redirect = op
            return
        self.end_word()
        self.i += len(op)
        self.end_segment(op)

    def read_heredocs(self) -> None:
        for segment, delimiter, strip, expands in self.pending:
            lines = []
            closed = False
            while self.i < self.n:
                end = self.s.find("\n", self.i)
                line = self.s[self.i:end if end >= 0 else self.n]
                self.i = end + 1 if end >= 0 else self.n
                if (line.lstrip("\t") if strip else line) == delimiter:
                    closed = True
                    break
                lines.append(line)
            if not closed:
                self.fail("a heredoc without its end marker")
            body = "\n".join(lines)
            segment.heredocs.append((body, expands))
            if expands:
                self.subs.extend(substitutions_in(body))
        self.pending = []

    # Quotes and expansions

    def double_quoted(self) -> None:
        self.start()
        self.i += 1
        while self.i < self.n:
            c = self.s[self.i]
            if c == '"':
                self.i += 1
                return
            if c == "\\" and self.i + 1 < self.n and self.s[self.i + 1] in '$`"\\\n':
                if self.s[self.i + 1] != "\n":
                    self.lit(self.s[self.i + 1], True)
                self.i += 2
            elif c == "$":
                self.dollar(quoted=True)
            elif c == "`":
                self.backtick()
            else:
                self.lit(c, True)
                self.i += 1
        self.fail("an unclosed quote")

    def backtick(self) -> None:
        self.start()
        j = self.i + 1
        inner = []
        while j < self.n and self.s[j] != "`":
            if self.s[j] == "\\" and j + 1 < self.n and self.s[j + 1] in "$`\\":
                inner.append(self.s[j + 1])
                j += 2
            else:
                inner.append(self.s[j])
                j += 1
        if j >= self.n:
            self.fail("an unclosed backtick")
        command = "".join(inner)
        self.subs.append(command)
        self.part(("sub", command))
        self.i = j + 1

    def dollar(self, quoted: bool) -> None:
        s, i = self.s, self.i
        after = s[i + 1] if i + 1 < self.n else ""
        if after == "'" and not quoted:
            text, end = ansi_c(s, i + 2)
            if end > self.n:
                self.fail("an unclosed quote")
            self.lit(text, True)
            self.i = end
        elif after == '"' and not quoted:
            self.i += 1
            self.double_quoted()
        elif s.startswith("((", i + 1):
            inner, end = self.balanced(i + 1, "(", ")")
            expression = inner[1:-1] if inner.startswith("(") and inner.endswith(")") else inner
            self.subs.extend(substitutions_in(expression))
            self.part(("arith", expression))
            self.i = end
        elif after == "(":
            inner, end = self.balanced(i + 1, "(", ")")
            self.subs.append(inner)
            self.part(("sub", inner))
            self.i = end
        elif after == "{":
            inner, end = self.balanced(i + 1, "{", "}")
            match = re.match(r"[#!]?([A-Za-z_][A-Za-z0-9_]*|[@*#?$!0-9-])", inner)
            name = match.group(1) if match else inner
            if len(inner) > 1 and inner[0] in "#!":
                name = inner[0] + name
            self.subs.extend(substitutions_in(inner))
            self.part(("var", name, inner, quoted))
            self.i = end
        elif after and (after.isalpha() or after == "_"):
            match = NAME.match(s, i + 1)
            self.part(("var", match.group(0), match.group(0), quoted))
            self.i = match.end()
        elif after and after in SPECIAL:
            self.part(("var", after, after, quoted))
            self.i = i + 2
        else:
            self.lit("$", quoted)
            self.i = i + 1

    def balanced(self, start: int, opening: str, closing: str) -> Tuple[str, int]:
        """Text between s[start] (the opening bracket) and its match, and the index after the match."""
        depth = 0
        j = start
        quote = ""
        while j < self.n:
            c = self.s[j]
            if quote:
                if c == "\\" and quote == '"':
                    j += 2
                    continue
                if c == quote:
                    quote = ""
            elif c == "\\":
                j += 2
                continue
            elif c in "'\"`":
                quote = c
            elif c == opening:
                depth += 1
            elif c == closing:
                depth -= 1
                if depth == 0:
                    return self.s[start + 1:j], j + 1
            j += 1
        self.fail(f"an unclosed {opening}")
        return self.s[start + 1:], self.n


_ESCAPES = {"a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f", "n": "\n", "r": "\r", "t": "\t", "v": "\v",
            "\\": "\\", "'": "'", '"': '"', "?": "?"}


def ansi_c(s: str, j: int) -> Tuple[str, int]:
    """Decodes $'...' from index j (just past the opening quote); returns (text, index after the quote)."""
    out = []
    n = len(s)
    while j < n:
        c = s[j]
        if c == "'":
            return "".join(out), j + 1
        if c != "\\" or j + 1 >= n:
            out.append(c)
            j += 1
            continue
        e = s[j + 1]
        if e in _ESCAPES:
            out.append(_ESCAPES[e])
            j += 2
        elif e in "01234567":
            digits = re.match(r"[0-7]{1,3}", s[j + 1:]).group(0)
            out.append(chr(int(digits, 8)))
            j += 1 + len(digits)
        elif e in "xuU":
            limit = {"x": 2, "u": 4, "U": 8}[e]
            digits = re.match(r"[0-9a-fA-F]{0,%d}" % limit, s[j + 2:]).group(0)
            if digits:
                try:
                    out.append(chr(int(digits, 16)))
                except (ValueError, OverflowError):
                    out.append("?")
            else:
                out.append("\\" + e)
            j += 2 + len(digits)
        elif e == "c" and j + 2 < n:
            out.append(chr(ord(s[j + 2]) & 0x1F))
            j += 3
        else:
            out.append("\\" + e)
            j += 2
    return "".join(out), n + 1
