import Foundation
import DaisyCore

/// New background jobs wait while JobsModel.holdNewJobs gives a reason (the usage budget), and start
/// once it's lifted; running jobs aren't touched.
final class JobsHoldTests {
    let ledger = FileManager.default.temporaryDirectory.appendingPathComponent("jobs-hold-\(UUID().uuidString).json")
    func tearDown() { try? FileManager.default.removeItem(at: ledger) }

    private final class InstantBackend: JobBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var opened = 0
        var runs: Int { lock.withLock { opened } }
        func openWorker() async throws -> String { lock.withLock { opened += 1; return "w\(opened)" } }
        func run(worker session: String, prompt: AgentPrompt) -> AsyncThrowingStream<AgentUpdate, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.event(.text("done")))
                continuation.yield(.event(.finished(stopReason: "end_turn")))
                continuation.finish()
            }
        }
        func cancel(worker session: String) async {}
        func closeWorker(_ session: String) async {}
        func resolve(approval id: String, optionID: String?) async {}
    }

    @MainActor
    func testHeldJobsWaitUntilTheHoldLifts() async throws {
        let backend = InstantBackend()
        let jobs = JobsModel(backend: backend, ledger: JobLedger(url: ledger))
        var reason: String? = "85% of the 5-hour window is used, so new background jobs wait."
        jobs.holdNewJobs = { reason }
        let job = try unwrap(jobs.start("Summarize my notes"))
        try await Task.sleep(nanoseconds: 100_000_000)
        expectEqual(jobs.job(job.id)?.status, .queued)
        expectEqual(jobs.held, reason)
        expectEqual(backend.runs, 0)
        reason = nil
        jobs.recheck()
        let deadline = Date().addingTimeInterval(5)
        while jobs.job(job.id)?.status != .done, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        expectEqual(jobs.job(job.id)?.status, .done)
        expectTrue(jobs.held == nil)
        expectEqual(backend.runs, 1)
    }
}
