import CryptoKit
import Darwin
import Foundation

/// One card the guard showed in a Daisy chat, from asks.jsonl (hermes/daisy/guard/asks.py).
public struct PermissionAsk: Equatable, Sendable {
    public let at: Date
    public let session: String
    public let tool: String
    /// The card's first line: "Add text to the end of “Essay”".
    public let title: String
    /// The typed tool's risk ("write", "send"), or the guard's rule for anything else ("run").
    public let risk: String
    /// A standing OK could cover it; `scope` is what that OK would have to name.
    public let grantable: Bool
    public let scope: String
    public let app: String
    public let script: String
    /// When no OK can cover it: a short code and one line ("send", "Sends always ask").
    public let why: String
    public let reason: String

    init?(_ fields: [String: Any]) {
        guard let tool = fields["tool"] as? String, !tool.isEmpty, let seconds = (fields["at"] as? NSNumber)?.doubleValue else { return nil }
        at = Date(timeIntervalSince1970: seconds)
        self.tool = tool
        session = fields["session"] as? String ?? ""
        title = fields["title"] as? String ?? ""
        risk = fields["risk"] as? String ?? ""
        grantable = (fields["grantable"] as? Bool) == true
        scope = fields["scope"] as? String ?? ""
        app = fields["app"] as? String ?? ""
        script = fields["script"] as? String ?? ""
        why = fields["why"] as? String ?? ""
        reason = fields["reason"] as? String ?? ""
    }
}

/// Exactly what one Permissions switch turns on, scoped the way the guard scopes a card
/// (grants.call_scope): one tool by name, clicking and typing in one app, or one script as it is now.
public struct PermissionScope: Hashable, Sendable {
    public let tool: String
    /// Clicking and typing: the app as it was typed ("Pages").
    public let app: String
    /// A script's real path.
    public let script: String

    /// The guard's key for it: "docs_write", "computer_act@pages", "script:/path/to/fix.py".
    public var key: String {
        if !script.isEmpty { return "script:" + script }
        return app.isEmpty ? tool : tool + "@" + Self.appKey(app)
    }

    /// From a card the guard said an OK could cover. Nil when the line doesn't hold together, or names
    /// something no switch should turn on. The guard checks every call again either way; this keeps the
    /// list from offering a switch that would do nothing.
    public init?(ask: PermissionAsk) {
        guard ask.grantable else { return nil }
        if !ask.script.isEmpty {
            guard ask.tool == "terminal", ask.script.hasPrefix("/"), ask.scope == "script:" + ask.script else { return nil }
            self.init(tool: ask.tool, app: "", script: ask.script)
            return
        }
        let app = ask.app.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard Self.switchable(ask.tool), ask.scope == (app.isEmpty ? ask.tool : ask.tool + "@" + Self.appKey(app)) else { return nil }
        if !app.isEmpty {
            let low = app.lowercased()
            guard app.count <= 60, !low.contains("daisy"), !Self.terminals.contains(where: low.contains) else { return nil }
        }
        self.init(tool: ask.tool, app: app, script: "")
    }

    init(tool: String, app: String, script: String) { self.tool = tool; self.app = app; self.script = script }

