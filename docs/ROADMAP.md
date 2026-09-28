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
- [ ] Typed plugin tools for risky actions (`gmail_send`, `drive_share`, `drive_delete`, `imsg_send`, `calendar_write`); block the same actions from `terminal` / `execute_code`
- [ ] Guard loads in every Hermes process (cron, gateway), not just `DAISY_SESSION`; fails closed if it throws
- [ ] Allowlists per role, enforced by the plugin (chat, worker read-only, cron pre-approved)
- [ ] Taint: after reading mail/web/files, new recipients, URLs or memory writes need a card
- [ ] Approval queue: no answer = no, card removed on timeout, voice loop freed
- [ ] Rules plus test lines for:
  - Drive `delete` / `share` / `upload`
  - `gmail modify`
  - Docs/Sheets writes
  - chrome-devtools `click` / `fill` / `press_key` / `evaluate_script`
  - `computer_use` `type` and `key(return)`
  - `javascript:` URLs
  - camelCase MCP names

## Orchestrator

Notes: [orchestrator.md](research/orchestrator.md)

- [ ] Test live: does a background `delegate_task` over ACP ever return its result? Until it does, tell Hermes not to use it in Daisy sessions
- [ ] Worker sessions: `session/new` per background job (max 2–3), route updates by session ID, job ledger + jobs panel, speak results when done
- [ ] Fix or patch ACP so delegation results come back (read `completion_queue`, or run delegations synchronously)
- [ ] `hermes gateway` as a LaunchAgent: cron, Kanban, Telegram/iMessage from my phone
- [ ] Daisy shows cron output (`~/.hermes/cron/output/`) and the Kanban board
- [ ] Budget: cheaper `delegation.model`, poll usage windows, pause background work around 80%, add a fallback provider
- [ ] Launch at login (`SMAppService.mainApp`); push-to-talk on battery
- [ ] Later, if 24/7 matters: gateway on a home box or VPS with its own device-code login (never copy `auth.json`)

## Chrome and Mac control

- [ ] Plugin tools `chrome_tabs` / `chrome_focus` / `chrome_open` over AppleScript, registered into `hermes-acp`
- [ ] `daisy-chrome` skill: reuse an open tab before opening a new one ("check my email" → Gmail tab)
- [ ] `computer_use` into ACP sessions through a plugin tool (keeps Hermes's hard-blocks); check how its approvals behave over ACP
- [ ] Try `chrome-devtools-mcp --autoConnect` in `mcp_servers` and count the Chrome consent prompts
- [ ] Auto-connect the old Chrome adapter at launch for the local fallback, or retire it
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
- [ ] Switch Kokoro to `af_heart` (or a heart/bella 70/30 blend) today
- [ ] Hosted American female voice: Cartesia "Jacqueline" (Pro $5), or OpenAI "marin"; needs its own API key in the Keychain
- [ ] Local: design the voice with Qwen3-TTS 1.7B VoiceDesign, then clone from a reference clip
- [ ] Later: train an openWakeWord model for the new name on Colab
- [x] Internal rename: bundle ID, targets, `hermes/daisy`, Application Support folder, repo (verified 2026-09-27: clean build and 74 tests, Daisy.app installed as `com.local.daisy.desktop` and launched with its memories, settings and Hermes session carried over, live `daisy-check --hermes` answered, GitHub repo renamed to daisy-assistant)

## Voice out

- [ ] Kokoro quick fixes:
  - try `af_heart` if the name changes, `bf_emma` / a george-fable blend if it stays Daisy
  - A/B test playback with echo cancellation on and off
  - merge short fragments
  - expand numbers and abbreviations
- [ ] ElevenLabs: design an original British voice, stream v3 Conversational into the sentence feed, cancel on barge-in
- [ ] Local option: Qwen3-TTS 0.6B from ModelScope, measured on this Mac; Pocket TTS if it's too heavy

## Speech in

- [ ] SpeechTranscriber (macOS 26) as the main recognizer, with whisper-server kept as the fallback
- [ ] Silero VAD in place of the energy endpointer
- [ ] openWakeWord `hey_daisy` (trained on Colab) so Whisper doesn't run on every pause
- [ ] Willow stays a push-to-talk typing aid; keep its `autoMuteAudio` off

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
- [ ] Find out why `ollama serve` / `whisper-server` outlived the app once
