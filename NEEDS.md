# NEEDS: feat/orchestrator

Changes this branch needs in files it doesn't own. The wiring patch below was applied to a scratch copy of this branch and built there (`swift build`, no new warnings) before it was written down; the delegation check was run through `daisy-check` in that copy against the stand-in agent. None of it has run against the real Hermes.

## 1. Run the delegation check first

Apply the patch in section 2 (or just its `Check.swift` hunk, one line), then:

```
swift build --product daisy-check
.build/debug/daisy-check --delegation              # watches 90 s after the delegation
.build/debug/daisy-check --delegation --wait 150   # longer window, 5 to 600 s
```

- Starts the real `~/.hermes/hermes-agent/venv/bin/hermes-acp` (or `--agent PATH`) from the home folder with `DAISY_SESSION=1`, the way the app does, so the guard plugin and persona are loaded.
- Cost: `/tools` (Hermes answers it itself, no model call), then one short turn asking for a single tiny `delegate_task`: the subagent spells a random 8-character code word backwards, no tools. So one or two parent model calls and one subagent call.
- Every approval request is declined. Nothing is sent or changed.
- It watches every message on the session until 90 s after the delegation and at least 10 s after the turn ends. Takes about 100 s when nothing comes back, less otherwise.
- It opens one ACP session, which shows up in Hermes's own session list (same as `--hermes`).

What it prints: the session id, then a timeline with times from the moment the prompt went out (tool calls with their state and output, runs of message text, bookkeeping updates counted by kind with "(after the turn)" marked, declined approvals, the turn's end), then one `VERDICT:` line.

| Verdict | Exit | Meaning | Then |
| --- | --- | --- | --- |
| `NEVER CAME BACK` | 1 | delegate_task was dispatched, the turn ended, and only bookkeeping (usage, title) arrived in the window | What the research expects. Keep the persona's "Don't use delegate_task here" line; background work goes through worker sessions (this branch) |
| `CAME BACK` | 0 | After the turn ended, the subagent's answer (the reversed word) arrived on the session, or Hermes started talking again on its own (the line says whether the word was in it) | ACP does deliver background results. The persona line can go; worth showing subagents in the HUD |
| `CAME BACK IN THE TURN` | 0 | The answer was in delegate_task's own output, so it ran synchronously (Hermes falls back to that when it can't deliver later or its pool is full) | Results come back, but the turn waits for the subagent |
| `UNCLEAR` | 3 | The reversed word appeared only in Hermes's own reply during the turn, so it may have reversed it itself | Run it again |
| `DELEGATION FAILED` | 3 | The delegate_task call itself failed; its output is printed. Most likely the guard's chat allowlist blocked it | Nothing was tested. Allow delegate_task for one run, or check `hermes tools` |
| `NOT CALLED` | 3 | Hermes didn't call delegate_task. The prompt lifts the persona's rule for that one message, but the persona may still win | Run again; if it keeps refusing, run once with a temporary `$HERMES_HOME/daisy-persona.md` without that line, then delete it |
| `NOT OFFERED` | 3 | `/tools` doesn't list delegate_task in Daisy sessions | Nothing to test |
| `COULD NOT RUN` | 2 | Hermes missing, not signed in, or not answering; the line says which | Fix that first |

## 2. Wire the app (AppModel, ContentView, DaisyApp, Check.swift)

One patch for all four files, against this branch's base (`4b3076e`). From the repo root:

```
sed -n '/^```diff$/,/^```$/p' NEEDS.md | sed '1d;$d' | git apply
```

What it changes, and why:

