import Foundation
import DaisyCore

/// Background jobs against a scripted stand-in for `hermes-acp` that keeps turns open across
/// sessions the way the real one does (it runs several sessions' turns at once), plus the
/// delegation check against a stand-in for each way delegate_task could behave.
final class JobsTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("jobs-\(UUID().uuidString)")
    var agent: URL { root.appendingPathComponent("fake-hermes-acp") }
    var probeAgent: URL { root.appendingPathComponent("fake-delegation-acp") }
    var rolesFile: URL { root.appendingPathComponent("hermes-home/daisy/roles.json") }
    var agentLog: URL { root.appendingPathComponent("agent.log") }
    var ledgerFile: URL { root.appendingPathComponent("jobs.json") }

    func setUp() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (url, script) in [(agent, Self.fixture), (probeAgent, Self.delegationFixture)] {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }
    func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func backend(approvalWindow: TimeInterval = 57) -> HermesBackend {
        HermesBackend(settings: .init(executable: agent, workingDirectory: root, sessionFile: root.appendingPathComponent("session"),
                                      environment: ["FAKE_ROLES": rolesFile.path, "FAKE_LOG": agentLog.path],
                                      rolesFile: rolesFile, approvalWindow: approvalWindow))
    }

    /// What the stand-in saw, one line per message: "prompt s-2 role=worker", "answer s-2 allow_once".
    private func agentSaw() -> [String] {
        ((try? String(contentsOf: agentLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func until(_ seconds: Double = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    private func expectSoon(_ seconds: Double = 5, file: StaticString = #filePath, line: UInt = #line, _ condition: () async -> Bool) async {
        if !(await until(seconds, condition)) { fail("Still waiting after \(seconds)s", file: file, line: line) }
    }

    /// A job's stream read in the background, so the test can act while it runs.
    private final class Listener: @unchecked Sendable {
        private let lock = NSLock()
        private var _text = ""
        private var _stop: String?
        private var _plans: [AgentPlan] = []
        private var _error: Error?
        var text: String { lock.withLock { _text } }
        var stop: String? { lock.withLock { _stop } }
        var plans: [AgentPlan] { lock.withLock { _plans } }
        var error: Error? { lock.withLock { _error } }
        init(_ stream: AsyncThrowingStream<AgentUpdate, Error>) {
            Task {
                do {
                    for try await update in stream {
                        lock.withLock {
                            switch update {
                            case .event(.text(let delta)): _text += delta
                            case .event(.finished(let reason)): _stop = reason
                            case .plan(let plan): _plans.append(plan)
                            default: break
                            }
                        }
                    }
                } catch { lock.withLock { _error = error } }
            }
        }
    }

    // MARK: Backend

    func testTwoSessionsInterleaveAndEachGetsItsOwnUpdates() async throws {
        let hermes = backend()
        _ = await hermes.connect()
        let worker = try await hermes.openWorker()
        expectEqual(worker, "s-2")
        let job = Listener(hermes.run(worker: worker, prompt: AgentPrompt(text: JobsModel.prompt(for: "interleave"))))
        await expectSoon { job.text == "A1" }
        // The conversation's turn arrives mixed in with the job's: pong, A2, done, then A3.
        var chat = ""
        for try await event in hermes.send("ping") { if case .text(let delta) = event { chat += delta } }
        expectEqual(chat, "pong done")
        await expectSoon { job.stop != nil }
        expectEqual(job.text, "A1A2A3")
        expectEqual(job.stop, "end_turn")
        await hermes.closeWorker(worker)
        await hermes.shutdown()
    }

    func testWorkerSessionIsMarkedBeforeItsFirstPromptAndUnmarkedAfter() async throws {
        try FileManager.default.createDirectory(at: rolesFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version": 1, "sessions": {"cron-7": "cron"}}"#.utf8).write(to: rolesFile)
        let hermes = backend()
        var chat = ""
        for try await event in hermes.send("hello") { if case .text(let delta) = event { chat += delta } }
        expectEqual(chat, "ok")
        let worker = try await hermes.openWorker()
        expectEqual(WorkerRoles(url: rolesFile).sessions(), ["cron-7": "cron", worker: "worker"])
        let job = Listener(hermes.run(worker: worker, prompt: AgentPrompt(text: JobsModel.prompt(for: "role"))))
        await expectSoon { job.stop != nil }
        // The stand-in read roles.json when the prompt arrived.
        expectEqual(job.text, "role=worker")
        await hermes.closeWorker(worker)
        expectEqual(WorkerRoles(url: rolesFile).sessions(), ["cron-7": "cron"])
        // The conversation is never listed.
        expectTrue(agentSaw().contains("prompt s-1 role=none"))
        let file = try JSONSerialization.jsonObject(with: Data(contentsOf: rolesFile)) as? [String: Any]
        expectEqual(file?["version"] as? Int, 1)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: rolesFile.deletingLastPathComponent().path)
        expectEqual(leftovers, ["roles.json"])
        await hermes.shutdown()
    }

    func testJobSessionsStopAtTwoAndStayOutOfTheChatList() async throws {
        let hermes = backend()
        let first = try await hermes.openWorker(), second = try await hermes.openWorker()
        do {
            _ = try await hermes.openWorker()
            fail("a third job session should be refused")
        } catch { expectTrue(error.localizedDescription.contains("2 jobs")) }
        let chats = await hermes.sessions()
        expectEqual(chats.map(\.id), ["s-1"])
        await hermes.closeWorker(first)
        let third = try await hermes.openWorker()
        expectEqual(third, "s-4")
        await hermes.closeWorker(second); await hermes.closeWorker(third)
        expectEqual(WorkerRoles(url: rolesFile).sessions(), [:])
        await hermes.shutdown()
    }

    func testAlwaysAllowIsAnsweredAsAllowOnce() async throws {
        let hermes = backend()
        let worker = try await hermes.openWorker()
        var asked: AgentApproval?
        var allowed: Bool?
        var text = ""
        for try await update in hermes.run(worker: worker, prompt: AgentPrompt(text: JobsModel.prompt(for: "approve"))) {
            switch update {
            case .event(.approval(let approval)):
                asked = approval
                await hermes.resolve(approval: approval.id, optionID: "allow_session")
            case .event(.approvalResolved(_, let yes)): allowed = yes
            case .event(.text(let delta)): text += delta
            default: break
            }
        }
        expectEqual(asked?.title, "Send an iMessage to Dad")
        expectEqual(allowed, true)
        expectEqual(text, "sent")
        expectTrue(agentSaw().contains("answer s-2 allow_once"))
        await hermes.closeWorker(worker)
        await hermes.shutdown()
    }

    func testPlanUpdatesReachTheConversation() async throws {
        let hermes = backend()
        var plans: [AgentPlan] = []
        var text = ""
        for try await update in hermes.stream(AgentPrompt(text: "PLAN")) {
            switch update {
            case .plan(let plan): plans.append(plan)
            case .event(.text(let delta)): text += delta
            default: break
            }
        }
        expectEqual(text, "planned")
        let plan = try unwrap(plans.last)
        expectEqual(plan.entries.map(\.content), ["Find the repos", "Read the logs", "Email Dad"])
        expectEqual(plan.entries.map(\.status), [.completed, .inProgress, .completed])
        expectEqual(plan.entries.map(\.cancelled), [false, false, true])
        expectEqual(plan.completed, 1)
        expectEqual(plan.current?.content, "Read the logs")
        // `send` keeps to the events it always had.
        var plain = ""
        for try await event in hermes.send("PLAN") { if case .text(let delta) = event { plain += delta } }
        expectEqual(plain, "planned")
        await hermes.shutdown()
    }

    // MARK: Jobs

    @MainActor
    func testFinishedJobIsAnnouncedAndKept() async throws {
        let hermes = backend()
        let jobs = JobsModel(backend: hermes, ledger: JobLedger(url: ledgerFile))
        var said: [JobAnnouncement] = []
        jobs.onAnnouncement = { said.append($0) }
        let job = try unwrap(jobs.start("echo Three repos changed today. The Daisy repo has two new commits.", title: "repo digest"))
        await expectSoon { jobs.job(job.id)?.status == .done }
        let done = try unwrap(jobs.job(job.id))
        expectEqual(done.result, "Three repos changed today. The Daisy repo has two new commits.")
        expectEqual(done.session, "s-2")
        expectTrue(done.started != nil && done.finished != nil)
        expectEqual(said.map(\.kind), [.finished])
        expectEqual(said.first?.text, "Your repo digest is ready: Three repos changed today. The Daisy repo has two new commits.")
        let saved = JobLedger(url: ledgerFile).load()
        expectEqual(saved.map(\.id), [job.id])
        expectEqual(saved.first?.status, .done)
        expectEqual(saved.first?.result, done.result)
        expectEqual(WorkerRoles(url: rolesFile).sessions(), [:])
        await jobs.shutdown()
        await hermes.shutdown()
    }

    @MainActor
    func testThirdJobWaitsForAFreeSlot() async throws {
        let hermes = backend()
        let jobs = JobsModel(backend: hermes, ledger: JobLedger(url: ledgerFile))
        let first = try unwrap(jobs.start("hold")), second = try unwrap(jobs.start("hold")), third = try unwrap(jobs.start("hold"))
        await expectSoon { agentSaw().filter { $0.hasPrefix("prompt") }.count == 2 }
        expectEqual(jobs.running.count, 2)
        expectEqual(jobs.job(first.id)?.status, .running)
        expectEqual(jobs.job(second.id)?.status, .running)
        expectEqual(jobs.job(third.id)?.status, .queued)
        expectEqual(Set(WorkerRoles(url: rolesFile).sessions().keys), ["s-2", "s-3"])
        let firstSession = try unwrap(jobs.job(first.id)?.session)
        jobs.cancel(first.id)
        await expectSoon { jobs.job(first.id)?.status == .cancelled }
        await expectSoon { jobs.job(third.id)?.status == .running && jobs.job(third.id)?.session != nil }
        expectEqual(jobs.job(third.id)?.session, "s-4")
        expectTrue(agentSaw().contains("cancel \(firstSession)"))
        expectEqual(WorkerRoles(url: rolesFile).sessions()[firstSession], nil)
        jobs.cancel(second.id); jobs.cancel(third.id)
        await expectSoon { jobs.jobs.allSatisfy(\.status.finished) }
        expectEqual(jobs.jobs.map(\.status), [.cancelled, .cancelled, .cancelled])
        expectEqual(WorkerRoles(url: rolesFile).sessions(), [:])
        await jobs.shutdown()
        await hermes.shutdown()
    }

    @MainActor
    func testWorkerApprovalBecomesACardTaggedWithItsJob() async throws {
        let hermes = backend()
        let queue = ApprovalQueue { id, option in await hermes.resolve(approval: id, optionID: option) }
        var decisions: [ApprovalQueue.Outcome] = []
        queue.onDecision = { _, outcome in decisions.append(outcome) }
        let jobs = JobsModel(backend: hermes, ledger: JobLedger(url: ledgerFile), approvals: queue)
        var said: [JobAnnouncement.Kind] = []
        jobs.onAnnouncement = { said.append($0.kind) }
        let job = try unwrap(jobs.start("approve", title: "dad text"))
        await expectSoon { !queue.items.isEmpty }
        let card = try unwrap(queue.items.first)
        expectEqual(card.source, .job(job.id))
        expectEqual(card.label, "dad text")
        expectEqual(card.approval.title, "Send an iMessage to Dad")
        expectEqual(card.approval.detail, "“hi”")
        expectEqual(jobs.job(job.id)?.status, .needsApproval)
        queue.answer(card.id, allow: true)
        await expectSoon { jobs.job(job.id)?.status == .done }
        expectEqual(jobs.job(job.id)?.result, "sent")
        expectTrue(queue.items.isEmpty)
        expectEqual(decisions, [.allowed])
        expectEqual(said, [.needsApproval, .finished])
        expectTrue(agentSaw().contains("answer s-2 allow_once"))
        await jobs.shutdown()
        await hermes.shutdown()
    }

    @MainActor
    func testUnansweredCardIsDeclinedAndTakenDownInTime() async throws {
        let hermes = backend()
        let queue = ApprovalQueue(window: 0.3) { id, option in await hermes.resolve(approval: id, optionID: option) }
        var decisions: [ApprovalQueue.Outcome] = []
        queue.onDecision = { _, outcome in decisions.append(outcome) }
        let jobs = JobsModel(backend: hermes, ledger: JobLedger(url: ledgerFile), approvals: queue)
        let job = try unwrap(jobs.start("approve"))
        await expectSoon { !queue.items.isEmpty }
        let card = try unwrap(queue.items.first)
        expectLess(card.expires.timeIntervalSince(card.arrived), 0.31)
        await expectSoon { queue.items.isEmpty }
        expectEqual(decisions, [.expired])
        await expectSoon { jobs.job(job.id)?.status == .done }
        expectEqual(jobs.job(job.id)?.result, "declined")
        expectTrue(agentSaw().contains("answer s-2 cancelled"))
        // A tap after the card came down does nothing.
        queue.answer(card.id, allow: true)
        expectEqual(decisions, [.expired])
        await jobs.shutdown()
        await hermes.shutdown()
    }

    @MainActor
    func testBackendDeclinesAnApprovalNobodyAnswers() async throws {
        let hermes = backend(approvalWindow: 0.3)
        let worker = try await hermes.openWorker()
        var asked: [String] = []
        var settled: [String: Bool] = [:]
        var text = ""
        for try await update in hermes.run(worker: worker, prompt: AgentPrompt(text: JobsModel.prompt(for: "approve"))) {
            switch update {
            case .event(.approval(let approval)): asked.append(approval.id)
            case .event(.approvalResolved(let id, let allowed)): settled[id] = allowed
            case .event(.text(let delta)): text += delta
            default: break
            }
        }
        expectEqual(asked.count, 1)
        expectEqual(settled, [asked[0]: false])
        expectEqual(text, "declined")
        await hermes.closeWorker(worker)
        await hermes.shutdown()
    }

    @MainActor
    func testCardsComeDownWhenTheirJobEnds() async throws {
        let hermes = backend()
        let queue = ApprovalQueue { id, option in await hermes.resolve(approval: id, optionID: option) }
        var decisions: [ApprovalQueue.Outcome] = []
        queue.onDecision = { _, outcome in decisions.append(outcome) }
        let jobs = JobsModel(backend: hermes, ledger: JobLedger(url: ledgerFile), approvals: queue)
        let job = try unwrap(jobs.start("approve"))
        await expectSoon { !queue.items.isEmpty }
        jobs.cancel(job.id)
        await expectSoon { jobs.job(job.id)?.status == .cancelled }
        expectTrue(queue.items.isEmpty)
        expectEqual(decisions, [.withdrawn])
        expectTrue(agentSaw().contains("answer s-2 cancelled"))
        expectEqual(WorkerRoles(url: rolesFile).sessions(), [:])
        await jobs.shutdown()
        await hermes.shutdown()
    }

    @MainActor
    func testJobPlanAndFailureShowUp() async throws {
        let hermes = backend()
        let jobs = JobsModel(backend: hermes, ledger: JobLedger(url: ledgerFile))
        var said: [JobAnnouncement] = []
        jobs.onAnnouncement = { said.append($0) }
        let planned = try unwrap(jobs.start("plan"))
        await expectSoon { jobs.job(planned.id)?.status == .done }
        expectEqual(jobs.plans[planned.id]?.entries.map(\.content), ["Find the repos", "Read the logs", "Email Dad"])
        let broken = try unwrap(jobs.start("fail", title: "inbox sweep"))
        await expectSoon { jobs.job(broken.id)?.status == .failed }
        expectEqual(jobs.job(broken.id)?.problem, "The model provider is out of usage.")
        expectEqual(said.last?.text, "Your inbox sweep didn't finish: The model provider is out of usage.")
        await jobs.shutdown()
        await hermes.shutdown()
    }

    @MainActor
    func testVoiceTurnCardFreesTheVoiceOnce() async throws {
        var answered: [String: String] = [:]
        let queue = ApprovalQueue(window: 5, parkDelay: 0.05) { id, option in answered[id] = option ?? "no answer" }
        var lines: [String] = []
        queue.onPark = { lines.append($0) }
        let options = [AgentApproval.Option(id: "allow_once", name: "Allow once", kind: .allowOnce),
                       AgentApproval.Option(id: "allow_session", name: "Allow for session", kind: .allowAlways),
                       AgentApproval.Option(id: "deny", name: "Deny", kind: .rejectOnce)]
        queue.add(AgentApproval(id: "a", title: "Send an email to Dad", detail: "Hi", options: options), from: .conversation, voice: true)
        queue.add(AgentApproval(id: "b", title: "Delete notes.txt", detail: nil, options: options), from: .conversation, voice: true)
        await expectSoon { queue.parked }
        try await Task.sleep(nanoseconds: 100_000_000)
        expectEqual(lines, [ApprovalQueue.parkLine])
        queue.answer("a", allow: true)
        queue.answer("b", allow: false)
        expectFalse(queue.parked)
        await expectSoon { answered.count == 2 }
        expectEqual(answered["a"], "allow_once")
        expectEqual(answered["b"], "deny")
        // A request that can't be allowed once is only ever declined.
        queue.add(AgentApproval(id: "c", title: "Run a command", detail: "rm -rf build", options: [options[1], options[2]]), from: .conversation)
        queue.answer("c", allow: true)
        await expectSoon { answered.count == 3 }
        expectEqual(answered["c"], "deny")
        // Too many at once: the extra one is declined straight away.
        let small = ApprovalQueue(limit: 1) { id, option in answered[id] = option ?? "no answer" }
        var outcomes: [ApprovalQueue.Outcome] = []
        small.onDecision = { _, outcome in outcomes.append(outcome) }
        small.add(AgentApproval(id: "d", title: "Send", detail: nil, options: options), from: .conversation)
        small.add(AgentApproval(id: "e", title: "Send", detail: nil, options: options), from: .conversation)
        expectEqual(small.items.map(\.id), ["d"])
        expectEqual(outcomes, [.overflow])
        small.withdrawAll()
        expectEqual(outcomes, [.overflow, .withdrawn])
    }

    // MARK: Ledger and roles file

    func testLedgerKeepsRecentHistoryAndStopsInterruptedJobs() throws {
        let ledger = JobLedger(url: ledgerFile, historyLimit: 3)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var saved: [Job] = []
        for index in 0..<4 {
            var job = Job(goal: "old \(index)", created: base.addingTimeInterval(Double(index)))
            job.status = .done; job.result = "r\(index)"; job.finished = base.addingTimeInterval(Double(index) + 100)
            saved.append(job)
        }
        var running = Job(goal: "running", created: base.addingTimeInterval(10)); running.status = .running; running.session = "s-9"
        let waiting = Job(goal: "waiting", created: base.addingTimeInterval(11))
        try ledger.save(saved + [running, waiting])
        let loaded = ledger.load()
        expectEqual(loaded.map(\.goal), ["waiting", "running", "old 3"])
        expectEqual(loaded.map(\.status), [.cancelled, .failed, .done])
        expectEqual(loaded[1].problem, "Daisy quit before it finished.")
        expectEqual(loaded[0].problem, "Daisy quit before it started.")
        expectEqual(loaded[2].result, "r3")
        expectEqual(JobLedger(url: root.appendingPathComponent("missing.json")).load(), [])
    }

    func testRolesFileLocationFollowsHermesHome() {
        expectEqual(WorkerRoles.defaultURL(environment: ["HERMES_HOME": "/tmp/hh"]).path, "/tmp/hh/daisy/roles.json")
        let roles = WorkerRoles(url: rolesFile)
        expectEqual(roles.sessions(), [:])
    }

    // MARK: Delegation check

    private func probe(_ scenario: String, wait: TimeInterval = 1) async -> (DelegationProbe.Report, [String]) {
        let lines = LineLog()
        var options = DelegationProbe.Options(executable: probeAgent, workingDirectory: root,
                                              environment: ["FAKE_DELEGATION": scenario], wait: wait)
        options.afterTurn = 0.3
        let report = await DelegationProbe.run(options) { lines.add($0) }
        return (report, lines.all)
    }

    private final class LineLog: @unchecked Sendable {
        private let lock = NSLock(); private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }

    func testDelegationCheckReportsEachOutcome() async throws {
        let (never, neverLines) = await probe("never")
        expectEqual(never.verdict, .neverCameBack)
        expectEqual(never.verdict.exitCode, 1)
        expectTrue(neverLines.last?.hasPrefix("VERDICT: NEVER CAME BACK") == true)
        expectTrue(neverLines.contains { $0.contains("session_info_update (after the turn) ×1") })
        expectTrue(neverLines.contains { $0.contains("tool_call delegate_task [pending]") })

        let (late, _) = await probe("late")
        expectEqual(late.verdict, .cameBack)
        expectTrue(late.reason.contains("after the turn ended"))

        let (sync, _) = await probe("sync")
        expectEqual(sync.verdict, .cameBackInTurn)
        expectEqual(sync.verdict.exitCode, 0)

        let (quiet, _) = await probe("quiet")
        expectEqual(quiet.verdict, .cameBack)
        expectTrue(quiet.reason.contains("without"))

        let (echo, _) = await probe("echo")
        expectEqual(echo.verdict, .unclear)

        let (refused, _) = await probe("refuse")
        expectEqual(refused.verdict, .notCalled)
        expectTrue(refused.reason.contains("can't use delegate_task"))

        let (blocked, _) = await probe("blocked")
        expectEqual(blocked.verdict, .delegationFailed)
        expectTrue(blocked.reason.contains("Blocked by the Daisy guard"))

        let (missing, _) = await probe("notools")
        expectEqual(missing.verdict, .notOffered)
        expectEqual(missing.verdict.exitCode, 3)

        let (signedOut, _) = await probe("signedout")
        expectEqual(signedOut.verdict, .couldNotRun)
        expectEqual(signedOut.verdict.exitCode, 2)
    }

    func testDelegationPromptCarriesTheWordButNotItsAnswer() {
        let prompt = DelegationProbe.prompt(word: "AB12CD34")
        expectTrue(prompt.contains("AB12CD34"))
        expectFalse(prompt.contains("43DC21BA"))
        expectTrue(prompt.contains("delegate_task exactly once"))
        expectEqual(DelegationProbe.randomWord().count, 8)
    }

    // MARK: Fixtures

    /// Sessions are s-1, s-2… in the order Daisy opens them. A job's goal is whatever follows
    /// "Job: " in its prompt: "echo …", "role", "interleave", "hold", "approve", "plan", "fail".
    static let fixture = #"""
    #!/usr/bin/python3
    import json, os, sys
    out = sys.stdout
    def send(obj):
        out.write(json.dumps(obj) + "\n"); out.flush()
    def update(sid, upd):
        send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": upd}})
    def chunk(sid, text):
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}})
    def end(mid, reason="end_turn"):
        send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": reason}})
    def note(text):
        with open(os.environ["FAKE_LOG"], "a") as f:
            f.write(text + "\n")
    def role(sid):
        try:
            with open(os.environ["FAKE_ROLES"]) as f:
                return json.load(f).get("sessions", {}).get(sid, "none")
        except Exception:
            return "none"
    PLAN = [{"content": "Find the repos", "priority": "medium", "status": "completed"},
            {"content": "Read the logs", "priority": "medium", "status": "in_progress"},
            {"content": "[cancelled] Email Dad", "priority": "medium", "status": "completed"}]
    models = {"currentModelId": "openai-codex:gpt-test", "availableModels": []}
    counter, asked = 0, 100
    held, asks = {}, {}
    def ask(sid, mid):
        global asked
        asked += 1
        asks[asked] = (sid, mid)
        send({"jsonrpc": "2.0", "id": asked, "method": "session/request_permission", "params": {"sessionId": sid,
              "toolCall": {"toolCallId": "perm-check-%d" % asked, "title": "x", "kind": "execute", "status": "pending",
                           "rawInput": {"command": "<terminal> (plugin approval rule)", "description": "Send an iMessage to Dad — “hi”"}},
              "options": [{"optionId": "allow_once", "name": "Allow once", "kind": "allow_once"},
                          {"optionId": "allow_session", "name": "Allow for session", "kind": "allow_always"},
                          {"optionId": "deny", "name": "Deny", "kind": "reject_once"}]}})
    for line in iter(sys.stdin.readline, ""):
        msg = json.loads(line)
        method, mid, params = msg.get("method"), msg.get("id"), msg.get("params", {})
        if method is None:
            if mid in asks:
                sid, pid = asks.pop(mid)
                outcome = msg.get("result", {}).get("outcome", {})
                note("answer %s %s" % (sid, outcome.get("optionId") or outcome.get("outcome")))
                chunk(sid, "sent" if outcome.get("optionId") == "allow_once" else "declined")
                end(pid)
            continue
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": 1, "authMethods": [{"id": "openai-codex", "name": "openai-codex"}]}})
        elif method == "session/new":
            counter += 1
            send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": "s-%d" % counter, "models": models, "modes": {"currentModeId": "default"}}})
        elif method == "session/list":
            send({"jsonrpc": "2.0", "id": mid, "result": {"sessions": [{"sessionId": "s-%d" % n, "cwd": params.get("cwd"), "title": "t"} for n in range(1, counter + 1)]}})
        elif method == "session/cancel":
            sid = params["sessionId"]
            note("cancel %s" % sid)
            if sid in held:
                end(held.pop(sid), "cancelled")
        elif method == "session/prompt":
            sid = params["sessionId"]
            text = next((b.get("text", "") for b in params["prompt"] if b.get("type") == "text"), "")
            goal = text.split("Job: ", 1)[1] if "Job: " in text else None
            note("prompt %s role=%s" % (sid, role(sid)))
            if goal is None:
                if text == "ping" and held:
                    other = next(iter(held))
                    chunk(sid, "pong "); chunk(other, "A2"); chunk(sid, "done")
                    end(mid)
                    chunk(other, "A3"); end(held.pop(other))
                elif text == "PLAN":
                    update(sid, {"sessionUpdate": "plan", "entries": PLAN}); chunk(sid, "planned"); end(mid)
                else:
                    chunk(sid, "ok"); end(mid)
            elif goal.startswith("echo "):
                chunk(sid, goal[5:]); end(mid)
            elif goal == "role":
                chunk(sid, "role=" + role(sid)); end(mid)
            elif goal in ("interleave", "hold"):
                chunk(sid, "A1" if goal == "interleave" else "holding "); held[sid] = mid
            elif goal == "approve":
                ask(sid, mid)
            elif goal == "plan":
                update(sid, {"sessionUpdate": "plan", "entries": PLAN}); chunk(sid, "planned"); end(mid)
            elif goal == "fail":
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32603, "message": "Internal error",
                      "data": {"details": "The model provider is out of usage."}}})
            else:
                chunk(sid, "ok"); end(mid)
        elif mid is not None:
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "Method not found"}})
    """#

    /// How delegate_task could come back, by FAKE_DELEGATION: never (only bookkeeping after the
    /// turn), late (a new turn with the answer), sync (the answer in the tool's output), quiet (a
    /// new turn without it), echo (Hermes reverses the word itself), blocked (the call fails),
    /// refuse, notools, signedout.
    static let delegationFixture = #"""
    #!/usr/bin/python3
    import json, os, re, sys, time
    out = sys.stdout
    scenario = os.environ.get("FAKE_DELEGATION", "never")
    def send(obj):
        out.write(json.dumps(obj) + "\n"); out.flush()
    def update(sid, upd):
        send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": upd}})
    def chunk(sid, text):
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}})
    def tool(sid, kind, status, text, title=None):
        upd = {"sessionUpdate": kind, "toolCallId": "tc-1", "kind": "execute", "status": status,
               "content": [{"type": "content", "content": {"type": "text", "text": text}}]}
        if title:
            upd["title"] = title
        update(sid, upd)
    for line in iter(sys.stdin.readline, ""):
        msg = json.loads(line)
        method, mid, params = msg.get("method"), msg.get("id"), msg.get("params", {})
        if method == "initialize":
            methods = [{"id": "hermes-setup", "name": "setup"}]
            if scenario != "signedout":
                methods.insert(0, {"id": "openai-codex", "name": "openai-codex"})
            send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": 1, "authMethods": methods}})
        elif method == "session/new":
            send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": "d-1", "models": {}, "modes": {}}})
        elif method == "session/prompt":
            sid = params["sessionId"]
            text = params["prompt"][0]["text"]
            if text == "/tools":
                listed = "  read_file: Read a file" + ("" if scenario == "notools" else "\n  delegate_task: Spawn subagents")
                chunk(sid, "Available tools:\n" + listed)
                send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
                continue
            word = re.search(r"nothing else: ([A-Z0-9]+)\.", text).group(1)
            back = word[::-1]
            if scenario == "refuse":
                chunk(sid, "Sorry, I can't use delegate_task here.")
            else:
                tool(sid, "tool_call", "pending", "Delegating task: Reply with only this code word spelled backwards: " + word,
                     title="delegate: Reply with only this code word spelled backwards")
                if scenario == "sync":
                    tool(sid, "tool_call_update", "completed", "Delegation results: 1 task\n\nTask 1: completed\n" + back)
                elif scenario == "blocked":
                    tool(sid, "tool_call_update", "failed", "Blocked by the Daisy guard: delegate_task isn't allowed here.")
                else:
                    tool(sid, "tool_call_update", "completed", json.dumps({"status": "dispatched", "delegation_id": "dg-1", "goal": word}))
                chunk(sid, "Dispatched it: " + back + "." if scenario == "echo" else "Dispatched it.")
                update(sid, {"sessionUpdate": "usage_update", "size": 1000, "used": 10})
            send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
            time.sleep(0.2)
            if scenario == "late":
                update(sid, {"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": "[IMPORTANT: background task dg-1 finished]"}})
                chunk(sid, "The subagent says " + back[:5]); chunk(sid, back[5:] + ".")
            elif scenario == "quiet":
                chunk(sid, "A background task finished.")
            elif scenario == "never":
                update(sid, {"sessionUpdate": "session_info_update", "title": "Diagnostic"})
        elif mid is not None:
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "Method not found"}})
    """#
}
