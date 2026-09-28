# Roadmap

What's left to build. Short items here, the reasoning and findings behind them in `docs/research/`. Check things off when they're verified live, not when the code compiles. Decisions that get made along the way go in [DECISIONS.md](DECISIONS.md).

Research notes:
- [learning.md](research/learning.md): learning without /remember
- [mac-control.md](research/mac-control.md): Chrome and Mac control
- [google.md](research/google.md): Gmail, Drive and Calendar
- [voice.md](research/voice.md): a better voice
- [speech-in.md](research/speech-in.md): speech in, and Willow Voice
- [lukebuildsai.md](research/lukebuildsai.md): what his Jarvis does and how it compares

## Guard first

These gaps have to close before the tools below go live.

- [ ] Guard rules plus test lines for:
  - Drive `delete` / `share` / `upload`
  - `gmail modify`
  - Docs/Sheets writes
  - chrome-devtools `click` / `fill` / `press_key` / `evaluate_script`
  - `computer_use` `type` and `key(return)`
  - `javascript:` URLs

## Chrome and Mac control

- [ ] Plugin tools `chrome_tabs` / `chrome_focus` / `chrome_open` over AppleScript, registered into `hermes-acp`
- [ ] `jarvis-chrome` skill: reuse an open tab before opening a new one ("check my email" → Gmail tab)
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

## Voice out

- [ ] Kokoro quick fixes:
  - try `bf_emma` and a george/fable blend
  - A/B test playback with echo cancellation on and off
  - merge short fragments
  - expand numbers and abbreviations
- [ ] ElevenLabs: design an original British voice, stream v3 Conversational into the sentence feed, cancel on barge-in
- [ ] Local option: Qwen3-TTS 0.6B from ModelScope, measured on this Mac; Pocket TTS if it's too heavy

## Speech in

- [ ] SpeechTranscriber (macOS 26) as the main recognizer, with whisper-server kept as the fallback
- [ ] Silero VAD in place of the energy endpointer
- [ ] openWakeWord `hey_jarvis` so Whisper doesn't run on every pause
- [ ] Willow stays a push-to-talk typing aid; keep its `autoMuteAudio` off

## Learning without /remember

- [ ] Make Hermes's background review run more often (`memory.nudge_interval` is 10 user turns; try 3)
- [ ] "Learned" feed in the Memory tab with undo/edit for anything Hermes saved on its own
- [ ] One memory store: move the old SQLite memories into Hermes and stop writing to both
- [ ] Contacts tool (`CNContactStore`) that Hermes can call, plus an alias table (nickname → contact, learned the first time I confirm who I meant)
- [ ] Try the `holographic` memory plugin for aliases and facts that won't fit in `USER.md`
- [ ] Opt-in folder indexing: a Hermes cron job that writes a "where I left off" note per repo in folders I pick
- [ ] Show running subagents (`delegate_task`) in the HUD
- [ ] Recall check in `jarvis-check`: teach facts on day one, ask on day seven, plus a correction case and a "you don't know that" case

## Integrations still open

- [x] Install the `hermes/jarvis` approval plugin
- [ ] iMessage: `imsg` CLI, permissions, contact mapping (overlaps with the Contacts item)
- [ ] Reminders and Notes CLIs (`remindctl`, `memo`)
- [ ] Specialist agents on cron (inbox triage overnight, repo digests), in the spirit of lukebuildsai's setup

## Voice loop and app

- [ ] Run the full voice loop live on Hermes: wake word from across the room, barge-in over speakers, follow-up
- [ ] Find out why `ollama serve` / `whisper-server` outlived the app once