**`Sources/DaisyApp/AppModel.swift`**
- `@Published var approvals: [AgentApproval]` becomes `lazy var approvalQueue: ApprovalQueue`. The queue declines a card nobody answers at 54 s (Hermes gives up at 60) and takes it down, drops a turn's cards when the turn ends (`withdraw(from: .conversation)` in `run`, `stop` and both turn endings), shows job cards tagged with their job, and only ever answers allow-once. `answer(_:allow:)` now goes through it; the old code fell back to any allowing option (which could be "allow for session") when there was no allow-once.
- Decisions for the transcript move to `approvalQueue.onDecision`: "Approved: …", "Declined: …", and new "No answer, so declined: …".
- `lazy var jobs: JobsModel`, plus `announce(_:)`: job news goes in the transcript as an assistant line tagged "Background job · name", and is read aloud when Daisy is idle, or after the current turn (`pendingAnnouncements`, flushed in `finishTurn`).
- `@Published var plan: AgentPlan?`. The turn loop uses `backend.stream(...)` instead of `backend.send(...)` so it gets `.plan` updates; everything else in the loop is unchanged. Reset when a turn starts, on New conversation and on a backend switch.
- `park(_:)`, from `approvalQueue.onPark`: when a card from a voice turn has waited 3 s, Daisy stops the half-spoken reply, says "I've left that for you to approve.", ends the voice turn (no follow-up listening) and, in wake-word mode, goes back to standby while the turn keeps waiting. For that, standby may be armed while `phase == .awaitingApproval` (`canStandBy`) and `observe(power:)` feeds the standby endpointer in that phase too. "Hey Daisy, …" then starts a new turn, which cancels the waiting one, and its card counts as no.
- `/job <goal>` in the composer starts a background job instead of a turn.
- `saveSettings()`: a new backend withdraws every card and hands the jobs model the new backend (running jobs on the old one stop).
- `shutdown()`: `await jobs.shutdown()` before `backend.shutdown()`, so job sessions lose their roles.json entry while Hermes is still up.

**`Sources/DaisyApp/ContentView.swift`**
- A JOBS tab (`square.stack.3d.forward.dottedline`) after TASKS, showing `JobsView`.
- The transcript shows `ApprovalQueueList` (every waiting card, job ones labelled "JOB · NAME · NEEDS YOUR OK", with a countdown) instead of `ForEach(model.approvals) { ApprovalCard … }`; the scroll-to-bottom follows the queue.
- Telemetry: `PlanView` under ACTIVITY when the turn has a plan, and a JOBS readout ("1 running · 1 waiting", amber "A job needs your OK") that opens the tab.

**`Sources/DaisyApp/DaisyApp.swift`**: Jobs joins the ⌘1… tab shortcuts after Tasks, so Memory through Settings move up one number.

**`Sources/DaisyCheck/Check.swift`**: the `--delegation` dispatch.

After this, `ApprovalCard` in `WorkspaceViews.swift` is unused (`QueuedApprovalCard` replaces it) and can go.

Known rough edges in the parking wiring (compiles, not run): if the card is answered while standby is mid-utterance, that capture isn't discarded until the next rest; in hands-free and manual modes the line is spoken but there's no standby to go back to, so Talk starts a new request (which cancels the waiting turn).

