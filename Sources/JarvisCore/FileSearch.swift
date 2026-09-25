import Foundation

public struct FileMatch: Identifiable, Codable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let modified: Date
    public let bytes: Int
}
public struct SearchReport: Codable, Sendable {
    public let files: [FileMatch]
    public let scanned: Int
    public let limited: Bool
    public let unreadableLocations: Int
    public var summary: String {
        var text = files.isEmpty ? "No matching filenames found in the selected folder." : "Found \(files.count) matching \(files.count == 1 ? "file" : "files"), newest first. Choose a result to open it or reveal it in Finder."
        if limited { text += " These are partial results; narrow your search or choose a smaller folder." }
        if unreadableLocations > 0 { text += " Some locations could not be read." }
        return text
    }
}
public enum FileSearch {
    public static func isInside(_ url: URL, root: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/") && path != rootPath
    }

    /// Filename metadata only. Hidden paths, symlinks and packages are never traversed.
    public static func search(query: String, root: URL, maxEntries: Int = 50_000) throws -> SearchReport {
        try Task.checkCancellation()
        let tokens = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty, query.count <= 120, !query.contains("/"), !query.contains("\\") else {
            throw JarvisError.message("Search needs a filename phrase of 1–120 characters, without a path.")
        }
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
              FileManager.default.isReadableFile(atPath: root.path) else {
            throw JarvisError.message("This folder is no longer readable. Choose it again.")
        }
        var errors = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in errors += 1; return true }) else {
            throw JarvisError.message("Could not enumerate the selected folder.")
        }
        var matches: [FileMatch] = []; var scanned = 0; var limited = false
        let deadline = Date().addingTimeInterval(10)
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            if scanned >= maxEntries || Date() > deadline { limited = true; break }
            scanned += 1
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { errors += 1; continue }
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true, isInside(url, root: root) else { continue }
            let name = url.lastPathComponent.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if tokens.allSatisfy({ name.contains($0) }) {
                matches.append(FileMatch(path: url.path, name: url.lastPathComponent,
                    modified: values.contentModificationDate ?? .distantPast, bytes: values.fileSize ?? 0))
            }
        }
        matches.sort { $0.modified == $1.modified ? $0.path < $1.path : $0.modified > $1.modified }
        return SearchReport(files: Array(matches.prefix(30)), scanned: scanned,
                            limited: limited || matches.count > 30, unreadableLocations: errors)
    }
}

public struct ToolExecutor: Sendable {
    public let root: URL?
    public let allowed: Bool
    public init(root: URL?, allowed: Bool) { self.root = root; self.allowed = allowed }
    public func execute(_ call: ToolCall) async throws -> SearchReport {
        try Task.checkCancellation()
        guard call.function.name == "search_files" else { throw JarvisError.message("Unsupported tool. No action was performed.") }
        guard allowed else { throw JarvisError.message("File search is disabled in Settings.") }
        guard let root else { throw JarvisError.message("Choose a folder before searching your files.") }
        guard call.function.arguments.count == 1, let query = call.function.arguments["query"]?.stringValue else {
            throw JarvisError.message("Invalid search arguments. No action was performed.")
        }
        let work = Task.detached { try FileSearch.search(query: query, root: root) }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }
}
