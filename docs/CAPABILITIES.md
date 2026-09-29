# A multipurpose assistant with capability adapters

The assistant answers general requests using the local model. Requests needing actual data go through a shared registry and execution loop. Files, memory, utilities, and future app/account connections all implement the same provider interface. Google Calendar is a possible adapter, not the organizing principle of the assistant.

## Request flow

1. The desktop app checks its local engine and verifies the selected model is local.
2. It builds a fresh registry from installed providers and current permissions. The model receives schemas only for available, enabled read/prepare capabilities.
3. The model can answer directly or request structured calls. The host validates names, schema, availability, effect classification, and cancellation before dispatch.
4. A request-scoped session executes calls, records receipts, and reuses the result of an identical call. Tool output goes back to the model as data for the next step.
5. The UI shows confirmed receipts alongside the final explanation. The loop stops after eight model rounds or ten calls, or at its context/time boundary. An incomplete response keeps completed receipts visible.

Only registered code runs. There is no model-generated shell, arbitrary path reader, cloud inference fallback, or automatic outgoing action. The model can still make mistakes in prose or select an unnecessary read tool; the boundary limits executable access, not every possible model error.

## Current providers

| Provider | Capabilities | Access |
| --- | --- | --- |
| Files | `search_files`, `read_text_file` | Chosen root; search and reading have separate permissions. Reading defaults off. |
| Memory | `search_memories` | Explicit local notes/preferences only. Model cannot save or change them. |
| Tasks | `list_tasks`, `prepare_task` | Local persistent projects, subtasks, dates, status and notes; review to save. |
| Drafts | `prepare_file` | New file in selected folder; exact-content review, no overwrite. |
| Mac apps | `find_apps`, `prepare_open_app` | Discover installed apps and review launch; no app UI control. |
| Utilities | `calculate`, `current_time` | Arithmetic parser and system date/time; no shell or account data. |

Search issues temporary opaque references. The text reader accepts references from that same request, rechecks folder containment, and reads a bounded UTF-8 excerpt. Files larger than 64 KB and unsupported formats are rejected. Results are data, not authorization. Saved explicit memory commands and UI edits remain separate deterministic user actions.

## Adding an adapter

Implement `CapabilityProvider.capabilities()`. Each `Capability` has a definition (stable name, title, provider, description, strict input schema, effect), an optional unavailable reason, and a cancellable async executor returning `CapabilityOutput`. Register the provider in the composition root. The engine, model transport, and generic receipt UI require no provider-specific branch. A focused test composes two synthetic providers across multiple model rounds to exercise this boundary.

Account setup and native permissions belong in the adapter's UI/service layer. Credentials stay out of prompts, arguments, and receipts. Failed requests must distinguish no results from missing access. Add result renderers where a domain needs a richer view; do not pretend a missing adapter is installed.

`changesData` and `communicatesExternally` classifications exist, but are blocked by the host. The current review path is limited to local tasks, new files and app launches. Future external sends need exact target/content approval and a persistent action ledger with uncertain-outcome handling. Registering an effectful capability today cannot bypass that restriction. No real sends were tested.

## Runtime and voice

`LocalRuntime` owns only the server it creates, coalesces startup attempts, and checks readiness before user work. It never retries a dispatched action to recover a lost response. A health monitor clears stale readiness. Normal termination waits for owned-server cleanup.

The installed model assets live under `~/Library/Application Support/Daisy/Runtime`, avoiding a Documents access prompt during engine/decoder startup. Homebrew still supplies the model and speech binaries; this is a development installation, not a portable bundle.

Voice uses explicit Record/Finish controls. A common-mode timer keeps the level meter and recording limit running during mouse tracking. Recordings are no longer rejected based on a stale cached meter peak. Audio input, permission state, and a link to macOS input settings are visible. Whisper transcription and Kokoro neural speech remain local.


## Version 0.3 expansion

`MCPConnection` is a generic local stdio JSON-RPC transport with request IDs, bounded messages, cancellation notifications, timeouts, and owned-process shutdown. The Chrome adapter that used it was retired on 2026-09-28; Chrome now goes through Hermes (see [mac-control](research/mac-control.md)).

`preparesChanges` capabilities produce a `ReviewedAction` with an exact display preview and trusted Swift commit closure. Model-facing receipts say prepared/unsaved and never include that closure. Only the UI Apply button calls it. Task revisions reject stale updates; exclusive file creation rejects overwrites. A new request, Stop or permission change expires unapplied cards. Existing `changesData` and `communicatesExternally` capabilities still fail closed; this is not general autonomous mutation.

`TaskStore` persists local projects/tasks with status, dates and notes (see Tasks below). `DraftCapabilityProvider` prepares new documents or source files in the selected root. `MacCapabilityProvider` discovers installed apps and prepares launches, without claiming arbitrary application control. These providers use the same registry and receipt pathway.

The loop now allows eight model rounds and ten calls, up to 240 seconds, with a 28,000-byte messages-plus-schema guard and 16,384-token local context. Real model accuracy and latency remain separate from deterministic permission tests. Page excerpts are bounded and may require offset calls; large workflows may hit the limit.

## Tasks

The Tasks tab and Hermes share one file: `tasks.json` in Daisy's data folder (`~/Library/Application Support/Daisy`). The app passes its path to hermes-acp as `$DAISY_TASKS_FILE`. Before this, Hermes put the user's tasks in its own `todo_list`, a scratch plan for one chat that never reached the tab.

