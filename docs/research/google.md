# Gmail, Drive and Calendar

Checked 2026-09-27 against Hermes 0.21.0 and Google's docs. No OAuth flow was started and no token files were read. The typed tools went in on 2026-09-28, tested against stand-ins only: none of this has talked to Google yet.

## Pick

**Hermes's own `google-workspace` skill** (`~/.hermes/skills/productivity/google-workspace/`, v1.2.0), used with my own Google Cloud OAuth client.

- **Already installed.** It covers Gmail, Calendar, Drive, Docs, Sheets and Contacts through `scripts/google_api.py`.
- **No extra binary.** It uses the `gws` CLI if that's installed and falls back to Python otherwise.
- **No `mcp_servers` entry.** Daisy calls it through its own typed tools (below).
- **Scopes** (`setup.py:47-55`):
  - Gmail: `gmail.readonly`, `gmail.send`, `gmail.modify`
  - Calendar, Drive
  - Contacts: `contacts.readonly`
  - Sheets, Docs
  - The skill's SKILL.md mentions `--services` to narrow these, but the installed `setup.py` has no such flag, so the consent screen always asks for all of them.
- **Token:** plaintext JSON at `~/.hermes/google_token.json`, not in the Keychain. It must never end up in the repo.

**"Check my email" without a tab:** `gmail_search` with no query runs `google_api.py gmail search "is:unread in:inbox newer_than:2d" --max 15` and returns id, sender, subject, date and a snippet. Only `gmail_read` fetches a full message, when I ask for it.

**Email-only fallback, no Cloud project:** the `himalaya` skill over IMAP with a Gmail app password, stored in the Keychain via `auth.cmd`. Needs 2-Step Verification.

## Setup

About 10 minutes, once. I do this myself; Daisy never runs the sign-in.

