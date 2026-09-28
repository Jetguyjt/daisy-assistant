# Learning without /remember

Checked 2026-09-25 against Hermes 0.21.0 at `~/.hermes/hermes-agent` and Jarvis at the Hermes/ACP commit.

The goal: Jarvis picks things up while I use it. A nickname for someone turns into the right contact when I say "text them." "Email" means Gmail. It reads my files, does research, and splits big jobs across several agents at once.

## What Hermes already does

Most of this ships in Hermes and is already turned on in `~/.hermes/config.yaml`. All of it is in the `hermes-acp` toolset Jarvis talks to.

| Feature | What it does | Setting |
| --- | --- | --- |
| Background review (`agent/background_review.py`) | After a turn, a forked copy of the agent re-reads the conversation and saves anything worth keeping to memory or skills. No `/remember` needed | `memory.nudge_interval: 10` user turns |
| Memory + user profile | `MEMORY.md` and `USER.md`, loaded into every session | about 2,200 + 1,375 characters |
| Self-written skills | Writes and fixes its own `SKILL.md` files for repeated workflows. The review prompt treats corrections and "remember this" as skill signals | `skills.creation_nudge_interval: 15`; curator prunes weekly |
| `session_search` | Searches and summarizes past conversations | on |
| `delegate_task` | Subagents with their own context, run in parallel | 3 at once, depth 1, `subagent_auto_approve: false` |

At the time of checking, Hermes had seen 9 user messages across 5 sessions, so the every-10-turns review had never run. The one saved preference so far came from an explicit request. Lowering `nudge_interval` is the cheapest first step.

## Nickname → contact

The hard one, because nothing can read Contacts yet.

1. "Text Bubba." No alias is known, so Jarvis searches Contacts and asks "Robert Lukose?"
2. I say yes. The alias `bubba → Robert Lukose, +1…` gets saved then and there.
3. Next time it resolves the name directly. It still shows the approval card before sending, because a wrong guess texts the wrong person.

Needs a Contacts tool (`CNContactStore`, names plus phone/email only) that Hermes can call, and a real alias table. `USER.md` is too small for dozens of nicknames. The bundled `holographic` memory plugin (local SQLite, FTS5, entity resolution, trust scores) looks like the right fit but hasn't been tried.

## "Email means Gmail"

Hermes's memory handles this as it is. Corrections are the strongest signal ("no, Gmail" should stick after one time). Repeated choices are weaker; saving after about three identical picks seems right.

## Reading my computer and research

Hermes already has file read/search, terminal and web tools. For learning over time, the plan is a Hermes cron job over folders I pick (say `~/projects`) that keeps a short "where I left off" note per repo.

Two rules:

- Anything learned from files, web pages or mail is marked by source. It can't overwrite facts I told it directly, so a page can't plant a fake memory.
- File contents go to OpenAI, so only folders I pick get indexed.

## Parallel agents

`delegate_task` already runs 3 at a time. The model is hosted, so each subagent costs almost no RAM on this Mac, unlike the local model that fought Chrome for memory. What's missing is Jarvis showing each one in the HUD. I haven't checked yet how ACP reports child agents.

## Risks

- **Silent wrong memories.** `memory.write_approval` is off. Instead of approval pop-ups, use a Learned feed with one-tap undo.
- **Two memory stores drifting.** The old SQLite store and Hermes's files will drift apart. Hermes should be the only one.
- **Usage.** Every background review and subagent counts against the ChatGPT subscription's limits.

## Not checked yet

- How well `holographic` resolves names
- How the `imessage` skill sends
- What ACP sends for subagent activity
