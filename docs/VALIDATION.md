# Jarvis 0.3 validation — 2026-09-24 (local time)

## Environment and installed build

Actual local M3 MacBook Air, 24 GB unified memory, macOS 26.5.1, arm64. Swift 6.2.3 Command Line Tools, Ollama 0.34.4, whisper.cpp 1.9.4. Chrome 154.0.8037.57, Node 22.22.3, Chrome DevTools MCP 1.10.1. Kokoro-ONNX 0.6.1 in a separate Python 3.11 environment with downloaded Kokoro-82M ONNX weights and voice vectors.

Release compilation succeeded and the signed build was installed at `~/Applications/Jarvis.app`. `codesign --verify --deep --strict` passed. Packaging uses a temporary staging directory and ZIP because File Provider metadata under Documents can invalidate the signature.

## Automated verification

**30 focused tests passed, zero failures** with `swift run -c release jarvis-tests`.

Coverage includes explicit-memory persistence/corrections/deletion, lexical retrieval fallback, file scope and symlink boundaries, opaque references, schema validation, unknown/disabled/effectful capability blocking, independent-provider composition, duplicate-call reuse, cancellation, process timeout, bounded context, local-model verification, malformed model responses and non-leaking errors.

New checks exercise:

- Preparing a task causes no save. UI-equivalent commit persists it; duplicate/stale revisions cannot overwrite a newer edit. Invalid dates fail.
- Preparing a file causes no write. Commit creates exact text, and subsequent commits, path traversal, hidden names and symlink targets are rejected.
- A synthetic 40-tab browser fixture verifies that newly opened tab 41 remains discoverable, pagination works, unobserved IDs cannot be read and unsafe URL schemes/embedded credentials are rejected.
- A real subprocess JSON-RPC fixture verifies fragmented responses, request IDs, timeouts, cancellation and restart.

`swift run -c release jarvis-check --browser-metadata` also passed against the installed Chrome DevTools package: real MCP initialization and tool discovery, required read/navigation methods present, JavaScript and input methods disabled. This invoked **no browser tools**, did not connect to Chrome and did not access account pages.

## Real local-model smoke test

**9/9 checks passed** on Qwen 3.5 4B, using only synthetic fixtures. See [exact results and timings](benchmarks/v0.3-qwen3.5-4b.json).

| Request | Seconds | Verified result |
| --- | ---: | --- |
| Brief greeting | 9.47 | Short response |
| Find latest resume | 7.14 | Scoped search found synthetic fixture |
| Recall response length | 3.85 | Correct two-sentence preference |
| Send unavailable text | 4.56 | No send; unavailable stated |
| Read unavailable Calendar | 4.25 | No account access; unavailable stated |
| Calculate expression | 5.68 | Calculator receipt; 24.5 |
| Find and read file | 8.49 | Real search + read receipts; synthetic contents |
| Prepare essay task | 8.87 | Review card created; task store remained empty |
| Prepare Python file | 6.81 | Review card created; no file saved or executed |

The registry in this run included built-in, task, draft, and disconnected browser capabilities. Native app discovery/launch is compiled but is not part of this model smoke suite. The generation settings are temperature 0, thinking off, 16,384-token context and 512-token output cap. Loop bounds: eight model rounds, ten calls, 240 seconds and a 28,000-byte message/schema guard. Large requests can stop before completion and report that limit.

This is a small smoke suite, not a broad model-quality benchmark. Model prose still sometimes suggests imprecise setup instructions (for example an unspecified browser extension for Calendar). The actual available tools, review cards and receipts are authoritative. The browser wrapper uses the local Chrome DevTools process; no extension is required for Jarvis.

The historical 2B/4B reports predate the generic capability system. They are retained as development evidence, not presented as current-build performance comparisons.

## Voice and microphone

Kokoro synthesized “Find my latest resume.” in **2.65 seconds**; conversion and Whisper decoding returned that exact phrase, with decoding **0.38 seconds**. Those measurements use generated audio, not a live microphone. Longer synthesis and cold starts vary; voices are previewable because intelligibility is not a subjective quality rating.

The previous 0.2 build's Record/Finish flow was confirmed by the user: “Yes, it transcribed and answered.” The old macOS voice was then rejected for quality. Version 0.3 replaces that output with local Kokoro and five selectable voices; no cloud fallback exists. The new app's subjective voice quality and live-mic permission after re-signing await user confirmation. A local ad-hoc rebuild may prompt for microphone permission again.

## Desktop validation and current limits

