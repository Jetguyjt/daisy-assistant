# Daisy for Mac

<img src="docs/images/icon.png" width="128" alt="Daisy app icon: an arc-reactor core on a dark tile">

A native Mac assistant. Version 0.4 splits the work: Daisy is the face and the voice (a HUD, an audio-reactive core, the "Hey Daisy" wake word, local speech in and out), [Hermes Agent](https://github.com/NousResearch/hermes-agent) is the agent runtime (tool loop, sessions, memory, skills, MCP, approvals), and OpenAI is the reasoning model through Hermes's ChatGPT/Codex subscription sign-in. Daisy talks to Hermes over ACP and never sees the model or its credentials. The original on-device engine (Ollama plus a Swift tool loop) is still there as an optional fallback. See [architecture](docs/ARCHITECTURE.md). What's left to build is in the [roadmap](docs/ROADMAP.md).

Built and tested on an **M3 MacBook Air, 24 GB, macOS 26.5.1**. Minimum deployment target is macOS 14, but older systems have not been tested. Uses the installed Swift Command Line Tools; full Xcode is not required.

## Run

One-time Hermes setup:

```sh
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash   # only if Hermes isn't installed
hermes auth add openai-codex      # device-code login in Terminal; Hermes keeps the tokens
bash scripts/setup-hermes.sh      # Daisy plugin: persona, and approval before sends, deletes and calendar changes
DAISY_GATEWAY=1 DAISY_CRON=1 bash scripts/setup-hermes.sh   # optional: Hermes's gateway as a LaunchAgent, and two read-only morning jobs (inbox triage, repo digest)
open ~/Applications/Daisy.app    # first launch: press Connect
```

After the first connection Daisy starts Hermes on launch and resumes the last conversation. If Hermes is missing, signed out, or has no provider, the HUD says so and shows the command that fixes it. **Setup → Agent** switches between Hermes and the on-device model, and **New conversation** (⌘N) starts a fresh Hermes session; Hermes's memory carries over.

Type `/job <what you want done>` (or use the **JOBS** tab) to run something in the background while you keep talking. Two jobs run at once, each in its own Hermes session that can only read; Daisy says the result when one finishes. Anything that needs a yes shows up as a card with a countdown, and no answer counts as no.

### On-device fallback

Daisy checks and starts its dedicated local Ollama server before each model request. It monitors connectivity while open and stops a server it owns on exit. The first answer after the model unloads may take longer. The installer copies downloaded model assets into `~/Library/Application Support/Daisy/Runtime` (APFS clones when available). Startup does not depend on Documents access. Homebrew binaries are still required; this is not a self-contained distributable yet.

For a fresh install:

```sh
bash scripts/setup.sh
open ~/Applications/Daisy.app
```

This installs Ollama, whisper.cpp and Python 3.11 through Homebrew, downloads Qwen 3.5 4B (~3.4 GB), Whisper base.en (~148 MB), Kokoro speech weights (~354 MB) and the speech-in models (Silero voice activity and openWakeWord features, ~3.7 MB from GitHub, via `scripts/setup-speech.sh`), compiles the app, signs it, and installs it in your user Applications folder. Run `bash scripts/make-signing-identity.sh` once first: it makes a local signing certificate ("Daisy Local Signing") so every build is the same app to macOS and keeps its microphone, Contacts and Automation permissions. Without it the build is signed ad hoc and macOS asks for them again after each install. Downloads require internet. Normal assistant inference does not. The setup script does not enable a login service. `dist/Daisy.zip` preserves the signed bundle when the repository is in an iCloud/File Provider folder.

1. Click **Choose folder**. Daisy searches filenames only under that folder.
2. Type “Find my latest resume”, or `/find resume` for a search without the language model.
3. Try `/remember response_style = Keep spoken answers short` or “Remember that I prefer short spoken answers.”
4. Click **Record**, speak, then click **Finish**. On first use, allow Microphone access. The input meter, elapsed time, and current microphone appear while recording. The recognized request is submitted automatically. Settings shows the microphone permission and a shortcut to macOS input selection.
5. Press **⌘.** or Stop to interrupt inference, transcription, recording, or spoken output. Sending another request also interrupts the current response.

**⌘⇧Space** starts/finishes recording (while Daisy is focused). **⌘N** clears the conversation. Text input always works without microphone permission. Recording stops after 60 seconds. Disable spoken output in Settings if preferred.

## Available capabilities

| Capability | This build |
| --- | --- |
| Conversation | Hermes Agent over ACP (`hermes-acp`), model and provider chosen in Hermes; answers stream into the transcript. Optional on-device Ollama fallback |
| Voice | Mic → Silero voice activity → wake word or Talk → Apple's on-device recognizer (whisper.cpp as the fallback) → agent → Kokoro, starting on the first finished sentence while the answer is still streaming |
| Approvals | Sends, deletes, calendar changes and posts wait on an amber card with the exact content (Hermes plugin in `hermes/daisy`); dangerous commands and file edits use Hermes's own prompts |
| HUD | Reactor-style core that follows the mic and the voice, live tool activity, link and mic status, always-listening switch; respects Reduce Motion and pauses when hidden |
| Memory | Hermes's `USER.md` / `MEMORY.md`; a Learned feed in the Memory tab lists what Hermes saved on its own, with Undo and Edit. The old SQLite memory moves into Hermes once and stays for the on-device fallback |
| Files | One chosen folder; recursive filename matching; newest first; click to open/reveal; optional bounded UTF-8 content reading |
| Tasks/projects | Persistent local title, project, due date, status and notes; UI editing and model-prepared review cards |
| Document/code drafts | Prepare a new text file; review full content and Apply; no overwrites or code execution |
| Mac apps | Find installed apps and review a launch; opening does not grant UI control |
| Chrome | Your own Chrome through Hermes: list tabs, switch to one, open pages. macOS asks once whether Daisy can control Chrome |
| Utilities | Validated arithmetic and date/time with timezone support |
| Capability system | Dynamic schemas, per-capability permissions, multi-step execution, deduplication, cancellation, verified result cards |
| Permissions | Folder selection/revocation, individual capability toggles, content reading off by default, microphone on first use |
| Gmail, Calendar, Drive | Typed tools over Hermes's `google-workspace` skill: "check my email" reads headers and snippets, and every send, share, delete or calendar change waits on a card. Needs your own Google sign-in first (steps in [google.md](docs/research/google.md)) |
| Other Mac apps | `computer_look` reads a window; every click, key or bit of typing through `computer_act` waits on a card that says exactly what it will do. Needs Accessibility and Screen Recording for CuaDriver |
| Contacts | Looks people up by name or a nickname you've confirmed once ("Bubba" means Robert); the first lookup asks for Contacts access |
| Messages | `imsg_send`: "Text Dad I'm on my way" resolves Dad through your saved nicknames, then Contacts, and waits on a card with the exact number and the whole message. Needs `imsg` and Automation access to Messages; it can't read your texts |
| Reminders | List, add and check off Apple Reminders; every add or check-off waits on a card with the date in words. Needs `remindctl` (`brew install steipete/tap/remindctl`) and Reminders access |
| Notes | Search and read Apple Notes, create a note or add to one; every change waits on a card with the whole text. Needs Automation access to Notes |
| Wake word | "Hey Daisy", heard in Apple's streaming transcript (or by a trained openWakeWord model once there is one, see [wake word](docs/wake-word.md)); on/off switch on the main screen (⌘⇧L) |
| Proactive suggestions, fine-tuning | **Not implemented** |

Search does not inspect document contents, determine which resume is substantively correct, query all of Spotlight, or download cloud-only file contents. It excludes hidden entries, symlinks, and app/package contents; caps work at 50,000 entries or 10 seconds and returns up to 30 matches (the interface displays 8). Partial/inaccessible results are identified. Narrow the folder or query when needed. A filename match is not evidence of a file's meaning.

The model chooses from the enabled capabilities and can combine them, such as finding a text file, reading it, and summarizing it. Enable **Read text files** in Capabilities first. This reader accepts only references obtained from that request's scoped search, limits files to 64 KB, and returns at most 1,200 characters. It does not parse PDF/Word files. `/find budget` remains a direct search without inference.

General questions, writing, explanations, brainstorming, and planning do not require a special integration. Real data or actions in another app require an installed adapter and the appropriate access. Anything that sends, shares, deletes, changes a calendar or drives another app goes through a typed tool and its approval card; none of it has been run against the real accounts and apps yet.

The agent is bounded to eight model rounds and ten tool calls, with strict schema validation and duplicate-call reuse. The current request is limited to 4,000 UTF-8 bytes. Complete memories/history are included only while they fit the context budget. Only result cards prove that an operation ran; model prose can still be inaccurate. Tools may read data or prepare exact changes. Task saves, new files and app launches require the user to Apply a review card. Other effectful adapters remain blocked. Old cards expire when another request starts, access changes, or Stop is pressed; task revisions and exclusive file creation also prevent stale overwrites. See [capability architecture](docs/CAPABILITIES.md).

## Voice, tasks and Chrome

In **Settings → Voice**, choose any American or British Kokoro voice (Heart is the default) or the Heart + Bella blend, use **Preview voice**, then Save settings. Speech synthesis uses the downloaded Kokoro model locally, kept loaded in a worker process while Daisy runs and spoken sentence by sentence. While Daisy talks, the reply's text shows up a sentence at a time as she says it, and the whole reply joins the transcript once it's been said (Stop or talking over her puts it there straight away). Run `bash scripts/setup-voice.sh` if the voice runtime is missing. The old macOS voice is not a fallback.

**Listening** has three modes in the same settings group. *Wake word* (the default) keeps the microphone open: Apple's on-device recognizer streams what it hears, and Daisy wakes mid-sentence when it hears "Hey Daisy" and takes down the rest as the request; anything else is dropped. When Apple's recognizer isn't ready, each pause goes to whisper.cpp instead; after an answer Daisy listens for a follow-up until you stay quiet. *Hands-free conversation* starts with one click on Record and then runs the same loop. *Click to talk* keeps the microphone off until you click. In every mode a recording ends on its own when you pause, and you can talk over Daisy to interrupt it (Apple's voice processing cancels its own speech from the mic input). whisper.cpp runs as a `whisper-server` child so the model loads once; if that binary is missing, each utterance falls back to `whisper-cli`. Silero voice activity detection decides when you've stopped talking, with the old loudness endpointer as the fallback. Helper processes (whisper-server, `ollama serve`, the voice worker) are tied to Daisy and stop with it, even after a crash or force quit.

