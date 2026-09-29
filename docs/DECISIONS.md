# Project decision log

## 2026-09-24 — Foundation on the verified Mac

Environment: local MacBook Air `Mac15,12`, Apple M3, 24 GB, arm64, macOS 26.5.1 (25F80), Swift 6.2.3 Command Line Tools. Repository started empty with no ancestor AGENTS.md instructions. Full Xcode is not installed. Hardware identifiers were not stored in this repository.

### 001 — SwiftUI rather than Tauri + React + Python

Use one native Swift application, a core Swift library, and separately installed local model binaries. SwiftUI/Canvas handles the orb and UI; AppKit handles folder selection and file opening; AVFoundation handles recording/playback; system SQLite handles memory. This avoids Rust, JavaScript, Python service lifecycle, IPC authentication, and a backend web server in the first milestone. Python is used only for generating build-time JSON defaults.

Tradeoff: macOS-specific. More sophisticated GPU visuals or a cross-platform UI could justify Metal/Tauri later. Canvas is sufficient for a smooth audio-reactive foundation. Test on older macOS before claiming support beyond the verified system.

### 002 — Local Ollama, isolated configuration

Installed Ollama 0.34.4. Use a dedicated loopback server on 11435, cloud disabled, one inference request at a time, 8192-token context. Keep total message text to 6,000 UTF-8 bytes, reserving space for the tool template and response; include complete memories/history only if they fit. Verify local model metadata before supplying conversation context. Disable HTTP redirects/proxies. No generic remote endpoint setting or cloud API keys.

Qwen 3.5 4B is the initial baseline. Compare 2B using identical synthetic requests on this Mac before tuning default latency. Disk/parameter size is not evidence of usability. Start with thinking disabled, bounded output and short answers; expose the model tag in Settings. See validation for actual results. No embeddings are needed for the first handful of explicit memories.

