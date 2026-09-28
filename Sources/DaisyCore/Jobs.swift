import Foundation

/// A piece of work Daisy runs in the background, in a Hermes session of its own, while the
/// conversation carries on.
public struct Job: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case queued, running, needsApproval, done, failed, cancelled
        public var finished: Bool { self == .done || self == .failed || self == .cancelled }
    }
    public let id: UUID
    /// What Daisy calls it when it's done ("repo digest"). Optional.
    public var title: String?
    /// What was asked, in the user's words.
    public let goal: String
    public var status: Status
    /// The Hermes session it runs in, once started.
    public var session: String?
    /// The worker's answer.
    public var result: String?
    /// Why it didn't finish, in words fit for the screen.
    public var problem: String?
    public let created: Date
    public var started: Date?
    public var finished: Date?

    public init(goal: String, title: String? = nil, id: UUID = UUID(), created: Date = Date()) {
        self.id = id; self.goal = goal; self.created = created; status = .queued
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title?.isEmpty == false ? title : nil
    }

    /// "repo digest", or "background job" when it has no title.
    public var name: String { title ?? "background job" }
}

/// jobs.json in Daisy's data folder: jobs waiting or running, plus the latest finished ones.
/// A job can't be picked up after Daisy quits (its turn ended with Hermes), so loading marks
/// unfinished ones as stopped instead of running them again unasked.
public struct JobLedger: Sendable {
    public let url: URL
    /// Finished jobs kept; unfinished ones are always kept.
    public let historyLimit: Int

    public init(url: URL, historyLimit: Int = 50) { self.url = url; self.historyLimit = max(0, historyLimit) }
    public static var standard: JobLedger { JobLedger(url: Configuration.dataDirectory.appendingPathComponent("jobs.json")) }

    /// Saved jobs, newest first. A missing or unreadable file is an empty ledger.
    public func load() -> [Job] {
        guard let data = try? Data(contentsOf: url), let saved = try? Self.decoder.decode([Job].self, from: data) else { return [] }
        let now = Date()
        return bounded(saved.map { job in
            var job = job
            switch job.status {
            case .queued: job.status = .cancelled; job.problem = "Daisy quit before it started."; job.finished = now
            case .running, .needsApproval: job.status = .failed; job.problem = "Daisy quit before it finished."; job.finished = now
            case .done, .failed, .cancelled: break
            }
            return job
        })
    }

    public func save(_ jobs: [Job]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Self.encoder.encode(bounded(jobs)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Every unfinished job and the newest `historyLimit` finished ones, newest first.
    public func bounded(_ jobs: [Job]) -> [Job] {
        let finished = jobs.filter(\.status.finished)
            .sorted { ($0.finished ?? $0.created) > ($1.finished ?? $1.created) }
            .prefix(historyLimit)
        let kept = Set(finished.map(\.id))
        return jobs.filter { !$0.status.finished || kept.contains($0.id) }.sorted { $0.created > $1.created }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// roles.json in Hermes's home folder, which the Daisy guard plugin reads to tell background
/// jobs from the conversation: `{"version": 1, "sessions": {"<acp session id>": "worker"}}`.
/// Only job sessions are listed. Every change rewrites the whole file through a temporary file
/// and a rename in the same folder, so the plugin never reads half of it. Entries this process
/// didn't write are left as they are.
public struct WorkerRoles: Sendable {
    public static let version = 1
    public let url: URL
    /// One writer at a time in this process; each change reads the file fresh.
    private static let lock = NSLock()

    public init(url: URL) { self.url = url }

    /// `$HERMES_HOME/daisy/roles.json`, else `~/.hermes/daisy/roles.json`. `environment` is what
    /// hermes-acp starts with, so it wins over Daisy's own.
    public static func defaultURL(environment: [String: String] = [:]) -> URL {
        let configured = environment["HERMES_HOME"] ?? ProcessInfo.processInfo.environment["HERMES_HOME"] ?? ""
        let home = configured.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes", isDirectory: true)
                                      : URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
        return home.appendingPathComponent("daisy", isDirectory: true).appendingPathComponent("roles.json")
    }

    /// Listed sessions and their roles.
    public func sessions() -> [String: String] { Self.lock.withLock { read() } }

    public func mark(_ session: String, as role: String = "worker") throws {
        try Self.lock.withLock {
            var sessions = read()
            sessions[session] = role
            try write(sessions)
        }
    }

    public func clear(_ ids: [String]) throws {
        try Self.lock.withLock {
            var sessions = read()
            guard ids.contains(where: { sessions[$0] != nil }) else { return }
            for id in ids { sessions[id] = nil }
            try write(sessions)
        }
    }

    private func read() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = object["sessions"] as? [String: Any] else { return [:] }
        return sessions.compactMapValues { $0 as? String }
    }

    private func write(_ sessions: [String: String]) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONSerialization.data(withJSONObject: ["version": Self.version, "sessions": sessions] as [String: Any],
                                              options: [.sortedKeys])
        let temporary = folder.appendingPathComponent(".roles-\(UUID().uuidString).tmp")
        try data.write(to: temporary)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard rename(temporary.path, url.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temporary)
            throw DaisyError.message("Couldn't update \(url.path): \(reason).")
        }
    }
}
