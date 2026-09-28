import Foundation

/// Hermes's built-in memory: two small files it curates itself, entries separated by "§" lines.
/// Daisy only reads them so memory stays inspectable; changes go through Hermes.
public enum HermesMemory {
    public static var directory: URL {
        let home = ProcessInfo.processInfo.environment["HERMES_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes")
        return home.appendingPathComponent("memories", isDirectory: true)
    }
    /// What Hermes has learned about the user (USER.md).
    public static func profile(in directory: URL = directory) -> [String] { entries(directory.appendingPathComponent("USER.md")) }
    /// Hermes's own working notes (MEMORY.md).
    public static func notes(in directory: URL = directory) -> [String] { entries(directory.appendingPathComponent("MEMORY.md")) }

    static func entries(_ file: URL) -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n§\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "§" }
    }
}
