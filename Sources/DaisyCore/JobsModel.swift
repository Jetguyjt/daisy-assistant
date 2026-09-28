import Combine
import Foundation

/// Something about a background job worth saying out loud. The app decides when to say it
/// (not over the top of an answer).
public struct JobAnnouncement: Sendable, Equatable {
    public enum Kind: Sendable { case finished, failed, needsApproval }
    public let kind: Kind
    public let job: Job
    /// What to say, e.g. "Your repo digest is ready: three repos changed today."
    public let text: String
}

/// Background jobs: each runs in a Hermes session of its own while the conversation carries on,
/// at most `limit` at once (the rest wait their turn). Jobs are kept in `JobLedger`. A job's
/// approvals go on the shared `ApprovalQueue`, tagged with the job, and come down when it ends.
@MainActor public final class JobsModel: ObservableObject {
    /// Newest first.
    @Published public private(set) var jobs: [Job] = []
    /// What each running job is doing now, in plain words ("Searching the web").
    @Published public private(set) var steps: [UUID: String] = [:]
    /// Each job's latest plan, when the agent keeps one.
    @Published public private(set) var plans: [UUID: AgentPlan] = [:]
    /// A job finished, failed, or needs an OK.
    public var onAnnouncement: ((JobAnnouncement) -> Void)?
    /// Asked before a queued job starts. A reason holds new jobs back (running ones carry on); the app
    /// passes BudgetMonitor's, so jobs wait while a usage window is about 80% used.
    public var holdNewJobs: (() -> String?)?
    /// Why queued jobs are waiting, besides the two-at-a-time limit.
    @Published public private(set) var held: String?
    public let limit: Int
    /// Largest goal accepted; the rest of the request is Daisy's note to the worker.
    public static let maxGoalBytes = HermesBackend.maxRequestBytes - 2_000

    private var backend: JobBackend?
    private let ledger: JobLedger
    private let approvals: ApprovalQueue?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var waiting: [UUID: Set<String>] = [:]

    /// With no backend (the on-device fallback), jobs can't start.
    public init(backend: JobBackend?, ledger: JobLedger = .standard, approvals: ApprovalQueue? = nil,
                limit: Int = HermesBackend.maxWorkers) {
        self.backend = backend; self.ledger = ledger; self.approvals = approvals; self.limit = max(1, limit)
        jobs = ledger.load()
        persist()
    }

    public var available: Bool { backend != nil }
    public var running: [Job] { jobs.filter { $0.status == .running || $0.status == .needsApproval } }
    public var queued: [Job] { jobs.filter { $0.status == .queued } }
    /// Hermes sessions that belong to jobs, to keep them out of the chat list.
    public var sessionIDs: Set<String> { Set(jobs.compactMap(\.session)) }
    public func job(_ id: UUID) -> Job? { jobs.first { $0.id == id } }

    /// Queues a job; it starts when a slot is free. nil when jobs can't run or the goal is empty
    /// or too long.
    @discardableResult public func start(_ goal: String, title: String? = nil) -> Job? {
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard backend != nil, !goal.isEmpty, goal.utf8.count <= Self.maxGoalBytes else { return nil }
        let job = Job(goal: goal, title: title)
        jobs.insert(job, at: 0)
        persist()
        pump()
        return self.job(job.id)
    }

