"""Daisy's scheduled jobs, kept in step with the templates in hermes/cron/*.md.

  cron_jobs.py add    --hermes H --home HERMES_HOME --templates DIR [--model M --provider P]
  cron_jobs.py remove --hermes H --home HERMES_HOME --templates DIR
  cron_jobs.py status --home HERMES_HOME --templates DIR

A template is the job's prompt with a short header:

    ---
    name: Daisy inbox triage
    schedule: 30 5 * * *
    reasoning: low
    script: daisy-repo-digest.py     (optional: runs first, from $HERMES_HOME/scripts)
    ---
    The prompt...

Jobs are found by name in $HERMES_HOME/cron/jobs.json (read only here; every change goes through
`hermes cron create/edit/remove`, so Hermes's own checks run). `add` creates what's missing, puts the
prompt and the model pin back when they drift from the repo, and leaves the schedule alone once a job
exists, since that's mine to change (`hermes cron edit <id> --schedule ...`). Output stays local:
$HERMES_HOME/cron/output/<job id>/<time>.md, which Daisy's JOBS tab reads.
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

FIELDS = ("name", "schedule", "reasoning", "script")


def read_template(path):
    """(header fields, prompt) from one template file."""
    text = Path(path).read_text(encoding="utf-8").replace("\r\n", "\n")
    fields = {}
    lines = text.split("\n")
    if lines and lines[0].strip() == "---":
        for index in range(1, len(lines)):
            line = lines[index]
            if line.strip() == "---":
                text = "\n".join(lines[index + 1:])
                break
            key, _, value = line.partition(":")
            if key.strip() in FIELDS and value.strip():
                fields[key.strip()] = value.strip()
        else:
            raise ValueError(f"{Path(path).name}: the header never ends (no closing ---)")
    prompt = text.strip()
    for key in ("name", "schedule"):
        if not fields.get(key):
            raise ValueError(f"{Path(path).name}: no {key} in the header")
    if not prompt:
        raise ValueError(f"{Path(path).name}: no prompt")
    return fields, prompt


def templates(folder):
    return [(path, *read_template(path)) for path in sorted(Path(folder).glob("*.md"))]


def jobs(home):
    """Hermes's job records, or [] when there are none yet. Never written here."""
    path = Path(home) / "cron" / "jobs.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    found = data.get("jobs", []) if isinstance(data, dict) else data
    if isinstance(found, dict):
        found = [dict(job, id=job.get("id", key)) for key, job in found.items() if isinstance(job, dict)]
    return [job for job in found if isinstance(job, dict)] if isinstance(found, list) else []


def named(home, name):
    return [job for job in jobs(home) if str(job.get("name") or "").strip() == name]


def run(hermes, *args):
    done = subprocess.run([hermes, *args], stdin=subprocess.DEVNULL, capture_output=True, text=True,
                          encoding="utf-8", errors="replace", check=False)
    output = "\n".join(part.strip() for part in (done.stdout, done.stderr) if part and part.strip())
    return done.returncode == 0, output


def last_line(text):
    lines = [line.strip() for line in (text or "").splitlines() if line.strip()]
    return lines[-1] if lines else "no output"


def add(args):
    failed = False
    for path, fields, prompt in templates(args.templates):
        name = fields["name"]
        existing = named(args.home, name)
        if len(existing) > 1:
            print(f"  cron: {len(existing)} jobs are called '{name}'; leaving them alone "
                  f"(hermes cron list, then hermes cron remove <id> for the extra ones)")
            continue
        if not existing:
            command = ["cron", "create", "--name", name, "--deliver", "local"]
            if fields.get("script"):
                command += ["--script", fields["script"]]
            if fields.get("reasoning"):
                command += ["--reasoning-effort", fields["reasoning"]]
            if args.model:
                command += ["--model", args.model] + (["--provider", args.provider] if args.provider else [])
            ok, output = run(args.hermes, *command, fields["schedule"], prompt)
            if ok:
                print(f"  added cron job '{name}' ({fields['schedule']})")
            else:
                failed = True
                print(f"  cron: couldn't add '{name}': {last_line(output)}")
            continue
        job = existing[0]
        changes = []
        if str(job.get("prompt") or "").strip() != prompt:
            changes += ["--prompt", prompt]
        if args.model and (job.get("model") or "") != args.model:
            changes += ["--model", args.model] + (["--provider", args.provider] if args.provider else [])
        if not changes:
            continue
        ok, output = run(args.hermes, "cron", "edit", str(job.get("id")), *changes)
        if ok:
            print(f"  updated cron job '{name}'")
        else:
            failed = True
            print(f"  cron: couldn't update '{name}': {last_line(output)}")
    return 1 if failed else 0


def remove(args):
    failed = False
    for path, fields, prompt in templates(args.templates):
        for job in named(args.home, fields["name"]):
            ok, output = run(args.hermes, "cron", "remove", str(job.get("id")))
            if ok:
                print(f"  removed cron job '{fields['name']}'")
            else:
                failed = True
                print(f"  cron: couldn't remove '{fields['name']}': {last_line(output)}")
    return 1 if failed else 0


def status(args):
    names = [fields["name"] for path, fields, prompt in templates(args.templates)]
    there = [name for name in names if named(args.home, name)]
    if there:
        print(f"  cron: {', '.join(there)} scheduled (DAISY_CRON=0 takes them out)")
    else:
        print("  cron: Daisy's jobs aren't scheduled; DAISY_CRON=1 adds " + " and ".join(names))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="Daisy's scheduled jobs")
    parser.add_argument("command", choices=("add", "remove", "status"))
    parser.add_argument("--hermes", default="hermes")
    parser.add_argument("--home", required=True)
    parser.add_argument("--templates", required=True)
    parser.add_argument("--model", default="")
    parser.add_argument("--provider", default="")
    args = parser.parse_args(argv)
    try:
        return {"add": add, "remove": remove, "status": status}[args.command](args)
    except ValueError as problem:
        print(f"  cron: {problem}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