```diff
--- a/Sources/DaisyApp/AppModel.swift
+++ b/Sources/DaisyApp/AppModel.swift
@@ -75,8 +75,14 @@
     @Published var appVisible = true
     /// Where the agent stands: starting, ready, waiting on setup, or offline.
     @Published var agentLink: AgentLink = .starting
-    /// Decisions the agent is waiting on during this turn.
-    @Published var approvals: [AgentApproval] = []
+    /// Approval cards waiting on the user, from the conversation and from background jobs.
+    lazy var approvalQueue: ApprovalQueue = makeApprovalQueue()
+    /// Background jobs, each in a Hermes session of its own.
+    lazy var jobs: JobsModel = makeJobs()
+    /// The agent's plan for the current (or last) turn, when it keeps one.
+    @Published var plan: AgentPlan?
+    /// Job news that came in mid-turn, said once Daisy is free.
+    private var pendingAnnouncements: [String] = []
     /// The listening mode to return to when always-listening is switched off.
     private var quietMode: ListeningMode = .handsFree
     private lazy var backend: AgentBackend = makeBackend()
@@ -270,10 +276,53 @@
 
     /// Answers a pending approval from its card. Sends and deletes only ever get "once".
     func answer(_ request: AgentApproval, allow: Bool) {
-        let option = allow ? (request.options.first { $0.kind == .allowOnce } ?? request.options.first { $0.allows })
-                           : request.options.first { $0.kind == .rejectOnce }
-        let backend = self.backend
-        Task { await backend.resolve(approval: request.id, optionID: option?.id) }
+        approvalQueue.answer(request.id, allow: allow)
+    }
+
+    private func makeApprovalQueue() -> ApprovalQueue {
+        let queue = ApprovalQueue { [weak self] id, option in
+            guard let self else { return }
+            await self.backend.resolve(approval: id, optionID: option)
+        }
+        queue.onDecision = { [weak self] item, outcome in
+            guard let self, item.source == .conversation else { return }
+            switch outcome {
+            case .allowed: self.decisions.append("Approved: " + item.approval.title)
+            case .declined, .overflow: self.decisions.append("Declined: " + item.approval.title)
+            case .expired: self.decisions.append("No answer, so declined: " + item.approval.title)
+            case .withdrawn: break
+            }
+        }
+        queue.onPark = { [weak self] line in self?.park(line) }
+        return queue
+    }
+
+    private func makeJobs() -> JobsModel {
+        let jobs = JobsModel(backend: backend as? JobBackend, approvals: approvalQueue)
+        jobs.onAnnouncement = { [weak self] note in self?.announce(note) }
+        return jobs
+    }
+
+    /// Job news goes in the transcript, and is said out loud once Daisy isn't busy.
+    private func announce(_ note: JobAnnouncement) {
+        messages.append(ConversationItem(role: "assistant", text: note.text, detail: "Background job · " + note.job.name))
+        guard config.speakResponses else { return }
+        if phase == .idle { readAloud(note.text) } else { pendingAnnouncements.append(note.text) }
+    }
+
+    /// A card from a voice turn has waited a few seconds: say so, and stop holding the voice for
+    /// it. The turn keeps waiting until the card is answered or times out; a new request cancels
+    /// it, which counts as no.
+    private func park(_ line: String) {
+        guard voiceTurn else { return }
+        voiceTurn = false
+        endVoice()
+        let token = generation
+        Task {
+            try? await audio.speak(line, voice: config.naturalVoice ?? "bm_george", speed: config.speechRate ?? 1) { }
+            guard generation == token, phase == .awaitingApproval else { return }
+            if listeningMode == .wakeWord { armStandby() }
+        }
     }
 
     var linkLabel: String {
@@ -285,6 +334,17 @@
         let text = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
         let files = composer.attachments
         guard !text.isEmpty || !files.isEmpty else { return }
+        if text.hasPrefix("/job ") {
+            // Runs in the background, in a session of its own; the conversation carries on.
+            guard files.isEmpty else { notice = "Background jobs don't take attachments yet."; return }
+            guard let job = jobs.start(String(text.dropFirst(5))) else {
+                notice = usesHermes ? "That job couldn't start." : "Background jobs need Hermes. Switch the brain in Setup."
+                return
+            }
+            composer.text = ""; composerExpanded = false
+            messages.append(ConversationItem(role: "assistant", text: "Started in the background: " + job.goal, detail: "Background job"))
+            return
+        }
         // Hermes gets up to 100 KB; the on-device model's small context keeps it at 4,000 bytes.
         if usesHermes {
             guard text.utf8.count <= HermesBackend.maxRequestBytes else { notice = "Please keep each message under 100 KB."; return }
@@ -339,7 +399,7 @@
         messages.append(ConversationItem(role: "user", text: text, attachments: attachments.map(\.name)))
         if messages.count > 100 { messages.removeFirst(messages.count - 100) }
         phase = .thinking
-        activity = []; liveText = ""; approvals = []; decisions = []; feed = SpeechFeed()
+        activity = []; liveText = ""; approvalQueue.withdraw(from: .conversation); decisions = []; plan = nil; feed = SpeechFeed()
         let started = Date()
         let backend = self.backend
         let direct = text.hasPrefix("/find ")
@@ -355,9 +415,13 @@
                     let receipt = try await session.execute(.init(name: "search_files", arguments: ["query": .string(String(text.dropFirst(6)))]))
                     receipts = [receipt]; liveText = receipt.output.summary
                 } else {
-                    for try await event in backend.send(AgentPrompt(text: text, attachments: attachments)) {
+                    for try await update in backend.stream(AgentPrompt(text: text, attachments: attachments)) {
                         try Task.checkCancellation()
                         guard generation == token else { return }
+                        guard case .event(let event) = update else {
+                            if case .plan(let next) = update { plan = next }
+                            continue
+                        }
                         switch event {
                         case .text(let delta):
                             if firstText == nil { firstText = Date().timeIntervalSince(started) }
@@ -367,13 +431,10 @@
                         case .tool(let tool):
                             track(tool)
                         case .approval(let request):
-                            approvals.append(request); phase = .awaitingApproval
+                            approvalQueue.add(request, from: .conversation, voice: voiceTurn); phase = .awaitingApproval
                         case .approvalResolved(let id, let allowed):
-                            if let request = approvals.first(where: { $0.id == id }) {
-                                decisions.append((allowed ? "Approved: " : "Declined: ") + request.title)
-                            }
-                            approvals.removeAll { $0.id == id }
-                            if phase == .awaitingApproval { phase = approvals.isEmpty ? .working : .awaitingApproval }
+                            approvalQueue.settled(id, allowed: allowed)
+                            if phase == .awaitingApproval { phase = approvalQueue.items(from: .conversation).isEmpty ? .working : .awaitingApproval }
                         case .receipts(let more):
                             receipts += more
                         case .finished:
@@ -385,7 +446,7 @@
                 guard generation == token else { return }
                 let report = receipts.compactMap(\.output.files).last
                 if let report { recentSearch = report }
-                currentStep = nil; settleActivity(.done); approvals = []
+                currentStep = nil; settleActivity(.done); approvalQueue.withdraw(from: .conversation)
                 let answer = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
                 let total = Date().timeIntervalSince(started)
                 lastReply = ReplyTiming(firstText: firstText, total: total)
@@ -408,7 +469,7 @@
                 case .offline(let reason): agentLink = .offline(reason); connected = false
                 default: if error is URLError { connected = false }
                 }
-                currentStep = nil; settleActivity(.failed); approvals = []
+                currentStep = nil; settleActivity(.failed); approvalQueue.withdraw(from: .conversation)
                 if !liveText.isEmpty {
                     messages.append(ConversationItem(role: "assistant", text: liveText, detail: "Cut off", decisions: decisions))
                     liveText = ""
@@ -510,15 +571,17 @@
             if !busy { audio.stopEngine() }
         }
     }
+    /// Standby can be armed while idle, or while a turn waits on a card after `park`.
+    private var canStandBy: Bool { !busy || phase == .awaitingApproval }
     private func armStandby() {
-        guard listeningMode == .wakeWord, !busy, !standby else { return }
+        guard listeningMode == .wakeWord, canStandBy, !standby else { return }
         standbyWork?.cancel()
         standbyWork = Task { [weak self] in
             guard let self else { return }
             guard await self.audio.requestMicrophone() else {
                 self.notice = "Allow Daisy in System Settings → Privacy & Security → Microphone to use the wake word."; return
             }
-            guard !Task.isCancelled, self.listeningMode == .wakeWord, !self.busy else { return }
+            guard !Task.isCancelled, self.listeningMode == .wakeWord, self.canStandBy else { return }
             do { try self.audio.startEngine() } catch { self.notice = error.localizedDescription; return }
             self.endpointer = SpeechEndpointer(settings: .standby)
             self.standby = true
@@ -547,7 +610,7 @@
         case .speaking:
             guard listeningMode != .manual, audio.echoCancellation else { return }
             if bargeEndpointer.observe(power: power, duration: duration) == .speechStarted { bargeIn() }
-        case .idle:
+        case .idle, .awaitingApproval:
             guard standby else { return }
             switch endpointer.observe(power: power, duration: duration) {
             case .speechStarted: audio.beginCapture(preRoll: 1.0)
@@ -640,6 +703,8 @@
         phase = .idle; currentStep = nil
         let again = voiceTurn && listeningMode != .manual
         voiceTurn = false
+        // Job news that came in during the turn goes first; the follow-up can wait.
+        if !pendingAnnouncements.isEmpty { readAloud(pendingAnnouncements.joined(separator: " ")); pendingAnnouncements = []; return }
         if again { beginListening(purpose: .followUp) } else { rest() }
     }
     /// Back to whatever idle means for the current mode: standby with the mic open, or mic off.
@@ -688,7 +753,7 @@
         }
         generation = UUID(); work?.cancel(); work = nil
         standbyWork?.cancel(); standbyWork = nil
-        endVoice(); approvals = []
+        endVoice(); approvalQueue.withdraw(from: .conversation)
         // Whatever was already written stays in the transcript, marked as cut off.
         if !liveText.isEmpty {
             messages.append(ConversationItem(role: "assistant", text: liveText, detail: "Stopped", decisions: decisions))
@@ -705,7 +770,7 @@
         rest()
     }
     func clearConversation() {
-        stop(clearNotice: true); messages = []; recentSearch = nil; reviewResults = [:]; expiredReviews = []; activity = []
+        stop(clearNotice: true); messages = []; recentSearch = nil; reviewResults = [:]; expiredReviews = []; activity = []; plan = nil
         let backend = self.backend
         Task { await backend.newSession() }
         rest()
@@ -843,7 +908,9 @@
                 let old = backend
                 Task { await old.shutdown() }
                 backend = makeBackend(); backendSignature = signature
-                messages = []; activity = []
+                messages = []; activity = []; plan = nil
+                approvalQueue.withdrawAll()
+                jobs.use(backend as? JobBackend)
             }
             connected = false; connectWhenAllowed()
             if config.speakResponses { Task { await speechWorker.warmUp() } }
@@ -857,6 +924,9 @@
         browserWork?.cancel(); await chrome.disconnect()
         await speechWorker.stop()
         await speech.shutdown()
+        // Jobs first, so their sessions lose the job mark before Hermes goes.
+        await jobs.shutdown()
+        approvalQueue.withdrawAll()
         await backend.shutdown()
     }
 }
--- a/Sources/DaisyApp/ContentView.swift
+++ b/Sources/DaisyApp/ContentView.swift
@@ -8,6 +8,7 @@
 
     private static let tabs: [(id: String, label: String, symbol: String)] = [
         ("Assistant", "DAISY", "circle.hexagongrid"), ("Tasks", "TASKS", "checklist"),
+        ("Jobs", "JOBS", "square.stack.3d.forward.dottedline"),
         ("Memory", "MEMORY", "square.stack.3d.up"), ("Connections", "LINKS", "point.3.connected.trianglepath.dotted"),
         ("Capabilities", "TOOLS", "square.grid.2x2"), ("Settings", "SETUP", "slider.horizontal.3")
     ]
@@ -24,6 +25,7 @@
                         switch model.tab {
                         case "Memory": MemoryView(model: model)
                         case "Tasks": TasksView(model: model)
+                        case "Jobs": JobsView(jobs: model.jobs, approvals: model.approvalQueue)
                         case "Connections": ConnectionsView(model: model)
                         case "Settings": SettingsView(model: model)
                         case "Capabilities": CapabilitiesView(model: model)
@@ -231,7 +233,7 @@
                     if !model.liveText.isEmpty || [.thinking, .searching, .working, .responding, .awaitingApproval].contains(model.phase) {
                         LiveReply(text: model.liveText, step: model.currentStep ?? model.phase.rawValue).id("live")
                     }
-                    ForEach(model.approvals) { request in ApprovalCard(model: model, request: request).id(request.id) }
+                    ApprovalQueueList(queue: model.approvalQueue)
                     if setupShowing { SetupPanel(model: model) }
                     Color.clear.frame(height: 1).id("bottom")
                 }
@@ -240,7 +242,9 @@
             .scrollIndicators(.never)
             .onChange(of: model.messages.count) { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) } }
             .onChange(of: model.liveText) { proxy.scrollTo("bottom", anchor: .bottom) }
-            .onChange(of: model.approvals.count) { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) } }
+            .onReceive(model.approvalQueue.$items.map(\.count).removeDuplicates()) { _ in
+                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
+            }
         }
         .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.035),
                                      .init(color: .black, location: 0.965), .init(color: .clear, location: 1)],
@@ -311,6 +315,10 @@
             }
             .padding(16)
             rule
+            if let plan = model.plan, !plan.entries.isEmpty {
+                PlanView(plan: plan).padding(16)
+                rule
+            }
             VStack(alignment: .leading, spacing: 12) {
                 readout("LINK", model.agentLink.isReady ? (model.agentDetail ?? model.linkLabel) : linkText.capitalized, color: model.agentLink.isReady ? HUD.ice : linkColor)
                 readout("REPLY", replyText)
@@ -319,6 +327,7 @@
                 readout("FOLDER", model.selectedFolder?.lastPathComponent ?? "None") { model.chooseFolder() }
                 readout("MEMORY", "\(model.memories.count) saved") { model.tab = "Memory" }
                 readout("TASKS", "\(model.tasks.filter { $0.status != "done" }.count) open") { model.tab = "Tasks" }
+                JobsReadout(jobs: model.jobs) { model.tab = "Jobs" }
                 readout("CHROME", model.chromeConnected ? "Connected" : "Not linked", color: model.chromeConnected ? HUD.ice : HUD.steel) { model.tab = "Connections" }
             }
             .padding(16)
--- a/Sources/DaisyApp/DaisyApp.swift
+++ b/Sources/DaisyApp/DaisyApp.swift
@@ -35,7 +35,7 @@
                 Button("Choose search folder…") { model.chooseFolder() }.keyboardShortcut("o", modifiers: [.command, .shift])
             }
             CommandGroup(before: .sidebar) {
-                ForEach(Array(["Assistant", "Tasks", "Memory", "Connections", "Capabilities", "Settings"].enumerated()), id: \.offset) { index, tab in
+                ForEach(Array(["Assistant", "Tasks", "Jobs", "Memory", "Connections", "Capabilities", "Settings"].enumerated()), id: \.offset) { index, tab in
                     Button(tab == "Connections" ? "Links" : tab == "Capabilities" ? "Tools" : tab) { model.tab = tab }
                         .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                 }
--- a/Sources/DaisyCheck/Check.swift
+++ b/Sources/DaisyCheck/Check.swift
@@ -8,6 +8,7 @@
         let runtime = LocalRuntime()
         do {
             let args = CommandLine.arguments
+            if args.dropFirst().first == "--delegation" { exit(await DelegationCheck.run(Array(args.dropFirst(2)))) }
             if args.dropFirst().first == "--hermes" {
                 // Live run through the same ACP bridge the app uses. Approvals are always declined,
                 // so a check can never send, delete or change anything.
```

