import Foundation

/// One memory store. Before Hermes, Daisy kept what it was told in its own SQLite store
/// (`MemoryStore`, memory.sqlite). This moves those memories into Hermes's files once, as Hermes
/// entries, so Hermes has them in every chat and the two stores stop drifting apart.
///
/// - Each memory becomes one entry: a "Remember that …" note as its text, a named one as
///   "Response style: Keep it short".
/// - USER.md first (it's about the user), MEMORY.md when USER.md is full. The newest memories get the
///   room when there isn't enough for all of them.
/// - Nothing is cut to fit. What doesn't fit is listed in the report and stays in the old store, which
///   the on-device fallback still reads.
/// - Entries Hermes already has, word for word, aren't added twice.
/// - A marker file (the report itself) makes it run once.
public enum LearnedMigration {
    public struct Report: Codable, Sendable, Equatable {
        public struct Moved: Codable, Sendable, Equatable {
            public let key: String
            public let text: String
            public let target: HermesMemory.Target
        }
        public struct Left: Codable, Sendable, Equatable {
            public let key: String
            public let text: String
            public let reason: String
        }
        public var date: Date
        public var moved: [Moved] = []
        /// Keys whose entry Hermes already had.
        public var alreadyThere: [String] = []
        public var left: [Left] = []

        /// Worth telling the user about.
        public var worthMentioning: Bool { !moved.isEmpty || !left.isEmpty }

        public var summary: String {
            if moved.isEmpty && left.isEmpty {
                return alreadyThere.isEmpty ? "No old memories to move." : "Hermes already had the old memories."
            }
            var parts: [String] = []
            if !moved.isEmpty {
                parts.append("Moved \(count(moved.count, "old memory", "old memories")) into Hermes's memory.")
            }
            if !alreadyThere.isEmpty { parts.append("\(count(alreadyThere.count, "was", "were")) already there.") }
            if !left.isEmpty {
                parts.append("\(count(left.count, "didn't", "didn't")) fit and \(left.count == 1 ? "stays" : "stay") in the on-device list: "
                             + left.map { "\($0.key) (\($0.reason))" }.joined(separator: ", ") + ".")
            }
            return parts.joined(separator: " ")
        }

        private func count(_ number: Int, _ one: String, _ many: String) -> String {
            number == 1 ? "1 \(one)" : "\(number) \(many)"
        }
    }

    public static var standardMarker: URL { Configuration.dataDirectory.appendingPathComponent("hermes-memory-move.json") }

    /// The Hermes entry for an old memory.
    public static func entry(for memory: Memory) -> String {
        let value = HermesMemory.strip(memory.value)
        guard !memory.key.hasPrefix("note.") else { return value }
        let label = memory.key.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ")
            .split(separator: " ").joined(separator: " ")
        guard let first = label.first else { return value }
        return first.uppercased() + label.dropFirst() + ": " + value
    }

    /// Moves the memories in, once. nil when the marker says it already ran.
    public static func run(memories: [Memory], files: HermesMemoryFiles, marker: URL, now: Date = Date()) throws -> Report? {
        guard !FileManager.default.fileExists(atPath: marker.path) else { return nil }
        var report = Report(date: now)
        // Newest first for who gets the room; each file then gets its share oldest first, the order
        // they were told.
        let candidates = memories.sorted { $0.updatedAt > $1.updatedAt }.map { (memory: $0, text: entry(for: $0)) }
        var waiting: [(memory: Memory, text: String)] = []
        let largest = HermesMemory.Target.allCases.map(files.limit).max() ?? 0
        let others = Set((try files.entries(.memory)).map { $0.unicodeScalars.map(\.value) })
        for candidate in candidates {
            if candidate.text.isEmpty || HermesMemory.parse(candidate.text).count != 1 {
                report.left.append(.init(key: candidate.memory.key, text: candidate.text, reason: "has a line with only “§” on it"))
            } else if HermesMemory.length(candidate.text) > largest {
                report.left.append(.init(key: candidate.memory.key, text: candidate.text,
                                         reason: "\(HermesMemory.length(candidate.text).formatted()) characters, more than Hermes keeps in one entry"))
            } else if others.contains(candidate.text.unicodeScalars.map(\.value)) {
                report.alreadyThere.append(candidate.memory.key)
            } else {
                waiting.append(candidate)
            }
        }
        for target in [HermesMemory.Target.user, .memory] where !waiting.isEmpty {
            var there: [String] = []
            var taken: [(memory: Memory, text: String)] = []
            var rest: [(memory: Memory, text: String)] = []
            try files.edit(target) { entries in
                there = []; taken = []; rest = []
                let limit = files.limit(target)
                var total = HermesMemory.length(HermesMemory.render(entries))
                for candidate in waiting {
                    if entries.contains(where: { HermesMemory.same($0, candidate.text) }) {
                        there.append(candidate.memory.key)
                        continue
                    }
                    let added = HermesMemory.length(candidate.text) + (entries.isEmpty && taken.isEmpty ? 0 : HermesMemory.length(HermesMemory.delimiter))
                    if total + added <= limit {
                        total += added
                        taken.append(candidate)
                    } else {
                        rest.append(candidate)
                    }
                }
                taken.sort { $0.memory.updatedAt < $1.memory.updatedAt }
                entries += taken.map(\.text)
            }
            report.alreadyThere += there
            report.moved += taken.map { .init(key: $0.memory.key, text: $0.text, target: target) }
            waiting = rest
        }
        for candidate in waiting {
            report.left.append(.init(key: candidate.memory.key, text: candidate.text, reason: "no room left in Hermes's memory"))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try encoder.encode(report).write(to: marker, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        return report
    }
}