- Installed 0.3 launched and visibly showed **LOCAL ENGINE READY**, version 0.3, Record controls, Tasks and Connections navigation. The Tasks screen rendered its empty state and Add task control.
- Opening Settings triggered repeated `Sky Computer Use native pipe closed before response` errors in the desktop automation tool. Other desktop inventory remained accessible. A one-second process sample showed Jarvis's main thread in the normal event loop, not a sampled hang; this does not prove every Settings control works. Voice preview, Connections UI and review-card Apply still need hands-on acceptance in this installed build.
- The installed process owns its dedicated Ollama child (verified parent PID). Earlier CLI lifecycle tests completed two startup/shutdown cycles; prior installed-app quitting also stopped its owned server. A forced engine-death/recovery test in the final GUI has not been completed.
- The user subsequently reported “I connected Chrome,” but the next observed Jarvis Connections screen still showed **Not connected** and a generic connection failure. No successful retry or browser workflow was observed before handoff. No claim is made of tested Gmail/Drive reading, live web research or document editing through Jarvis. A successful metadata handshake is not a successful authenticated workflow.
- No personal tasks, deadlines, documents, emails or messages were created, modified or sent during development tests. Persistent-state tests use disposable temporary directories.
- No battery/thermal endurance, offline network-isolation, extended accessibility, older macOS, or broad prompt-injection resistance test was performed. Local inference is configured, but this development app is not an OS-enforced sandbox.

Full Gmail/Drive APIs, arbitrary Mac application control, browser form editing/sending, code execution, existing-document edits, notifications/reminders, wake word, embeddings and proactive automation remain unimplemented. Task tracking, coding assistance and new-file drafts are useful bounded foundations, not those future capabilities.

## Spoken output and Chrome probe — 2026-09-24, later

The user reported that the voice said "asterisk asterisk" and spoke in disconnected fragments. Cause, verified with the installed phonemizer: the model answers in Markdown, espeak reads `**` as "asterisk asterisk" and `#` as "hash", a URL is spelled out, and a bold list header with no end punctuation runs into the next line. Three real Qwen 3.5 4B answers captured from the running server had bold on nearly every list item.

Two changes, both tested:

- `SpeechText.spoken` strips inline Markdown, turns headings, bullets, quotes and table rows into sentences, replaces fenced code with "Code is shown on screen.", reduces URLs to their host, drops emoji and the length-limit marker, and cuts at a sentence boundary within the 2,200-character synthesis limit. Six tests pin these rules; `jarvis-check --spoken` prints the result for any file.
- When read-aloud is on, the system prompt asks for plain spoken prose. On the same three questions the model then answered in one paragraph each at 64 to 78 tokens instead of 186 to 308.

Measured on this Mac with George: the cleaned Markdown answer produced 49.9 s of audio in 11.7 s; the plain-prose answer 24.0 s of audio in 6.5 s. Samples are in `.runtime/voice-previews/`. Whether the result *sounds* right is the user's call; nothing here rates naturalness.

The user also reported Chrome "doesn't work" in the build with the health probe. Observed process state: the adapter child was alive with an established socket to Chrome's debugging port, so Chrome had accepted the connection. The probe used a 4-second timeout and treated any failure, including a slow reply during model inference, as a lost connection, then stopped probing without stopping the child. `ChromeConnection.health` now returns alive, slow or lost; only a closed transport or exited child counts as lost, and the child is then stopped. The app skips the probe while the model is busy and polls every 10 seconds. A fixture test covers a slow adapter (stays connected) and one that exits (dropped and cleaned up). A live reconnect through the installed app has **not** yet been observed after this change.

## Chrome tab list — 2026-09-24, later still

With the probe fix installed the user reconnected Chrome and asked for Gmail. The connection held, the browser tools were offered, and `browser_tabs` failed with "Chrome returned no structured tab list." Cause, read from the installed adapter source (chrome-devtools-mcp 1.10.1): `structuredContent` is attached to a tool result only when the server runs with `--experimentalStructuredContent`, which defaults to off and was not passed. The page list was arriving as text lines under a `## Pages` heading and the parser only knew the structured form. This is very likely what the earlier "Not connected" screenshots were about too, since the connect step itself never parsed pages.

Fix: the adapter is now launched with that flag, and the parser also accepts the text form (`3: Title (https://url) [selected]`, optional `isolatedContext=` suffix, extension pages under their own heading ignored). A fixture test covers the text form through `browser_tabs` and `browser_open`, including a title that contains parentheses and a URL that contains parentheses. The check tool's `--browser-metadata` mode uses the same argument list as the app. A live tab read through the installed app after this change has **not** yet been observed.

## Hands-on acceptance

1. Settings → Voice → Preview voice; compare voices, then Save settings. Stop should interrupt playback/preparation.
2. Ask for a synthetic task or file draft and inspect the exact review card. Apply only if you intend to save it. Verify a saved task after restarting.
3. Connect Chrome in Connections only if you want the local browser process to access signed-in tabs. Approve Chrome's prompt, then test a public research page first.
4. Click Record, speak, and Finish; confirm the recognized request and answer. Rebuilt local signatures may need microphone permission again.
