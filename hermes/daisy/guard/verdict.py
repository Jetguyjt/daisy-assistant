"""What the guard decided about one tool call, and the facts later steps need (taint, roles)."""

from __future__ import annotations

from dataclasses import dataclass, replace
from typing import Tuple


@dataclass(frozen=True)
class Verdict:
    decision: str = "allow"       # "allow", "card" (stop for a yes) or "block"
    rule: str = ""                # short name used in the rule key: "send-email", "delete", a typed tool's name
    title: str = ""               # first line of the card, or what was blocked
    detail: str = ""              # the exact content, never shortened
    message: str = ""             # for blocks: what the model is told
    read_only: bool = False       # only looks at things; fine for workers and cron
    network: bool = False         # talks to the network, so it can't hide inside a chain of reads
    reads: str = ""               # untrusted content this call brings in ("the web", "email"), for taint
    urls: Tuple[str, ...] = ()    # links it opens or fetches
    navigates: bool = False       # opens a page; a site the turn hasn't touched needs a card after taint
    persists: bool = False        # memory, skills, scheduled jobs: instructions that outlive the turn
    hard: bool = False            # never overridden, not even by a cron pre-approval

    @property
    def stops(self) -> bool:
        return self.decision != "allow"

    @property
    def severity(self) -> int:
        return {"block": 3, "card": 2}.get(self.decision, 0 if self.read_only else 1)

    def but(self, **changes) -> "Verdict":
        return replace(self, **changes)


def read(reads: str = "", **fields) -> Verdict:
    return Verdict(decision="allow", read_only=True, reads=reads, **fields)


def allow(**fields) -> Verdict:
    return Verdict(decision="allow", **fields)


def card(rule: str, title: str, detail: str = "", **fields) -> Verdict:
    fields.pop("read_only", None)
    return Verdict(decision="card", rule=rule, title=title, detail=detail, **fields)


def block(message: str, title: str = "", hard: bool = False, **fields) -> Verdict:
    fields.pop("read_only", None)
    return Verdict(decision="block", message=message, title=title, hard=hard, **fields)


def worst(*verdicts: Verdict) -> Verdict:
    """The most restrictive of several verdicts (the first one wins a tie)."""
    chosen = verdicts[0]
    for verdict in verdicts[1:]:
        if verdict.severity > chosen.severity:
            chosen = verdict
    return chosen
