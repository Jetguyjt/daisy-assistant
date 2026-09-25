# Jarvis for Mac

A native, local-first personal assistant. Version 0.3 provides local conversation and neural voice, an audio-reactive orb, editable memory, persistent tasks/projects, reviewed document/code drafts, app launching, and an optional general Chrome connection. New app connections are adapters to the same assistant, not separate hard-coded workflows.

Built and tested on an **M3 MacBook Air, 24 GB, macOS 26.5.1**. Minimum deployment target is macOS 14, but older systems have not been tested. Uses the installed Swift Command Line Tools; full Xcode is not required.

## Run

The installed app is at `~/Applications/Jarvis.app`. Double-click it, or run:

```sh
open ~/Applications/Jarvis.app
```

Jarvis checks and starts its dedicated local Ollama server before each model request. It monitors connectivity while open and stops a server it owns on exit. The first answer after the model unloads may take longer. The installer copies downloaded model assets into `~/Library/Application Support/Jarvis/Runtime` (APFS clones when available). Startup does not depend on Documents access. Homebrew binaries are still required; this is not a self-contained distributable yet.

For a fresh install:

```sh
bash scripts/setup.sh
open ~/Applications/Jarvis.app
```

This installs Ollama, whisper.cpp and Python 3.11 through Homebrew, downloads Qwen 3.5 4B (~3.4 GB), Whisper base.en (~148 MB), and Kokoro speech weights (~354 MB), compiles the app, applies a local ad-hoc signature, and installs it in your user Applications folder. Downloads require internet. Normal assistant inference does not. Optional browser access needs Node 22.12+ and npm; run `bash scripts/setup-browser.sh` to install its pinned local adapter. Website access still uses the internet. The setup script does not enable a login service. `dist/Jarvis.zip` preserves the signed bundle when the repository is in an iCloud/File Provider folder.

1. Click **Choose folder**. Jarvis searches filenames only under that folder.
2. Type “Find my latest resume”, or `/find resume` for a search without the language model.
3. Try `/remember response_style = Keep spoken answers short` or “Remember that I prefer short spoken answers.”
4. Click **Record**, speak, then click **Finish**. On first use, allow Microphone access. The input meter, elapsed time, and current microphone appear while recording. The recognized request is submitted automatically. Settings shows the microphone permission and a shortcut to macOS input selection.
5. Press **⌘.** or Stop to interrupt inference, transcription, recording, or spoken output. Sending another request also interrupts the current response.

**⌘⇧Space** starts/finishes recording (while Jarvis is focused). **⌘N** clears the conversation. Text input always works without microphone permission. Recording stops after 60 seconds. Disable spoken output in Settings if preferred.

## Available capabilities

| Capability | This build |
| --- | --- |
| Local conversation | Ollama on `127.0.0.1:11435`; downloaded Qwen models; no hosted fallback |
| Voice | AVAudioRecorder → whisper.cpp → local model → Kokoro ONNX neural voice → AVAudioPlayer |
| Orb | Animated SwiftUI Canvas; microphone and playback levels drive its movement; respects Reduce Motion |
| Memory | SQLite + FTS5; explicit save, edit, delete, source, revision; retrieved locally |
| Files | One chosen folder; recursive filename matching; newest first; click to open/reveal; optional bounded UTF-8 content reading |
| Tasks/projects | Persistent local title, project, due date, status and notes; UI editing and model-prepared review cards |
| Document/code drafts | Prepare a new text file; review full content and Apply; no overwrites or code execution |
| Mac apps | Find installed apps and review a launch; opening does not grant UI control |
| Chrome | Optional user-approved connection; tab search, accessible text reading, new background pages and web searches |
| Utilities | Validated arithmetic and date/time with timezone support |
| Capability system | Dynamic schemas, per-capability permissions, multi-step execution, deduplication, cancellation, verified result cards |
| Permissions | Folder selection/revocation, individual capability toggles, content reading off by default, microphone on first use |
| Calendar, Contacts, Messages | **Unavailable**; investigated and documented in [integration plan](docs/INTEGRATIONS.md) |
| Wake word, embeddings, inferred habits, fine-tuning, proactive suggestions | **Not implemented** |

