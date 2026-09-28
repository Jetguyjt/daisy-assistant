# Integration investigation

## With Hermes (0.4)

Integrations now belong to Hermes, not Daisy code: skills for procedures, MCP servers or Hermes plugins for code and credentials. Checked against the installed Hermes 0.21.0 on 2026-09-25:

| Need | Hermes route | State on this Mac |
| --- | --- | --- |
| Find files | built-in `search_files` and terminal tools | Works. A live check found a resume by name in about 30 s |
| Memory | built-in `memory` tool, `USER.md` / `MEMORY.md` | Works. Saved a preference in one session and recalled it in a new one |
| Text someone | `imsg_send` typed tool on the `imsg` CLI ([Messages](#messages)) | Built, tests only. `imsg` 0.15.9 is installed; "Dad" resolves through saved nicknames, then Contacts |
| Calendar | `google-workspace` skill (`gws` or its bundled Python, Google OAuth token) | No Google token yet; no Apple Calendar skill exists |
| Reminders | `reminders_list` / `reminders_add` / `reminders_complete` on `remindctl` ([Reminders](#reminders)) | Built, tests only. `remindctl` isn't installed yet, so the tools stay hidden |
| Notes | `notes_search` / `notes_read` / `notes_create` / `notes_append` through `osascript` ([Notes](#notes)) | Built, tests only. Nothing to install |

Hermes only asks before dangerous commands and file edits; skills send with no prompt. In Daisy sessions the `hermes/daisy` plugin stops sends, email, calendar writes, posts and deletes at an approval card first ([architecture](ARCHITECTURE.md#approvals)). Messages, Reminders and Notes are typed tools now (below), and [Permissions](#permissions) lists what macOS will ask for. The rest of this document is the original investigation for the on-device engine, kept for the Contacts, EventKit and Messages details that still apply.

These are adapter examples, not a fixed feature roadmap. New services plug into the common [capability system](CAPABILITIES.md).

Status as of the verified macOS 26.5.1 development environment. The following integrations are **not wired into the application**. No account credentials were accessed and no real messages or contacts were read during investigation.

## Google Calendar

Preferred direct route: Google's Calendar REST API, a Desktop OAuth client, system-browser consent and loopback redirect. Use `calendar.events.readonly` for events plus `calendar.calendarlist.readonly` when listing calendars; store refresh tokens in macOS Keychain. A local model sees only the event fields required for the answer. It never sees OAuth tokens. The app—not the model—makes the authenticated network call.

Requires a Google Cloud project with Calendar API enabled, Desktop OAuth client configuration, consent screen/test-user setup, and the user's account login. Credentials are **not needed for milestone one**. Development/testing-mode refresh-token lifetime and app verification requirements must be checked at implementation time.

“Tomorrow” must use the user's timezone and calendar timezone, including all-day events and DST boundaries. Fetch bounded intervals, follow pagination, expand recurring events, handle cancellations and denied/revoked scopes, and distinguish an empty calendar from a failed request.

Alternative: if Google is already synced in macOS Calendar, EventKit can read the local event store after permission. macOS full event access is a read/write permission even if this application only reads. It reflects the sync state, not necessarily live Google data. We have not inspected which personal accounts are configured. No Calendar permission was requested.

Sources: [Google Calendar scopes](https://developers.google.com/workspace/calendar/api/auth), [Desktop OAuth setup example](https://developers.google.com/workspace/calendar/api/quickstart/nodejs), [EventKit full event access](https://developer.apple.com/documentation/eventkit/ekeventstore/requestfullaccesstoevents(completion:)).

## Local file search

Implemented: native NSOpenPanel folder selection and saved bookmark, bounded filesystem metadata enumeration, case/diacritic-insensitive filename tokens, newest first. iCloud placeholders may expose metadata; content is not downloaded or read by search. A later explicit Open can cause the OS to hydrate a file.

Spotlight/NSMetadataQuery is a potential next step for faster broad searches. Its results depend on indexing, exclusions, and cloud state; all results must still be filtered against user-approved roots. A full-disk grant does not override every privacy boundary or make every app controllable.

## Contacts

Use `CNContactStore` with a Contacts purpose string and an explicit permission request. Retrieve only identifiers, names, and necessary phone/email fields. Handle partial/denied access and the permissions behavior of the deployed OS. A relationship such as “Dad” must come from an explicit user mapping or a verified, unambiguous contact relationship; never guess among similarly named contacts. Confirm the target phone/email and channel before first use.

The framework is present in the installed SDK; no contact access was requested. Google Contacts is a separate online integration and is not implied by macOS Contacts permission.

Source: [Apple Contacts access](https://developer.apple.com/documentation/contacts/accessing-the-contact-store).

## Messages

Built, tests only, never run against Messages: `imsg_send` in `hermes/daisy/tools/messages.py`, on `imsg` 0.15.9 (`brew install steipete/tap/imsg`). It's hidden until imsg is installed.

- **Who.** `to` is a nickname, a name, a phone number or an email address. Saved nicknames come first (`$HERMES_HOME/daisy/aliases.json`), then Contacts through `daisy-contacts`. It only resolves when there's exactly one answer: a saved nickname, or one contact whose whole name or contact-card nickname matches, with one number (or one mobile among several, or one email address). Anything else is refused before any card, with who it could be ("Two people match “Rob”: Robert Doe (mobile …); Robin Doe (home …)"), so Daisy asks instead of guessing. Numbers and addresses go as written. imsg only ever gets a number or an address, so it never runs its own name lookup.
- **The card.** "Send an iMessage to Dad", then the exact number or address, who that is and where it came from (saved nickname, Contacts, or as written), the service, any attachment's path and size, and the whole message with its line breaks. Nothing is shortened. A number with no country code says it's read as a US number (imsg's default).
- **The send.** `imsg send --to=… --text=… [--file=…] --service=… --json`, as an argv list. Every value goes in as `--flag=value`: imsg prints its help instead of sending if it sees a bare `--help` anywhere, and a message starting with a dash would otherwise be read as a flag. run() only sends what a card showed in the last five minutes, and refuses if the nickname, the contact or the file changed after the card.
- **Afterwards.** imsg's errors come back as plain sentences: Automation off, Messages not signed in or the number can't get iMessage/SMS, attachment problems. When imsg says the send may have happened (`may_have_completed`), or it times out, Daisy says to check Messages and never sends again on its own. "Sent" means Messages took it; nothing checks delivery.
- **No reading tool.** `imsg chats` and `history` read `~/Library/Messages/chat.db`, which needs Full Disk Access for Daisy. That grant would reach Hermes's shell too, and the guard treats `sqlite3` on chat.db as a read, so the agent could read every message without a card. "Who texted me?" isn't worth that.
- **Attachments** need Full Disk Access anyway: imsg copies the file into `~/Library/Messages/Attachments/imsg/` before sending it. Without it the send fails before anything goes out, and Daisy says why. Text on its own doesn't need it.

What follows is the first investigation, from before imsg; the draft-then-send part is what the card does now.

Verified the actual local `/System/Applications/Messages.app/Contents/Resources/Messages.sdef` by reading its public scripting definition. It exposes `send` for `text` or `file`, to a `participant` or `chat`; chats are described as SMS or iMessage. It also exposes file-transfer status. This proves a scripting interface is present, **not** that sending or delivery has been tested successfully.

Planned transport: narrowly scoped Apple Events/ScriptingBridge or safely parameterized AppleScript, using resolved participant/chat identities rather than interpolating model-generated scripts. Requires a signed app purpose string and macOS Automation permission to control Messages; the user must have Messages configured. SMS availability depends on their account/device configuration and cannot be inferred from the scripting dictionary.

Before any sending test, show an exact draft: recipient, address, channel, text, and attachment identity/path. An explicit Send button commits the approved action. Uncertain address, conflicting “Dad” mappings, or multiple resume versions require clarification. Do not treat a file's contents as authorization.

Use an action ledger with a unique operation ID and states such as draft, approved, submitting, submitted, failed, and outcome-unknown. Do not automatically retry after a timeout once the transport may have accepted the send. A successful `send` Apple Event is submission evidence; do not label it delivered without actual delivery evidence. File transfers and text messages have different evidence surfaces. A crash/restart after submission needs reconciliation or user review, not another send.

UI automation is a fallback when the structured interface proves insufficient, and requires Accessibility permission and tests on the actual UI. Window layouts, focus, app state, and OS changes can break it. Accessibility is not requested now. Do not read private Messages databases or request Full Disk Access just to simulate a delivery guarantee.

## Reminders

Built, tests only: `reminders_list`, `reminders_add` and `reminders_complete` in `hermes/daisy/tools/apple.py`, on `remindctl` 0.3.8 (`brew install steipete/tap/remindctl`), which uses EventKit. All three stay hidden until remindctl is installed; `scripts/hermes.d/60-apple-clis.sh` installs it when run with `DAISY_INSTALL_APPLE_CLIS=1`.

- `reminders_list` reads: open ones by default, or today (with anything overdue), tomorrow, week, overdue, upcoming, completed, all, one date, one list, or a search. It gives ids, titles, lists, due dates in words and notes, labelled as information rather than instructions, since a shared list can have items other people added.
- `reminders_add` is a card with the title, the list, the due date written out with its time zone ("Tuesday, September 29, 2026 at 8:00 AM EDT (UTC-04:00), tomorrow", or "all day"), whether it alerts, and the notes. The same moment goes to remindctl with its offset, so the card and the reminder can't disagree about the time. A list has to match one list by name, and the reminder goes to that list by id; otherwise it's refused with the list names.
- `reminders_complete` takes the id and title reminders_list showed, checks them with `remindctl complete --dry-run`, then completes that one id.
- No delete tool, on purpose: done covers most of it, and `remindctl delete` from the shell stops at a delete card.
- remindctl gets every value as `--flag=value` or after `--`, because it prints its help for a bare `--help` before `--`. Plain numbers aren't taken as ids: remindctl reads those as positions in a list.

## Notes

Built, tests only: `notes_search`, `notes_read`, `notes_create` and `notes_append` in `hermes/daisy/tools/apple.py`. They go straight to Notes' own scripting through `osascript -l JavaScript`: one fixed script, with every value passed as an argument after `--`, never pasted into the script. Nothing to install.

- Why not memo, the CLI Hermes's apple-notes skill uses: it builds its AppleScript by pasting the note's HTML and the folder name into the script (a Markdown link's quotes are enough to break it, and it's an injection path), it only adds or edits through an interactive `$EDITOR`, it searches through fzf, it edits by rewriting the whole note through Markdown, its move deletes the note and makes a new one, and it reports failures with exit code 0.
- `notes_search` matches titles (any case) and text, newest first, optionally in one folder; with no query it lists the most recently changed notes. Recently Deleted is skipped, and locked notes show up without their text. `notes_read` gives one note's text, 8,000 characters unless asked for more. Both label what they return as content that can include other people's writing, and the guard counts the turn as having read documents.
- `notes_create` is a card with the folder (or "your default Notes folder"), whether that folder is shared, the title and every line. The body is Notes' own HTML: a `<div>` per line, escaped.
- `notes_append` is a card with the note, its folder and id, whether it's shared, and every line being added. Before changing anything, the script checks the note's title, folder and sharing against what the card said, and refuses locked notes and notes with attachments: adding means setting the note's whole body to what was there plus the new lines, and setting a body drops images and attachments.
- Not checked yet: whether that rewrite keeps checklists and tables exactly as they were. Notes' scripting only offers the body as HTML.

## Permissions

What macOS will ask for, and what it will say. Daisy.app starts hermes-acp and the CLIs are hermes-acp's children, so the prompts should name Daisy, as they do for Contacts; run from Terminal, they name Terminal instead. None of this has been seen live yet.

| Permission | When it's asked | What the prompt says | Where to change it |
| --- | --- | --- | --- |
| Automation: Messages | the first text | “Daisy” wants access to control “Messages”. | Privacy & Security → Automation → Daisy → Messages |
| Automation: Notes | the first Notes call | “Daisy” wants access to control “Notes”. | Privacy & Security → Automation → Daisy → Notes |
| Reminders, full access | the first Reminders call | “Daisy” would like full access to your Reminders. | Privacy & Security → Reminders → Daisy |
| Contacts | the first name that isn't a saved nickname | “Daisy” would like to access your contacts. | Privacy & Security → Contacts → Daisy |
| Files and Folders | sending a file from Desktop, Documents or Downloads | “Daisy” would like to access files in your Documents folder. | Privacy & Security → Files and Folders → Daisy |
| Full Disk Access | never asked; only attachments need it | none | Privacy & Security → Full Disk Access. Not recommended: it opens every file on the Mac to Daisy's agent |

Messages also has to be signed in to iMessage on the Mac, and SMS needs an iPhone with Text Message Forwarding turned on for this Mac. The first text can wait up to two and a half minutes (imsg's own limit) while the Automation prompt is up; after a denial, each tool says which setting to turn on.
