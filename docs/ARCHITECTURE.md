# Architecture

Daisy is the face and the voice. Hermes Agent is the agent runtime. OpenAI, through Hermes's ChatGPT/Codex subscription sign-in, is the reasoning model. Daisy doesn't know or care which model Hermes uses.

```text
┌───────────────────────────── this Mac ──────────────────────────────────┐
│                                                                          │
│  Daisy.app (SwiftUI)                                                     │
│    HUD, transcript, approval queue (cards count down; no answer = no)    │
│    JOBS tab (background jobs, cron output)                               │
│    mic → Silero → "hey daisy" → Apple speech (Whisper fallback)          │
│    Kokoro worker → speakers, text shown as it's spoken                   │
│         │                                                                │
│    AppModel ─► AgentBackend ─┬─ HermesBackend ─ ACP over stdio ─┐        │
│                              └─ LocalBackend (optional Ollama)  │        │
│                                                                 ▼        │
│  hermes-acp: one conversation session + up to 2 job sessions             │
│    (job sessions listed in ~/.hermes/daisy/roles.json)                   │
│    Hermes: tool loop, sessions, memory files, skills, MCP, sign-in       │
│    Daisy plugin (hermes/daisy):                                          │
│      guard ── every tool call: run, card, or block (every process)       │
│      typed tools ─┬─ chrome_*  → your Chrome (AppleScript)               │
│                   ├─ gmail_*, calendar_*, drive_* → Google APIs          │
│                   ├─ computer_* → other apps (cua-driver)                │
│                   └─ contacts_* → daisy-contacts (Contacts)              │
│      persona, learned-memory log                                         │
│                                                                          │
│  hermes gateway (optional, launchd): cron jobs, same plugin and guard    │
│    (read-only) → ~/.hermes/cron/output → shown in Daisy                  │
└─────────────────────────────────┬────────────────────────────────────────┘
                                  ▼
                    OpenAI (ChatGPT/Codex subscription)
```

## What runs where