Search does not inspect document contents, determine which resume is substantively correct, query all of Spotlight, or download cloud-only file contents. It excludes hidden entries, symlinks, and app/package contents; caps work at 50,000 entries or 10 seconds and returns up to 30 matches (the interface displays 8). Partial/inaccessible results are identified. Narrow the folder or query when needed. A filename match is not evidence of a file's meaning.

The model chooses from the enabled capabilities and can combine them, such as finding a text file, reading it, and summarizing it. Enable **Read text files** in Capabilities first. This reader accepts only references obtained from that request's scoped search, limits files to 64 KB, and returns at most 1,200 characters. It does not parse PDF/Word files. `/find budget` remains a direct search without inference.

General questions, writing, explanations, brainstorming, and planning do not require a special integration. Real data or actions in another app require an installed adapter and the appropriate access. Connected Chrome enables browsing and accessible page reading across sites, including signed-in pages. Full Gmail/Drive APIs, Google Docs canvas editing, arbitrary app control, form input, shell execution and sending messages are not implemented.

The agent is bounded to eight model rounds and ten tool calls, with strict schema validation and duplicate-call reuse. The current request is limited to 4,000 UTF-8 bytes. Complete memories/history are included only while they fit the context budget. Only result cards prove that an operation ran; model prose can still be inaccurate. Tools may read data or prepare exact changes. Task saves, new files and app launches require the user to Apply a review card. Other effectful adapters remain blocked. Old cards expire when another request starts, access changes, or Stop is pressed; task revisions and exclusive file creation also prevent stale overwrites. See [capability architecture](docs/CAPABILITIES.md).

## Voice, tasks and Chrome

In **Settings → Voice**, choose George, Fable, Michael, Heart or Emma, use **Preview voice**, then Save settings. Speech synthesis uses the downloaded Kokoro model locally. Run `bash scripts/setup-voice.sh` if the voice runtime is missing. The old macOS voice is not a fallback.

Use **Tasks → Add task** for homework, essay or coding projects. Or ask “Prepare a task to outline my essay in project College essays.” Jarvis produces a review card; **Apply** saves it. Due dates are tracking fields, not scheduled reminders. Ask “What tasks do I have for College essays?” to retrieve saved work. Notes can contain prompts, source links and next steps. “Prepare a new file study-plan.md with …” creates a review card showing exact content and destination. No existing file is overwritten.

Use **Connections → Open Chrome connection settings**, enable remote debugging in Chrome, click **Connect Chrome**, and approve Chrome’s prompt. This grants the local Chrome DevTools process access to your browser session; only the four restricted browser capabilities are exposed to Jarvis. Telemetry, CrUX requests, JavaScript evaluation, input, network-inspection and emulation tools are disabled. Disconnect ends the process; quitting Jarvis also disconnects. Connections are not restored automatically.

After connecting, try “Research this topic and cite sources” or “Summarize my open Gmail tab.” Full Gmail and Drive APIs are not connected. Reading a Drive listing does not prove a document’s contents were read. Some sites and document canvases expose little accessible text; the assistant must report that limitation. No signed-in browser workflow is claimed as validated until tested with your permission.

## Memory and privacy

Only direct `Remember that …` and `/remember key = value` commands, or edits in the Memory tab, write memories. The model cannot write memory or execute arbitrary code. Reusing a key updates its value and provenance. Repeating the same value is idempotent. Freeform notes get a stable content-based key; correct contradictory freeform notes in the Memory tab. Automatic conflict merging and inferred habits are deliberately deferred.

Memories, configuration, and the selected folder's bookmark live in:

```text
~/Library/Application Support/Jarvis/
    memory.sqlite
    tasks.json        # editable local tasks and projects
    config.json
    folder.bookmark
    Runtime/          # installed local model assets
```

The app uses a private data directory and file permissions; the database is **not separately encrypted**. FileVault and system backups govern storage-at-rest protection. Deletion removes a memory from active storage and retrieval, and clears the current conversation. OS backups, snapshots, or model-server RAM are not forensic-erased. Temporary recordings and speech text are removed after success, cancellation, or ordinary failure; a force-kill/system crash can leave files named `jarvis-…` in the OS temporary directory.