1. Create a project at console.cloud.google.com (any name, like "Daisy").
2. APIs & Services → Library: enable the **Gmail**, **Google Calendar**, **Google Drive**, **Google Docs**, **Google Sheets** and **People** APIs.
3. OAuth consent screen (now called Google Auth Platform): user type **External**, app name "Daisy", my Gmail as the support and developer contact. Under Audience → Test users, add my Gmail address.
4. Audience → **Publish app**, so the status says **In production**. Skip verification.
   - Why: while the app is in Testing, refresh tokens for these scopes expire after 7 days ([Google](https://developers.google.com/identity/protocols/oauth2)), and Daisy would lose Google every week. That published apps avoid this is widely reported, not stated by Google.
   - Personal use under 100 users is exempt from verification ([Google](https://support.google.com/cloud/answer/13464323)). Sign-in will say "Google hasn't verified this app": click Advanced, then continue to Daisy.
5. Clients → Create client → type **Desktop app**. Download the JSON (`client_secret_….json`).
6. In Terminal, with Hermes's own Python (the one Daisy's tools run with):

   ```sh
   PY=~/.hermes/hermes-agent/venv/bin/python
   GSETUP=~/.hermes/skills/productivity/google-workspace/scripts/setup.py
   $PY $GSETUP --client-secret ~/Downloads/client_secret_XXXX.json
   $PY $GSETUP --auth-url
   ```

   Open the URL it prints, pick my account and allow everything. The browser then fails to load `http://localhost:1/...`; that's expected. Copy the whole address from the address bar and paste it in quotes:

   ```sh
   $PY $GSETUP --auth-code "http://localhost:1/?state=...&code=...&scope=..."
   $PY $GSETUP --check
   ```

   `--check` should print `AUTHENTICATED`. Then delete the downloaded `client_secret_….json`; setup.py keeps its own copy.

Notes:

- The token stays in `~/.hermes/google_token.json` and the client secret in `~/.hermes/google_client_secret.json`. Neither goes in the repo, a chat or a script. Daisy's code never opens them; the skill's own scripts do the signing in.
- There's no `--services` step: this `setup.py` doesn't have the flag (the skill's docs are ahead of its code), so `--auth-url` asks for every scope above, Contacts included. Unticking one on the consent screen is fine; the tools that need it will say to sign in again.
- The Google client libraries are already in Hermes's venv at the versions `setup.py` pins, so `--check` won't install anything. If they ever go missing: `$PY $GSETUP --install-deps`.
- If Daisy says the sign-in expired, run `--auth-url`, `--auth-code` and `--check` again. If that happens every week, the app is still in Testing (step 4).
- To undo it all: `$PY $GSETUP --revoke`, then delete the Cloud project.

## How Daisy uses it

Typed tools in `hermes/daisy/tools/google.py`, hidden until the skill is installed. Reads run; everything else stops at a card first.

| Tool | Risk | What it does |
| --- | --- | --- |
| `gmail_search` | read | Sender, subject, date and snippet; unread inbox from the last 2 days by default, 15 at most |
| `gmail_read` | read | One email's text, 8,000 characters unless asked for more |
| `gmail_send` | send | New email: to, Cc, Bcc, subject, body, attachments (about 18 MB) |
| `gmail_reply` | send | Reply in the thread, after checking the sender and subject against the original |
| `gmail_modify` | write | Archive, back to the inbox, read/unread, star, labels |
| `gmail_delete` | delete | Move to the Gmail trash |
| `calendar_list` | read | Events, the next 7 days by default |
| `calendar_write` | write | Add an event (timed or all day), or change one |
| `calendar_delete` | delete | One occurrence, or the whole series if asked |
| `drive_search` | read | Names, types, ids and links, no contents |
| `drive_read` | read | A Doc's text, a Sheet's rows, Slides, plain text files, or a folder's listing |
| `drive_upload` | write | A local file, optionally into a folder |
| `drive_share` | share | A person, group, domain or anyone with the link; view, comment or edit |
| `drive_delete` | delete | Move to the Drive trash |
| `docs_write` | write | Add text to the end of a Doc |
| `sheets_write` | write | Overwrite a range or append rows |

- Everything runs through the skill with Hermes's own Python, as an argv list, never a shell. Values go in as `--flag=value` and positionals after `--`, so a subject or query starting with a dash can't turn into an option.
- `google_api.py` can't do Bcc, attachments, checked replies, labels on several emails at once, calendar updates or checked calendar deletes. For those Daisy runs a short bridge script that signs in with the skill's own `google_api.build_service`, so the token still never passes through Daisy's code. The request goes in on stdin, not argv.
- Cards list every recipient, Cc, Bcc and attachment before the message, and never cut anything short. Shares spell out who and what access ("anyone with the link", "can edit"). Deletes name the email, event or file.
- Whatever a card says about something that already exists (an email's sender and subject, an event's title and start, a file's name) is checked against Google right before acting. If it doesn't match, nothing happens and Daisy asks again.
- Attachments and uploads refuse anything in `~/.hermes`, `~/.ssh` and similar folders, and files that look like keys or sign-ins.
- Sign-in problems come back as a plain message pointing at Setup above, never a traceback.

## Other options

| Option | Why not first |
| --- | --- |
| Google's remote Workspace MCP servers | Developer Preview behind enrollment; unclear whether personal @gmail.com works; drafts only, no send |
| `taylorwilsdon/google_workspace_mcp` | Good community MCP (MIT); the backup if the skill falls short. Can run `--read-only` |
| Composio / Zapier / Pipedream | Easiest setup, but a third party holds my Gmail refresh token |
| Reading Gmail through the Chrome tab | Needs the tab open, only sees what's on the page, brittle |
| Mail.app via AppleScript | Only if Gmail is set up in Mail; slow |

## Guard

The shell route is covered too. `drive delete`, `drive share` (especially `--type anyone`), `drive upload`, `gmail modify`, `docs append` and `sheets update` / `sheets append` through `google_api.py` all stop at a card, and once the typed tools are loaded the guard refuses the shell route and points at the tool instead.

## Privacy

Whatever the tool returns goes to OpenAI through Hermes.

- Default to headers and snippets: about 15 messages over the last 48 hours.
- Bodies and Drive files only when asked, capped (8,000 characters by default, 30,000 at most).
- Treat mail, event and document text as untrusted: it can contain instructions meant for the agent. It comes back labelled as other people's writing, and reading it marks the turn, so a new recipient, link or memory write after it needs a card.

## Not tried yet

- The sign-in itself, and whether "In production" really keeps the token alive past 7 days.
- Real Google responses. The tools were tested against samples written from `google_api.py`'s output code, a stand-in skill run as a real process, and the installed skill's own argument parser.
- The bridge's Bcc, attachments, reply threading and calendar updates against the real Gmail and Calendar APIs.
