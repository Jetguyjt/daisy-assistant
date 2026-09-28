# Integration investigation

## With Hermes (0.4)

Integrations now belong to Hermes, not Daisy code: skills for procedures, MCP servers or Hermes plugins for code and credentials. Checked against the installed Hermes 0.21.0 on 2026-09-25:

| Need | Hermes route | State on this Mac |
| --- | --- | --- |
| Find files | built-in `search_files` and terminal tools | Works. A live check found a resume by name in about 30 s |
| Memory | built-in `memory` tool, `USER.md` / `MEMORY.md` | Works. Saved a preference in one session and recalled it in a new one |
| Text someone | `imessage` skill (`imsg` CLI) | `imsg` not installed; "Dad" needs a contact mapping |
| Calendar | `google-workspace` skill (`gws` or its bundled Python, Google OAuth token) | No Google token yet; no Apple Calendar skill exists |
| Reminders, Notes | `apple-reminders` (`remindctl`), `apple-notes` (`memo`) | CLIs not installed |

Hermes only asks before dangerous commands and file edits; skills send with no prompt. In Daisy sessions the `hermes/daisy` plugin stops sends, email, calendar writes, posts and deletes at an approval card first ([architecture](ARCHITECTURE.md#approvals)). The rest of this document is the original investigation for the on-device engine, kept for the Contacts, EventKit and Messages details that still apply.

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

Verified the actual local `/System/Applications/Messages.app/Contents/Resources/Messages.sdef` by reading its public scripting definition. It exposes `send` for `text` or `file`, to a `participant` or `chat`; chats are described as SMS or iMessage. It also exposes file-transfer status. This proves a scripting interface is present, **not** that sending or delivery has been tested successfully.

Planned transport: narrowly scoped Apple Events/ScriptingBridge or safely parameterized AppleScript, using resolved participant/chat identities rather than interpolating model-generated scripts. Requires a signed app purpose string and macOS Automation permission to control Messages; the user must have Messages configured. SMS availability depends on their account/device configuration and cannot be inferred from the scripting dictionary.

Before any sending test, show an exact draft: recipient, address, channel, text, and attachment identity/path. An explicit Send button commits the approved action. Uncertain address, conflicting “Dad” mappings, or multiple resume versions require clarification. Do not treat a file's contents as authorization.

Use an action ledger with a unique operation ID and states such as draft, approved, submitting, submitted, failed, and outcome-unknown. Do not automatically retry after a timeout once the transport may have accepted the send. A successful `send` Apple Event is submission evidence; do not label it delivered without actual delivery evidence. File transfers and text messages have different evidence surfaces. A crash/restart after submission needs reconciliation or user review, not another send.

UI automation is a fallback when the structured interface proves insufficient, and requires Accessibility permission and tests on the actual UI. Window layouts, focus, app state, and OS changes can break it. Accessibility is not requested now. Do not read private Messages databases or request Full Disk Access just to simulate a delivery guarantee.