Use **Tasks → Add task** for homework, essay or coding projects. Or ask “Prepare a task to outline my essay in project College essays.” Daisy produces a review card; **Apply** saves it. Due dates are tracking fields, not scheduled reminders. Ask “What tasks do I have for College essays?” to retrieve saved work. Notes can contain prompts, source links and next steps. “Prepare a new file study-plan.md with …” creates a review card showing exact content and destination. No existing file is overwritten.

Chrome needs no setup. Ask “what tabs do I have open”, “switch to my Gmail tab” or “search Google for …”: Hermes lists your tabs, switches to one or opens a page in your own Chrome, signed-in tabs included. The first time, macOS asks whether Daisy can control Google Chrome; allow it (System Settings → Privacy & Security → Automation). Daisy never clicks, types or runs anything inside a page. The old **Connect Chrome** adapter (remote debugging for the on-device model) is gone.

## Memory and privacy

With Hermes, personal memory is Hermes's: `~/.hermes/memories/USER.md` and `MEMORY.md`, curated by Hermes and shown read-only in the Memory tab. It doesn't depend on which model is selected, and ChatGPT's own memory is not used. Reasoning is remote: each turn sends OpenAI the request, that session's conversation, Hermes's system prompt (with its memory snapshot) and the results of tools it ran. Speech, the wake word, tools, sessions and memory files stay on this Mac. The rest of this section describes the on-device engine's memory.

