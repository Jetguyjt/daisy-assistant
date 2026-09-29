import CryptoKit
import Foundation

/// A project: the name its tasks share, plus a color, a status, notes, a due date, links and a folder on
/// this Mac (context for Hermes). Tasks point at their project by name (`WorkItem.project`), matched
/// without case, so old files and anything that only knows names keep working.
///
/// A name on a task that has no project of its own still reads as a project, with an id and a color made
/// from the name (the plugin makes the same ones). Nothing is written for it until the file next changes;
/// then it's saved with the rest, revision 0.
public struct Project: Identifiable, Codable, Sendable, Equatable {
    public enum Status: String, CaseIterable, Codable, Sendable, Identifiable {
        case active, paused, done, archived
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .active: "Active"
            case .paused: "Paused"
            case .done: "Done"
            case .archived: "Archived"
            }
        }
        public var hint: String {
            switch self {
            case .active: "Being worked on"
            case .paused: "On hold for now"
            case .done: "Finished, still shown"
            case .archived: "Put away: hidden until you show archived projects"
            }
        }
        /// Ids and a few other words ("on hold", "completed"); anything else is active.
        public static func read(_ text: String) -> Status {
            let key = text.split(whereSeparator: { $0.isWhitespace || $0 == "_" || $0 == "-" }).joined(separator: " ").lowercased()
            return ["paused": .paused, "pause": .paused, "on hold": .paused, "done": .done, "completed": .done, "finished": .done,
                    "archived": .archived, "archive": .archived][key] ?? .active
        }
    }

    public static let nameLimit = 100
    public static let notesLimit = 8000
    public static let folderLimit = 1024

    public var id: UUID
    public var name: String
    public var color: ProjectColor
    public var notes: String
    public var status: Status
    public var due: String
    public var links: [TaskLink]
    public var folder: String
    public var revision: Int
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, color: ProjectColor = .accent, notes: String = "", status: Status = .active,
                due: String = "", links: [TaskLink] = [], folder: String = "", revision: Int = 0) {
        self.id = id; self.name = name; self.color = color; self.notes = notes; self.status = status; self.due = due
        self.links = links; self.folder = folder; self.revision = revision; updatedAt = Date()
    }

    /// The project a task names when there isn't one saved: the id and color come from the name.
    public static func named(_ name: String) -> Project {
        let shown = squashed(name)
        return Project(id: derivedID(shown), name: shown, color: .derived(for: shown))
    }

    /// How names match: spaces squashed, case ignored. "" is no project.
    public var key: String { Self.key(name) }
    public static func key(_ name: String) -> String { squashed(name).lowercased() }
    /// A name as it's saved: spaces squashed, trimmed.
    public static func squashed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    static func digest(_ name: String) -> [UInt8] { Array(SHA256.hash(data: Data(("daisy-project:" + key(name)).utf8))) }
    /// The id a project made from a task's name gets, the same the plugin makes.
    public static func derivedID(_ name: String) -> UUID {
        var bytes = Array(digest(name).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Checks it can be saved. Links in `kept` (the ones already saved) aren't checked again.
    public func validate(keeping kept: [TaskLink] = []) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, name.count <= Self.nameLimit, notes.count <= Self.notesLimit, folder.count <= Self.folderLimit else {
            throw DaisyError.message("Use a project name up to \(Self.nameLimit) characters, and notes up to 8,000.")
        }
        guard trimmed.lowercased() != "no project" else { throw DaisyError.message("“No project” is where tasks without one go. Pick another name.") }
        guard folder.isEmpty || folder.hasPrefix("/") else { throw DaisyError.message("The folder needs its full path.") }
        if !due.isEmpty { guard WorkItem.isDate(due) else { throw DaisyError.message("Use a real due date in YYYY-MM-DD form, or leave it blank.") } }
        guard links.count <= TaskLink.perItem else { throw DaisyError.message("A project can have up to \(TaskLink.perItem) links.") }
        for link in links where !kept.contains(link) { try link.validate() }
    }

    // Reading never drops a project for an odd field: a color or status that isn't known gets a default,
    // a missing id comes from the name. One with no name can't hold tasks and is skipped.
    private enum Keys: String, CodingKey { case id, name, color, notes, status, due, links, folder, revision, updatedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func text(_ key: Keys) -> String { (try? c.decode(String.self, forKey: key)) ?? "" }
        name = Self.squashed(text(.name))
        guard !name.isEmpty else { throw DaisyError.message("A project with no name.") }
        let key = text(.id).trimmingCharacters(in: .whitespacesAndNewlines)
        id = key.isEmpty ? Self.derivedID(name) : TaskFile.stableID(key)
        color = ProjectColor(rawValue: text(.color)) ?? .derived(for: name)
        notes = text(.notes); status = Status.read(text(.status)); due = text(.due); folder = text(.folder)
        links = TaskLink.list(c, Keys.links)
        revision = (try? c.decode(Int.self, forKey: .revision)) ?? 0
        updatedAt = WorkItem.readDate(c, .updatedAt) ?? Date()
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id.uuidString, forKey: .id); try c.encode(name, forKey: .name); try c.encode(color.rawValue, forKey: .color)
        try c.encode(notes, forKey: .notes); try c.encode(status.rawValue, forKey: .status); try c.encode(due, forKey: .due)
        try c.encode(links, forKey: .links); try c.encode(folder, forKey: .folder); try c.encode(revision, forKey: .revision)
        try c.encode(WorkItem.stamp(updatedAt), forKey: .updatedAt)
    }
}

/// A project's color, from a small set that sits with any theme. Stored by name.
public enum ProjectColor: String, CaseIterable, Codable, Sendable, Identifiable {
    case accent, red, orange, yellow, green, teal, blue, violet, pink, gray

    public var id: String { rawValue }
    public var title: String { self == .accent ? "Theme" : rawValue.capitalized }

    /// The eight a project made from a task's name picks from, by its name.
    static let picks: [ProjectColor] = [.red, .orange, .yellow, .green, .teal, .blue, .violet, .pink]
    public static func derived(for name: String) -> ProjectColor { picks[Int(Project.digest(name)[16]) % picks.count] }

    /// Calm, like the status chips: the theme's own accent and steel, or a soft fixed hue.
    public func tint(in palette: ThemePalette) -> RGB {
        switch self {
        case .accent: return palette.accent
        case .gray: return palette.steel
        case .red: return RGB(h: 4 / 360, s: 0.5, v: 0.95)
        case .orange: return RGB(h: 26 / 360, s: 0.55, v: 0.96)
        case .yellow: return RGB(h: 48 / 360, s: 0.5, v: 0.95)
        case .green: return RGB(h: 140 / 360, s: 0.45, v: 0.85)
        case .teal: return RGB(h: 178 / 360, s: 0.5, v: 0.85)
        case .blue: return RGB(h: 214 / 360, s: 0.5, v: 0.98)
        case .violet: return RGB(h: 266 / 360, s: 0.42, v: 0.98)
        case .pink: return RGB(h: 324 / 360, s: 0.42, v: 0.98)
        }
    }
}

/// What happens to a project's tasks when the project is deleted.
public enum ProjectDeletion: Sendable {
    /// They stay, with no project.
    case keepTasks
    /// They go too, with everything under them.
    case deleteTasks
}
