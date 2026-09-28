import Foundation

/// Cross-project "where did I leave off" briefings. Reads git status, recent commits and any
/// plan/TODO/notes file for a curated list of project roots. The list itself lives in explicit
/// memory (key `active_projects`) so the user, not the model, decides which projects are in scope.
public struct ProjectSnapshotCapabilityProvider: CapabilityProvider {
    public struct Project: Sendable {
        public let name: String
        public let path: URL
    }
    private let projects: [Project]
    private let git: URL
    public init(memories: [Memory], git: URL = URL(fileURLWithPath: "/usr/bin/git")) {
        self.projects = Self.parse(memories.first { $0.key == "active_projects" }?.value ?? "")
        self.git = git
    }
    /// One project per line. Accepts "name: /absolute/path", "name: ~/path", or a bare path
    /// (name defaults to the last path component). Blank lines and "#" comments are ignored.
    static func parse(_ text: String) -> [Project] {
        text.split(whereSeparator: \.isNewline).compactMap { line -> Project? in
            let raw = line.trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty, !raw.hasPrefix("#") else { return nil }
            let name: String, path: String
            if let colon = raw.firstIndex(of: ":") {
                name = String(raw[..<colon]).trimmingCharacters(in: .whitespaces)
                path = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            } else {
                path = raw
                name = URL(fileURLWithPath: expand(raw)).lastPathComponent
            }
            guard !path.isEmpty else { return nil }
            return Project(name: name, path: URL(fileURLWithPath: expand(path)))
        }
    }
    static func expand(_ path: String) -> String {
        path.hasPrefix("~") ? NSString(string: path).expandingTildeInPath : path
    }
    public func capabilities() -> [Capability] {
        let git = self.git
        let projects = self.projects
        let missing = projects.isEmpty
            ? "Configure projects first: /remember active_projects = carScrapingML: ~/projects/carScrapingML (one per line)."
            : nil
        return [
            Capability(.init(name: "project_state", title: "Where did I leave off", provider: "Projects",
                description: "Cross-project status. With no arguments, returns a one-line summary per configured project. Pass name for detailed git status, recent commits and any plan/TODO/notes excerpt. Projects are configured via the active_projects memory key.",
                parameters: .object(properties: ["name": .string(maxLength: 100)], required: [])),
                unavailableReason: missing) { args in
                    guard FileManager.default.isExecutableFile(atPath: git.path) else {
                        throw DaisyError.message("git is not installed at \(git.path).")
                    }
                    if let query = args["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
                        guard let match = projects.first(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) else {
                            let names = projects.map(\.name).joined(separator: ", ")
                            throw DaisyError.message("Unknown project '\(query)'. Configured: \(names.isEmpty ? "none" : names).")
                        }
                        let detail = try await Self.detail(match, git: git)
                        return .init(summary: "\(match.name) [\(detail.branch)] — \(detail.headline).", data: .object([
                            "name": .string(match.name), "path": .string(match.path.path),
                            "branch": .string(detail.branch), "status_summary": .string(detail.headline),
                            "status_lines": .array(detail.statusLines.prefix(20).map(JSONValue.string)),
                            "recent_commits": .array(detail.commits.map(JSONValue.string)),
                            "notes_source": .string(detail.notesFile ?? ""),
                            "notes_excerpt": .string(detail.notesExcerpt)
                        ]))
                    }
                    var lines: [JSONValue] = []
                    for project in projects.prefix(12) {
                        do {
                            let detail = try await Self.detail(project, git: git)
                            lines.append(.string("\(project.name) [\(detail.branch)] — \(detail.headline)\(detail.commits.first.map { " · last: \($0)" } ?? "")"))
                        } catch {
                            lines.append(.string("\(project.name) — unavailable (\(error.localizedDescription))"))
                        }
                    }
                    return .init(summary: "Snapshot of \(lines.count) project\(lines.count == 1 ? "" : "s").",
                                 data: .object(["projects": .array(lines)]))
                }
        ]
    }
    struct Detail { let branch: String; let headline: String; let statusLines: [String]; let commits: [String]; let notesFile: String?; let notesExcerpt: String }
    static func detail(_ project: Project, git: URL) async throws -> Detail {
        let dir = project.path
        guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw DaisyError.message("path missing")
        }
        let notes = notesExcerpt(under: dir)
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) else {
            return Detail(branch: "no-git", headline: "not a git repo", statusLines: [], commits: [], notesFile: notes.name, notesExcerpt: notes.text)
        }
        // Any of these can fail on an unborn branch, corrupt repo or missing commits. Keep going
        // so a partly-broken project still gets a useful summary.
        // symbolic-ref returns the branch name (e.g. "main") even on an unborn branch, where
        // rev-parse --abbrev-ref would fail with a fatal error. Falls back to empty for detached HEAD.
        async let branchTask = LocalProcess.capture(executable: git, arguments: ["-C", dir.path, "symbolic-ref", "--short", "HEAD"], timeout: 5, maxBytes: 200)
        async let statusTask = LocalProcess.capture(executable: git, arguments: ["-C", dir.path, "status", "--short"], timeout: 5, maxBytes: 8_192)
        async let logTask = LocalProcess.capture(executable: git, arguments: ["-C", dir.path, "log", "--oneline", "-5", "--since=2.weeks"], timeout: 5, maxBytes: 4_096)
        let branch = ((try? await branchTask) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let status = (try? await statusTask) ?? ""
        let log = (try? await logTask) ?? ""
        let statusLines = status.split(whereSeparator: \.isNewline).map { String($0) }
        let modified = statusLines.filter { !$0.hasPrefix("??") }.count
        let untracked = statusLines.filter { $0.hasPrefix("??") }.count
        let headline: String
        if statusLines.isEmpty { headline = branch.isEmpty ? "no HEAD yet" : "clean tree" }
        else { headline = "\(modified) modified, \(untracked) untracked" }
        let commits = log.split(whereSeparator: \.isNewline).map { String($0) }
        return Detail(branch: branch.isEmpty ? "unknown" : branch, headline: headline, statusLines: statusLines, commits: commits, notesFile: notes.name, notesExcerpt: notes.text)
    }
    static func notesExcerpt(under dir: URL) -> (name: String?, text: String) {
        for candidate in ["plan.md", "PLAN.md", "TODO.md", "todo.md", "notes.md", "NOTES.md"] {
            let target = dir.appendingPathComponent(candidate)
            if let data = try? Data(contentsOf: target), let text = String(data: data, encoding: .utf8) {
                return (candidate, String(text.prefix(600)))
            }
        }
        return (nil, "")
    }
}
