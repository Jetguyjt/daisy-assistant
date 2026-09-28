# Gmail, Drive and Calendar

Checked 2026-09-27 against Hermes 0.21.0 and Google's docs. No OAuth flow was started and no token files were read.

## Pick

**Hermes's own `google-workspace` skill** (`~/.hermes/skills/productivity/google-workspace/`, v1.2.0), used with my own Google Cloud OAuth client.

- **Already installed.** It covers Gmail, Calendar, Drive, Docs, Sheets and Contacts through `scripts/google_api.py`.
- **No extra binary.** It uses the `gws` CLI if that's installed and falls back to Python otherwise.
- **No `mcp_servers` entry.** Hermes runs it through the terminal tool.
- **Scopes** (`setup.py:47-55`):
  - Gmail: `gmail.readonly`, `gmail.send`, `gmail.modify`
  - Calendar, Drive
  - Contacts: `contacts.readonly`
  - Sheets, Docs
  - `--services` narrows what the consent screen asks for.
- **Token:** plaintext JSON at `~/.hermes/google_token.json`, not in the Keychain. It must never end up in the repo.

**"Check my email" without a tab:** `google_api.py gmail search "is:unread in:inbox newer_than:2d" --max 15` returns id, sender, subject, date and a snippet. Only fetch a full message when I ask for it.

**Email-only fallback, no Cloud project:** the `himalaya` skill over IMAP with a Gmail app password, stored in the Keychain via `auth.cmd`. Needs 2-Step Verification.

## Setup I have to do (about 10 min)

1. Create a project at console.cloud.google.com.
2. Enable the Gmail, Calendar, Drive, Docs, Sheets and People APIs.
3. OAuth consent screen: External. Add myself as a test user.
4. **Publish the app to "In production"** and skip verification.
   - Personal use under 100 users is exempt ([Google](https://support.google.com/cloud/answer/13464323)). Sign-in shows "Google hasn't verified this app": click Advanced, then continue.
   - Why: in Testing mode, refresh tokens expire after 7 days for these scopes ([Google](https://developers.google.com/identity/protocols/oauth2)). That published apps avoid this is widely reported, not stated by Google.
5. Create an OAuth client, type Desktop app, and download the JSON.
6. In Hermes, run `setup.py` with `--client-secret <file>`, then `--auth-url --services email,calendar,drive,docs,sheets`, then `--auth-code "<redirected url>"`, then `--check`.

## Other options

| Option | Why not first |
| --- | --- |
| Google's remote Workspace MCP servers | Developer Preview behind enrollment; unclear whether personal @gmail.com works; drafts only, no send |
| `taylorwilsdon/google_workspace_mcp` | Good community MCP (MIT); the backup if the skill falls short. Can run `--read-only` |
| Composio / Zapier / Pipedream | Easiest setup, but a third party holds my Gmail refresh token |
| Reading Gmail through the Chrome tab | Needs the tab open, only sees what's on the page, brittle |
| Mail.app via AppleScript | Only if Gmail is set up in Mail; slow |

## Guard gaps before connecting

The guard already catches `gmail send/reply/forward` and calendar create/update/delete. It misses these `google_api.py` commands:

- `drive delete`
- `drive share`, especially `--type anyone`
- `drive upload`
- `gmail modify` (archive, trash, relabel)
- `docs append`
- `sheets update` / `sheets append`

Add rules and test lines first.

## Privacy

Whatever the tool returns goes to OpenAI through Hermes.

- Default to headers and snippets: about 15 messages over the last 48 hours.
- Fetch bodies and Drive files only when asked.
- Treat mail and document text as untrusted: it can contain instructions meant for the agent.
