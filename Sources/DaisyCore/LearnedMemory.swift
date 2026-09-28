import Combine
import CryptoKit
import Foundation

/// One line of $HERMES_HOME/daisy/learned.jsonl, the log the Daisy plugin keeps of every memory write
/// (hermes/daisy/learned.py): what changed, in which file, and who did it.
public struct LearnedRecord: Decodable, Sendable, Equatable {
    public enum Action: String, Decodable, Sendable { case add, replace, remove }
    public let at: Date
    /// "background_review" when Hermes's own review of a finished turn saved it, "assistant_tool" when
    /// it happened in the conversation.
    public let origin: String
    public let target: HermesMemory.Target
    public let action: Action
    /// The text as saved (add, replace).
    public let entry: String?
    /// What the call matched on (replace, remove): often just a fragment of the entry.
    public let oldText: String?
    /// The whole entry a replace or remove took out, when the plugin could tell for sure.
    public let was: String?
    public let call: String?

    public init(at: Date, origin: String, target: HermesMemory.Target, action: Action, entry: String? = nil,
                oldText: String? = nil, was: String? = nil, call: String? = nil) {
        self.at = at; self.origin = origin; self.target = target; self.action = action
        self.entry = entry; self.oldText = oldText; self.was = was; self.call = call
    }

    enum CodingKeys: String, CodingKey { case at, origin, target, action, entry, oldText = "old_text", was, call }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        at = Date(timeIntervalSince1970: try values.decode(Double.self, forKey: .at))
        origin = try values.decodeIfPresent(String.self, forKey: .origin) ?? "unknown"
        target = try values.decode(HermesMemory.Target.self, forKey: .target)
        action = try values.decode(Action.self, forKey: .action)
        entry = try values.decodeIfPresent(String.self, forKey: .entry)
        oldText = try values.decodeIfPresent(String.self, forKey: .oldText)
        was = try values.decodeIfPresent(String.self, forKey: .was)
        call = try values.decodeIfPresent(String.self, forKey: .call)
    }

    /// Hermes did it without being asked: anything but the conversation the user was watching.
    public var onItsOwn: Bool { !LearnedLog.conversation.contains(origin) }
}

public enum LearnedLog {
    /// Origins that mean the write happened in a conversation: the user saw it happen there.
    public static let conversation: Set<String> = ["assistant_tool", "foreground"]
    public static var standardURL: URL { HermesMemory.home.appendingPathComponent("daisy/learned.jsonl") }

    /// Every readable line, oldest first. Lines it can't read (one being written, a newer format) are skipped.
    public static func read(_ url: URL) -> [LearnedRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(LearnedRecord.self, from: Data($0)) }
            .sorted { $0.at < $1.at }
    }
}

/// Something Hermes did to its memory on its own, for the Learned feed.
public struct LearnedItem: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable { case learned, changed, forgot }
    public let id: String
    public let kind: Kind
    public let target: HermesMemory.Target
    /// The entry as it is now (learned, changed), or what was taken out (forgot).
    public let text: String
    /// What a change replaced, when known.
    public let previous: String?
    public let date: Date
    /// The log's origin, or nil when no log line explains the entry (added outside a chat, or before
    /// the plugin logged anything).
    public let origin: String?
    /// False for a forgotten entry known only by the fragment Hermes matched on.
    public let exact: Bool

    public var canUndo: Bool {
        switch kind {
        case .learned: return true
        case .changed: return previous != nil
        case .forgot: return exact
        }
    }
    public var canEdit: Bool { kind != .forgot }
}

/// What Daisy keeps between looks, in its own data folder: when each entry first showed up, what the
/// log said about it (the log gets trimmed), what Daisy wrote itself, and what the user marked as fine.
public struct LearnedState: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var first: Date
        public var gone: Date?
        public var origin: String?
        public var logged: Date?
        public var action: String?
        public var previous: String?
        public var matched: String?
        public init(first: Date) { self.first = first }
    }
    public var version = 1
    /// When the feed first looked. Entries already there then aren't news.
    public var baseline: Date?
    /// target → entry → what's known about it.
    public var entries: [String: [String: Entry]] = [:]
    /// target → text Daisy wrote itself (an edit, an undo, the move from the old store) → when.
    public var mine: [String: [String: Date]] = [:]
    /// Items the user said were fine.
    public var kept: [String] = []
    public init() {}
}

public enum LearnedFeed {
    /// Forgotten entries show for this long.
    public static let forgetWindow: TimeInterval = 30 * 86_400
    static let goneKept: TimeInterval = 60 * 86_400