Only direct `Remember that …` and `/remember key = value` commands, or edits in the Memory tab, write memories. The model cannot write memory or execute arbitrary code. Reusing a key updates its value and provenance. Repeating the same value is idempotent. Freeform notes get a stable content-based key; correct contradictory freeform notes in the Memory tab. Automatic conflict merging and inferred habits are deliberately deferred.

Memories, configuration, and the selected folder's bookmark live in:

```text
~/Library/Application Support/Daisy/
    memory.sqlite
    tasks.json        # editable local tasks and projects
    config.json
    folder.bookmark
    Runtime/          # installed local model assets
```

The app uses a private data directory and file permissions; the database is **not separately encrypted**. FileVault and system backups govern storage-at-rest protection. Deletion removes a memory from active storage and retrieval, and clears the current conversation. OS backups, snapshots, or model-server RAM are not forensic-erased. Temporary recordings and speech text are removed after success, cancellation, or ordinary failure; a force-kill/system crash can leave files named `daisy-…` in the OS temporary directory.

Conversation history is session-only, bounded, and never written to a transcript log. Explicit memory is retrieved with lexical FTS and recent notes; there are no embedding or inference API calls to an external provider. Most recent/relevant memories fit a bounded prompt; this is not unlimited recall. Chrome keeps account credentials in its own profile; Daisy does not copy them into settings or request passwords.

The dedicated Ollama process sets `OLLAMA_NO_CLOUD=1`. The client has a fixed loopback endpoint, disables proxies and redirects, and rejects cloud tags/remote-model metadata. It does not connect to your normal Ollama port 11434. If you manually supply an existing server on 11435, you are responsible for running the genuine Ollama binary with cloud disabled; a compromised local server is outside this trust boundary. Model downloads and Ollama's own startup/download metadata traffic may access the internet; this is not an OS-enforced network sandbox.

