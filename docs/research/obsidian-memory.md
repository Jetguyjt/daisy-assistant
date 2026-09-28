# Obsidian as long-term memory

Checked 2026-09-28 against Hermes 0.21 and Obsidian's docs. Read-only. Obsidian isn't installed yet and there's no vault.

## What I want

Two layers, both filled in by Daisy automatically, and both editable by me.

- **My brain.** A normal Obsidian vault I use every day for my own notes. It only holds things useful to me: people, projects, meetings, decisions, dates, tasks. Daisy's writes have to fit my own folders and templates. No confidence scores or source junk in my notes.
- **Daisy's brain.** Context that's good for Daisy but not for me: where each fact came from, why two notes got linked, how sure it is, what a new fact replaced, open questions, and patterns in how I work. Hidden unless I want to look.

Example: "Had a meeting with John today. We pushed the launch back two weeks because the designs aren't ready."

- **My brain gets:**
  - a meeting note with the decision
  - links to John and the project
  - a timeline line on the project page
- **Daisy's brain gets:**
  - why it picked that project
  - how sure it is
  - the source (this conversation)
  - that the new date replaced the old one, with the old date kept
  - "two weeks later" flagged if there was no launch date to count from

## What exists

- **Hermes `obsidian` skill** (`~/.hermes/skills/note-taking/obsidian`): read, search, create and link notes through the file tools. No schema, no people/project matching, no sources.
- **Hermes `llm-wiki` skill:** Karpathy's LLM Wiki pattern. Its "look around before writing" step is worth copying.
- **Memory provider plugins** (`agent/memory_provider.py`) get these hooks:
  - `prefetch` (context before a turn)
  - `sync_turn`
  - `on_session_end`
  - `on_memory_write`
  - their own tools
  - a system prompt block
