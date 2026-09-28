"""Stand-in for the google-workspace skill's scripts/google_api.py, for hermes/test_daisy_google.py.

No network and no token. Run as the CLI, it writes what it was given to $HERMES_HOME/fake-google/cli.json and
prints a canned answer. Imported by Daisy's bridge, build_service hands out a fake Gmail whose send writes the
raw email to $HERMES_HOME/fake-google/sent.eml. With $HERMES_HOME/fake-google/signed-out present, both act the
way the real skill does before sign-in."""

import base64
import json
import os
import sys
from pathlib import Path

OUT = Path(os.environ.get("HERMES_HOME", "")) / "fake-google"


def _signed_in():
    if (OUT / "signed-out").exists():
        print("Not authenticated. Run the setup script first:", file=sys.stderr)
        print("  python ~/.hermes/skills/productivity/google-workspace/scripts/setup.py", file=sys.stderr)
        sys.exit(1)


class _Request:
    def __init__(self, result):
        self.result = result

    def execute(self):
        return self.result


class _Gmail:
    def users(self):
        return self

    def messages(self):
        return self

    def send(self, userId, body, media_body=None):
        OUT.mkdir(parents=True, exist_ok=True)
        (OUT / "sent.eml").write_bytes(base64.urlsafe_b64decode(body["raw"]))
        return _Request({"id": "sent0001", "threadId": body.get("threadId", "thread0001")})


def build_service(api, version):
    _signed_in()
    if api != "gmail":
        raise RuntimeError("the stand-in only fakes Gmail")
    return _Gmail()


def main(argv):
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "cli.json").write_text(json.dumps({"argv": argv, "env": sorted(os.environ)}), encoding="utf-8")
    _signed_in()
    if argv[:2] == ["gmail", "search"]:
        print(json.dumps([{"id": "18c0ffee0001", "threadId": "18c0ffee0001", "from": "Dad <dad@example.com>",
                           "to": "josh@example.com", "subject": "From the stand-in",
                           "date": "Mon, 28 Sep 2026 08:12:00 -0400", "snippet": "Hi from the fake skill",
                           "labels": ["INBOX"]}], indent=2))
        return
    print(json.dumps({"status": "ok"}))


if __name__ == "__main__":
    main(sys.argv[1:])