    /// Apps are matched the way the guard matches them: spaces squeezed, lower case.
    public static func appKey(_ app: String) -> String {
        app.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// Terminals, where typing runs commands (grants.TERMINALS).
    static let terminals = ["terminal", "iterm", "warp", "ghostty", "kitty", "alacritty", "wezterm", "hyper"]
    /// Tools a grant never names, whatever a log line says (grants._check_tool).
    static let neverTools: Set<String> = ["approval_grant", "terminal", "execute_code", "process", "process_manage",
                                           "write_file", "patch"]
    /// Words in a tool's name that mean it sends, deletes, shares or installs (classify.py's word lists,
    /// less "upload" and "attach": drive_upload keeps files private and can be allowed).
    static let neverWords: Set<String> = [
        "send", "reply", "forward", "post", "publish", "tweet", "retweet", "toot", "dm", "invite", "submit", "broadcast",
        "respond", "rsvp", "pay", "purchase", "buy", "checkout", "transfer", "donate", "comment",
        "delete", "remove", "trash", "destroy", "purge", "erase", "wipe", "drop", "unlink", "rm", "del", "clear", "empty",
        "expunge", "revoke", "share", "unshare", "permission", "permissions", "grant", "install"]

    static func switchable(_ tool: String) -> Bool {
        guard !tool.isEmpty, tool.count <= 128, !neverTools.contains(tool),
              tool.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_-.".unicodeScalars.contains($0) })
        else { return false }
        return neverWords.isDisjoint(with: words(tool))
    }

    /// snake_case, kebab-case and camelCase split into lower-case words.
    static func words(_ name: String) -> Set<String> {
        var result: Set<String> = []
        var current = ""
        var previousLower = false
        for character in name {
            if !(character.isLetter || character.isNumber) {
                if !current.isEmpty { result.insert(current.lowercased()); current = "" }
                previousLower = false
                continue
            }
            if character.isUppercase && previousLower { result.insert(current.lowercased()); current = "" }
            current.append(character)
            previousLower = character.isLowercase || character.isNumber
        }
        if !current.isEmpty { result.insert(current.lowercased()) }
        return result
    }
}

/// One row of the Permissions list.
public struct PermissionRow: Identifiable, Equatable, Sendable {
    public enum Group: Sendable, Equatable { case allowed, request, often, locked }
    public let id: String
    public let group: Group
    /// Plain words: "Add to Google Docs", "Run ~/essays/format.py", or what the user said.
    public let label: String
    /// Under the label: what a grant from Daisy covers, or a note about what still asks.
    public let lines: [String]
    /// On: steps that ran under it in the window. Asked often or locked: cards in the window.
    public let count: Int
    /// The last of those.
    public let last: Date?
    /// On: when it was given.
    public let given: Date?
    /// Locked: why it always asks. On: a script that changed since, so it asks again.
    public let reason: String
    public let grantID: String?
    /// Asked often: what the switch turns on.
    public let scope: PermissionScope?

    public var isOn: Bool { group == .allowed || group == .request }
    /// Locked rows never switch. On rows switch off by revoking; asked-often rows switch on by scope.
    public var canSwitch: Bool { group != .locked && (isOn ? grantID != nil : scope != nil) }
}

/// The Permissions list, built from what Daisy actually had to ask (asks.jsonl), what's allowed
/// (grants.json) and what ran under it (grants.jsonl). Nothing on it is fixed: a kind of step shows up
/// once it's been carded often enough, and drops off once it hasn't.
public enum Permissions {
    /// Cards in the window before something counts as asked often.
    public static let minimumAsks = 3
    public static let window: TimeInterval = 14 * 24 * 3600
    public static let stillAsks = "Sends, shares and deletes always ask."
    static let changedScript = "Changed since you turned it on, so it asks again. Turn it off and on to allow it as it is now."

