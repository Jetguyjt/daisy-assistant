import Darwin
import Foundation

/// Hermes's built-in memory: two small files in $HERMES_HOME/memories that it curates itself
/// (tools/memory_tool_store.py). USER.md is what it knows about the user, MEMORY.md its own notes.
/// Each file is its entries joined by "\n§\n", and each has a character limit.
///
/// Daisy reads them for the Memory tab and edits them for Undo and Edit in the Learned feed and for
/// moving the old on-device memories in. Edits go through `HermesMemoryFiles.edit`, which does what
/// Hermes's own writes do. Hermes loads memory once per session, so a change shows up in new chats.
public enum HermesMemory {
    public enum Target: String, CaseIterable, Codable, Sendable {
        case memory, user
        public var fileName: String { self == .user ? "USER.md" : "MEMORY.md" }
        /// Hermes's defaults for memory.user_char_limit and memory.memory_char_limit.
        public var defaultLimit: Int { self == .user ? 1375 : 2200 }
        public var title: String { self == .user ? "About you" : "Notes" }
    }

    public static let delimiter = "\n§\n"

    /// $HERMES_HOME, or ~/.hermes.
    public static var home: URL {
        if let value = ProcessInfo.processInfo.environment["HERMES_HOME"], !value.isEmpty {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes", isDirectory: true)
    }
    public static var directory: URL { home.appendingPathComponent("memories", isDirectory: true) }

    /// What Hermes has learned about the user (USER.md).
    public static func profile(in directory: URL = directory) -> [String] { entries(directory.appendingPathComponent(Target.user.fileName)) }
    /// Hermes's own working notes (MEMORY.md).
    public static func notes(in directory: URL = directory) -> [String] { entries(directory.appendingPathComponent(Target.memory.fileName)) }

    static func entries(_ file: URL) -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return unique(parse(text.replacingOccurrences(of: "\r\n", with: "\n"))).filter { $0 != "§" }
    }

    // MARK: Hermes's format, exactly

    /// Hermes's split: on the full delimiter, each entry stripped, empty ones dropped.
    public static func parse(_ raw: String) -> [String] {
        let scalars = Array(raw.unicodeScalars)
        var pieces: [String] = []
        var start = 0, index = 0
        while index + 2 < scalars.count {
            if scalars[index] == "\n", scalars[index + 1] == "§", scalars[index + 2] == "\n" {
                pieces.append(string(scalars[start..<index]))
                index += 3
                start = index
            } else {
                index += 1
            }
        }
        pieces.append(string(scalars[start...]))
        return pieces.map(strip).filter { !$0.isEmpty }
    }

    public static func render(_ entries: [String]) -> String { entries.joined(separator: delimiter) }

    /// Python's str.strip(), which is what Hermes trims entries with.
    public static func strip(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var start = 0, end = scalars.count
        while start < end, isSpace(scalars[start]) { start += 1 }
        while end > start, isSpace(scalars[end - 1]) { end -= 1 }
        return start == 0 && end == scalars.count ? text : string(scalars[start..<end])
    }

    /// Hermes counts characters the way Python does: code points, not what Swift calls characters.
    public static func length(_ text: String) -> Int { text.unicodeScalars.count }

    /// Exact equality, code point for code point (Swift's == treats "é" and "e\u{301}" as the same).
    public static func same(_ a: String, _ b: String) -> Bool { a.unicodeScalars.elementsEqual(b.unicodeScalars) }

    /// Drops repeats, keeping the first, as Hermes does when it loads a file.
    public static func unique(_ entries: [String]) -> [String] {
        var seen = Set<[UInt32]>()
        return entries.filter { seen.insert($0.unicodeScalars.map(\.value)).inserted }
    }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// Python's str.isspace().
    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }

    // MARK: Limits

    /// memory.memory_char_limit and memory.user_char_limit from Hermes's config.yaml, or its defaults.
    public static func limits(home: URL = home) -> [Target: Int] {
        var limits: [Target: Int] = [:]
        guard let text = try? String(contentsOf: home.appendingPathComponent("config.yaml"), encoding: .utf8) else { return limits }
        var inMemory = false
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                inMemory = trimmed.hasPrefix("memory:") && trimmed.dropFirst(7).trimmingCharacters(in: .whitespaces).allSatisfy { $0 != "{" }
                continue
            }
            guard inMemory else { continue }
            let parts = trimmed.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let number = parts[1].split(separator: "#").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard let value = Int(number), value > 0 else { continue }
            if parts[0] == "memory_char_limit" { limits[.memory] = value }
            if parts[0] == "user_char_limit" { limits[.user] = value }
        }
        return limits
    }
}

public enum HermesMemoryError: LocalizedError, Equatable {
    case unreadable(file: String)
    /// The file isn't just its entries joined by "\n§\n" (a hand edit, say). Hermes won't touch it
    /// either until it's tidied, so neither does Daisy.
    case untidy(file: String)
    case busy
    case tooLong(file: String, length: Int, limit: Int)
    case full(file: String, total: Int, limit: Int)
    case badEntry
    case missing(file: String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let file): return "Couldn't read \(file), so nothing was changed. Try again in a moment."
        case .untidy(let file):
            return "\(file) has text Hermes can't read back as entries, maybe from a hand edit, so Daisy left it alone. Hermes won't change it either until it's tidied."
        case .busy: return "Hermes is writing its memory right now. Try again in a moment."
        case .tooLong(let file, let length, let limit):
            return "That entry is \(length.formatted()) characters, and \(file) holds \(limit.formatted()) in all."
        case .full(let file, let total, let limit):
            return "That would put \(file) at \(total.formatted()) of its \(limit.formatted()) characters. Shorten it or take something else out first."
        case .badEntry: return "An entry can't be empty or have a line with only “§” on it."
        case .missing(let file): return "That entry isn't in \(file) anymore."
        }
    }
}

