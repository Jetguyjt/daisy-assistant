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
| Tasks | `list_tasks`, `prepare_task` | Local persistent projects, dates, status and notes; review to save. |
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

`TaskStore` persists local projects/tasks with status, dates and notes. `DraftCapabilityProvider` prepares new documents or source files in the selected root. `MacCapabilityProvider` discovers installed apps and prepares launches, without claiming arbitrary application control. These providers use the same registry and receipt pathway.

The loop now allows eight model rounds and ten calls, up to 240 seconds, with a 28,000-byte messages-plus-schema guard and 16,384-token local context. Real model accuracy and latency remain separate from deterministic permission tests. Page excerpts are bounded and may require offset calls; large workflows may hit the limit.