    /// The feed, newest first, from the files as they are now and the log. Updates `state` with what
    /// it saw.
    public static func build(current: [HermesMemory.Target: [String]], records: [LearnedRecord],
                             state: inout LearnedState, now: Date = Date()) -> [LearnedItem] {
        let firstLook = state.baseline == nil
        if firstLook { state.baseline = now }
        let baseline = state.baseline ?? now
        for target in HermesMemory.Target.allCases {
            let present = current[target] ?? []
            var known = state.entries[target.rawValue] ?? [:]
            for entry in present {
                if known[entry] == nil { known[entry] = LearnedState.Entry(first: now) } else { known[entry]?.gone = nil }
            }
            for (entry, info) in known where info.gone == nil && !present.contains(where: { HermesMemory.same($0, entry) }) {
                known[entry]?.gone = now
            }
            known = known.filter { $0.value.gone.map { now.timeIntervalSince($0) < goneKept } ?? true }
            for record in records where record.target == target && record.action != .remove {
                guard let text = record.entry, known[text] != nil else { continue }
                known[text]?.origin = record.origin
                known[text]?.logged = record.at
                known[text]?.action = record.action.rawValue
                known[text]?.previous = record.was
                known[text]?.matched = record.oldText
            }
            state.entries[target.rawValue] = known
            var mine = state.mine[target.rawValue] ?? [:]
            mine = mine.filter { text, marked in present.contains { HermesMemory.same($0, text) } || now.timeIntervalSince(marked) < 600 }
            state.mine[target.rawValue] = mine.isEmpty ? nil : mine
        }
        if state.kept.count > 300 { state.kept.removeFirst(state.kept.count - 300) }

        var items: [LearnedItem] = []
        for target in HermesMemory.Target.allCases {
            let present = current[target] ?? []
            let known = state.entries[target.rawValue] ?? [:]
            let mine = state.mine[target.rawValue] ?? [:]
            for entry in present where mine[entry] == nil {
                guard let info = known[entry] else { continue }
                if let origin = info.origin {
                    guard !LearnedLog.conversation.contains(origin) else { continue }
                    let changed = info.action == LearnedRecord.Action.replace.rawValue
                    let previous = changed ? (info.previous ?? recover(info.matched, in: known, present: present)) : nil
                    items.append(item(changed ? .changed : .learned, target, entry, previous: previous,
                                      date: info.logged ?? info.first, origin: origin, exact: true))
                } else if info.first > baseline {
                    items.append(item(.learned, target, entry, previous: nil, date: info.first, origin: nil, exact: true))
                }
            }
            for record in records where record.target == target && record.action == .remove && record.onItsOwn
                && now.timeIntervalSince(record.at) < forgetWindow {
                if let removed = record.was ?? recover(record.oldText, in: known, present: present) {
                    guard !present.contains(where: { HermesMemory.same($0, removed) }) else { continue }
                    items.append(item(.forgot, target, removed, previous: nil, date: record.at, origin: record.origin, exact: true))
                } else if let fragment = record.oldText, !fragment.isEmpty {
                    items.append(item(.forgot, target, fragment, previous: nil, date: record.at, origin: record.origin, exact: false))
                }
            }
        }
        let kept = Set(state.kept)
        var seen = Set<String>()
        return items.filter { !kept.contains($0.id) && seen.insert($0.id).inserted }.sorted { $0.date > $1.date }
    }

    /// The whole entry a fragment came from, when exactly one entry Daisy saw before (and that's gone
    /// now) contains it.
    static func recover(_ fragment: String?, in known: [String: LearnedState.Entry], present: [String]) -> String? {
        guard let fragment, !fragment.isEmpty else { return nil }
        let candidates = known.filter { text, info in
            info.gone != nil && text.range(of: fragment, options: .literal) != nil && !present.contains { HermesMemory.same($0, text) }
        }
        return candidates.count == 1 ? candidates.first?.key : nil
    }

    static func item(_ kind: LearnedItem.Kind, _ target: HermesMemory.Target, _ text: String, previous: String?,
                     date: Date, origin: String?, exact: Bool) -> LearnedItem {
        let digest = SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return LearnedItem(id: "\(kind.rawValue):\(target.rawValue):\(digest):\(Int(date.timeIntervalSince1970))", kind: kind,
                           target: target, text: text, previous: previous, date: date, origin: origin, exact: exact)
    }
}

/// The Learned feed in the Memory tab: what Hermes saved, changed or dropped on its own (its background
/// review, or no log line at all), newest first, with Undo and Edit. Changes go straight into Hermes's
/// files under its own lock (`HermesMemoryFiles`) and reach the next chat Hermes starts.
@MainActor public final class LearnedMemory: ObservableObject {
    @Published public private(set) var items: [LearnedItem] = []
    /// The last thing that went wrong, in plain words.
    @Published public private(set) var problem: String?
    /// An undo, edit or move is being written.
    @Published public private(set) var working = false
    public let files: HermesMemoryFiles
    public let logURL: URL
    public let stateURL: URL
    private var state = LearnedState()
    private var loaded = false
    private var unreadable = false