The development app is not App Sandbox-contained. Chosen-folder scoping is enforced in the tool implementation; macOS TCC still governs protected locations. It does not need Full Disk Access, Accessibility, Contacts, or Calendar permissions. Granting those permissions would not create new implemented capabilities.

## Development and validation

```sh
swift build
swift run daisy-tests
bash scripts/build-app.sh              # release app; optionally pass debug
bash scripts/install-app.sh            # quit Daisy first when updating
bash scripts/serve-model.sh            # diagnostic standalone server
swift run daisy-check qwen3.5:4b       # actual local inference and synthetic speech round trip
swift run daisy-check --runtime       # quit Daisy/external server first; owned startup/shutdown twice
swift run daisy-check --hermes "What is 37 × 18?" "Find my resume."  # real Hermes over ACP; approvals always declined
for t in hermes/test_*.py; do python3 "$t"; done  # approval guard rules and the typed-tool contract
python3 scripts/gen-tests.py          # after adding a *Tests.swift file
swift run daisy-check --spoken answer.md  # print what the voice would say for a Markdown answer
swift run daisy-check --endpoint clip.wav  # replay a WAV through the silence endpointer
swift run daisy-check --wake-gate clip.wav # transcribe a WAV and show whether the wake phrase fires
swift run daisy-check --voice-timing clip.wav # persistent whisper-server and Kokoro worker versus one-shot processes
swift run daisy-check --mic [plain] [clip.wav] # the app's audio engine on the real microphone; with a clip, checks Daisy does not interrupt itself
```

The focused tests use a small standalone Swift runner because the installed Command Line Tools do not ship XCTest. Tests exit nonzero on failure. They cover persisted corrections, idempotency, deletion/retrieval, query escaping, scope boundaries, symlink exclusion, disabled/unknown tools, malformed responses, local-model checks, and cancellation/timeouts. The smoke test creates only synthetic files, task drafts and preferences in a temporary folder, generates local speech, transcribes it, and writes measurements under `.runtime/benchmark-*.json`.

To compare models with your normal apps running:

```sh
bash scripts/download-models.sh qwen3.5:2b
# Start Daisy, or keep scripts/serve-model.sh running in another terminal.
swift run daisy-check qwen3.5:2b
swift run daisy-check qwen3.5:4b
```

Change the model tag in Settings and select Save & reconnect. No automatic model substitution occurs. Measurements and limitations are recorded in [validation](docs/VALIDATION.md). Architecture and rationale are in the [decision log](docs/DECISIONS.md).

## Troubleshooting

- **Engine offline / model missing:** run `bash scripts/download-models.sh`, then Save & reconnect. Use `bash scripts/serve-model.sh` to see startup errors. Another process on 11435 can prevent startup.
- **No speech recognized:** click Record, speak, then Finish. Check the input meter and the microphone shown in Settings. macOS may choose a display or headset microphone; use the sound input settings shortcut to choose your preferred device.
- **Microphone denied:** System Settings → Privacy & Security → Microphone → Daisy. Launch the `.app`, not the bare binary, to ensure the usage description is present. An ad-hoc rebuilt app may need permission again; stable distribution signing is future work.
- **Voice model missing:** check the absolute paths in Settings. `config.example.json` shows the format. Bundle defaults are generated at build time; saved user settings take precedence.
- **Old/custom runtime paths:** saved settings take precedence over bundle defaults. If you saved a path under Documents, update it to the installed `Runtime` location. Moving this repository does not affect the new installed model paths. Keep the memory database unless you intend to erase memories.
- **macOS asks for the microphone again after every install:** the build was signed ad hoc. Run `bash scripts/make-signing-identity.sh` once, reinstall, and allow the microphone one last time. If codesign reports `errSecInternalComponent`, macOS is asking (or asked) whether codesign may use the key: choose Always Allow.
- **Signature check fails under Documents/iCloud:** install from `dist/Daisy.zip` with `bash scripts/install-app.sh`. Build-time signing/verification happens in a temporary staging directory; the user Applications folder avoids File Provider adding forbidden bundle metadata.
- **Folder removed or permissions changed:** choose it again. Revoking access cancels current work and disables opening stale results from that folder.
- **First speech/model request slow:** weights and Metal kernels may need a cold start. Subsequent timings vary with memory pressure and the fanless Air's thermal state.

Closing the window quits Daisy and stops a server it started. A server started separately in a terminal remains yours to stop with Ctrl-C. No personal messages or account changes were used during development.