Local: the Daisy app, speech-to-text (Apple's on-device recognizer, whisper.cpp as the fallback), text-to-speech (Kokoro), the wake word, Hermes itself, its tools (file search, terminal, skills), Chrome and Contacts lookups, other-app control through cua-driver, its session database and memory files, and anything in the optional local backend.

Remote: whatever Hermes sends OpenAI for a turn. That is the request, the conversation so far in that session, Hermes's system prompt (including its memory snapshot and the Daisy persona), and the results of tools it ran for that request, including email headers, calendar events or a screenshot when a tool fetched them. Gmail, Calendar and Drive calls go from this Mac to Google with the sign-in the `google-workspace` skill keeps in `~/.hermes/google_token.json`. File search results reach the model as names and paths, not folder dumps; the persona tells Hermes to pass only what the task needs. That is guidance to the model, not an enforced filter.

Offline, Daisy still runs: the HUD shows the agent as offline, `/find` still does a direct filename search in the chosen folder, and the on-device backend can be switched on in Setup.

## Why ACP

`hermes-acp` speaks the Agent Client Protocol: newline-delimited JSON-RPC over stdin/stdout. From Hermes 0.21's code:

- streamed answer text (`agent_message_chunk`), with reasoning sent separately (`agent_thought_chunk`) so Daisy can hide it
- typed tool events (`tool_call`, `tool_call_update`) with a title and kind
- permission requests (`session/request_permission`) that block the tool until answered
- `session/cancel`, and sessions stored in Hermes's database that `session/load` resumes after a restart

The alternative, Hermes's OpenAI-compatible API server, lives inside the gateway daemon and needs a port and a bearer key. It's worth adding only for scheduled jobs. Daisy never runs `hermes chat -q` or parses terminal output.

## The bridge

`DaisyCore/JSONRPCPeer.swift` is a two-way JSON-RPC peer on a child process: requests out, and notifications and requests in. It skips non-JSON lines on stdout and keeps stderr in a small ring for diagnosis.

`DaisyCore/HermesBackend.swift` turns ACP into `AgentEvent`s (`text`, `tool`, `approval`, `approvalResolved`, `finished`). It:

- starts `~/.hermes/hermes-agent/venv/bin/hermes-acp` from the home folder. A code repo as the working folder switches Hermes into coding mode.
- reads sign-in state from `initialize`. Hermes lists its provider as an auth method only when that provider's credentials resolve.
- resumes the saved session and rebuilds the transcript from Hermes's replay. An unknown id comes back as an empty success, so it checks for `models`/`modes` before trusting it.
- turns tool titles into plain phrases ("Searching your files", "Reading resume.pdf") and never shows raw commands or payloads.
- on Stop, sends `session/cancel`. If the prompt hasn't ended six seconds later, it abandons that session and opens a fresh one, because a stop can leave a Hermes session stuck.
- runs the conversation and up to two background jobs on the one `hermes-acp`, each job in a session of its own. Every update and approval request is routed by `sessionId`; anything for a session with no turn running is dropped, and its approval requests are declined.
- passes Hermes's plan (its `todo` list) through `stream(_:)`, which the HUD shows under Activity.

The UI only sees `AgentBackend`. `LocalBackend` wraps the original Ollama engine behind the same interface.

## Background jobs

`/job <goal>` or the JOBS tab starts a job. `JobsModel` runs two at a time and queues the rest, keeps them in `jobs.json` in the data folder (the last 50 finished ones), and says the result out loud when one finishes ("Your repo digest is ready: …"), after the current answer if Daisy is talking.

Each job gets its own Hermes session. Before its first prompt, the session is listed in `~/.hermes/daisy/roles.json` as a `worker`, so the guard lets it read and nothing else; the entry comes off once Hermes has ended the turn. If the file can't be written, the job doesn't run.

Hermes's own `delegate_task` isn't used in Daisy sessions: over ACP its background results never come back (`daisy-check --delegation`, checked 2026-09-27), so the persona tells Hermes not to call it.

## Always on

Hermes's gateway can run as a LaunchAgent (`scripts/hermes.d/60-gateway.sh`, opt-in) and runs scheduled jobs while Daisy is closed; the guard loads in it and treats every cron run as read-only. `DAISY_CRON=1` adds two read-only jobs: an overnight inbox triage and a morning digest of the repos listed in `~/.hermes/daisy/repo-digest.txt`. The JOBS tab reads `~/.hermes/cron/output/`, `cron/jobs.json` and `kanban.db` (read-only) through `AlwaysOnFeed`.

`BudgetMonitor` reads the 5-hour and weekly usage windows by running Hermes's Python with a short script around `agent/account_usage.py`, every ten minutes once Hermes is connected, and `JobsModel` holds new background jobs while either is at 80%. `PowerMonitor` (IOKit) turns the wake word's open mic into click to talk on battery, since an open mic keeps the Mac awake, and `LoginItem` (`SMAppService.mainApp`) opens Daisy at login.

Kanban workers run as other Hermes profiles (`hermes -p <name>`) and load only that profile's plugins, so the guard isn't there unless it's installed into that profile too. `HERMES_SAFE_MODE=1` skips every plugin, the guard included.

## Sign-in

Daisy never handles OpenAI credentials. `hermes auth add openai-codex` (or `hermes model` → ChatGPT or Codex Subscription) runs a device-code login in Terminal and stores tokens in `~/.hermes/auth.json`. Hermes refreshes them itself. Daisy only reads whether `initialize` reports a working provider, and shows the command when it doesn't. On first run Daisy waits for **Connect** instead of starting Hermes on its own, because starting Hermes can trigger a token refresh.

## Approvals

Hermes asks before dangerous shell commands and before file edits in its default mode. It doesn't ask before a skill sends a message or email or changes a calendar. The guard in `hermes/daisy/guard/` closes that gap. It's a `pre_tool_call` hook in every Hermes process (Daisy, CLI, gateway, cron), and for each tool call it lets it run, blocks it, or escalates it to Hermes's own approval gate, which reaches Daisy over ACP as a card:

- typed tools are judged by the risk they declare (below). Everything else goes through the command rules: `shell.py` reads a command the way bash will, `commands.py` knows what each program does, `code.py` reads `execute_code` and inline scripts, and `classify.py` covers the rest (MCP tools, browser and computer-use actions).
- chained commands are refused unless every step only reads this Mac, so a card always shows one action, in full. The shell route to something a typed tool does (a Gmail send through a skill's CLI) is refused and points at the tool.
- once a turn has read mail, web pages, files or messages, a memory write or a site the turn hasn't touched yet needs a card, and the card says what was read first (`taint.py`).
- roles (`roles.py`): background jobs only read; cron runs only read, plus actions pre-approved with fixed values in `~/.hermes/daisy/cron-allow.json`. Where nobody could answer a card (yolo, one-shot runs, webhooks) it's blocked instead.
- more than five cards in a minute in one session are refused, `javascript:` links always are, and so are writes to the guard's own files. Code can build a path at run time where the guard can't see it, so `guard/sealed.py` also wraps every tool call and undoes anything it added to `grants.json` or `cron-allow.json` (only `approval_grant` may add a standing OK).
- standing permissions (`guard/grants.py`): when the user says outright that Daisy can do something without asking, `approval_grant` asks once with a card, and after that yes the steps it names run without a card, for that request (same session and turn, three hours at most) or from now on. Only edits (typed write, own and ui tools, one app for clicks), scripts held to how they were when granted, and MCP edit tools can be covered; sends, shares, deletes and anything that reaches other people keep their card, and grants never apply in jobs, cron, yolo or one-shot runs. Each step under a grant is logged in `~/.hermes/daisy/grants.jsonl`.
- an error inside the guard blocks the call, because Hermes would otherwise run the tool.

In the app:

- each request is an amber card with the exact content and **Cancel / Send**. Daisy only ever answers "once"; an "always" answer is sent back as "once", and every card has its own rule key, so nothing is remembered as always-allowed.
- no answer is no. Hermes gives up after 60 seconds, so the card counts down, and at 54 seconds it's declined and taken down (the bridge declines at 57 as a backstop). Cards go as soon as their turn or job ends, and job cards say which job asked.
- in a voice turn, a card left waiting for 3 seconds frees the voice: Daisy says "I've left that for you to approve." and, in wake-word mode, goes back to listening while the card stays up.
- a conversation card a grant could cover also has **Yes to all like this**, which allows it and the rest like it until the request is done. Setup lists standing permissions with Revoke, and an answer's decisions say what ran without a card ("Done under your OK: …").

The guard reads commands; it is not a sandbox. `hermes/test_daisy_guard.py` and `hermes/test_daisy_guard_bypass.py` list what it stops and what it lets through. Install with `bash scripts/setup-hermes.sh`. The plugin also adds the Daisy persona as a system-prompt section in Daisy sessions; `$HERMES_HOME/daisy-persona.md` replaces it without touching code.

## Memory

Personal memory belongs to Hermes, so it survives model changes. Hermes keeps `~/.hermes/memories/USER.md` (about the user) and `MEMORY.md` (its notes), and its `session_search` tool finds earlier conversations. The Memory tab shows both files. Changes go through Daisy ("Remember that…", "forget…"). ChatGPT's own memory is not available through this sign-in and isn't used.

Hermes also saves things on its own: every 3 turns (`memory.nudge_interval`, set by `scripts/hermes.d/10-memory.sh`) a background review re-reads the conversation. The plugin logs every memory write and who made it (`$HERMES_HOME/daisy/learned.jsonl`), and the Memory tab's Learned feed lists what the review saved, with Undo and Edit. Those edit the files the way Hermes does: under the same `.lock`, re-read inside it, in its exact `\n§\n` form and within its size limits, so a running session never writes over them.

The old SQLite memory moves into Hermes's files once (`hermes-memory-move.json` in Daisy's data folder is the marker and the report); whatever doesn't fit stays there and is named. While Hermes is the brain nothing new is written to SQLite; the on-device backend still reads it.

Nicknames: `contacts_search` looks people up through `daisy-contacts` (a small helper inside Daisy.app that reads names, numbers and emails from Contacts), and `contacts_alias_save` remembers "Bubba means Robert Lukose" in `$HERMES_HOME/daisy/aliases.json` after a card. `imsg_send` resolves names the same way, saved nickname first, and refuses anything that isn't exactly one person and one number before a card is shown. Sends still show who they go to on their own card.

## Adding tools

Use Hermes, not Daisy code:

- procedures and workflows go in a Hermes skill (`~/.hermes/skills/<category>/<name>/SKILL.md`)
- read-only integrations can be an MCP server in Hermes's `config.yaml` (`mcp_servers`)
- anything that sends, shares, deletes, writes outside the Mac or drives another app's UI is a **typed tool** in the `hermes/daisy` plugin (below), never a shell command

### Typed tools

`hermes/daisy/registry.py` is the contract. A typed tool declares:

- `name` (snake_case) and `parameters` (JSON schema)
- `risk`: `read`, `own`, `write`, `send`, `delete`, `share` or `ui` (`own` is Daisy's own records, like the task list: no card unless the turn read outside content)
- `card(args)`: the approval text in full. First line is the title ("Send an email to Dad"); the rest is the exact content, every recipient, Cc, Bcc and attachment, never cut short
- `run(args)`: does the work and returns data

A new family is one file in `hermes/daisy/tools/` that calls `registry.add(TypedTool(...))` at import. The tools package imports every file in it, so nothing else changes. Typed tools register into the `hermes-acp` toolset, which is what Daisy's sessions get. `computer.py` wraps Hermes's built-in `computer_use` handler in-process, so its hard-blocks apply: `computer_look` reads and `computer_act` is `ui`, a card per call. A tool whose card raises `registry.Refused` is blocked with that reason instead of carded. `messages.py` (`imsg_send`) and `apple.py` (Reminders, Notes) run their CLIs as argv lists with every value as `--flag=value` or after `--`, and their `run()` only does what a card showed: it refuses a call the guard didn't card in the last five minutes, or one that would now do something else (a nickname, contact or attachment that changed after the card, or "tomorrow" once it's past midnight).

The guard decides from that metadata alone: `read` runs, anything else stops at a card, and every approval is for that one call only. It never parses a typed tool's arguments. A read tool's name says what it brings into the turn: a name with mail, message, doc, drive, file, calendar, web, page, tab, search, computer or screen in it marks the turn as having read outside content, and a name with open or navigate in it needs a card once that has happened.

### Hermes settings

Each feature that needs a Hermes setting adds a fragment, `scripts/hermes.d/NN-name.sh`. `scripts/setup-hermes.sh` installs the plugin and then sources every fragment in order. Fragments are idempotent and change settings with `config_set <key> <value>`, which only writes when the value differs and backs up `config.yaml` once per run. See `scripts/hermes.d/README.md`.

### Phrases

What the HUD says while a tool runs comes from `Sources/DaisyCore/ToolPhrases.swift` ("Searching your files", "Reading resume.pdf"). Add a phrase there when the default ("Working", or the tool name) reads badly.

## Tests

- `python3 scripts/gen-tests.py` rewrites `Tests/DaisyCoreTests/TestRunner.swift` from every `*Tests.swift` file, so a new test file needs no registration by hand.
- `for t in hermes/test_*.py; do python3 "$t"; done` runs the plugin checks (guard rules and the typed-tool contract).

- `swift run daisy-tests` runs the Hermes bridge against a scripted stand-in for `hermes-acp` that sends the same ACP messages the installed Hermes does:
  - streamed math answer
  - file-search tool events
  - iMessage approval, allowed and denied
  - cancel and recover
  - missing sign-in and missing provider
  - session resume
  - two sessions at once, job approvals, cards timing out, the two-job limit, roles.json and plan updates
- `swift run daisy-check --hermes "What is 37 × 18?" "Find my resume."` runs the same bridge against the real Hermes. It declines every approval, so a check can't send or delete anything.
- `swift run daisy-check --delegation` asks the real Hermes for one tiny background `delegate_task` and watches whether its result ever comes back.
- `swift run daisy-check --voice-ab` plays the same sentence plain, through the voice-processing engine and without it, for comparing by ear (`--render-only` just writes the WAVs to `.build/voice-ab`).
