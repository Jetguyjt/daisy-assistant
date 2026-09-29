import Foundation

/// Where a task stands. Stored as the id (`rawValue`), shown by `title`. The same nine live in the
/// Hermes plugin (hermes/daisy/tools/tasks.py), and both read odd status text the same way.
public enum TaskStatus: String, CaseIterable, Codable, Sendable, Identifiable, ExpressibleByStringLiteral {
    case idea, todo
    case inProgress = "in_progress", needsReview = "needs_review"
    case waiting, blocked, submitted, done, dropped

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .idea: "Idea"
        case .todo: "To do"
        case .inProgress: "In progress"
        case .needsReview: "Needs review"
        case .waiting: "Waiting"
        case .blocked: "Blocked"
        case .submitted: "Submitted"
        case .done: "Done"
        case .dropped: "Dropped"
        }
    }
    /// One line on what it means, for the status menu.
    public var hint: String {
        switch self {
        case .idea: "Maybe someday"
        case .todo: "Not started yet"
        case .inProgress: "Being worked on"
        case .needsReview: "Drafted, waiting on feedback or a read-through"
        case .waiting: "On someone else: a recommender, a reply"
        case .blocked: "Can't move until something changes"
        case .submitted: "Sent in. Counts as finished"
        case .done: "Finished"
        case .dropped: "Not doing it"
        }
    }
    /// Submitted, done and dropped. Everything else is open.
    public var isFinished: Bool { self == .submitted || self == .done || self == .dropped }
    public var isOpen: Bool { !isFinished }

    /// `"done"` in code reads the same as a stored "done".
    public init(stringLiteral value: String) { self = Self.read(value).status }
    public init(from decoder: Decoder) throws { self = Self.read(try decoder.singleValueContainer().decode(String.self)).status }

    /// Any status text as a status. Ids, names and old values ("planned", "completed") map straight
    /// across; other text goes by its words ("needs to get started" is To do). Text with no known words
    /// is To do, and comes back as `leftover` so it can be kept in the notes.
    public static func read(_ text: String) -> (status: TaskStatus, leftover: String?) {
        let raw = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let key = raw.replacingOccurrences(of: "[_\\-]+", with: " ", options: .regularExpression).lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if key.isEmpty { return (.todo, nil) }
        if let exact = exact[key] { return (exact, nil) }
        let words = String(key.unicodeScalars.map { ("a"..."z").contains($0) || ("0"..."9").contains($0) ? Character($0) : " " })
            .split(separator: " ").map(String.init)
        for (status, patterns) in wordRules where patterns.contains(where: { has(words, $0) }) { return (status, nil) }
        return (.todo, raw)
    }

    private static let exact: [String: TaskStatus] = [
        "idea": .idea, "todo": .todo, "to do": .todo, "planned": .todo, "pending": .todo,
        "in progress": .inProgress, "needs review": .needsReview, "waiting": .waiting, "blocked": .blocked,
        "submitted": .submitted, "done": .done, "completed": .done,
        "dropped": .dropped, "cancelled": .dropped, "canceled": .dropped
    ]
    /// First match wins. "word*" matches any word starting with it; "to do" is two words in a row.
    private static let wordRules: [(TaskStatus, [String])] = [
        (.todo, ["start*", "todo*", "to do", "not started", "planned"]),
        (.inProgress, ["progress*", "drafting", "working", "writing"]),
        (.needsReview, ["review*", "feedback", "edit*", "proofread*"]),
        (.waiting, ["wait*"]),
        (.blocked, ["block*", "stuck"]),
        (.submitted, ["submit*", "sent"]),
        (.done, ["done", "complete*", "finish*"]),
        (.dropped, ["cancel*", "drop*", "skip*"]),
        (.idea, ["idea*", "someday", "maybe"])
    ]
    private static func has(_ words: [String], _ phrase: String) -> Bool {
        let parts = phrase.split(separator: " ").map(String.init)
        guard words.count >= parts.count else { return false }
        return (0...(words.count - parts.count)).contains { start in
            parts.indices.allSatisfy { n in
                let part = parts[n], word = words[start + n]
                return part.hasSuffix("*") ? word.hasPrefix(String(part.dropLast())) : word == part
            }
        }
    }

    /// The chip color: calm and distinct from the others, worked out from the theme so it sits with any
    /// accent. Not started and in progress use the theme's own colors; review, waiting, blocked and
    /// submitted get soft fixed hues, and one that sits too close to the accent swaps to a spare hue.
    public func tint(in palette: ThemePalette) -> RGB {
        switch self {
        case .idea: return palette.dim
        case .todo: return palette.steel
        case .inProgress: return palette.accent
        case .done: return Self.calm(.submitted, palette).mixed(with: palette.dim, 0.55)
        case .dropped: return palette.dim.mixed(with: palette.void, 0.35)
        default: return Self.calm(self, palette)
        }
    }

    private static let hues: [(TaskStatus, Double)] = [(.needsReview, 268), (.waiting, 200), (.blocked, 4), (.submitted, 150)]
    private static let spareHues: [Double] = [320, 100, 236]
    private static func calm(_ status: TaskStatus, _ palette: ThemePalette) -> RGB {
        let (accent, saturation, _) = palette.accent.hsb
        func near(_ a: Double, _ b: Double) -> Bool { ThemePalette.hueDistance(a / 360, b / 360) < 28.0 / 360 }
        var chosen: [Double] = []
        var hue = 0.0
        for (candidate, preferred) in hues {
            var pick = preferred
            if saturation > 0.25, near(preferred, accent * 360) {
                pick = spareHues.first { spare in
                    !near(spare, accent * 360) && !hues.contains { near(spare, $0.1) } && !chosen.contains { near(spare, $0) }
                } ?? preferred
            }
            chosen.append(pick)
            if candidate == status { hue = pick }
        }
        return RGB(h: hue / 360, s: 0.42, v: 0.92)
    }
}