    /// Stops a job. A queued one just never starts.
    public func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch jobs[index].status {
        case .queued:
            tasks.removeValue(forKey: id)?.cancel()
            jobs[index].status = .cancelled; jobs[index].finished = Date()
            persist()
            pump()
        case .running, .needsApproval:
            tasks[id]?.cancel()
        case .done, .failed, .cancelled:
            break
        }
    }

    /// Removes a finished job from the list.
    public func dismiss(_ id: UUID) {
        guard job(id)?.status.finished == true else { return }
        jobs.removeAll { $0.id == id }; plans[id] = nil
        persist()
    }

    public func clearFinished() {
        for job in jobs where job.status.finished { plans[job.id] = nil }
        jobs.removeAll { $0.status.finished }
        persist()
    }

    /// Switches to another backend (or none). Jobs running on the old one are stopped.
    public func use(_ backend: JobBackend?) {
        guard backend !== self.backend else { return }
        for task in tasks.values { task.cancel() }
        self.backend = backend
        pump()
    }

    /// Stops every running job and waits for each to wind down, so their sessions lose the job
    /// mark before Hermes goes away. Queued jobs stay queued (the ledger marks them on next launch).
    public func shutdown() async {
        let running = Array(tasks.values)
        backend = nil
        for task in running { task.cancel() }
        for task in running { await task.value }
    }

    /// What the worker is told. It works alone, so it shouldn't wait on questions, and its answer
    /// may be read aloud.
    public nonisolated static func prompt(for goal: String) -> String {
        """
        Background job from Daisy. Nobody is watching this live, so don't ask questions: if something \
        blocks you, stop and say what you'd need. Finish with the result, opening with a one- or \
        two-sentence summary that can be read aloud.

        Job: \(goal)
        """
    }

    /// Looks again at whether queued jobs may start; call it when what `holdNewJobs` reads changes.
    public func recheck() { pump() }

    // MARK: Running

    private func pump() {
        guard backend != nil else { return }
        held = queued.isEmpty ? nil : holdNewJobs?()
        guard held == nil else { return }
        // Oldest first.
        for job in jobs.reversed() where job.status == .queued && tasks[job.id] == nil {
            guard tasks.count < limit else { return }
            let id = job.id
            tasks[id] = Task { [weak self] in await self?.execute(id) }
        }
    }

    private func execute(_ id: UUID) async {
        // It may have been cancelled between being picked and starting.
        guard let backend, let job = job(id), job.status == .queued, !Task.isCancelled else {
            if tasks[id] != nil { tasks[id] = nil; pump() }
            return
        }
        let goal = job.goal
        change(id) { $0.status = .running; $0.started = Date() }
        var session: String?
        var text = ""
        var stop = "end_turn"
        var failure: String?
        do {
            let opened = try await backend.openWorker()
            session = opened
            change(id) { $0.session = opened }
            for try await update in backend.run(worker: opened, prompt: AgentPrompt(text: Self.prompt(for: goal))) {
                switch update {
                case .event(.text(let delta)): text += delta
                case .event(.tool(let tool)):
                    if tool.state == .running || tool.state == .pending { steps[id] = tool.title }
                    else if steps[id] == tool.title { steps[id] = nil }
                case .event(.approval(let request)): await ask(request, for: id, via: backend)
                case .event(.approvalResolved(let approval, let allowed)): settled(approval, allowed: allowed, for: id)
                case .event(.finished(let reason)): stop = reason
                case .event(.receipts): break
                case .plan(let plan): plans[id] = plan
                }
            }
        } catch is CancellationError {
            stop = "cancelled"
        } catch {
            failure = (error as? AgentFailure)?.errorDescription ?? error.localizedDescription
        }
        if Task.isCancelled { stop = "cancelled"; failure = nil }
        approvals?.withdraw(from: .job(id))
        waiting[id] = nil; steps[id] = nil
        if let session { await backend.closeWorker(session) }
        finish(id, text: text, stop: stop, failure: failure)
        tasks[id] = nil
        pump()
    }

    private func ask(_ request: AgentApproval, for id: UUID, via backend: JobBackend) async {
        guard let approvals else {
            // Nobody to ask: no answer means no.
            await backend.resolve(approval: request.id, optionID: nil)
            return
        }
        waiting[id, default: []].insert(request.id)
        change(id) { $0.status = .needsApproval }
        approvals.add(request, from: .job(id), label: job(id)?.name)
        if let job = job(id) {
            onAnnouncement?(JobAnnouncement(kind: .needsApproval, job: job, text: "Your \(job.name) needs your OK on screen."))
        }
    }

    private func settled(_ approval: String, allowed: Bool, for id: UUID) {
        approvals?.settled(approval, allowed: allowed)
        waiting[id]?.remove(approval)
        if waiting[id]?.isEmpty != false, job(id)?.status == .needsApproval { change(id) { $0.status = .running } }
    }

    private func finish(_ id: UUID, text: String, stop: String, failure: String?) {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        change(id) { job in
            job.finished = Date()
            job.result = answer.isEmpty ? nil : String(answer.prefix(20_000))
            if let failure { job.status = .failed; job.problem = failure }
            else if stop == "cancelled" { job.status = .cancelled }
            else if stop == "refusal" { job.status = .failed; job.problem = "Hermes didn't take the job." }
            else { job.status = .done }
        }
        guard let job = job(id) else { return }
        // Old finished jobs drop off the list the same way they drop out of the ledger.
        jobs = ledger.bounded(jobs)
        for key in plans.keys where self.job(key) == nil { plans[key] = nil }
        switch job.status {
        case .done:
            let summary = SpeechText.spoken(from: answer, limit: 240)
            onAnnouncement?(JobAnnouncement(kind: .finished, job: job,
                                            text: "Your \(job.name) is ready" + (summary.isEmpty ? "." : ": " + summary)))
        case .failed:
            onAnnouncement?(JobAnnouncement(kind: .failed, job: job,
                                            text: "Your \(job.name) didn't finish" + (job.problem.map { ": " + $0 } ?? ".")))
        default:
            break
        }
    }

    private func change(_ id: UUID, _ body: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        body(&jobs[index])
        persist()
    }

    private func persist() {
        try? ledger.save(jobs)
    }
}
