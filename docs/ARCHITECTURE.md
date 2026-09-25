# Architecture

Jarvis is the face and the voice. Hermes Agent is the agent runtime. OpenAI, through Hermes's ChatGPT/Codex subscription sign-in, is the reasoning model. Jarvis doesn't know or care which model Hermes uses.

```text
┌──────────────────────── this Mac ─────────────────────────────────────────┐
│                                                                            │
│  Jarvis.app (SwiftUI)                                                      │
│    HUD, orb, transcript, approval cards                                    │
│    mic → wake word → whisper-server (STT)      Kokoro worker (TTS) → speakers
│         │                                            ▲                     │
│         ▼                                            │ sentences as they   │
│    AppModel ──► AgentBackend ──────────────────────── stream in            │
│                    │                                                       │
│                    ├─ HermesBackend ──stdio JSON-RPC (ACP)──► hermes-acp   │
│                    │                                            │          │
│                    │        Hermes: tool loop, sessions (state.db),        │
│                    │        memory (MEMORY.md, USER.md), skills, MCP,      │
│                    │        approvals, provider sign-in (auth.json)        │
│                    │                                            │          │
│                    └─ LocalBackend (optional): Ollama + Swift tool loop    │
│                                                                 │          │
└─────────────────────────────────────────────────────────────────┼──────────┘
                                                                  ▼
                                         OpenAI (ChatGPT/Codex subscription)
```

## What runs where

Local: the Jarvis app, speech-to-text (whisper.cpp), text-to-speech (Kokoro), the wake word, Hermes itself, its tools (file search, terminal, skills), its session database and memory files, and anything in the optional local backend.

Remote: whatever Hermes sends OpenAI for a turn. That is the request, the conversation so far in that session, Hermes's system prompt (including its memory snapshot and the Jarvis persona), and the results of tools it ran for that request. File search results reach the model as names and paths, not folder dumps; the persona tells Hermes to pass only what the task needs. That is guidance to the model, not an enforced filter.

Offline, Jarvis still runs: the HUD shows the agent as offline, `/find` still does a direct filename search in the chosen folder, and the on-device backend can be switched on in Setup.

## Why ACP

`hermes-acp` speaks the Agent Client Protocol: newline-delimited JSON-RPC over stdin/stdout. From Hermes 0.21's code:

- streamed answer text (`agent_message_chunk`), with reasoning sent separately (`agent_thought_chunk`) so Jarvis can hide it
- typed tool events (`tool_call`, `tool_call_update`) with a title and kind
- permission requests (`session/request_permission`) that block the tool until answered
- `session/cancel`, and sessions stored in Hermes's database that `session/load` resumes after a restart

The alternative, Hermes's OpenAI-compatible API server, lives inside the gateway daemon and needs a port and a bearer key. It's worth adding only for scheduled jobs. Jarvis never runs `hermes chat -q` or parses terminal output.

## The bridge

`JarvisCore/JSONRPCPeer.swift` is a two-way JSON-RPC peer on a child process: requests out, and notifications and requests in. It skips non-JSON lines on stdout and keeps stderr in a small ring for diagnosis.

`JarvisCore/HermesBackend.swift` turns ACP into `AgentEvent`s (`text`, `tool`, `approval`, `approvalResolved`, `finished`). It:

- starts `~/.hermes/hermes-agent/venv/bin/hermes-acp` from the home folder. A code repo as the working folder switches Hermes into coding mode.
- reads sign-in state from `initialize`. Hermes lists its provider as an auth method only when that provider's credentials resolve.
- resumes the saved session and rebuilds the transcript from Hermes's replay. An unknown id comes back as an empty success, so it checks for `models`/`modes` before trusting it.
- turns tool titles into plain phrases ("Searching your files", "Reading resume.pdf") and never shows raw commands or payloads.
- on Stop, sends `session/cancel`. If the prompt hasn't ended six seconds later, it abandons that session and opens a fresh one, because a stop can leave a Hermes session stuck.

The UI only sees `AgentBackend`. `LocalBackend` wraps the original Ollama engine behind the same interface.

## Sign-in

Jarvis never handles OpenAI credentials. `hermes auth add openai-codex` (or `hermes model` → ChatGPT or Codex Subscription) runs a device-code login in Terminal and stores tokens in `~/.hermes/auth.json`. Hermes refreshes them itself. Jarvis only reads whether `initialize` reports a working provider, and shows the command when it doesn't. On first run Jarvis waits for **Connect** instead of starting Hermes on its own, because starting Hermes can trigger a token refresh.

## Approvals

Hermes asks before dangerous shell commands and before file edits in its default mode. It doesn't ask before a skill sends a message or email or changes a calendar. `hermes/jarvis` is a small Hermes plugin that closes that gap for Jarvis sessions only (`JARVIS_SESSION=1`):

- a `pre_tool_call` hook escalates sends (iMessage, Mail, email CLIs), calendar writes, GitHub posts and deletes to Hermes's own approval gate. Denied, timed out or unanswered means blocked.
- Jarvis shows each request as an amber card with the exact content and **Cancel / Send**. It only ever answers "once". Nothing is remembered as always-allowed.
- it also adds the Jarvis persona as a system-prompt section. `$HERMES_HOME/jarvis-persona.md` replaces it without touching code.

The guard pattern-matches commands; it is not a sandbox. `python3 hermes/test_jarvis_guard.py` lists what it stops and what it lets through. Install with `bash scripts/setup-hermes.sh`.

## Memory

Personal memory belongs to Hermes, so it survives model changes. Hermes keeps `~/.hermes/memories/USER.md` (about the user) and `MEMORY.md` (its notes), and its `session_search` tool finds earlier conversations. The Memory tab shows both files read-only. Changes go through Jarvis ("Remember that…", "forget…"). The older SQLite memory remains for the local backend, with a button to hand each entry to Hermes. ChatGPT's own memory is not available through this sign-in and isn't used.

## Adding tools

Use Hermes, not Jarvis code:

- procedures and workflows go in a Hermes skill (`~/.hermes/skills/<category>/<name>/SKILL.md`)
- deterministic code, credentials or APIs go in an MCP server in Hermes's `config.yaml` (`mcp_servers`), or a Hermes plugin
- anything that sends, deletes or changes data outside the Mac also needs a guard rule in `hermes/jarvis` and a test line in `hermes/test_jarvis_guard.py`

Jarvis picks tools up with no changes. New tools only need a phrase in `HermesBackend.describeTool` when the default ("Working", or the tool name) reads badly.

## Tests

- `swift run jarvis-tests` runs the Hermes bridge against a scripted stand-in for `hermes-acp` that sends the same ACP messages the installed Hermes does:
  - streamed math answer
  - file-search tool events
  - iMessage approval, allowed and denied
  - cancel and recover
  - missing sign-in and missing provider
  - session resume
- `swift run jarvis-check --hermes "What is 37 × 18?" "Find my resume."` runs the same bridge against the real Hermes. It declines every approval, so a check can't send or delete anything.