    public init(files: HermesMemoryFiles = .standard(), log: URL = LearnedLog.standardURL,
                state: URL = Configuration.dataDirectory.appendingPathComponent("learned.json")) {
        self.files = files; logURL = log; stateURL = state
    }

    /// Reads the files and the log again. Cheap; call it whenever the feed is on screen.
    public func refresh() {
        load()
        var current: [HermesMemory.Target: [String]] = [:]
        do {
            for target in HermesMemory.Target.allCases { current[target] = try files.entries(target) }
        } catch {
            problem = error.localizedDescription
            unreadable = true
            return
        }
        if unreadable { problem = nil; unreadable = false }
        items = LearnedFeed.build(current: current, records: LearnedLog.read(logURL), state: &state)
        save()
    }

    /// Takes a learned entry out, puts back what a change replaced, or puts back a forgotten entry.
    @discardableResult public func undo(_ item: LearnedItem) async -> Bool {
        guard item.canUndo else { return false }
        let restored = item.kind == .learned ? nil : (item.kind == .changed ? item.previous : item.text)
        return await change(item.target, marking: restored) { entries in
            switch item.kind {
            case .learned:
                guard let index = entries.firstIndex(where: { HermesMemory.same($0, item.text) }) else {
                    throw HermesMemoryError.missing(file: item.target.fileName)
                }
                entries.remove(at: index)
            case .changed:
                guard let previous = item.previous, let index = entries.firstIndex(where: { HermesMemory.same($0, item.text) }) else {
                    throw HermesMemoryError.missing(file: item.target.fileName)
                }
                entries[index] = previous
            case .forgot:
                if !entries.contains(where: { HermesMemory.same($0, item.text) }) { entries.append(item.text) }
            }
        }
    }

    /// Rewrites an entry in the user's own words. It's theirs after that, so it leaves the feed.
    @discardableResult public func edit(_ item: LearnedItem, to text: String) async -> Bool {
        let replacement = HermesMemory.strip(text)
        guard item.canEdit else { return false }
        guard !replacement.isEmpty else { problem = "An entry can't be empty. Use Undo to take it out."; return false }
        return await change(item.target, marking: replacement) { entries in
            guard let index = entries.firstIndex(where: { HermesMemory.same($0, item.text) }) else {
                throw HermesMemoryError.missing(file: item.target.fileName)
            }
            entries[index] = replacement
        }
    }

    /// The user looked and it's fine: it leaves the feed.
    public func keep(_ item: LearnedItem) {
        load()
        problem = nil
        state.kept.append(item.id)
        save()
        items.removeAll { $0.id == item.id }
    }

    /// Moves the old on-device memories into Hermes's files, once (see `LearnedMigration`). They count
    /// as the user's own, so they don't show up as learned. nil when there was nothing to do.
    public func moveOldMemories(from store: MemoryStore, marker: URL = LearnedMigration.standardMarker,
                                hermesHome: URL = HermesMemory.home) async -> LearnedMigration.Report? {
        guard !FileManager.default.fileExists(atPath: marker.path),
              FileManager.default.fileExists(atPath: hermesHome.path),
              let memories = try? await store.all() else { return nil }
        load()
        for memory in memories { mark(LearnedMigration.entry(for: memory), in: nil) }
        save()
        let files = self.files
        working = true
        defer { working = false }
        do {
            let report = try await Task.detached { try LearnedMigration.run(memories: memories, files: files, marker: marker) }.value
            refresh()
            return report
        } catch {
            problem = "Moving the old memories into Hermes didn't finish: \(error.localizedDescription)"
            refresh()
            return nil
        }
    }

    private func change(_ target: HermesMemory.Target, marking text: String?,
                        _ edit: @escaping @Sendable (inout [String]) throws -> Void) async -> Bool {
        let files = self.files
        working = true
        defer { working = false }
        problem = nil
        if let text {
            load(); mark(text, in: target); save()
        }
        do {
            _ = try await Task.detached { try files.edit(target, edit) }.value
            refresh()
            return true
        } catch {
            problem = error.localizedDescription
            refresh()
            return false
        }
    }

    /// Marks text Daisy wrote itself; nil marks it in both files.
    private func mark(_ text: String, in target: HermesMemory.Target?) {
        for target in target.map({ [$0] }) ?? HermesMemory.Target.allCases {
            state.mine[target.rawValue, default: [:]][HermesMemory.strip(text)] = Date()
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let data = try? Data(contentsOf: stateURL), let saved = try? decoder.decode(LearnedState.self, from: data) {
            state = saved
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            try encoder.encode(state).write(to: stateURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        } catch {
            problem = "Couldn't save the Learned feed's notes: \(error.localizedDescription)"
        }
    }
}