    public static func rows(asks: [PermissionAsk], grants: [StandingGrant], log: [GrantLogEntry], now: Date = Date(),
                            home: String = NSHomeDirectory(), changed: (StandingGrant) -> Bool = { _ in false }) -> [PermissionRow] {
        let since = now.addingTimeInterval(-window)
        let live = grants.filter { $0.isLive(at: now) }
        var steps: [String: (count: Int, last: Date)] = [:]
        for entry in log where entry.at >= since && !entry.grant.isEmpty {
            let before = steps[entry.grant]
            steps[entry.grant] = ((before?.count ?? 0) + 1, max(before?.last ?? entry.at, entry.at))
        }
        func row(_ grant: StandingGrant) -> PermissionRow {
            let ran = steps[grant.id]
            return PermissionRow(id: "grant:" + grant.id, group: grant.forever ? .allowed : .request,
                                 label: PermissionLabels.label(grant, home: home), lines: PermissionLabels.lines(grant, home: home),
                                 count: ran?.count ?? 0, last: ran?.last, given: grant.given,
                                 reason: changed(grant) ? changedScript : "", grantID: grant.id, scope: nil)
        }
        let allowed = live.filter(\.forever).sorted { $0.given > $1.given }.map { row($0) }
        let request = live.filter { !$0.forever }.sorted { $0.given > $1.given }.map { row($0) }

        // Asks in the window, by what a switch would name, or by tool and reason when none can.
        var order: [String] = []
        var buckets: [String: (scope: PermissionScope?, asks: [PermissionAsk])] = [:]
        for ask in asks where ask.at >= since && ask.at <= now.addingTimeInterval(300) {
            let scope = PermissionScope(ask: ask)
            let key = scope.map { "scope:" + $0.key } ?? "ask:\(ask.tool)|\(ask.why)"
            if buckets[key] == nil { order.append(key); buckets[key] = (scope, []) }
            buckets[key]?.asks.append(ask)
        }
        let forever = live.filter(\.forever)
        var often: [PermissionRow] = []
        var locked: [PermissionRow] = []
        for key in order {
            guard let bucket = buckets[key], bucket.asks.count >= minimumAsks else { continue }
            let asked = bucket.asks.sorted { $0.at < $1.at }
            let latest = asked[asked.count - 1]
            let titles = asked.suffix(20).map(\.title)
            if let scope = bucket.scope {
                if forever.contains(where: { $0.covers(scope) }) { continue }
                let label = PermissionLabels.label(tool: scope.tool, app: scope.app, script: scope.script, titles: titles, home: home)
                often.append(PermissionRow(id: key, group: .often, label: label, lines: PermissionLabels.notes(scope),
                                           count: asked.count, last: latest.at, given: nil, reason: "", grantID: nil, scope: scope))
            } else {
                let label = PermissionLabels.label(tool: latest.tool, app: "", script: "", why: latest.why, titles: titles, home: home)
                let reason = asked.reversed().first { !$0.reason.isEmpty }?.reason ?? "This always asks"
                locked.append(PermissionRow(id: key, group: .locked, label: label, lines: [], count: asked.count, last: latest.at,
                                            given: nil, reason: reason, grantID: nil, scope: nil))
            }
        }
        let busiest: (PermissionRow, PermissionRow) -> Bool = { a, b in
            a.count != b.count ? a.count > b.count : (a.last ?? .distantPast) > (b.last ?? .distantPast)
        }
        return allowed + request + often.sorted(by: busiest) + locked.sorted(by: busiest)
    }
}

extension StandingGrant {
    /// Whether this grant already covers a scope, the way the guard's grants.covers reads it (scripts
    /// also have to be as they were, which the guard checks when it runs).
    public func covers(_ scope: PermissionScope) -> Bool {
        if !scope.script.isEmpty {
            let place = (scope.script as NSString).deletingLastPathComponent
            return pins[scope.script] != nil && (scripts.contains(scope.script) || scripts.contains(place))
        }
        guard tools.contains(scope.tool) else { return false }
        return scope.app.isEmpty || PermissionScope.appKey(app) == PermissionScope.appKey(scope.app)
    }
}

/// Plain words for the Permissions list. Rows come from what was asked; this only names them.
public enum PermissionLabels {
    /// Daisy's own typed tools. Anything else is named from its card titles or its tool name.
    static let tools: [String: String] = [
        "docs_write": "Add to Google Docs",
        "sheets_write": "Change Google Sheets",
        "calendar_write": "Add and change calendar events",
        "gmail_modify": "Archive, label and mark emails",
        "drive_upload": "Upload to Google Drive (kept private)",
        "notes_create": "Create Apple Notes",
        "notes_append": "Add to Apple Notes",
        "reminders_add": "Add reminders",
        "reminders_complete": "Check off reminders",
        "contacts_alias_save": "Save nicknames for contacts",
        "tasks_add": "Add tasks",
        "tasks_update": "Change tasks",
        "computer_act": "Click and type in {app}",
        "gmail_send": "Send emails",
        "gmail_reply": "Reply to emails",
        "gmail_delete": "Move emails to the trash",
        "calendar_delete": "Delete calendar events",
        "drive_share": "Share Drive files",
        "drive_delete": "Delete Drive files",
        "imsg_send": "Send texts",
        "tasks_remove": "Remove tasks",
    ]
    /// Things no switch covers, named by why, when their card titles don't share a name.
    static let whys: [String: String] = [
        "send": "Send things", "share": "Share things", "delete": "Delete things", "install": "Install software",
        "command": "Run commands", "code": "Run code", "people": "Changes that reach other people",
        "calendar": "Change the calendar another way", "settings": "Change Hermes settings",
        "memory": "Change memory, skills or scheduled jobs", "open": "Open new sites after reading",
        "browser": "Drive the browser or an app directly", "ui": "Risky clicks and keys",
        "terminal": "Click and type in a terminal", "ui-app": "Click and type",
    ]
    static let smallWords: Set<String> = ["to", "the", "a", "an", "of", "in", "on", "for", "with", "from", "and", "at",
                                          "into", "by", "as"]

    public static func label(tool: String, app: String = "", script: String = "", why: String = "", titles: [String] = [],
                             home: String = NSHomeDirectory()) -> String {
        if !script.isEmpty { return "Run " + shortPath(script, home: home) }
        if let known = tools[tool] { return known.replacingOccurrences(of: "{app}", with: app.isEmpty ? "apps" : app) }
        let place = app.isEmpty ? "" : " in " + app
        if tool.hasPrefix("mcp_") { return mcp(tool) + place }
        if let shared = sharedStart(titles) { return shared }
        if let named = whys[why] { return named }
        let phrase = ToolPhrases.describe(title: tool, kind: nil).title
        return titles.last.flatMap { $0.isEmpty ? nil : $0 } ?? (phrase + place)
    }

