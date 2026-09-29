import Foundation

/// Something a task or project points at: a file on this Mac, a web page, a Google Doc or Drive file, a
/// Google Calendar event, a Gmail thread, an Apple note or reminder. Kept on the task (or project) in
/// tasks.json; Hermes's tasks tools (hermes/daisy/tools/tasks.py) read and write the same fields and
/// detect kinds the same way. A file link keeps a bookmark too, so the file is still found after it moves.
public struct TaskLink: Identifiable, Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, CaseIterable, Codable, Sendable, Identifiable {
        case file, url
        case googleDoc = "google_doc", googleDrive = "google_drive", calendarEvent = "calendar_event"
        case gmail, note, reminder

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .file: "File"
            case .url: "Web page"
            case .googleDoc: "Google Doc"
            case .googleDrive: "Drive file"
            case .calendarEvent: "Calendar event"
            case .gmail: "Email"
            case .note: "Note"
            case .reminder: "Reminder"
            }
        }
        /// Opens in the browser.
        public var isWeb: Bool { self != .file && self != .note && self != .reminder }
    }

    public static let perItem = 50
    public static let titleLimit = 200

    public var id: UUID
    public var kind: Kind
    public var title: String
    /// The web link: anything that opens in the browser.
    public var url: String
    /// A file's full path, and a bookmark that follows it when it moves.
    public var path: String
    public var bookmark: Data?
    /// A Google Docs or Drive file.
    public var fileID: String
    /// A Google Calendar event, its calendar, and when it starts (ISO 8601).
    public var eventID: String
    public var calendarID: String
    public var start: String
    /// A Gmail thread, and the message in it.
    public var threadID: String
    public var messageID: String
    /// Apple Notes (x-coredata://…) and Apple Reminders ids.
    public var noteID: String
    public var reminderID: String

    public init(id: UUID = UUID(), kind: Kind, title: String = "", url: String = "", path: String = "", bookmark: Data? = nil,
                fileID: String = "", eventID: String = "", calendarID: String = "", start: String = "",
                threadID: String = "", messageID: String = "", noteID: String = "", reminderID: String = "") {
        self.id = id; self.kind = kind; self.title = title; self.url = url; self.path = path; self.bookmark = bookmark
        self.fileID = fileID; self.eventID = eventID; self.calendarID = calendarID; self.start = start
        self.threadID = threadID; self.messageID = messageID; self.noteID = noteID; self.reminderID = reminderID
        if self.title.isEmpty { self.title = defaultTitle }
    }

    /// A link to a file, titled with its name. No bookmark yet: `refreshed()` adds one.
    public static func file(path: String) -> TaskLink { TaskLink(kind: .file, path: path) }

    // MARK: Pasting

    /// What a pasted URL or path points at, or nil when it's neither. docs.google.com → a Google Doc,
    /// drive.google.com → a Drive file, calendar.google.com → an event when its id can be read, else a web
    /// page; mail.google.com → an email; file:// or a path → a file; anything else on the web → a web page.
    public static func detect(_ text: String) -> TaskLink? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(where: \.isNewline) else { return nil }
        let lower = t.lowercased()
        if lower.hasPrefix("file://") {
            guard let url = URL(string: t), url.isFileURL, url.path.hasPrefix("/") else { return nil }
            return file(path: trimmed(url.path))
        }
        if t.hasPrefix("/") || t.hasPrefix("~/") || t == "~" { return file(path: trimmed((t as NSString).expandingTildeInPath)) }
        if lower.hasPrefix("x-apple-reminderkit://") {
            let id = String(t.split(separator: "/").last ?? "")
            return isReminderID(id) ? TaskLink(kind: .reminder, reminderID: id) : nil
        }
        if lower.hasPrefix("x-coredata://") { return isNoteID(t) ? TaskLink(kind: .note, noteID: t) : nil }
        var web = t
        if !lower.contains("://") {
            let host = String(t.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            guard host.contains("."), matches(host, #"^[A-Za-z0-9.-]+(:[0-9]+)?$"#) else { return nil }
            web = "https://" + t
        }
        guard isWeb(web), var host = URLComponents(string: web)?.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let rest = String(web[web.range(of: "://")!.upperBound...])
        switch host {
        case "docs.google.com":
            if let id = capture(rest, #"/d/([A-Za-z0-9_-]{10,})"#) { return TaskLink(kind: .googleDoc, url: web, fileID: id) }
        case "drive.google.com":
            if let id = capture(rest, #"(?:/d/|/folders/|[?&]id=)([A-Za-z0-9_-]{10,})"#) {
                return TaskLink(kind: .googleDrive, url: web, fileID: id)
            }
        case "calendar.google.com", "google.com":
            if host == "google.com", !(URLComponents(string: web)?.path ?? "").hasPrefix("/calendar") { break }
            if let event = calendarEvent(web) {
                return TaskLink(kind: .calendarEvent, url: web, eventID: event.event, calendarID: event.calendar)
            }
        case "mail.google.com":
            let last = String((URLComponents(string: web)?.fragment ?? "").split(separator: "/").last ?? "")
            return TaskLink(kind: .gmail, url: web, threadID: matches(last, "^[0-9a-fA-F]{16}$") ? last : "")
        default: break
        }
        return TaskLink(kind: .url, url: web)
    }

    /// The event and calendar in a Google Calendar link's eid: base64 of "eventId calendarId", with
    /// "@m" standing for "@gmail.com".
    static func calendarEvent(_ web: String) -> (event: String, calendar: String)? {
        guard let parts = URLComponents(string: web) else { return nil }
        var eid = parts.queryItems?.first { $0.name == "eid" }?.value ?? ""
        if eid.isEmpty {
            let segments = parts.path.split(separator: "/").map(String.init)
            if let at = segments.firstIndex(where: { $0 == "eventedit" || $0 == "event" }), at + 1 < segments.count { eid = segments[at + 1] }
        }
        var base = eid.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base += String(repeating: "=", count: (4 - base.count % 4) % 4)
        guard !eid.isEmpty, let data = Data(base64Encoded: base), let text = String(data: data, encoding: .utf8) else { return nil }
        let pieces = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let event = pieces.first, matches(event, "^[A-Za-z0-9_-]{1,1024}$") else { return nil }
        var calendar = pieces.count > 1 ? pieces[1] : ""
        if calendar.hasSuffix("@m") { calendar = String(calendar.dropLast(2)) + "@gmail.com" }
        guard calendar.isEmpty || matches(calendar, #"^[^\s]{1,1024}$"#) else { return nil }
        return (event, calendar)
    }

    // MARK: Showing and opening

    /// What the title is when none was given.
    public var defaultTitle: String {
        switch kind {
        case .file:
            let name = (path as NSString).lastPathComponent
            return name.isEmpty ? path : name
        case .url:
            var host = URLComponents(string: url)?.host?.lowercased() ?? ""
            if host.hasPrefix("www.") { host.removeFirst(4) }
            return host.isEmpty ? "Web page" : host
        case .googleDoc:
            if url.contains("/spreadsheets/") { return "Google Sheet" }
            if url.contains("/presentation/") { return "Google Slides" }
            if url.contains("/forms/") { return "Google Form" }
            return "Google Doc"
        case .googleDrive: return url.contains("/folders/") ? "Drive folder" : "Drive file"
        default: return kind.title
        }
    }

    /// Where it points, in a few words: the path, the site, the event's day.
    public var detail: String {
        switch kind {
        case .file: return (path as NSString).abbreviatingWithTildeInPath
        case .note: return "Apple Notes"
        case .reminder: return "Apple Reminders"
        case .calendarEvent where !start.isEmpty: return start
        default:
            var host = URLComponents(string: webLink)?.host?.lowercased() ?? ""
            if host.hasPrefix("www.") { host.removeFirst(4) }
            return host
        }
    }

    /// The link to open in the browser: the one saved, or one made from the ids.
    public var webLink: String {
        guard kind.isWeb else { return "" }
        return url.isEmpty ? Self.builtURL(kind: kind, fileID: fileID, eventID: eventID, calendarID: calendarID, start: start,
                                           threadID: threadID, messageID: messageID) : url
    }

    /// A web link from ids alone (what Hermes has for a calendar event or an email).
    public static func builtURL(kind: Kind, fileID: String = "", eventID: String = "", calendarID: String = "", start: String = "",
                                threadID: String = "", messageID: String = "") -> String {
        switch kind {
        case .googleDoc, .googleDrive: return fileID.isEmpty ? "" : "https://drive.google.com/open?id=\(fileID)"
        case .gmail:
            let id = threadID.isEmpty ? messageID : threadID
            return "https://mail.google.com/mail/u/0/" + (id.isEmpty ? "#inbox" : "#all/\(id)")
        case .calendarEvent:
            if !eventID.isEmpty, calendarID.contains("@") {
                let eid = Data("\(eventID) \(calendarID)".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
                    .replacingOccurrences(of: "+", with: "%2B").replacingOccurrences(of: "/", with: "%2F")
                return "https://calendar.google.com/calendar/event?eid=\(eid)"
            }
            let day = start.prefix(10).split(separator: "-").compactMap { Int($0) }
            if matches(start, "^[0-9]{4}-[0-9]{2}-[0-9]{2}"), day.count == 3 {
                return "https://calendar.google.com/calendar/r/day/\(day[0])/\(day[1])/\(day[2])"
            }
            return "https://calendar.google.com/calendar/r"
        default: return ""
        }
    }

    /// Where the file is now: the bookmark first (it follows a move or a rename), then the saved path.
    /// Nil when neither finds it.
    public func resolvedFile() -> URL? {
        guard kind == .file else { return nil }
        if let bookmark {
            var stale = false
            if let found = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil,
                                    bookmarkDataIsStale: &stale), FileManager.default.fileExists(atPath: found.path) {
                return found
            }
        }
        return !path.isEmpty && FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    /// The same link with its path following the file, and a bookmark when it has none (links Hermes
    /// adds only have a path). Unchanged when the file can't be found.
    public func refreshed() -> TaskLink {
        guard kind == .file, let found = resolvedFile() else { return self }
        var link = self
        let moved = found.path != path
        if moved { link.path = found.path }
        if bookmark == nil || moved, let fresh = try? found.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
           fresh.count <= 65_536 {
            link.bookmark = fresh
        }
        return link
    }

    /// The same thing, whatever the link's id or title: used so a link isn't added twice.
    public var reference: String {
        switch kind {
        case .file: return "file:" + path
        case .googleDoc, .googleDrive: return fileID.isEmpty ? "web:" + url : "drive:" + fileID
        case .calendarEvent: return eventID.isEmpty ? "web:" + url : "event:" + eventID
        case .gmail: return threadID.isEmpty && messageID.isEmpty ? "web:" + url : "mail:" + threadID + "/" + messageID
        case .note: return "note:" + noteID
        case .reminder: return "reminder:" + reminderID
        case .url: return "web:" + url
        }
    }

    // MARK: Checking

    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= Self.titleLimit else {
            throw DaisyError.message("Give each link a title up to \(Self.titleLimit) characters.")
        }
        guard url.count <= 2048, path.count <= 1024, (bookmark?.count ?? 0) <= 65_536,
              [fileID, eventID, calendarID, start, threadID, messageID, noteID, reminderID].allSatisfy({ $0.count <= 1024 }) else {
            throw DaisyError.message("That link is too long to keep.")
        }
        if !url.isEmpty, !Self.isWeb(url) { throw DaisyError.message("Web links have to start with http:// or https://.") }
        let fine: Bool
        switch kind {
        case .file: fine = path.hasPrefix("/")
        case .url: fine = !url.isEmpty
        case .googleDoc, .googleDrive: fine = Self.matches(fileID, "^[A-Za-z0-9_-]{1,1024}$") || (fileID.isEmpty && !url.isEmpty)
        case .calendarEvent: fine = !eventID.isEmpty || !url.isEmpty
        case .gmail: fine = !threadID.isEmpty || !messageID.isEmpty || !url.isEmpty
        case .note: fine = Self.isNoteID(noteID)
        case .reminder: fine = Self.isReminderID(reminderID)
        }
        guard fine else { throw DaisyError.message("That \(kind.title.lowercased()) link is missing what it points at.") }
    }

    /// http or https, a host, and nothing a browser would choke on: no spaces, no stray % or brackets, one #
    /// at most. The plugin checks the same pattern.
    public static func isWeb(_ text: String) -> Bool {
        matches(text, webPattern) && !(URLComponents(string: text)?.host ?? "").isEmpty
    }
    static let webPattern = #"^[Hh][Tt][Tt][Pp][Ss]?://(?:[^\s<>"{}|\\^`%\[\]#]|%[0-9A-Fa-f]{2})+(?:#(?:[^\s<>"{}|\\^`%\[\]#]|%[0-9A-Fa-f]{2})*)?$"#
    /// A path without a trailing slash.
    static func trimmed(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
    static func isNoteID(_ text: String) -> Bool { matches(text, #"^x-coredata://[A-Za-z0-9-]+/[A-Za-z]+/p[0-9]+$"#) }
    static func isReminderID(_ text: String) -> Bool { matches(text, "^[A-Za-z0-9-]{1,100}$") }

    static func matches(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
    private static func capture(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    // MARK: Stored form

    // Reading is lenient like tasks: a missing id gets a stable one (the plugin makes the same), a kind
    // that isn't known reads as a web page or a file when it has a url or a path, and a link that has
    // neither is dropped.
    private enum Keys: String, CodingKey {
        case id, kind, title, url, path, bookmark, fileId, eventId, calendarId, start, threadId, messageId, noteId, reminderId
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func text(_ key: Keys) -> String { (try? c.decode(String.self, forKey: key)) ?? "" }
        url = text(.url); path = text(.path); title = text(.title)
        fileID = text(.fileId); eventID = text(.eventId); calendarID = text(.calendarId); start = text(.start)
        threadID = text(.threadId); messageID = text(.messageId); noteID = text(.noteId); reminderID = text(.reminderId)
        let saved = text(.bookmark)
        bookmark = saved.isEmpty ? nil : Data(base64Encoded: saved)
        if let known = Kind(rawValue: text(.kind)) { kind = known }
        else if !url.isEmpty { kind = .url }
        else if !path.isEmpty { kind = .file }
        else { throw DaisyError.message("A link with nothing to point at.") }
        let key = text(.id).trimmingCharacters(in: .whitespacesAndNewlines)
        id = TaskFile.stableID(key.isEmpty ? "link:\(url)\n\(path)\n\(title)" : key)
        if title.isEmpty { title = defaultTitle }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id.uuidString, forKey: .id); try c.encode(kind.rawValue, forKey: .kind); try c.encode(title, forKey: .title)
        for (key, value) in [(Keys.url, url), (.path, path), (.fileId, fileID), (.eventId, eventID), (.calendarId, calendarID),
                             (.start, start), (.threadId, threadID), (.messageId, messageID), (.noteId, noteID), (.reminderId, reminderID)]
        where !value.isEmpty {
            try c.encode(value, forKey: key)
        }
        if let bookmark { try c.encode(bookmark.base64EncodedString(), forKey: .bookmark) }
    }

    /// Reads a list of links, skipping any that can't be read.
    static func list<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> [TaskLink] {
        ((try? container.decode([LenientLink].self, forKey: key)) ?? []).compactMap(\.link)
    }
}

private struct LenientLink: Decodable {
    let link: TaskLink?
    init(from decoder: Decoder) throws { link = try? TaskLink(from: decoder) }
}
