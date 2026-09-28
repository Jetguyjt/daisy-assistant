# Needs from daisy-main (feat/guard)

Changes outside the guard's files, for merge time.

## Required

1. `Sources/DaisyApp/WorkspaceViews.swift`, `ApprovalCard`: drop `.lineLimit(14)` on the detail text (or put the detail in a `ScrollView` with a max height). The guard now sends every recipient, Bcc, attachment and the whole command, and the card must never cut them off. Today anything past line 14 is hidden.
2. `hermes/daisy/plugin.yaml`, `description`: it still says the plugin is "only active when Daisy starts Hermes ... CLI, cron and gateway sessions are untouched". The guard now loads in every Hermes process. Suggested: "Daisy desktop client: the Daisy persona and typed tools in Daisy sessions, and an approval guard in every Hermes process (Daisy, CLI, gateway, cron) for messages, email, calendar changes, shares, posts and deletes."
3. `hermes/daisy/__init__.py`, module docstring (lines 1-12): same fix. The guard runs everywhere; only the persona and typed tools need `DAISY_SESSION=1`. (I only touched `register()`.)
4. `scripts/setup-hermes.sh`, header comment (lines 2-4): same fix ("The plugin only acts in sessions Daisy starts" is no longer true for the guard).
5. `docs/ARCHITECTURE.md`, "Approvals" and "Typed tools": the guard is no longer Daisy-only, and untyped routes now go through `guard/commands.py` (shell), `guard/code.py` (execute_code and inline code) and `guard/classify.py` (everything else), then taint, roles and the card limit in `guard/policy.py`. Worth one line each on: chained commands are refused, the shell route to a typed tool is refused, workers only read, cron only reads plus `cron-allow.json`, a guard error blocks the call.
6. After merge, reinstall the plugin and restart anything already running (`hermes-acp`, the gateway) so every process picks up the new `register()`.

## For daisy-orchestrator (roles.json)

7. Write `${HERMES_HOME:-~/.hermes}/daisy/roles.json` atomically (write a temp file in the same folder, then rename). The guard keeps the last good copy if it catches a half-written file, but a missing file means "no workers".
8. Key it by the ACP session id from `session/new`. Hermes passes that id to the hook as `task_id` and it stays the same after compression rotates `session_id`; the guard checks both.
9. Remove a worker's entry when the job ends, so a reused id doesn't stay restricted.

## For whoever writes the typed tools

10. The shell route is refused and pointed at a typed tool when one with these names is registered (and its `check()` passes) in a Daisy process:
    `gmail_send` (also used for `gmail reply/forward`, `mail`, `sendmail`, `himalaya send` when `gmail_reply` / `gmail_forward` don't exist), `gmail_reply`, `gmail_forward`, `gmail_draft`, `gmail_modify`, `gmail_delete`, `calendar_write` (and `calendar_delete`), `drive_upload`, `drive_share`, `drive_delete`, `drive_write`, `sheets_write`, `docs_write`, `slides_write`, `contacts_write`, `imsg_send`. Until one exists, the shell command gets a card instead.
11. Taint and link checks go by typed tools' names, never their arguments: a read tool whose name has `mail`, `gmail`, `message`, `imsg`, `doc`, `drive`, `sheet`, `file`, `note`, `calendar`, `event`, `web`, `page`, `tab`, `chrome`, `browser` or `search` marks the turn as having read untrusted content; a tool whose name has `open`, `navigate`, `goto`, `visit` or `browse` (e.g. `chrome_open`) needs a card once the turn is tainted, and every string it's given is checked for `javascript:`. For other tools, values under `url`/`href`/`link`-style keys are checked.

## Optional

12. `hermes/daisy/persona.py`: one line so the model doesn't walk into refusals: "Run one terminal command at a time and write every value out (no `;`, `&&`, pipes into other commands, or `$(...)`); chained commands are refused so the card can show exactly what runs. When a typed tool exists for a send, share or delete, use it instead of a skill's CLI."
13. `Sources/DaisyApp/WorkspaceViews.swift`, `ApprovalCard.verb`: add "Share", "Upload", "Install", "Push", "Publish", "Type", "Press", "Click", "Save", "Empty" so those cards get a real button label instead of "Allow".
14. `.gitignore`: add `__pycache__/` (running the plugin tests or `hermes plugins doctor` creates them in `hermes/daisy/`).