    /// A grant's name on the list: what the user said for one Daisy asked for, else its scope.
    static func label(_ grant: StandingGrant, home: String) -> String {
        if grant.by == "settings" || grant.what.isEmpty {
            if let script = grant.scripts.first, grant.tools.isEmpty {
                return (grant.pins[script] == nil ? "Run the scripts in " : "Run ") + shortPath(script, home: home)
            }
            if grant.tools.count == 1 { return label(tool: grant.tools[0], app: grant.app, home: home) }
            if !grant.what.isEmpty { return grant.what }
            return grant.tools.map { label(tool: $0, app: grant.app, home: home) }.joined(separator: ", ")
        }
        return grant.fromCard ? grant.what : "“\(grant.what)”"
    }

    /// Lines under a grant's name: for one Daisy asked for, everything it covers; for a switch, what
    /// still asks.
    static func lines(_ grant: StandingGrant, home: String) -> [String] {
        if grant.by == "settings" {
            var notes: [String] = []
            if !grant.scripts.isEmpty { notes.append("Held to how it was when you turned it on. If it changes, it asks again.") }
            if !grant.app.isEmpty { notes.append("Send, delete or share buttons, Return and shortcuts in \(grant.app) still ask.") }
            return notes
        }
        return grant.covers
    }

    /// What still asks inside a scope a switch would turn on.
    static func notes(_ scope: PermissionScope) -> [String] {
        if !scope.script.isEmpty { return ["Turning it on allows it as it is now. If it changes, it asks again."] }
        if !scope.app.isEmpty { return ["Send, delete or share buttons, Return and shortcuts in \(scope.app) still ask."] }
        return []
    }

    /// "Update page in Notion" from mcp__notion__update_page.
    static func mcp(_ name: String) -> String {
        let body = name.hasPrefix("mcp__") ? String(name.dropFirst(5)) : String(name.dropFirst(4))
        let parts = body.components(separatedBy: "__")
        func spaced(_ text: String) -> String {
            text.split(whereSeparator: { $0 == "_" || $0 == "-" }).joined(separator: " ")
        }
        let tool = spaced(parts.count > 1 ? parts.dropFirst().joined(separator: " ") : body)
        let server = parts.count > 1 ? spaced(parts[0]) : ""
        let words = tool.prefix(1).uppercased() + tool.dropFirst()
        return server.isEmpty ? words : "\(words) in \(server.prefix(1).uppercased() + server.dropFirst())"
    }

    /// The words every title starts with, up to the first quoted name and without a dangling "to" or
    /// "the": "Add a row to “Budget”" and "Add a row to “Trips”" give "Add a row". Nil under two words.
    static func sharedStart(_ titles: [String]) -> String? {
        let split = titles.map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }.filter { !$0.isEmpty }
        guard var shared = split.first else { return nil }
        for words in split.dropFirst() {
            var count = 0
            while count < min(shared.count, words.count), shared[count] == words[count] { count += 1 }
            shared = Array(shared.prefix(count))
        }
        if let quoted = shared.firstIndex(where: { $0.contains(where: { "“”\"‘’'«".contains($0) }) }) {
            shared = Array(shared.prefix(quoted))
        }
        if let last = shared.last, last.hasSuffix(":") { shared[shared.count - 1] = String(last.dropLast()) }
        while let last = shared.last, smallWords.contains(last.lowercased()) { shared.removeLast() }
        return shared.count >= 2 ? shared.joined(separator: " ") : nil
    }