- **The `holographic` plugin** already models facts with trust scores and entities with aliases.
- **The background review** can be given extra tools (`auxiliary.background_review.extra_tools`), so saving can run on its own after a turn.
- **Obsidian's options:**
  - **Obsidian CLI** (1.12+): has backlinks and link-updating renames, but needs the app running ([docs](https://obsidian.md/help/cli)).
  - **Local REST API plugin:** also needs the app running, but now refuses a write if the file changed in between ([repo](https://github.com/coddingtonbear/obsidian-local-rest-api)).
  - **Bases** (built in, 1.9+): timeline and "meetings with John" views with no plugin ([docs](https://help.obsidian.md/bases/syntax)).

## Design

### One vault, Daisy's brain in a hidden folder

- **My brain** is the vault itself.
- **Daisy's brain** is `.daisy/` inside it. Obsidian skips dot-folders in search, the graph and Bases. That's from community write-ups, not Obsidian's docs.
  - It syncs with the vault and stays plain Markdown.
  - I can show it with a "reveal hidden files" plugin, or read it in a "Daisy's reasoning" panel in the app.
- **A rebuildable index** at `~/.hermes/daisy_brain.db` (SQLite) holds:
  - full-text search
  - people and project aliases
  - a note-path ↔ id map
  - file hashes
- **Rejected:**
  - a second vault (splits sync and links)
  - hidden frontmatter (still clutters my notes when I edit them)
  - SQLite only (I couldn't read or fix it)

### Writing: plain files, never over my edits

- Daisy writes the Markdown files directly. That works whether Obsidian is open or not, and with any sync.
- Before writing, it re-checks the file's hash. If I changed the file in the meantime, it re-reads and re-plans.
- It uses the Obsidian CLI only if the app is already open, for renames that update links.

### My layer follows my conventions

- **First run:** Daisy scans my folders, templates and property names and writes `.daisy/conventions.md`: which note type goes in which folder, which template, and which folders are off-limits (journal, health). I approve it once.
- **Default properties** (only useful ones):

  | Note type | Properties |
  | --- | --- |
  | person | `type`, `aliases`, `role` |
  | project | `type`, `status`, `launch` |
  | meeting | `type`, `date`, `attendees: [[John]]`, `project: [[Launch]]` |

- **Decisions:** bullets under `## Decisions` in the meeting note.
- **Timeline:** dated bullets under `## Timeline` on the project page, or a Base view.
- **John's page doesn't get edited.** Meetings show up there through backlinks.

### Daisy's layer

One file per note it knows about, `.daisy/notes/<name>.md`, in the observation style [Basic Memory](https://github.com/basicmachines-co/basic-memory) uses:

```
---
about: "[[Projects/Launch]]"
---
- [claim] launch = 2026-10-24 | src: voice 2026-09-28 | conf: 0.7 | status: active | supersedes: c12
- [claim c12] launch = 2026-10-10 | status: superseded 2026-09-28
- [link-reason] John↔Launch: at 3 of the last 4 Launch meetings; "designs" matches Launch notes
- [open] "two weeks later" counted from 2026-10-10; confirm?
- [pattern] pushes launches when design lags
```

- **Old facts are marked replaced, never deleted**, and every fact keeps its source. That's [Graphiti](https://github.com/getzep/graphiti)'s idea.
- **Renames:** a file watcher catches them (content hash as the fallback) and updates `about:`. My notes stay untouched.

### Which layer a fact goes in

The test: would I ever write this down or look it up myself?

- **Yes → my brain.** People, projects, meetings, decisions, dates, tasks.
- **No → Daisy's brain.** Sources, reasons, confidence, history, open questions, patterns, aliases, and anything learned from email or the web that I haven't confirmed.

### When I write or edit things myself

- The watcher re-indexes anything I change.
- If I edit something Daisy wrote, that counts as a correction: it's trusted most, and it replaces Daisy's version.
- **Merge, don't duplicate.** Before making a note, Daisy looks for an existing one by title, alias and the index.
- **Daisy only adds** to my notes: appends, plus properties and sections it created. Rewriting or deleting my writing needs my OK.
- I can edit `.daisy/` files by hand, or just say "John's on Beta, not Launch". Both count as my corrections.

## Where the code lives

**A Hermes memory provider plugin**, `obsidian_brain`. It provides these tools:

| Tool | What it does |
| --- | --- |
| `vault_search` | Search the vault |
| `vault_read` | Read a note |
| `vault_upsert_note` | Create or update a note, using my template |
| `vault_link` | Link two notes |
| `vault_timeline_add` | Add a dated line to a project timeline |
| `brain_record` | Save a claim with source, confidence, what it replaces, open questions |
| `resolve_entity` | Match a name to candidate people or projects |

- **`prefetch`** adds a small bit of context before each turn (about 1.5k characters).
- **The background review** calls the tools after a turn, so saving is automatic.
- **Not checked:** whether a second memory provider runs alongside Hermes's built-in MEMORY.md (`memory_manager.py`).
- **Matching names:**
  - One clear match (≥ 0.8) links silently.
  - Two Johns, or two projects I share with John: Daisy asks, and saves the answer as an alias.
- **In the app:**
  - Learned feed with undo
  - approval cards
  - a "Daisy's reasoning" panel

## Guard

Follows the taint rule in [orchestrator.md](orchestrator.md).

- **Silent, with undo in the Learned feed:** writes from my own words in a turn that didn't read email, web pages or files.
- **Candidate only** (goes to `.daisy/`, needs a card before it reaches my notes): anything from a turn that read email, the web or files.
- **Always needs my OK:**
  - editing or deleting my own writing
  - renames and bulk changes
  - anything in off-limits folders
  - unclear name matches

## Reading it back

- `prefetch` finds people and project names in what I said. It adds each note's title, its latest few timeline or decision lines, and Daisy's active claims and open questions.
- Deeper reads go through the tools.
- Backlinks come from the local index, so Obsidian doesn't need to be open.
- Search starts as plain full-text. Local embeddings (FastEmbed) later if needed, so nothing is sent out just to build them.
- **Only the snippets it pulls in go to OpenAI.** Off-limits folders are never indexed.

## The John example, step by step

1. I say it out loud.
2. The turn read no email or web, so the review saves it on its own: a meeting, John, "delay two weeks", "designs not ready".
3. `resolve_entity("John")`: one John, at 3 of the last 4 Launch meetings. Confidence 0.85, so no question. With two Johns it would ask "Launch or Beta?"
4. `Meetings/2026-09-28 John.md` gets made from my meeting template, with attendee and project links and a Decisions bullet.
5. The Launch page gets a timeline line and a new `launch:` date. John's page shows the meeting through backlinks.
6. `.daisy/` gets:
   - the new launch claim, replacing the old one
   - why it linked Launch
   - the source
   - an open question if there was no earlier date
7. The Learned feed shows "Launch moved to Oct 24 · undo".

## Risks

- **No vault yet.** I have to install Obsidian and make one. A vault in iCloud Drive can hit evicted files and conflict copies; Obsidian Sync is safer. OneNote, Apple Notes, Day One and Goodnotes are on this Mac if I want to import later.
- **Hiding `.daisy/` isn't official.** Obsidian ignoring dot-folders is community knowledge, not in its docs.
- **Silent wrong saves** are the main danger. Undo and the taint rule are the fix.
- **Usage.** Every save counts against ChatGPT usage.
- **Basic Memory is a pre-release.** Copy its format, don't depend on it.

## Effort

About 2–3 weeks part-time, estimated:

| Piece | Estimate |
| --- | --- |
| Conventions scan, schema, templates, Bases | 1 day |
| Plugin skeleton, index, watcher, rename tracking | 3 days |
| Safe writes, merge/append logic | 2 days |
| Extraction, name matching, replacements | 3 days |
| Guard + approval cards | 1–2 days |
| Learned feed and reasoning panel in the app | 2 days |
| Tests | 2 days |

## What I have to do

1. Install Obsidian and make a vault (Obsidian Sync or local, not iCloud Drive).
2. Pick the folders Daisy should never read.
3. Approve `conventions.md` once.
