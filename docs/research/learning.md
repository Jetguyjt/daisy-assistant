# Learning without /remember

Checked 2026-09-25 against Hermes 0.21.0 at `~/.hermes/hermes-agent` and Daisy at the Hermes/ACP commit.

The goal: Daisy picks things up while I use it. A nickname for someone turns into the right contact when I say "text them." "Email" means Gmail. It reads my files, does research, and splits big jobs across several agents at once.

## What Hermes already does

Most of this ships in Hermes and is already turned on in `~/.hermes/config.yaml`. All of it is in the `hermes-acp` toolset Daisy talks to.

| Feature | What it does | Setting |
| --- | --- | --- |
| Background review (`agent/background_review.py`) | After a turn, a forked copy of the agent re-reads the conversation and saves anything worth keeping to memory or skills. No `/remember` needed | `memory.nudge_interval: 10` user turns |
| Memory + user profile | `MEMORY.md` and `USER.md`, loaded into every session | about 2,200 + 1,375 characters |
| Self-written skills | Writes and fixes its own `SKILL.md` files for repeated workflows. The review prompt treats corrections and "remember this" as skill signals | `skills.creation_nudge_interval: 15`; curator prunes weekly |
| `session_search` | Searches and summarizes past conversations | on |
| `delegate_task` | Subagents with their own context, run in parallel | 3 at once, depth 1, `subagent_auto_approve: false` |

At the time of checking, Hermes had seen 9 user messages across 5 sessions, so the every-10-turns review had never run. The one saved preference so far came from an explicit request. Lowering `nudge_interval` is the cheapest first step: `scripts/hermes.d/10-memory.sh` sets it to 3.

The count is user turns in a row without a memory write (`agent/turn_context.py`). Any memory write in a turn, "remember that" included, starts it over.

## Nickname → contact

1. "Text Bubba." No alias is known, so Daisy searches Contacts and asks "Robert Lukose?"
2. I say yes. The alias `bubba → Robert Lukose, +1…` gets saved then and there.
3. Next time it resolves the name directly. It still shows the approval card before sending, because a wrong guess texts the wrong person.

`USER.md` is too small for dozens of nicknames, so they get a table of their own. How it's built:

- `daisy-contacts`, a small Swift helper inside Daisy.app, reads Contacts with `CNContactStore` and prints names, phone numbers and email addresses as JSON. Nothing else from the address book leaves it.
- `contacts_search` (a read) checks `$HERMES_HOME/daisy/aliases.json` first, then the helper. `contacts_alias_save` (a write, so it's a card: "Remember “Bubba” means Robert Lukose (+1 555…)") adds to the table. Both are typed tools in `hermes/daisy/tools/contacts.py`.
- The guard keeps the shell and file tools out of `$HERMES_HOME/daisy/`, so a nickname only changes through that card.
- The Contacts prompt belongs to Daisy: hermes-acp is Daisy's child and the helper is hermes-acp's, so macOS asks on Daisy's behalf. Run from Terminal, it asks for Terminal instead.

`holographic` was the other candidate. It isn't a fit for this (below).

## "Email means Gmail"

Hermes's memory handles this as it is. Corrections are the strongest signal ("no, Gmail" should stick after one time). Repeated choices are weaker; saving after about three identical picks seems right.

## The Learned feed

How Hermes writes its memory (`tools/memory_tool_store.py`), and so how Daisy's Undo and Edit have to:

- Every add, replace and remove takes an exclusive lock on a separate `USER.md.lock` (or `MEMORY.md.lock`), reads the file again inside it, and writes the whole file back through a temp file and a rename. Daisy does the same, so neither loses the other's write.
- Before a replace or remove, Hermes checks the file is exactly its entries joined by `\n§\n`: stripped, none empty, none longer than the file's limit. If not, it refuses and saves a `.bak`. Daisy only ever writes that form, and leaves a file alone that isn't in it.
- The limits are 2,200 (`MEMORY.md`) and 1,375 (`USER.md`) characters, counted the way Python counts, in code points.
- Each session copies memory into its system prompt once, at the start. An Undo reaches the next chat, not the one that's open.
- Hermes knows who's writing (`tools/skill_provenance.py`: `background_review` in the review fork, `assistant_tool` in a normal turn) but doesn't write it down. The Daisy plugin does: `hermes/daisy/learned.py` wraps each memory call and appends a line to `$HERMES_HOME/daisy/learned.jsonl` with the origin, the new text, and the whole entry a replace or remove took out. It's `tool_execution` middleware instead of a `post_tool_call` hook because only middleware sees the file before and after; the hook gets the model's `old_text`, often a fragment.

The feed in the Memory tab shows what came from the review, plus anything that showed up with no log line (added outside a chat), newest first, with Undo, Edit and Keep. What was there before the feed first looked isn't news. What happens in the conversation doesn't show, since I watched it happen.

## One store

The old SQLite memories (`memory.sqlite`, from `/remember` and "Remember that…") move into Hermes's files once: `USER.md` first, `MEMORY.md` when that's full, the newest first when there isn't room for all. A note becomes its text; a named one becomes "Response style: Keep it short". Nothing gets cut to fit. What doesn't fit stays in the old store, which the on-device fallback still reads, and is listed. From then on, with Hermes as the brain, the old store takes no new memories.

## Reading my computer and research

Hermes already has file read/search, terminal and web tools. For learning over time, the plan is a Hermes cron job over folders I pick (say `~/projects`) that keeps a short "where I left off" note per repo.

Two rules:

- Anything learned from files, web pages or mail is marked by source. It can't overwrite facts I told it directly, so a page can't plant a fake memory.
- File contents go to OpenAI, so only folders I pick get indexed.

## Parallel agents

`delegate_task` already runs 3 at a time. The model is hosted, so each subagent costs almost no RAM on this Mac, unlike the local model that fought Chrome for memory. What's missing is Daisy showing each one in the HUD. I haven't checked yet how ACP reports child agents.

## Risks

- **Silent wrong memories.** `memory.write_approval` is off. Instead of approval pop-ups, use a Learned feed with one-tap undo.
- **Two memory stores drifting.** The old SQLite store and Hermes's files will drift apart. Hermes should be the only one.
- **Usage.** Every background review and subagent counts against the ChatGPT subscription's limits.

## holographic: what I found

Read its source (`plugins/memory/holographic/`) on 2026-09-28. Not turned on.

- **What it is.** One of Hermes's external memory providers, picked with `memory.provider` (one at a time). It doesn't replace `MEMORY.md` and `USER.md`; it adds a SQLite store next to them (`$HERMES_HOME/memory_store.db`), two tools, `fact_store` (add, search, probe, related, reason, contradict, update, remove, list) and `fact_feedback`, and each turn it searches the facts for my message and puts the top five into the context.
- **How it stores facts.** One row per fact: the text (unique), a category (`user_pref`, `project`, `tool`, `general`), tags, a trust score and a few counters. FTS5 for keyword search, plus a vector per fact (holographic reduced representations) for "everything about this person" and "facts linking these two" queries. Those need numpy in Hermes's venv; without it they fall back to keyword search. Results are ranked by keyword rank, word overlap and vector similarity, times trust.
- **Name resolution is thin.** Entities come from regexes: two or more capitalized words ("Robert Lukose"), anything in quotes, and "X aka Y". A single name like Bubba or Dad isn't an entity unless it's quoted. There's an `aliases` column, but nothing ever writes it, so "Bubba aka Robert Lukose" makes two entities that share one fact, not a nickname that resolves to a person. No phone numbers or emails, and nothing checks against Contacts.
- **Trust isn't about the source.** Every fact starts at 0.5 and the model moves it with `fact_feedback` (+0.05 helpful, −0.10 not). Below 0.3 a fact stops coming back. Nothing records where a fact came from, so it doesn't give me "a web page can't overwrite what I told it."
- **It misses the background review.** The review fork runs with `skip_memory=True`, so what Hermes learns on its own only goes into `MEMORY.md` and `USER.md`. Memory adds made in a chat get copied in as facts, but replaces and removes don't, so the copies drift, and an Undo in the Learned feed would leave the fact behind.
- **The guard would stop every call.** `fact_store` isn't a typed tool and "store" reads as a write, so today each call, searches included, would stop at a card. It would need a rule of its own.
- **`auto_extract`** (off by default) saves whole messages that match "I prefer/like/use…", "my favorite … is…" or "we decided…", up to 400 characters. Too crude to turn on.

Switching would take `hermes config set memory.provider holographic`, numpy in Hermes's venv, a guard rule for `fact_store`, and teaching the Learned feed and the origin log about a second store that already drifts from the first. For nicknames it's the wrong tool anyway: "text Bubba" needs one exact person with a number, confirmed once and shown on a card, which the alias table does. Where it could help is facts that don't fit in 2,200 + 1,375 characters, and memory isn't close to full yet. Staying on the built-in memory.

## Not checked yet

- Whether the review picks up something said in passing, live: `daisy-check --recall`
- The Contacts permission prompt, and the first "text Bubba" end to end
- How the `imessage` skill sends
- What ACP sends for subagent activity