Conversation history is session-only, bounded, and never written to a transcript log. Explicit memory is retrieved with lexical FTS and recent notes; there are no embedding or inference API calls to an external provider. Most recent/relevant memories fit a bounded prompt; this is not unlimited recall. Chrome keeps account credentials in its own profile; Jarvis does not copy them into settings or request passwords. Browser page text is supplied to the local model only.

The dedicated Ollama process sets `OLLAMA_NO_CLOUD=1`. The client has a fixed loopback endpoint, disables proxies and redirects, and rejects cloud tags/remote-model metadata. It does not connect to your normal Ollama port 11434. If you manually supply an existing server on 11435, you are responsible for running the genuine Ollama binary with cloud disabled; a compromised local server is outside this trust boundary. Model downloads and Ollama's own startup/download metadata traffic may access the internet; this is not an OS-enforced network sandbox.

The development app is not App Sandbox-contained. Chosen-folder scoping is enforced in the tool implementation; macOS TCC still governs protected locations. It does not need Full Disk Access, Accessibility, Contacts, or Calendar permissions. Granting those permissions would not create new implemented capabilities.

## Development and validation

```sh
swift build
swift run jarvis-tests
bash scripts/build-app.sh              # release app; optionally pass debug
bash scripts/install-app.sh            # quit Jarvis first when updating
bash scripts/serve-model.sh            # diagnostic standalone server
swift run jarvis-check qwen3.5:4b       # actual local inference and synthetic speech round trip
swift run jarvis-check --runtime       # quit Jarvis/external server first; owned startup/shutdown twice
swift run jarvis-check --browser-metadata # real MCP handshake only; no browser/account access
```

The focused tests use a small standalone Swift runner because the installed Command Line Tools do not ship XCTest. Tests exit nonzero on failure. They cover persisted corrections, idempotency, deletion/retrieval, query escaping, scope boundaries, symlink exclusion, disabled/unknown tools, malformed responses, local-model checks, and cancellation/timeouts. The smoke test creates only synthetic files, task drafts and preferences in a temporary folder, generates local speech, transcribes it, and writes measurements under `.runtime/benchmark-*.json`.

To compare models with your normal apps running:

```sh
bash scripts/download-models.sh qwen3.5:2b
# Start Jarvis, or keep scripts/serve-model.sh running in another terminal.
swift run jarvis-check qwen3.5:2b
swift run jarvis-check qwen3.5:4b
```

Change the model tag in Settings and select Save & reconnect. No automatic model substitution occurs. Measurements and limitations are recorded in [validation](docs/VALIDATION.md). Architecture and rationale are in the [decision log](docs/DECISIONS.md).

## Troubleshooting

- **Engine offline / model missing:** run `bash scripts/download-models.sh`, then Save & reconnect. Use `bash scripts/serve-model.sh` to see startup errors. Another process on 11435 can prevent startup.
- **No speech recognized:** click Record, speak, then Finish. Check the input meter and the microphone shown in Settings. macOS may choose a display or headset microphone; use the sound input settings shortcut to choose your preferred device.
- **Microphone denied:** System Settings → Privacy & Security → Microphone → Jarvis. Launch the `.app`, not the bare binary, to ensure the usage description is present. An ad-hoc rebuilt app may need permission again; stable distribution signing is future work.
- **Voice model missing:** check the absolute paths in Settings. `config.example.json` shows the format. Bundle defaults are generated at build time; saved user settings take precedence.
- **Old/custom runtime paths:** saved settings take precedence over bundle defaults. If you saved a path under Documents, update it to the installed `Runtime` location. Moving this repository does not affect the new installed model paths. Keep the memory database unless you intend to erase memories.
- **Signature check fails under Documents/iCloud:** install from `dist/Jarvis.zip` with `bash scripts/install-app.sh`. Build-time signing/verification happens in a temporary staging directory; the user Applications folder avoids File Provider adding forbidden bundle metadata.
- **Folder removed or permissions changed:** choose it again. Revoking access cancels current work and disables opening stale results from that folder.
- **First speech/model request slow:** weights and Metal kernels may need a cold start. Subsequent timings vary with memory pressure and the fanless Air's thermal state.

Closing the window quits Jarvis and stops a server it started. A server started separately in a terminal remains yours to stop with Ctrl-C. No personal messages or account changes were used during development.
