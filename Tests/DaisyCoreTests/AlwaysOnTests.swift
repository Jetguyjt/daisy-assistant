import Foundation
import DaisyCore

/// The JOBS tab's always-on feed against a throwaway HERMES_HOME: Hermes's cron run files, cron/jobs.json
/// and the Kanban board. The run files follow the formats in Hermes's cron/scheduler.py; none of them is
/// real output.
final class AlwaysOnTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwayson-\(UUID().uuidString)")
    var home: URL { root.appendingPathComponent("hermes-home") }
    var output: URL { home.appendingPathComponent("cron/output") }

    func setUp() throws { try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true) }
    func tearDown() { try? FileManager.default.removeItem(at: root) }

    private let file = URL(fileURLWithPath: "/tmp/2026-09-28_05-30-41.md")

    static let answered = """
    # Cron Job: Daisy inbox triage

    **Job ID:** a1b2c3d4e5f6
    **Run Time:** 2026-09-28 05:30:41
    **Schedule:** 30 5 * * *

    ## Prompt

    [IMPORTANT: You are running as a scheduled cron job. Just produce your report as your final response.]

    Overnight inbox triage. This job only reads.

    ## Response

    9 unread from the last day, 2 need a reply.

    **Needs a reply**
    - Ms. Rivera: AP Lit essay feedback, wants the revised draft by Friday
    - Dad: Dinner Sunday?, asking if you're free at 6

    **FYI**
    - GitHub: CI passed on main

    """

    static let failed = """
    # Cron Job: Daisy repo digest (FAILED)

    **Job ID:** 0f0f0f0f0f0f
    **Run Time:** 2026-09-28 07:00:03
    **Schedule:** 0 7 * * *

    ## Prompt

    Morning repo digest.

    ## Error

    ```
    RuntimeError: provider timed out
    ```

    """

    static let blockedByScan = """
    # Cron Job: Daisy inbox triage

    **Job ID:** a1b2c3d4e5f6
    **Run Time:** 2026-09-29 05:30:02
    **Status:** BLOCKED

    The assembled prompt (user prompt + loaded skill content) tripped the cron injection scanner and the agent was NOT run.

    **Scanner result:** Blocked: prompt matches threat pattern 'prompt_injection'.

    Audit the skill(s) attached to this job.
    """

    static let blockedByConfig = """
    # Cron Job: Daisy inbox triage

    **Job ID:** a1b2c3d4e5f6
    **Run Time:** 2026-09-29 05:30:02
    **Status:** BLOCKED (configuration)

    Pre-dispatch validation found a configuration problem and the agent was NOT run (no tokens spent).

    **Reason:** the default model changed since this job was created

    The job will stay blocked (without re-alerting) until the configuration is fixed.
    """

    static let silent = """
    # Cron Job: Daisy inbox triage

    **Job ID:** a1b2c3d4e5f6
    **Run Time:** 2026-09-30 05:30:12
    **Schedule:** 30 5 * * *

    ## Prompt

    Overnight inbox triage.

    ## Response

    [SILENT]

    """

    static let gated = """
    # Cron Job: Daisy repo digest

    **Job ID:** 0f0f0f0f0f0f
    **Run Time:** 2026-09-28 07:00:01

    Script gate returned `wakeAgent=false` — agent skipped.

    """

    static let script = """
    # Cron Job: disk check

    **Job ID:** 123abc123abc
    **Run Time:** 2026-09-28 08:00:00
    **Mode:** no_agent (script)

    ---

    Disk is 91% full.

    """

    static let scriptFailed = """
    # Cron Job: disk check

    **Job ID:** 123abc123abc
    **Run Time:** 2026-09-28 08:00:00
    **Mode:** no_agent (script)
    **Status:** script failed

    Script timed out after 60s

    """

    func testAnsweredRun() throws {
        let run = CronOutput.parse(Self.answered, jobID: "a1b2c3d4e5f6", file: file)
        expectEqual(run.jobName, "Daisy inbox triage")
        expectEqual(run.outcome, .ok)
        expectEqual(run.summary, "9 unread from the last day, 2 need a reply.\nNeeds a reply\n- Ms. Rivera: AP Lit essay feedback, wants the revised draft by Friday")
        expectTrue(run.detail.hasPrefix("9 unread from the last day"))
        expectTrue(run.detail.contains("CI passed on main"))
        expectFalse(run.detail.contains("scheduled cron job"))
        let ranAt = try unwrap(run.ranAt)
        let when = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: ranAt)
        expectEqual([when.year, when.month, when.day, when.hour, when.minute, when.second], [2026, 9, 28, 5, 30, 41])
    }

    func testFailedAndBlockedRuns() {
        let failed = CronOutput.parse(Self.failed, jobID: "0f0f0f0f0f0f", file: file)
        expectEqual(failed.jobName, "Daisy repo digest")
        expectEqual(failed.outcome, .failed)
        expectEqual(failed.detail, "RuntimeError: provider timed out")
        let scanned = CronOutput.parse(Self.blockedByScan, jobID: "a1b2c3d4e5f6", file: file)
        expectEqual(scanned.outcome, .blocked)
        expectEqual(scanned.detail, "Blocked: prompt matches threat pattern 'prompt_injection'.")
        let config = CronOutput.parse(Self.blockedByConfig, jobID: "a1b2c3d4e5f6", file: file)
        expectEqual(config.outcome, .blocked)
        expectEqual(config.detail, "Blocked: the default model changed since this job was created")
        let broken = CronOutput.parse("# Cron Job: Daisy inbox triage\n\nError: config.yaml can't be parsed\n", jobID: "x", file: file)
        expectEqual(broken.outcome, .failed)
        expectEqual(broken.detail, "Error: config.yaml can't be parsed")
        let removed = CronOutput.parse("""
        # Cron job removed without producing output

        - job id: a1b2c3d4e5f6
        - name: Daisy inbox triage
        - removed at: 2026-09-28T05:40:00

        This one-shot job's dispatch was claimed, but the run never completed.
        """, jobID: "a1b2c3d4e5f6", file: file)
        expectEqual(removed.outcome, .failed)
        expectEqual(removed.jobName, "Daisy inbox triage")
        let dead = CronOutput.parse(Self.scriptFailed, jobID: "123abc123abc", file: file)
        expectEqual(dead.outcome, .failed)
        expectEqual(dead.detail, "Script timed out after 60s")
    }

    func testRunsWithNothingToSay() {
        for (text, name) in [(Self.silent, "silent"), (Self.gated, "gated"), ("", "empty"),
                             ("# Cron Job: disk check\n\n**Job ID:** x\n**Run Time:** 2026-09-28 08:00:00\n**Mode:** no_agent (script)\n**Status:** silent (empty output)\n", "no_agent silent"),
                             ("# Cron Job: feed\n\n**Job ID:** x\n**Run Time:** 2026-09-28 08:00:00\n**Mode:** monitor\n**Status:** no_change (agent run suppressed)\n", "monitor")] {
            let run = CronOutput.parse(text, jobID: "0f0f0f0f0f0f", file: file)
            if run.outcome != .skipped { fail("\(name) should be skipped, got \(run.outcome)") }
        }
        expectEqual(CronOutput.parse(Self.silent, jobID: "a", file: file).detail, "Nothing new to report.")
        let unnamed = CronOutput.parse("", jobID: "0f0f0f0f0f0f", file: URL(fileURLWithPath: "/tmp/2026-09-28_07-00-01.md"))
        expectEqual(unnamed.jobName, "0f0f0f0f0f0f")
        expectTrue(unnamed.ranAt != nil)
    }

    func testScriptOutputAndQuotedEarlierRuns() {
        let script = CronOutput.parse(Self.script, jobID: "123abc123abc", file: file)
        expectEqual(script.outcome, .ok)
        expectEqual(script.detail, "Disk is 91% full.")
        // With continuity on, the prompt quotes the previous run, "## Response" and all.
        let quoting = """
        # Cron Job: Daisy repo digest

        **Job ID:** 0f0f0f0f0f0f
        **Run Time:** 2026-09-29 07:00:00

        ## Prompt

        ## Your previous run's output

        ```
        # Cron Job: Daisy repo digest

        ## Response

        yesterday's digest
        ```

        Morning repo digest.

        ## Response

        today's digest
        """
        expectEqual(CronOutput.parse(quoting, jobID: "0f0f0f0f0f0f", file: file).detail, "today's digest")
        // A failed run after a quoted good one: the error is what counts.
        let failedAfterQuote = quoting
            .replacingOccurrences(of: "# Cron Job: Daisy repo digest\n\n**Job ID:** 0f0f0f0f0f0f", with: "# Cron Job: Daisy repo digest (FAILED)\n\n**Job ID:** 0f0f0f0f0f0f")
            .replacingOccurrences(of: "## Response\n\ntoday's digest", with: "## Error\n\n```\nTimeoutError: no reply\n```")
        let failed = CronOutput.parse(failedAfterQuote, jobID: "0f0f0f0f0f0f", file: file)
        expectEqual(failed.outcome, .failed)
        expectEqual(failed.detail, "TimeoutError: no reply")
    }

    func testSummaryIsShortAndPlain() {
        let text = "## Heading\n\n**Bold** line one\n---\nline two\nline three\nline four"
        expectEqual(CronOutput.summary(of: text), "Heading\nBold line one\nline two")
        let long = String(repeating: "word ", count: 200)
        expectTrue(CronOutput.summary(of: long).count <= 280)
        expectTrue(CronOutput.summary(of: long).hasSuffix("…"))
    }

    func testLatestRunsAcrossJobs() throws {
        try write(Self.answered, to: "a1b2c3d4e5f6/2026-09-28_05-30-41.md")
        try write(Self.silent, to: "a1b2c3d4e5f6/2026-09-30_05-30-12.md")
        try write(Self.failed, to: "0f0f0f0f0f0f/2026-09-28_07-00-03.md")
        try write(Self.gated, to: "0f0f0f0f0f0f/2026-09-29_07-00-01.md")
        try write("half written", to: "0f0f0f0f0f0f/.output_tmp123.md")
        try write("hash", to: "0f0f0f0f0f0f/monitor_last_output.txt")
        let runs = CronOutput.latest(in: output, limit: 3)
        expectEqual(runs.map(\.file.lastPathComponent), ["2026-09-30_05-30-12.md", "2026-09-29_07-00-01.md", "2026-09-28_07-00-03.md"])
        expectEqual(CronOutput.latest(in: output, limit: 10).count, 4)
        expectEqual(CronOutput.latest(in: home.appendingPathComponent("nowhere"), limit: 10), [])
    }

    func testJobsFile() throws {
        let canonical = Data("""
        {"jobs": [
          {"id": "a1b2c3d4e5f6", "name": "Daisy inbox triage", "schedule_display": "30 5 * * *",
           "next_run_at": "2026-09-29T05:30:00.123456-07:00", "last_run_at": "2026-09-28T05:31:02-07:00",
           "last_status": "ok", "last_error": null, "enabled": true, "state": "scheduled"},
          {"id": "0f0f0f0f0f0f", "name": "Daisy repo digest", "schedule": {"kind": "cron", "value": "0 7 * * *"},
           "next_run_at": null, "enabled": false, "state": "paused", "last_status": "error", "last_error": "boom"}
        ], "updated_at": "2026-09-28T05:31:02"}
        """.utf8)
        let jobs = CronJobsFile.parse(canonical)
        expectEqual(jobs.map(\.name), ["Daisy inbox triage", "Daisy repo digest"])
        expectEqual(jobs[0].schedule, "30 5 * * *")
        expectEqual(jobs[1].schedule, "0 7 * * *")
        expectFalse(jobs[0].paused)
        expectTrue(jobs[1].paused)
        expectEqual(jobs[1].lastError, "boom")
        let next = try unwrap(jobs[0].nextRun)
        expectEqual(next.timeIntervalSince1970, 1_790_685_000.123, accuracy: 0.001)
        let last = try unwrap(jobs[0].lastRun)
        expectEqual(last.timeIntervalSince1970, 1_790_598_662)
        let list = CronJobsFile.parse(Data(#"[{"id": "x1", "name": "one"}]"#.utf8))
        expectEqual(list.map(\.id), ["x1"])
        let keyed = CronJobsFile.parse(Data(#"{"jobs": {"k1": {"name": "keyed"}}}"#.utf8))
        expectEqual(keyed.map(\.id), ["k1"])
        expectEqual(CronJobsFile.parse(Data("not json".utf8)), [])
    }

    func testKanbanBoard() throws {
        let database = home.appendingPathComponent("kanban.db")
        try sqlite(database, """
        PRAGMA journal_mode=WAL;
        CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT NOT NULL, body TEXT, assignee TEXT, status TEXT NOT NULL,
          priority INTEGER DEFAULT 0, created_by TEXT, created_at INTEGER NOT NULL, started_at INTEGER, completed_at INTEGER,
          workspace_kind TEXT NOT NULL DEFAULT 'scratch', result TEXT, last_failure_error TEXT);
        INSERT INTO tasks (id, title, assignee, status, priority, created_at) VALUES
          ('t1', 'Draft the college essay outline', 'writer', 'ready', 1, 1790500000),
          ('t2', 'Research scholarship deadlines', 'researcher', 'running', 5, 1790500100),
          ('t3', 'Old idea', NULL, 'archived', 9, 1790500200),
          ('t4', 'Fix the CI badge', 'coder', 'done', 0, 1790500300);
        INSERT INTO tasks (id, title, assignee, status, priority, created_at, last_failure_error) VALUES
          ('t5', 'Email the counselor', NULL, 'blocked', 3, 1790500400, 'needs_input: which counselor?');
        """)
        let tasks = try KanbanReader.read(database: database)
        expectEqual(tasks.count, 4)
        expectEqual(tasks.map(\.id), ["t2", "t5", "t1", "t4"])
        expectEqual(tasks.first?.assignee, "researcher")
        expectEqual(tasks.first { $0.id == "t5" }?.problem, "needs_input: which counselor?")
        let board = KanbanBoard(name: "default", tasks: tasks)
        expectEqual(board.counts.map(\.status), ["ready", "running", "blocked", "done"])
        expectEqual(board.open.map(\.id), ["t2", "t5", "t1"])
        expectEqual(KanbanReader.location(home: home, environment: [:]).database.path, database.path)

        // A switched-to board lives under kanban/boards/<slug>.
        let school = home.appendingPathComponent("kanban/boards/school/kanban.db")
        try FileManager.default.createDirectory(at: school.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sqlite(school, "CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT NOT NULL, status TEXT NOT NULL, priority INTEGER DEFAULT 0, created_at INTEGER NOT NULL);")
        try "school\n".write(to: home.appendingPathComponent("kanban/current"), atomically: true, encoding: .utf8)
        let located = KanbanReader.location(home: home, environment: [:])
        expectEqual(located.board, "school")
        expectEqual(located.database.path, school.path)
        try expectEqual(KanbanReader.read(database: school), [])

        // A board that was created but never used has no tasks table yet.
        let fresh = root.appendingPathComponent("fresh.db")
        try sqlite(fresh, "CREATE TABLE other (x INTEGER);")
        try expectEqual(KanbanReader.read(database: fresh), [])
        expectThrows(try KanbanReader.read(database: root.appendingPathComponent("missing.db")))
    }

    func testNothingThereIsEmpty() {
        let snapshot = AlwaysOnSnapshot.read(home: home)
        expectEqual(snapshot.runs, [])
        expectEqual(snapshot.jobs, [])
        expectTrue(snapshot.board == nil)
        expectTrue(snapshot.problem == nil)
    }

    @MainActor
    func testFeedReadsAndChangesNothing() async throws {
        try write(Self.answered, to: "a1b2c3d4e5f6/2026-09-28_05-30-41.md")
        try write(Self.gated.replacingOccurrences(of: "# Cron Job: Daisy repo digest\n", with: ""), to: "0f0f0f0f0f0f/2026-09-28_07-00-01.md")
        try Data(#"{"jobs": [{"id": "0f0f0f0f0f0f", "name": "Daisy repo digest", "schedule_display": "0 7 * * *"}]}"#.utf8)
            .write(to: home.appendingPathComponent("cron/jobs.json"))
        try sqlite(home.appendingPathComponent("kanban.db"), """
        PRAGMA journal_mode=WAL;
        CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT NOT NULL, status TEXT NOT NULL, priority INTEGER DEFAULT 0, created_at INTEGER NOT NULL);
        INSERT INTO tasks VALUES ('t1', 'One task', 'todo', 0, 1790500000);
        """)
        let before = try listing(home)
        let board = try Data(contentsOf: home.appendingPathComponent("kanban.db"))
        let feed = AlwaysOnFeed(home: home)
        await feed.refresh()
        expectEqual(feed.runs.map(\.jobName), ["Daisy repo digest", "Daisy inbox triage"])
        expectEqual(feed.runs.first?.outcome, .skipped)
        expectEqual(feed.jobs.map(\.name), ["Daisy repo digest"])
        expectEqual(feed.board?.tasks.map(\.title), ["One task"])
        expectTrue(feed.problem == nil)
        expectTrue(feed.refreshed != nil)
        // Nothing Hermes keeps changed. SQLite's own -wal and -shm files are left out: any reader of a
        // WAL database uses them to keep out of a writer's way.
        try expectEqual(listing(home), before)
        try expectEqual(Data(contentsOf: home.appendingPathComponent("kanban.db")), board)
    }

    // MARK: Helpers

    private func write(_ text: String, to relative: String) throws {
        let url = output.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Makes a database with the sqlite3 command-line tool, the way Hermes's own would look on disk.
    private func sqlite(_ database: URL, _ script: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw DaisyError.message("sqlite3 failed") }
    }

    /// Every file under a folder with its size and modification time, SQLite's -wal and -shm aside.
    private func listing(_ folder: URL) throws -> [String] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let base = folder.resolvingSymlinksInPath().path
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys)?.compactMap { $0 as? URL } ?? []
        return try files.filter { !$0.lastPathComponent.hasSuffix("-wal") && !$0.lastPathComponent.hasSuffix("-shm") }.map { url in
            let values = try url.resourceValues(forKeys: Set(keys))
            let path = url.resolvingSymlinksInPath().path
            return "\(path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path) \(values.fileSize ?? -1) "
                + "\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }.sorted()
    }
}

private func expectEqual(_ a: Double, _ b: Double, accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    if abs(a - b) > accuracy { fail("\(a) != \(b)", file: file, line: line) }
}
