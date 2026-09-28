# Roadmap

What's left to build. Short items here, the reasoning and findings behind them in `docs/research/`. Check things off when they're verified live, not when the code compiles. Decisions that get made along the way go in [DECISIONS.md](DECISIONS.md).

Research notes:
- [learning.md](research/learning.md): learning without /remember
- [mac-control.md](research/mac-control.md): Chrome and Mac control
- [google.md](research/google.md): Gmail, Drive and Calendar
- [voice.md](research/voice.md): a better voice
- [speech-in.md](research/speech-in.md): speech in, and Willow Voice
- [lukebuildsai.md](research/lukebuildsai.md): what his Daisy does and how it compares
- [orchestrator.md](research/orchestrator.md): orchestrator design, always-on, guard stress test
- [persona.md](research/persona.md): American female voice and a new name

## Guard first

These gaps have to close before the tools below go live. Stress test in [orchestrator.md](research/orchestrator.md#guard-stress-test).

- [ ] Card must show exactly what runs: refuse chained commands (`;` `&&` `|` `$(`), and show every recipient, Bcc and attachment untruncated
  - guard side done: tests, and live on 2026-09-28 a chained `echo …; rm -f …` was refused (Hermes log: the terminal call returned the guard's message in 0.01s). The app's card scrolls instead of cutting off, not seen live yet
- [ ] Typed plugin tools for risky actions (`gmail_send`, `drive_share`, `drive_delete`, `imsg_send`, `calendar_write`); block the same actions from `terminal` / `execute_code`
  - guard side done (tests): the shell route is refused and points at the typed tool once it exists, and gets a card until then. The tools come with the Google and iMessage work
- [x] Guard loads in every Hermes process (cron, gateway), not just `DAISY_SESSION`; fails closed if it throws
  - tests, and `hermes plugins doctor --ci` registers the hook with and without `DAISY_SESSION=1`
- [x] Allowlists per role, enforced by the plugin (chat, worker read-only, cron pre-approved)
  - tests; workers come from `~/.hermes/daisy/roles.json`, cron's pre-approved list from `cron-allow.json`
- [x] Taint: after reading mail/web/files, new recipients, URLs or memory writes need a card
  - tests
- [ ] Approval queue: no answer = no, card removed on timeout, voice loop freed
  - built and tested against stand-ins; not seen live yet
- [x] Rules plus test lines for (tests: `hermes/test_daisy_guard_bypass.py`, 102 checks red on the old guard, all green now):
  - Drive `delete` / `share` / `upload`
  - `gmail modify`
  - Docs/Sheets writes
  - chrome-devtools `click` / `fill` / `press_key` / `evaluate_script`
  - `computer_use` `type` and `key(return)`
  - `javascript:` URLs
  - camelCase MCP names

## Orchestrator

Notes: [orchestrator.md](research/orchestrator.md)

- [x] Test live: does a background `delegate_task` over ACP ever return its result? Until it does, tell Hermes not to use it in Daisy sessions
  - 2026-09-27, `daisy-check --delegation`: dispatched in background mode at 3.5s, nothing came back in 94s. The persona keeps the "don't use delegate_task" line
- [ ] Worker sessions: `session/new` per background job (max 2–3), route updates by session ID, job ledger + jobs panel, speak results when done
  - built (max 2, roles.json marks them for the guard, `/job` or the JOBS tab); passes against scripted stand-ins, not run live yet
- [ ] Fix or patch ACP so delegation results come back (read `completion_queue`, or run delegations synchronously)
  - not doing it for now: Hermes 0.21 always runs top-level delegations in the background and ignores the model's `background` flag (`tools/delegate_tool.py`), so a plugin can't make them synchronous; only a patch to Hermes could. Daisy's own job sessions cover background work instead
- [ ] `hermes gateway` as a LaunchAgent: cron, Kanban, Telegram/iMessage from my phone
- [ ] Daisy shows cron output (`~/.hermes/cron/output/`) and the Kanban board
- [ ] Budget: cheaper `delegation.model`, poll usage windows, pause background work around 80%, add a fallback provider
- [ ] Launch at login (`SMAppService.mainApp`); push-to-talk on battery
- [ ] Later, if 24/7 matters: gateway on a home box or VPS with its own device-code login (never copy `auth.json`)

## Chrome and Mac control

- [ ] Plugin tools `chrome_tabs` / `chrome_focus` / `chrome_open` over AppleScript, registered into `hermes-acp`
  - built and tested with fakes (`hermes/test_daisy_chrome.py`; the tab script runs in jsc against a pretend Chrome). Not run against Chrome yet; the Automation prompt hasn't been seen
- [ ] `daisy-chrome` skill: reuse an open tab before opening a new one ("check my email" → Gmail tab)
  - `hermes/skills/daisy-chrome`, installed by `scripts/hermes.d/30-chrome.sh`; "check my email" is one `chrome_open(..., reuse=true)` so it never stops at a card
- [ ] `computer_use` into ACP sessions through a plugin tool (keeps Hermes's hard-blocks); check how its approvals behave over ACP
  - built (tests): `computer_look` / `computer_act`; over ACP the built-in approves everything (no callback), so the guard's card is the only yes. The shell route (`cua-driver call`) is refused now
  - not seen live: CuaDriver permissions, real captures and clicks
- [ ] Try `chrome-devtools-mcp --autoConnect` in `mcp_servers` and count the Chrome consent prompts
  - `scripts/hermes.d/31-chrome-devtools.sh` adds it only with `DAISY_CHROME_DEVTOOLS=1`; not tried
- [x] Auto-connect the old Chrome adapter at launch for the local fallback, or retire it
  - retired 2026-09-28 (mac-control.md, Decision): the Connections page now explains Chrome through Hermes; build and 160 tests pass without it
- [ ] Brave Search key for `web_search` if the free endpoints rate-limit
- [ ] Only if AppleScript falls short: MV3 extension + native messaging

## Google

- [ ] My part: Cloud project, APIs on, consent screen published to "In production", Desktop OAuth client
- [ ] `google-workspace` skill setup (`setup.py --services email,calendar,drive,docs,sheets`)
- [ ] "Check my email": unread headers + snippets, bodies only on request
- [ ] Keep `~/.hermes/google_token.json` out of every script and sweep

## New voice and name

Notes: [persona.md](research/persona.md)

- [x] Pick the name: DAISY, "Definitely An Intelligent System, Yeah" (decided 2026-09-27)
- [x] Rename what I see and hear: wake phrase + misspellings, display name, mic permission text, Hermes persona, UI strings, README (verified 2026-09-27: wake-phrase tests incl. misspellings pass, Daisy.app launched showing "Hey Daisy" standby; saying it live is still Josh's to try)
- [x] Switch Kokoro to `af_heart` (or a heart/bella 70/30 blend) today (see Voice out below)
- Not now: a hosted voice (Cartesia "Jacqueline", OpenAI "marin") or Qwen3-TTS VoiceDesign. Kokoro stays until I say otherwise
- [ ] Later: train an openWakeWord model for the new name on Colab
- [x] Internal rename: bundle ID, targets, `hermes/daisy`, Application Support folder, repo (verified 2026-09-27: clean build and 74 tests, Daisy.app installed as `com.local.daisy.desktop` and launched with its memories, settings and Hermes session carried over, live `daisy-check --hermes` answered, GitHub repo renamed to daisy-assistant)

## Voice out

- [x] `af_heart` by default, plus an optional Heart + Bella blend (`af_heart:0.7,af_bella:0.3`); every English Kokoro voice stays selectable
  - 2026-09-27: Heart and the blend render with the real model (`daisy-check --voice-ab --render-only`); a saved George switches to Heart once
- [ ] Kokoro quick fixes (built and tested, waiting on a listen):
  - A/B playback with echo cancellation on and off: `swift run daisy-check --voice-ab` (`--blind` shuffles it)
  - merge short fragments, even 200 ms joins, trimmed lead-in
  - numbers, money, times, dates and abbreviations read as words; no splits inside "3.5" or "e.g."
- Dropped: ElevenLabs and Qwen3-TTS. Daisy stays on local Kokoro

## Speech in

- [ ] SpeechTranscriber (macOS 26) as the main recognizer, with whisper-server kept as the fallback
  - built: Apple first, then whisper-server, then whisper-cli, with Apple set aside after repeated failures. Tests transcribed spoken clips with Apple; on 2026-09-28 `daisy-check --speech` found Apple's model not yet installed for that tool and Whisper took over correctly. Not heard live in the app yet
- [ ] Silero VAD in place of the energy endpointer
  - built in Swift from the ONNX weights (matches onnxruntime to 6e-7); `daisy-check --speech` on 2026-09-28 gave ~1.0 on speech and ~0.05 in the pause. Not tried on the live mic yet
- [ ] openWakeWord `hey_daisy` (trained on Colab) so Whisper doesn't run on every pause
  - hook ready: drop `hey_daisy.onnx` into `Runtime/speech` and it becomes the first stage. Training is mine to do, see [wake-word.md](wake-word.md)
- [x] Willow stays a push-to-talk typing aid; keep its `autoMuteAudio` off (written down in [wake-word.md](wake-word.md))

## Learning without /remember

- [ ] Make Hermes's background review run more often (`memory.nudge_interval` is 10 user turns; try 3)
- [ ] "Learned" feed in the Memory tab with undo/edit for anything Hermes saved on its own
- [ ] One memory store: move the old SQLite memories into Hermes and stop writing to both
- [ ] Contacts tool (`CNContactStore`) that Hermes can call, plus an alias table (nickname → contact, learned the first time I confirm who I meant)
- [ ] Try the `holographic` memory plugin for aliases and facts that won't fit in `USER.md`
- [ ] Opt-in folder indexing: a Hermes cron job that writes a "where I left off" note per repo in folders I pick
- [ ] Show running subagents (`delegate_task`) in the HUD
- [ ] Recall check in `daisy-check`: teach facts on day one, ask on day seven, plus a correction case and a "you don't know that" case

## Integrations still open

- [x] Install the `hermes/daisy` approval plugin (reinstalled under the new name 2026-09-27; `hermes plugins list` shows daisy enabled, jarvis gone)
- [ ] iMessage: `imsg` CLI, permissions, contact mapping (overlaps with the Contacts item)
- [ ] Reminders and Notes CLIs (`remindctl`, `memo`)
- [ ] Specialist agents on cron (inbox triage overnight, repo digests), in the spirit of lukebuildsai's setup

## Voice loop and app

- [ ] Run the full voice loop live on Hermes: wake word from across the room, barge-in over speakers, follow-up
- [x] Find out why `ollama serve` / `whisper-server` outlived the app once
  - likely cause, from the code (not reproduced): macOS has no parent-death signal, so a crash or force quit left them running, and the next launch used them on 11437/11435 without owning them. Fixed with a watchdog per child plus a sweep at launch; tested by killing a stand-in owner (its children were gone 0.2s later)