## 3. For daisy-guard: roles.json as written

`WorkerRoles` in `Sources/DaisyCore/Jobs.swift`, used by `HermesBackend.openWorker` and `closeWorker`:

- Path: `${HERMES_HOME:-~/.hermes}/daisy/roles.json`. HERMES_HOME comes from the environment Daisy starts hermes-acp with, then Daisy's own environment, then `~/.hermes`. The app passes only `DAISY_SESSION=1`, so in practice it's `~/.hermes/daisy/roles.json` unless HERMES_HOME is set. `HermesBackend.Settings.rolesFile` overrides it; the tests always point it at a temp folder.
- Content: `{"sessions":{"<acp session id>":"worker"},"version":1}` (keys sorted). Rewritten whole each time: a `.roles-<uuid>.tmp` file in the same folder, then `rename(2)`. Folder 0700, file 0600. Entries Daisy didn't write (other ids or roles) are kept as they are.
- Added right after `session/new` returns and before the job's first `session/prompt`. If the file can't be written, the job doesn't start.
- Removed only after Hermes has ended the job's turn. A cancelled job gets `session/cancel` and up to 6 s to stop; if it doesn't, the entry stays until hermes-acp stops or Daisy quits, when all of Daisy's entries are removed.
- The conversation's session is never listed. Jobs use the same cwd (home) and toolset as the conversation; only the entry tells them apart.
- After a crash, entries for dead job sessions can be left behind. Treating them as workers is harmless.
- Daisy never leaves the file half-written, so a file that doesn't parse means something else wrote it.

