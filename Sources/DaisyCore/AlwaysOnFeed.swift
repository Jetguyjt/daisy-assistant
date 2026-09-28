import CSQLite
import Foundation

/// What Hermes did while nobody was talking to Daisy, for the JOBS tab: the latest scheduled-job runs
/// ($HERMES_HOME/cron/output/<job id>/<time>.md), the jobs themselves ($HERMES_HOME/cron/jobs.json) and the
/// Kanban board (kanban.db). Everything here only reads: files are read, the board's database is opened
/// read-only, and Hermes itself is never run (`hermes kanban list` would create and update the board).
/// Anything missing (no gateway yet, no jobs, no board) is just empty.
@MainActor public final class AlwaysOnFeed: ObservableObject {
    /// Newest first.
    @Published public private(set) var runs: [CronRun] = []
    @Published public private(set) var jobs: [CronJobInfo] = []
    /// nil until Hermes has a board.
    @Published public private(set) var board: KanbanBoard?
    /// Something that couldn't be read, in words for the screen.
    @Published public private(set) var problem: String?
    @Published public private(set) var refreshed: Date?
    public let home: URL
    public let runLimit: Int
    private var reading = false

    public init(home: URL = HermesMemory.home, runLimit: Int = 12) {
        self.home = home; self.runLimit = max(1, runLimit)
    }

    public func refresh() async {
        guard !reading else { return }
        reading = true
        defer { reading = false }
        let home = self.home, limit = runLimit
        let snapshot = await Task.detached(priority: .utility) { AlwaysOnSnapshot.read(home: home, runLimit: limit) }.value
        runs = snapshot.runs; jobs = snapshot.jobs; board = snapshot.board; problem = snapshot.problem
        refreshed = Date()
    }
}

/// One run of a scheduled job, from its output file.
public struct CronRun: Identifiable, Equatable, Sendable {
    public enum Outcome: String, Sendable { case ok, failed, blocked, skipped }
    public var id: String { file.path }
    public let jobID: String
    public var jobName: String
    public let ranAt: Date?
    public let outcome: Outcome
    /// A few lines for the list.
    public let summary: String
    /// The whole answer, or the error or reason, for when the run is opened. The prompt Hermes also
    /// keeps in the file is left out.
    public let detail: String
    public let file: URL
}

/// A job as Hermes keeps it in cron/jobs.json.
public struct CronJobInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let schedule: String
    public let nextRun: Date?
    public let lastRun: Date?
    /// "ok", "error", "delivery_failed", "blocked_config"...
    public let lastStatus: String?
    public let lastError: String?
    public let paused: Bool
}

public struct KanbanTask: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let status: String
    public let assignee: String?
    public let priority: Int
    public let created: Date?
    public let finished: Date?
    public let result: String?
    public let problem: String?
}

public struct KanbanBoard: Equatable, Sendable {
    /// The board's slug ("default" unless another is switched to).
    public let name: String
    /// Everything not archived, highest priority first.
    public let tasks: [KanbanTask]
    public static let columns = ["triage", "todo", "scheduled", "ready", "running", "blocked", "review", "done"]

    public init(name: String, tasks: [KanbanTask]) { self.name = name; self.tasks = tasks }
    /// Tasks per column, in board order, empty columns left out.
    public var counts: [(status: String, count: Int)] {
        let grouped = Dictionary(grouping: tasks, by: \.status)
        let known = Self.columns.compactMap { status in grouped[status].map { (status, $0.count) } }
        let other = grouped.keys.filter { !Self.columns.contains($0) }.sorted().map { ($0, grouped[$0]!.count) }
        return known + other
    }
    /// What still needs doing or someone's attention: everything but done.
    public var open: [KanbanTask] { tasks.filter { $0.status != "done" } }
    public static func == (lhs: KanbanBoard, rhs: KanbanBoard) -> Bool { lhs.name == rhs.name && lhs.tasks == rhs.tasks }
}