    static func shortPath(_ path: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

extension GrantsFile {
    /// Most bytes a script can be and still be held to its hash, and most scripts in one folder
    /// (grants.MAX_PIN_BYTES and MAX_PINNED).
    static let maxPinBytes = 1024 * 1024
    static let maxPinned = 100
    static let codeSuffixes = [".py", ".sh", ".bash", ".zsh", ".command", ".js", ".mjs", ".cjs", ".ts", ".rb", ".pl"]

    /// Cards the guard showed since `date`, oldest first. Missing or unreadable is none; a line that
    /// isn't one is skipped.
    public func asks(since date: Date) -> [PermissionAsk] {
        guard let data = try? Data(contentsOf: asksURL) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            guard let fields = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let ask = PermissionAsk(fields), ask.at >= date else { return nil }
            return ask
        }
    }

    /// The forever grant a Permissions switch writes: exactly one scope, in the guard's fields, marked
    /// as given in settings. A script is held to its hash (and its folder's scripts to theirs) as of now.
    public func foreverGrant(for scope: PermissionScope, label: String, now: Date = Date(),
                             home: String = NSHomeDirectory()) throws -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(Self.newID()), "what": .string(label), "duration": "forever", "by": "settings",
            "given": .number(now.timeIntervalSince1970), "app": .string(scope.app),
        ]
        if !scope.script.isEmpty {
            let pins = try scriptPins(scope.script)
            fields["tools"] = []
            fields["scripts"] = [.string(scope.script)]
            fields["pins"] = .object(pins.mapValues(JSONValue.string))
            fields["covers"] = [.string("Run \(PermissionLabels.shortPath(scope.script, home: home)), as it is now. If it or a "
                                        + "script next to it changes, it asks again.")]
        } else {
            guard PermissionScope.switchable(scope.tool) else {
                throw DaisyError.message("\(scope.tool) always asks, so it can't be turned on.")
            }
            var covers: [JSONValue] = [.string("\(label) (\(scope.tool))")]
            if !scope.app.isEmpty {
                covers.append(.string("Clicks on send, delete or share buttons, Return, shortcuts and line breaks in \(scope.app) still ask."))
            }
            fields["tools"] = [.string(scope.tool)]
            fields["scripts"] = []
            fields["pins"] = .object([:])
            fields["covers"] = .array(covers)
        }
        return .object(fields)
    }

    /// Hashes for a script and every script next to it, the way grants.snapshot takes them. Throws when
    /// the script is gone, moved behind a link, too big, in Daisy's own settings, or in a folder of more
    /// than 100 scripts.
    public func scriptPins(_ script: String) throws -> [String: String] {
        guard script.hasPrefix("/"), let real = Self.realPath(script), real == script else {
            throw DaisyError.message("\((script as NSString).lastPathComponent) isn't where it was anymore.")
        }
        var info = stat()
        guard stat(real, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw DaisyError.message("\((script as NSString).lastPathComponent) isn't a file anymore.")
        }
        let settings = [folder.path, folder.deletingLastPathComponent().appendingPathComponent("plugins/daisy").path]
            .map { Self.realPath($0) ?? $0 }
        guard !settings.contains(where: { real.hasPrefix($0 + "/") }) else {
            throw DaisyError.message("Scripts in Daisy's own settings can't be allowed.")
        }
        var pins = try Self.snapshot((real as NSString).deletingLastPathComponent)
        if pins[real] == nil {
            guard Int(info.st_size) <= Self.maxPinBytes else {
                throw DaisyError.message("\((real as NSString).lastPathComponent) is over 1 MB, too big to hold to how it is now.")
            }
            pins[real] = try Self.sha256(real)
        }
        return pins
    }

    /// Whether a grant's scripts are still as they were when it was given (grants._script_pinned): the
    /// pinned ones unchanged and nothing new that could run next to them. True for a grant with none.
    public func scriptsHold(_ grant: StandingGrant) -> Bool {
        for place in grant.scripts {
            var info = stat()
            let isFolder = stat(place, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
            let folder = isFolder ? place : (place as NSString).deletingLastPathComponent
            do {
                for (path, digest) in grant.pins where (path as NSString).deletingLastPathComponent == folder {
                    guard FileManager.default.fileExists(atPath: path) else { continue }
                    guard try Self.sha256(path) == digest else { return false }
                }
                if try Self.codeFiles(folder).contains(where: { grant.pins[$0.real] == nil }) { return false }
            } catch {
                return false
            }
        }
        return true
    }

    /// The script files directly in a folder: code by name, or anything executable.
    static func codeFiles(_ place: String) throws -> [(name: String, real: String, size: Int)] {
        try FileManager.default.contentsOfDirectory(atPath: place).sorted().compactMap { name in
            let path = (place as NSString).appendingPathComponent(name)
            var info = stat()
            guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  codeSuffixes.contains(where: name.lowercased().hasSuffix) || info.st_mode & 0o111 != 0,
                  let real = realPath(path) else { return nil }
            return (name, real, Int(info.st_size))
        }
    }

    /// Hashes of the scripts in a folder by real path, leaving out links to somewhere else.
    static func snapshot(_ place: String) throws -> [String: String] {
        var pins: [String: String] = [:]
        for file in try codeFiles(place) where (file.real as NSString).deletingLastPathComponent == place {
            guard file.size <= maxPinBytes else {
                throw DaisyError.message("\(file.name) is over 1 MB, too big to be a script Daisy can hold to how it is now.")
            }
            pins[file.real] = try sha256(file.real)
            guard pins.count <= maxPinned else {
                throw DaisyError.message("That folder has more than \(maxPinned) scripts.")
            }
        }
        return pins
    }

    static func sha256(_ path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// realpath(3), like Python's os.path.realpath (which keeps /private on /var and /tmp).
    static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