/// Reads and edits Hermes's memory files in one folder (the real one, or a test's).
///
/// An edit does what Hermes's own writes do (MemoryStore._mutate): take the exclusive lock on the
/// separate "<file>.lock", read the file again inside it, apply the change to that fresh copy, and write
/// it back atomically (a temporary file, then a rename). The result is always the clean form Hermes
/// checks for before its own replace and remove: stripped entries, none empty, joined by "\n§\n", none
/// over the file's limit. A file that isn't in that form already is left alone, as Hermes would.
public struct HermesMemoryFiles: Sendable {
    public let directory: URL
    public let limits: [HermesMemory.Target: Int]
    /// How long an edit waits for Hermes to finish a write of its own.
    public var lockWait: TimeInterval = 3

    public init(directory: URL, limits: [HermesMemory.Target: Int] = [:]) {
        self.directory = directory; self.limits = limits
    }

    /// The real files, with the limits from Hermes's config.
    public static func standard() -> HermesMemoryFiles {
        HermesMemoryFiles(directory: HermesMemory.directory, limits: HermesMemory.limits())
    }

    public func url(_ target: HermesMemory.Target) -> URL { directory.appendingPathComponent(target.fileName) }
    public func limit(_ target: HermesMemory.Target) -> Int { limits[target] ?? target.defaultLimit }

    /// The entries as Hermes sees them; [] when the file doesn't exist yet.
    public func entries(_ target: HermesMemory.Target) throws -> [String] {
        HermesMemory.unique(HermesMemory.parse(try read(target)))
    }

    /// Changes one file under Hermes's lock. `change` gets the entries as they are on disk right now.
    /// Returns the entries written (or left as they were when nothing changed).
    @discardableResult
    public func edit(_ target: HermesMemory.Target, _ change: (inout [String]) throws -> Void) throws -> [String] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(url(target).path + ".lock", O_RDWR | O_CREAT, 0o600)
        guard lock >= 0 else { throw HermesMemoryError.unreadable(file: target.fileName) }
        defer { close(lock) }
        let deadline = Date().addingTimeInterval(lockWait)
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else { throw HermesMemoryError.busy }
            usleep(20_000)
        }
        defer { flock(lock, LOCK_UN) }

        let raw = try read(target)
        let limit = limit(target)
        let parsed = HermesMemory.parse(raw)
        let stripped = HermesMemory.strip(raw)
        guard stripped.isEmpty || (HermesMemory.same(stripped, HermesMemory.render(parsed))
                                   && parsed.allSatisfy { HermesMemory.length($0) <= limit }) else {
            throw HermesMemoryError.untidy(file: target.fileName)
        }
        let current = HermesMemory.unique(parsed)
        var next = current
        try change(&next)
        next = HermesMemory.unique(next.map(HermesMemory.strip))
        guard !next.contains(where: \.isEmpty),
              HermesMemory.parse(HermesMemory.render(next)).elementsEqual(next, by: HermesMemory.same) else {
            throw HermesMemoryError.badEntry
        }
        if let long = next.first(where: { HermesMemory.length($0) > limit }) {
            throw HermesMemoryError.tooLong(file: target.fileName, length: HermesMemory.length(long), limit: limit)
        }
        let total = HermesMemory.length(HermesMemory.render(next))
        // A file already over its limit (the limit went down) can still shrink.
        if total > limit, total > HermesMemory.length(HermesMemory.render(current)) {
            throw HermesMemoryError.full(file: target.fileName, total: total, limit: limit)
        }
        if next.elementsEqual(current, by: HermesMemory.same) { return current }
        try write(HermesMemory.render(next), to: url(target))
        return next
    }

    /// The file's text; "" when it doesn't exist. Strict UTF-8, a leading byte-order mark dropped, as
    /// Hermes reads it: a file that doesn't decode is never treated as empty.
    private func read(_ target: HermesMemory.Target) throws -> String {
        let data: Data
        do { data = try Data(contentsOf: url(target)) } catch {
            if (error as NSError).code == NSFileReadNoSuchFileError { return "" }
            throw HermesMemoryError.unreadable(file: target.fileName)
        }
        let text = String(decoding: data, as: UTF8.self)
        guard Data(text.utf8) == data else { throw HermesMemoryError.unreadable(file: target.fileName) }
        return text.unicodeScalars.first == "\u{FEFF}" ? String(text.unicodeScalars.dropFirst()) : text
    }

    private func write(_ text: String, to url: URL) throws {
        let temporary = directory.appendingPathComponent(".mem_daisy_\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw DaisyError.message("Couldn't write \(url.lastPathComponent).") }
        var written = true
        let bytes = Array(text.utf8)
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if count <= 0 { written = false; return }
                offset += count
            }
        }
        written = written && fchmod(fd, 0o600) == 0 && fsync(fd) == 0
        close(fd)
        guard written, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw DaisyError.message("Couldn't write \(url.lastPathComponent).")
        }
    }
}