Sources: [Ollama local-only mode](https://docs.ollama.com/faq), [native API](https://github.com/ollama/ollama/blob/main/docs/api.md), [Qwen 3.5 local variants](https://ollama.com/library/qwen3.5).

### 003 — whisper.cpp and system speech for milestone one

Installed whisper.cpp 1.9.4 and downloaded `ggml-base.en.bin`, SHA-256 `a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002`. Push-to-talk records 16 kHz mono PCM and runs a cancellable local decoder process with fixed argv. English only initially. Speech output uses installed Samantha through `/usr/bin/say`, then AVAudioPlayer for real amplitude metering and interruption. No cloud ASR/TTS or browser speech API.

This removes Pipecat, Python, MLX Whisper, and Kokoro dependencies from the first build. Their quality/latency may justify a later dedicated audio engine. A persistent Whisper worker would avoid per-utterance process/model startup. Apple Speech was considered but requires runtime verification of on-device support; it is not used as an implicit fallback.

Sources: [whisper.cpp](https://github.com/ggml-org/whisper.cpp), [Apple on-device recognition limitations](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition). Confirmed installed Samantha with `say -v '?'`.

### 004 — Explicit, inspectable memory before adaptation

Memory writes bypass the LLM. SQLite keys allow corrections; sources and revisions preserve provenance. Exact duplicate saves do not create duplicate records. FTS5 plus recent memories supplies bounded context. The UI can inspect/edit/delete everything saved. Freeform notes do not automatically resolve semantic contradictions; the UI and keyed writes make correction explicit. No observation of general computer activity, inferred habits, embeddings, or fine-tuning yet.

An inferred memory must later have a different type and confidence/source metadata, and cannot silently supersede explicit instructions. Add expiry/version history only with a clear user-facing policy. Embeddings must run locally if introduced; benchmark retrieval quality before adding them.

### 005 — Original milestone-one tool boundary (superseded by 007)

The LLM has one structured tool: `search_files(query)`. It never selects a root path. Tool arguments, permission, cancellation, and folder containment are validated outside the model. One tool per turn, no automatic retries. Search reads metadata only; hidden paths, symlinks, and packages are excluded. Open/reveal are direct user clicks, revalidated at use time.

During the initial live model test, Qwen offered to read a found file despite that feature being unavailable. The final search response is therefore rendered deterministically from the verified result. Filenames are not sent back for a second model generation. This also lowers latency and blocks filename-based prompt injection from gaining another tool turn. Both tested model sizes sometimes overused search on unrelated questions. A conservative host-side intent gate now exposes and authorizes search only for file-location requests; `/find` is the explicit route when the heuristic misses a request. Model-generated prose can still make inaccurate suggestions; only verified result cards represent executed actions.

Future writes require explicit typed capabilities, reviewed drafts, idempotency keys and an action ledger. External content is evidence, never user authorization. Keep credentials in Keychain/integration code, out of prompts and logs.

### 006 — Cancellable tasks, no speculative success

Cancel network tasks and owned audio processes, stop playback/recording, cancel detached search work, and discard stale generation results. A generation identifier prevents a stopped request from updating a new conversation. Stop does not roll back an already-committed explicit memory save; the notice says so. Child processes receive termination followed by a bounded kill if they fail to exit. All subprocesses use explicit binaries and argument arrays, never model-generated shell commands.

### 007 — Multipurpose capabilities and reliability update

The user clarified that the assistant must grow across many tasks, rather than orbit a fixed Calendar/Messages roadmap. Version 0.2 replaces the single-tool intent gate with typed capability providers, dynamic schemas and availability, a bounded multi-step agent, central permission/schema/effect checks, deduplication, and generic receipts. Installed providers cover files, memory, arithmetic, and time. A test composes unrelated providers without an engine change. See [CAPABILITIES.md](CAPABILITIES.md).

The context window is now 16,384 tokens, with a 13,500-byte request-plus-schema guard for later rounds and a bounded initial history. Content reading is optional and off by default. Effectful adapters remain blocked until reviewed commit support exists. New integrations can be chosen by user need, rather than requiring Calendar as the next feature.

A user report exposed a stale ready badge after the external development server disappeared. The app now owns server startup, preflights every request, monitors connection loss, and waits for child termination. Live launch also exposed a Documents permission prompt blocking model startup; installed model assets now live in application data.

Voice switches from a press/drag gesture to Record/Finish. Timer tracking runs in common run-loop modes, and a stale cached peak no longer suppresses decoding. Microphone device, permission, elapsed time and level are visible. This addresses concrete control/meter failure paths; it does not by itself prove the user's live speech was transcribed.

### Next work

Expand adapters based on real requests: richer documents, app/account data, browsing or workflows. Add the reviewed commit/action-ledger layer before any external writes or sends. Streaming, persistent local speech workers, stable signing, wake word, and menu-bar mode remain possible usability improvements. Proactive observation and inferred memory need their own explicit design and permissions.


## 008 — Neural local speech and general workspace adapters (2026-09-24)

The user rejected the quality of the macOS voice and prioritized web research, Gmail/Drive, apps/files, coding, homework, tasks and college essays. Replace the speech backend with Kokoro-82M through a pinned `kokoro-onnx` Python 3.11 environment. Keep synthesis offline, provide five previewable voices and speed control, and preserve Stop cancellation. Voice taste requires user listening; synthetic transcription is not a quality rating.

Add one local stdio MCP transport and a restricted Chrome DevTools adapter instead of bespoke Gmail/Calendar branches. Chrome's own approval is required for the existing signed-in session. Keep JavaScript/input/network tools and telemetry disabled. Browser reading is limited by accessible page text; full account APIs and Docs editing remain separate unfinished work.

Add local task/project persistence and prepared file/app/task actions through trusted review cards. Tasks cover any project rather than hardcoded essay fields; user notes can hold prompts and links. No auto-created personal deadlines, reminders, emails or changes are used in development tests. New files never overwrite existing files. App launch is not arbitrary app control. A stronger model and broader automation should be justified by real accuracy measurements, not advertised as completed capabilities.

## 009 — Always-listening voice on a Whisper gate, not Apple's recognizer (2026-09-25)

The user wants to talk to Jarvis without clicking. Three listening modes now exist: wake word (default), hands-free conversation, and click to talk. Recording ends on its own through an energy endpointer with an adaptive noise floor; there is no third-party VAD. In wake-word mode the microphone stays open, every endpointed utterance is transcribed locally, and only one that starts with "hey Jarvis" becomes a turn. Everything else is discarded unrecorded.

Apple's on-device SFSpeechRecognizer was tried for phrase spotting and rejected: it returned no results at all on test audio, and Apple's own forums say the on-device path prefers live microphone input. Whisper already runs for every request, so gating on its transcript costs no new dependency and no new permission. openWakeWord's pretrained "hey_jarvis" model (non-commercial weights) and sherpa-onnx keyword spotting stay as later options if the gate's delay bothers the user.

Capture moved from AVAudioRecorder to AVAudioEngine with Apple voice processing enabled, so the microphone hears the user over Jarvis's own speech and a sustained voice interrupts playback. Playback goes through the same engine when it runs, which is what makes the echo cancellation apply. whisper.cpp now runs as an owned `whisper-server` child (model loaded once), and Kokoro runs as an owned worker process that speaks one JSON line per sentence, with answers synthesized and played sentence by sentence. Measured on this Mac: first audio for a short opening sentence in about 0.6 s instead of about 2.5 s, and a warm transcription of a five second clip in about 0.1 s.


## 010 — Jarvis becomes DAISY (2026-09-27)

The voice moves from British male to American female (Kokoro `af_heart`), so the name changed with it: DAISY, "Definitely An Intelligent System, Yeah." Everything was renamed in one pass: the app and bundle ID (`com.local.daisy.desktop`), Swift targets and modules, the Hermes plugin (`hermes/daisy`, `DAISY_SESSION`), scripts, docs and the GitHub repo. The wake phrase is "hey daisy", and Whisper's misspellings of it are accepted. The first launch moves `~/Library/Application Support/Jarvis` to `.../Daisy` and rewrites the saved paths inside `config.json`, falling back to the old folder if the move fails. The new bundle ID means macOS asks for microphone and automation permissions again. Entries above this one keep the old name because that's what it was called then.

## 011 — Heart stays local on Kokoro (2026-09-27)

Daisy speaks with Kokoro's `af_heart`, its only A-graded voice, and a 70/30 Heart + Bella blend is one setting away (`af_heart:0.7,af_bella:0.3`, mixed from the two style vectors inside the worker). Every other English Kokoro voice stays selectable, including the British ones Jarvis used. A hosted voice (Cartesia, OpenAI) and Qwen3-TTS were left out on purpose: the local voice costs nothing per sentence, works offline, and a hosted one would need its own key and send every answer out. The worker now trims silence to an even 200 ms between chunks, and the text it reads has numbers, money, times, dates and abbreviations written out as words, because espeak reads "3.5" as "three. five". How it sounds is for me to judge by ear; `daisy-check --voice-ab` plays the comparisons.

## 012 — The guard rebuilt around one action per card (2026-09-28)

A stress test of the first guard found ways around it in every category: two chained sends showing a card for only the first, a Bcc or attachment pushed past the card's 400-character cutoff, sends through `mail`, `open mailto:`, Mail over osascript or `curl -F`, deletes that weren't recursive, `execute_code` calling `smtplib` directly, no guard at all in cron or gateway sessions, and nothing stopping a web page from steering a memory write. Every one of those became a test first, failing on the old guard.

The new guard reads commands the way bash will and refuses chains unless every step only reads, so a card always shows exactly one action in full. Risky actions become typed plugin tools that declare what they do, and the guard judges them by that declaration instead of parsing arguments; the shell route to the same action is refused. It loads in every Hermes process, blocks when it errors, gives background jobs and cron runs read-only roles, adds a card for memory writes and new sites once a turn has read outside content, limits a session to five cards a minute, and gives each card its own rule key so nothing can be approved for good. It's still a reader of commands, not a sandbox.

Hermes's `delegate_task` stays off in Daisy sessions: checked live, its background results never come back over ACP. Background work runs as Daisy's own jobs instead, each in a Hermes session the guard knows is read-only.

## 013 — Messages, Reminders and Notes as typed tools (2026-09-28)

Texts go through `imsg_send` on imsg, reminders through remindctl, notes straight through osascript. Three choices on purpose. Notes doesn't use memo, the CLI Hermes's apple-notes skill wants: it pastes note text into AppleScript source, only adds or edits through an interactive editor, and edits by rewriting the whole note through Markdown. There's no tool that reads messages: imsg reads chat.db, which needs Full Disk Access, and that would open every file on the Mac to the agent's shell. There are no delete tools for reminders or notes; the shell route to those deletes stops at a delete card. Who a text goes to is never guessed: a saved nickname, one exact contact, or a number, and anything else is refused with the choices so Daisy asks.

## 014 — One local signing certificate (2026-09-28)

Ad hoc, every build of Daisy was a new app to macOS, because the code signature's identity was the build's hash, so the microphone prompt came back after every install (and Contacts, Automation and Reminders would have too). Daisy is now signed with a self-signed certificate, "Daisy Local Signing", made once by `scripts/make-signing-identity.sh` and kept in the login keychain for codesign. The app's identity is its bundle ID plus that certificate, which stays the same across builds, so permissions are granted once. The trade-off: anything that can use that key can sign an app macOS treats as Daisy, which is why it lives in the login keychain and nowhere else.

## 015 — Always on, read-only (2026-09-28)

Hermes's gateway runs as a LaunchAgent so scheduled jobs run while Daisy is closed. The two jobs Daisy adds, an overnight inbox triage and a morning repo digest, only read; the guard treats every cron run as read-only, so a job that tried to send or change something would be blocked, not carded, since nobody is there to answer. Background jobs pause at 80% of either ChatGPT usage window. A cheaper model for background runs is picked from what Hermes lists, not written into the config by name; today none is listed, so they use the default.

## 016 — Standing permissions, only when I say so (2026-09-29)

Clicking yes on twenty cards to fix twenty docs is the kind of thing that teaches you to stop reading cards. So when I say outright that Daisy can do something without asking, she asks once with `approval_grant`, and that card is the yes: exactly what runs without a card, for how long, and what still asks. The guard holds the grant while the card is up, and the tool turns on exactly that one once the card is approved, so a declined or unanswered card leaves nothing. A grant lasts until the request is done (the same Hermes session and turn, three hours at most) unless I said "from now on", and then until I turn it off in Setup. A card a grant could cover also gets "Yes to all like this", which does the same for the rest of that request.

What a grant can cover is a short list on purpose: typed tools that edit or add (risk `write`, `own` or `ui`), scripts I named, exactly as they were when I said yes, and MCP tools whose name says they edit. Scripts are held to their contents because otherwise Daisy could write a new one and run it unseen; a changed script, a changed helper next to it, or a new one there asks again. Clicking and typing is for one app, and a click on a send, delete or share button, Return, shortcuts, a line break, a spot with no label and anything in a terminal still get their card. The guard's other card rules stay out: installs, settings, startup files, scheduled jobs, memory and skills, new sites after reading, raw browser control, and code. `write_file` and `patch` already run without the guard's card, and Hermes's own prompts for sensitive files and dangerous commands aren't touched. Sends, shares and deletes, and anything that emails, invites or notifies people or changes something shared, get their card every time.

Grants only apply in a Daisy chat session where someone could have answered the card: never a background job, a cron run, yolo or a one-shot run, and not other Hermes processes. Every step that runs under one is logged in `grants.jsonl` and shows in that answer ("Done under your OK: …"), and past 30 in a minute they go back to cards. `grants.json` sits with the guard's other files, which the shell, code and file tools can't write; like `roles.json` and `cron-allow.json`, that's a check on what a call says, not a sandbox, so code that builds the path while it runs, in a turn that hasn't read anything, isn't caught.