Statuses are fixed ids with names: `idea` Idea, `todo` To do, `in_progress` In progress, `needs_review` Needs review (drafted, waiting on feedback or a read-through), `waiting` Waiting (on someone else), `blocked` Blocked, `submitted` Submitted, `done` Done, `dropped` Dropped. Submitted, done and dropped count as finished; everything else is open. Any other status text (an old `planned`, a hand edit, "needs to get started") is read by its words, and text with no known words becomes To do with the text kept in the notes. `TaskStatus.read` (Swift) and `read_status` (Python) follow the same cases in `hermes/fixtures/tasks/status-cases.json`, and both test against it.

A task can sit under another (`parent`), so a project holds schools and each school its essays. A parent that's missing or loops back makes the task top-level. `order` keeps a list in the order it was given.

The file is `{"version": 2, "projects": [...], "tasks": [...]}`. Files from before projects are a plain list of tasks; they read the same, and nothing is rewritten until something changes. Then the whole file is written in the new form.

Projects are real things: a name, a color (from a small set that sits with any theme: accent, red, orange, yellow, green, teal, blue, violet, pink, gray), a status (active, paused, done, archived), an optional due date, notes, links, and an optional folder on this Mac, which Hermes can use to find the project's files. Tasks still point at their project by name, matched without case, so anything that only knows names keeps working. A name on a task with no project of its own reads as a project too, with an id and color made from the name (`Project.named` in Swift, `named_project` in Python, the same on both sides; `hermes/fixtures/tasks/legacy-projects-expected.json` checks it), and it's written down with the next change. Renaming a project renames it on its tasks in the same locked write. Deleting one asks what happens to its tasks: they stay, with no project, or they're deleted too, with everything under them. A project stays once it's written, tasks or not; one only named on a task goes when no task names it.

Links sit on tasks and projects (`links`, up to 50 each). Each has an id, a kind, a title, and what it points at: `file` (a path, plus a bookmark so a moved or renamed file is still found), `url`, `google_doc` / `google_drive` (file id and link), `calendar_event` (event id, calendar id, start and its web link), `gmail` (thread and message id and the mail.google.com link), `note` (the Apple Notes id) and `reminder` (the Apple Reminders id). A pasted link or path picks its kind: docs.google.com is a Google Doc, drive.google.com a Drive file, calendar.google.com an event when its id can be read from the link (a web page otherwise), mail.google.com an email, `file://` or a path a file, and anything else on the web a web page. `TaskLink.detect` and `detect_link` follow the same cases in `hermes/fixtures/tasks/link-cases.json`. Only http and https links are kept. Opening one: files in their own app (apps and scripts are shown in Finder instead of run), web links in the browser, notes in Notes, reminders in Reminders. A file that can't be found says so.

The Tasks tab has New project next to Add task, and the project sheet: name, color, status, due date, notes, folder, links. Each project header has a menu (add a task, edit, rename, archive, delete) and shows its color, status, links and folder. Archived projects and their tasks stay hidden until "Show archived projects". The task editor has a Links section: paste a link or a path, or choose files; each link can be opened, retitled or removed. Rows show small link icons that open them.

Two writers, one file. The app (`TaskStore`) and the plugin (`hermes/daisy/tools/tasks.py`) both take an exclusive `flock` on `tasks.json.lock`, read the file again inside the lock, change only their own tasks and projects, and swap the file in with a rename (0600). Each change bumps that task's or project's `revision`, and the app refuses to save an edit made against an older revision, so it never writes over something Daisy just changed. A file that can't be read (or whose `projects` isn't a list) is never written over. The plugin writes back every task and project it didn't change exactly as it read it. The Tasks tab watches the folder (and polls every two seconds) while it's open, and reloads.

Hermes's tools: `tasks_list` reads (by status, project, parent or text), with each task's links: a Google Doc's `file_id` for `drive_read`, an email's `message_id` for `gmail_read`, a file's `path`. `tasks_add` adds one task or a whole nested list in one call, with parents by id or by title, and links. `tasks_update` changes status, title, due date, notes, project or parent, and adds or removes links (by id, url, path or title), for several tasks at once; an ambiguous title is refused with the choices. A project name that doesn't exist yet makes the project, and the card says so. `projects_list` reads projects with their open counts; archived ones only when asked. `projects_add` and `projects_update` add, rename (the tasks move with it), archive, recolor, date, note, set the folder and link. These change only Daisy's own records, so they run without a card, like a memory save, unless the turn already read outside content (then the card shows every task, project, link and change in full); background jobs and cron can't use them. `tasks_remove` always shows a card that names every task it removes, subtasks included. `projects_remove` always shows a card too, and needs `tasks: "keep"` or `"delete"` when the project has tasks; the card lists every task that stays or goes. Each tool only does what its check saw: if the list changed in between, nothing happens and the model is told to look again.

`scripts/import-hermes-todos.py` moves a list Hermes already kept in `todo_list` (from a saved result or read-only from `state.db`) into `tasks.json`: the status comes from the text after " — " when it reads as one, nesting stays, a top-level item with subtasks becomes their project, and tasks already there are skipped. `--dry-run` shows what it would add.