/// One read of everything, off the main thread.
public struct AlwaysOnSnapshot: Sendable {
    public var runs: [CronRun] = []
    public var jobs: [CronJobInfo] = []
    public var board: KanbanBoard?
    public var problem: String?

    public static func read(home: URL, runLimit: Int = 12) -> AlwaysOnSnapshot {
        var snapshot = AlwaysOnSnapshot()
        let cron = home.appendingPathComponent("cron", isDirectory: true)
        if let data = try? Data(contentsOf: cron.appendingPathComponent("jobs.json")) { snapshot.jobs = CronJobsFile.parse(data) }
        snapshot.runs = CronOutput.latest(in: cron.appendingPathComponent("output", isDirectory: true), limit: runLimit)
        let names = Dictionary(snapshot.jobs.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        for index in snapshot.runs.indices where snapshot.runs[index].jobName == snapshot.runs[index].jobID {
            snapshot.runs[index].jobName = names[snapshot.runs[index].jobID] ?? snapshot.runs[index].jobID
        }
        let location = KanbanReader.location(home: home)
        if FileManager.default.fileExists(atPath: location.database.path) {
            do { snapshot.board = KanbanBoard(name: location.board, tasks: try KanbanReader.read(database: location.database)) }
            catch { snapshot.problem = "The Kanban board couldn't be read: \(error.localizedDescription)" }
        }
        return snapshot
    }
}

// MARK: Cron output

/// The run documents Hermes writes (cron/scheduler.py): "# Cron Job: <name>", then **Job ID:**, **Run Time:**
/// and **Schedule:** lines, "## Prompt", and "## Response" or "## Error". Runs that never reached the model
/// have a **Status:** line instead (blocked by the prompt scan or the config check, script failed, skipped).
public enum CronOutput {
    /// The newest runs across every job, by the time in their file names.
    public static func latest(in output: URL, limit: Int) -> [CronRun] {
        let files = FileManager.default
        guard let jobDirectories = try? files.contentsOfDirectory(at: output, includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: [.skipsHiddenFiles]) else { return [] }
        var found: [(job: String, file: URL)] = []
        for directory in jobDirectories where (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let runs = (try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            found += runs.filter { $0.pathExtension == "md" }.map { (directory.lastPathComponent, $0) }
        }
        // Names are local times (2026-09-28_05-30-12.md), so the newest sort last.
        let newest = found.sorted { $0.file.lastPathComponent > $1.file.lastPathComponent }.prefix(max(1, limit))
        return newest.compactMap { entry in
            guard let text = try? String(contentsOf: entry.file, encoding: .utf8) else { return nil }
            return parse(text, jobID: entry.job, file: entry.file)
        }
    }

    public static func parse(_ raw: String, jobID: String, file: URL) -> CronRun {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = text.components(separatedBy: "\n")
        var name = field("Cron Job", heading: true, in: lines) ?? ""
        var outcome = CronRun.Outcome.ok
        if name.hasSuffix(" (FAILED)") { name = String(name.dropLast(9)); outcome = .failed }
        if name.isEmpty, lines.first?.hasPrefix("# Cron job removed") == true {
            name = lines.first { $0.hasPrefix("- name: ") }.map { String($0.dropFirst(8)) } ?? ""
            outcome = .failed
        }
        let ranAt = field("Run Time", in: lines).flatMap(HermesDates.localStamp) ?? HermesDates.fileStamp(file.deletingPathExtension().lastPathComponent)
        let status = field("Status", in: lines)?.lowercased() ?? ""
        var detail = ""
        // Whichever of "## Response" and "## Error" Hermes wrote last is this run's; an earlier one can be
        // an old run quoted in the prompt.
        let answer = text.range(of: "\n## Response\n", options: .backwards)
        let error = text.range(of: "\n## Error\n", options: .backwards)
        if let answer, error.map({ $0.lowerBound < answer.lowerBound }) ?? true {
            detail = String(text[answer.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if detail == "[SILENT]" || detail.hasSuffix("\n[SILENT]") { outcome = .skipped; detail = "Nothing new to report." }
            else if detail == "(No response generated)" { outcome = .skipped; detail = "The job ran but had nothing to say." }
        } else if let error {
            outcome = .failed
            detail = String(text[error.upperBound...]).replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            outcome = .skipped; detail = "Skipped: there was nothing to do."
        } else if text.contains("wakeAgent=false") || status.hasPrefix("silent") || status.hasPrefix("no_change") {
            outcome = .skipped; detail = "Skipped: there was nothing to do."
        } else if status.hasPrefix("blocked") {
            outcome = .blocked
            detail = field("Reason", in: lines) ?? field("Scanner result", in: lines) ?? body(after: lines)
            if !detail.lowercased().hasPrefix("blocked") { detail = "Blocked: " + detail }
        } else if status.contains("failed") {
            outcome = .failed
            detail = body(after: lines)
        } else if let marker = text.range(of: "\n---\n") {
            detail = String(text[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            detail = body(after: lines)
            // "Error: ..." is a config.yaml Hermes couldn't read; "# Cron job removed..." a run that died.
            if detail.hasPrefix("Error:") || text.hasPrefix("# Cron job removed") { outcome = .failed }
        }
        if name.isEmpty { name = jobID }
        return CronRun(jobID: jobID, jobName: name, ranAt: ranAt, outcome: outcome, summary: summary(of: detail),
                       detail: detail.isEmpty ? "No details in the run's file." : detail, file: file)
    }

    /// The first few lines that say something, as plain text.
    public static func summary(of text: String, lines limit: Int = 3, characters: Int = 280) -> String {
        var kept: [String] = []
        for line in text.components(separatedBy: "\n") {
            var line = line.trimmingCharacters(in: .whitespaces)
            while line.hasPrefix("#") { line = String(line.dropFirst()) }
            line = line.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, line != "---" else { continue }
            kept.append(line)
            if kept.count == limit { break }
        }
        let joined = kept.joined(separator: "\n")
        return joined.count <= characters ? joined : String(joined.prefix(characters - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// "**Name:** value", or "# Name: value" for the title.
    static func field(_ name: String, heading: Bool = false, in lines: [String]) -> String? {
        let prefix = heading ? "# \(name): " : "**\(name):** "
        return lines.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
    }

    /// What follows the header lines when there's no named section.
    static func body(after lines: [String]) -> String {
        let rest = lines.drop { $0.hasPrefix("#") || $0.hasPrefix("**") || $0.trimmingCharacters(in: .whitespaces).isEmpty }
        return rest.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: cron/jobs.json

public enum CronJobsFile {
    /// Hermes keeps {"jobs": [...]}; a bare list or an id-keyed map is read too, as Hermes does.
    public static func parse(_ data: Data) -> [CronJobInfo] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var records: [[String: Any]] = []
        let list = (root as? [String: Any])?["jobs"] ?? root
        if let array = list as? [Any] { records = array.compactMap { $0 as? [String: Any] } }
        else if let map = list as? [String: Any] {
            records = map.keys.sorted().compactMap { key in (map[key] as? [String: Any]).map { ["id": key].merging($0) { _, new in new } } }
        }
        return records.compactMap { record in
            guard let id = text(record["id"]), !id.isEmpty else { return nil }
            let schedule = text(record["schedule_display"]) ?? text((record["schedule"] as? [String: Any])?["display"])
                ?? text((record["schedule"] as? [String: Any])?["value"]) ?? ""
            let state = text(record["state"])?.lowercased()
            return CronJobInfo(id: id, name: text(record["name"]) ?? id, schedule: schedule,
                               nextRun: text(record["next_run_at"]).flatMap(HermesDates.iso),
                               lastRun: text(record["last_run_at"]).flatMap(HermesDates.iso),
                               lastStatus: text(record["last_status"]), lastError: text(record["last_error"]),
                               paused: state == "paused" || record["enabled"] as? Bool == false)
        }
    }

    static func text(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: Kanban

/// The board Hermes's Kanban keeps in SQLite (hermes_cli/kanban_db.py): the default board at
/// <root>/kanban.db, other boards at <root>/kanban/boards/<slug>/kanban.db, the one in use named in
/// <root>/kanban/current. Opened read-only, so the data is never written; like any reader of a WAL
/// database, SQLite may still touch the -wal and -shm files beside it, which is its locking.
public enum KanbanReader {
    public static func location(home: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> (board: String, database: URL) {
        if let pinned = environment["HERMES_KANBAN_DB"], !pinned.isEmpty {
            return ("default", URL(fileURLWithPath: (pinned as NSString).expandingTildeInPath))
        }
        let override = environment["HERMES_KANBAN_HOME"] ?? ""
        let root = override.isEmpty ? home : URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        let current = (try? String(contentsOf: root.appendingPathComponent("kanban/current"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let slug = current.range(of: #"^[a-z0-9][a-z0-9_-]{0,63}$"#, options: .regularExpression) != nil ? current : "default"
        let board = root.appendingPathComponent("kanban/boards/\(slug)/kanban.db")
        if slug != "default", FileManager.default.fileExists(atPath: board.path) { return (slug, board) }
        return ("default", root.appendingPathComponent("kanban.db"))
    }

    public static func read(database: URL, limit: Int = 200) throws -> [KanbanTask] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let reason = db.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open it"
            sqlite3_close(db)
            throw DaisyError.message(reason)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        var statement: OpaquePointer?
        let query = "SELECT * FROM tasks WHERE status != 'archived' ORDER BY priority DESC, created_at ASC LIMIT \(max(1, limit))"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            // A board that was never used has no tasks table yet.
            let reason = String(cString: sqlite3_errmsg(db))
            if reason.contains("no such table") { return [] }
            throw DaisyError.message(reason)
        }
        defer { sqlite3_finalize(statement) }
        var columns: [String: Int32] = [:]
        for index in 0..<sqlite3_column_count(statement) {
            if let name = sqlite3_column_name(statement, index) { columns[String(cString: name)] = index }
        }
        func text(_ name: String) -> String? {
            guard let index = columns[name], sqlite3_column_type(statement, index) != SQLITE_NULL,
                  let raw = sqlite3_column_text(statement, index) else { return nil }
            let value = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        func number(_ name: String) -> Int64? {
            guard let index = columns[name], sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
            return sqlite3_column_int64(statement, index)
        }
        func date(_ name: String) -> Date? { number(name).map { Date(timeIntervalSince1970: TimeInterval($0)) } }
        var tasks: [KanbanTask] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw DaisyError.message(String(cString: sqlite3_errmsg(db))) }
            guard let id = text("id") else { continue }
            tasks.append(KanbanTask(id: id, title: text("title") ?? id, status: text("status")?.lowercased() ?? "todo",
                                    assignee: text("assignee"), priority: Int(number("priority") ?? 0), created: date("created_at"),
                                    finished: date("completed_at"), result: text("result"), problem: text("last_failure_error")))
        }
        return tasks
    }
}

// MARK: Dates

/// Times as Hermes writes them: local "2026-09-28 05:30:12" in run files and file names, ISO 8601 with an
/// offset (and often microseconds) in jobs.json and the usage windows.
enum HermesDates {
    static func localStamp(_ text: String) -> Date? { local("yyyy-MM-dd HH:mm:ss").date(from: text.trimmingCharacters(in: .whitespaces)) }
    static func fileStamp(_ text: String) -> Date? { local("yyyy-MM-dd_HH-mm-ss").date(from: text) }

    static func iso(_ text: String) -> Date? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasSuffix("Z") { value = String(value.dropLast()) + "+00:00" }
        // Keep milliseconds at most; Python writes microseconds.
        if let dot = value.range(of: #"\.\d+"#, options: .regularExpression) {
            value.replaceSubrange(dot, with: "." + value[dot].dropFirst().prefix(3).padding(toLength: 3, withPad: "0", startingAt: 0))
        }
        let withOffset = value.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) != nil
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = withOffset ? nil : TimeZone.current
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private static func local(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = format
        return formatter
    }
}