## 4. Docs, when merging (optional)

- `docs/ARCHITECTURE.md`, "The bridge": `HermesBackend` runs the conversation plus up to two job sessions on one hermes-acp, routes every update and approval request by `sessionId`, declines approvals nobody answers (queue at 54 s, backend backstop at 57 s), downgrades any allow-always answer to allow-once, and gives plan updates through `stream(_:)`. Job sessions are listed in roles.json.
- `docs/ARCHITECTURE.md`, "Tests": JobsTests (two sessions interleaving, job approvals, card timeout, max two jobs, roles.json, plan updates, ledger, and the delegation check's verdicts) and `swift run daisy-check --delegation`.
- `docs/ROADMAP.md`, "Orchestrator": the delegation live test and "Worker sessions … job ledger + jobs panel, speak results when done" once merged and run.

## 5. Not verified

- Nothing here ran against the real Hermes. Worker sessions, approvals from job sessions, plan updates and the delegation check are tested against scripted stand-ins that send what Hermes 0.21's `acp_adapter` sends.
- Plan updates only arrive when Hermes uses its `todo` tool (the adapter builds them from the tool's result), so most short turns have none.
- The app wiring compiles but hasn't been run.
- Not checked: whether one conversation plus two jobs ever queue behind Hermes's own background threads in its four-thread pool.
- Jobs start from the Jobs tab or `/job …`. Hermes can't start a Daisy job itself yet; that would need a plugin tool.
