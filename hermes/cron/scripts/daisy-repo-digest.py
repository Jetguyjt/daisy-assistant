"""Runs before the repo digest job (Hermes cron's --script). It lists the folders I picked in
$HERMES_HOME/daisy/repo-digest.txt and prints one read-only terminal command that covers all of them,
so the job's agent makes one tool call instead of one per repo. Hermes puts this output above the
job's prompt.

With no folders picked it prints {"wakeAgent": false}, and Hermes skips the model entirely, so an
empty list costs nothing. It never writes anything.

repo-digest.txt: one folder per line, ~ allowed, # starts a comment.
"""

import json
import os
import shlex
import subprocess
import sys
from pathlib import Path

LIMIT = 12


def hermes_home():
    return Path(os.environ.get("HERMES_HOME", "").strip() or Path.home() / ".hermes").expanduser()


def list_file():
    return hermes_home() / "daisy" / "repo-digest.txt"


def folders(path):
    """The picked folders, in order, without repeats, at most LIMIT."""
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    seen, found = set(), []
    for line in lines:
        text = line.split("#", 1)[0].strip()
        if not text:
            continue
        folder = Path(os.path.expanduser(text))
        if not folder.is_absolute():
            folder = Path.home() / folder
        key = os.path.normpath(str(folder))
        if key not in seen:
            seen.add(key)
            found.append(Path(key))
    return found[:LIMIT]


def shown(folder):
    """~/projects/x rather than the full home path."""
    home = str(Path.home())
    text = str(folder)
    return "~" + text[len(home):] if text == home or text.startswith(home + os.sep) else text


def is_repo(folder):
    try:
        done = subprocess.run(["git", "-C", str(folder), "rev-parse", "--is-inside-work-tree"],
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10, check=False)
    except (OSError, subprocess.SubprocessError):
        return False
    return done.returncode == 0 and done.stdout.strip() == "true"


def command(repos):
    """One terminal command, reads only: a header per repo, its status and its last commits."""
    parts = []
    for folder in repos:
        where = shlex.quote(str(folder))
        parts += [f"echo {shlex.quote('== ' + folder.name)}",
                  f"git -C {where} status --short --branch | head -n 40",
                  f"git -C {where} log -5 --format='%h %cr %s'"]
    return "; ".join(parts)


def report(picked):
    if not picked:
        return json.dumps({"wakeAgent": False})
    lines = [f"Folders for the repo digest (from {shown(list_file())}):"]
    repos = []
    for folder in picked:
        if not folder.is_dir():
            lines.append(f"- {folder.name}: {shown(folder)} (missing)")
        elif not is_repo(folder):
            lines.append(f"- {folder.name}: {shown(folder)} (not a git repo)")
        else:
            lines.append(f"- {folder.name}: {shown(folder)}")
            repos.append(folder)
    lines.append("")
    if repos:
        lines += ["Terminal command (reads only; run it once, exactly as written):", command(repos)]
    else:
        lines.append("No command to run: none of these folders is a git repo.")
    return "\n".join(lines)


if __name__ == "__main__":
    print(report(folders(list_file())))
    sys.exit(0)
