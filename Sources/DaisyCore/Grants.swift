import CryptoKit
import Darwin
import Foundation

/// A standing permission: the user said Daisy can do a kind of step without asking, for this request or
/// from now on. The Daisy guard plugin decides what one covers and enforces it
/// (hermes/daisy/guard/grants.py); the app lists them under Tools → Permissions, turns them on and off
/// there, and adds the request-only ones "Yes to all like this" gives.
public struct StandingGrant: Identifiable, Equatable, Sendable {
    public let id: String
    /// What the user said, in their words, or the card it came from.
    public let what: String
    /// What runs without a card, one line each ("Add to Google Docs (docs_write)").
    public let covers: [String]
    public let forever: Bool
    public let session: String?
    public let turn: String?
    public let given: Date
    /// Request grants only: the backstop, a few hours after it was given.
    public let expires: Date?
    /// Given with "Yes to all like this" on a card, rather than asked for by Daisy.
    public let fromCard: Bool
    /// Who gave it: "daisy" (her approval_grant card), "card" ("Yes to all like this") or "settings" (a
    /// Permissions switch). "" in files from before this was written down.
    public let by: String
    /// Its scope as the guard reads it: tool names, the one app for clicking and typing, and scripts (a
    /// file or a folder) with the hashes they're held to.
    public let tools: [String]
    public let app: String
    public let scripts: [String]
    public let pins: [String: String]

    public init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, !id.isEmpty,
              let duration = json["duration"]?.stringValue, duration == "forever" || duration == "request" else { return nil }
        self.id = id
        what = json["what"]?.stringValue ?? ""
        covers = (json["covers"]?.arrayValue ?? []).compactMap(\.stringValue)
        forever = duration == "forever"
        session = json["session"]?.stringValue
        turn = json["turn"]?.stringValue
        given = Date(timeIntervalSince1970: json["given"]?.numberValue ?? 0)
        expires = json["expires"]?.numberValue.map(Date.init(timeIntervalSince1970:))
        by = json["by"]?.stringValue ?? ""
        fromCard = by == "card"
        tools = (json["tools"]?.arrayValue ?? []).compactMap(\.stringValue)
        app = json["app"]?.stringValue ?? ""
        scripts = (json["scripts"]?.arrayValue ?? []).compactMap(\.stringValue)
        var pins: [String: String] = [:]
        if case .object(let fields)? = json["pins"] {
            for (path, digest) in fields { if let digest = digest.stringValue { pins[path] = digest } }
        }
        self.pins = pins
    }

    /// Forever ones until they're turned off; request ones until their request ends (the app takes
    /// them off then) or the backstop passes.
    public func isLive(at date: Date = Date()) -> Bool {
        forever || (expires.map { $0 > date } ?? false)
    }

    public var lasts: String { forever ? "From now on" : "Until this request is done" }
}

/// A card the guard said could be answered with "Yes to all like this", and the grant that answer gives.
public struct GrantOffer: Equatable, Sendable {
    public let session: String
    public let turn: String
    public let covers: [String]
    /// The grant's scope as the guard wrote it: tools, app, scripts and the scripts' hashes.
    public let grant: JSONValue
    public let at: Date
}

/// One step that ran under a grant, from grants.jsonl.
public struct GrantLogEntry: Equatable, Sendable {
    public let at: Date
    public let session: String
    public let turn: String
    public let grant: String
    public let tool: String
    /// The card it would have had ("Add to the note “Essay”").
    public let title: String
}

/// grants.json and the files next to it in `$HERMES_HOME/daisy/`, shared with the guard plugin.
/// Every change takes the flock on `.grants.lock` the plugin takes, reads the file fresh, and writes
/// the whole thing through a temporary file and a rename, 0600, so neither side ever reads half of it
/// or writes over the other. Fields the app doesn't use (the scripts' hashes) are kept as they are.
public struct GrantsFile: Sendable {
    public static let version = 1
    /// A request grant from "Yes to all like this" lasts until its turn ends; this is the backstop.
    public static let requestLimit: TimeInterval = 3 * 3600
    /// The guard keeps offers ten minutes; a card is up for under one.
    public static let offerLimit: TimeInterval = 600
    public let folder: URL
    public var url: URL { folder.appendingPathComponent("grants.json") }
    public var offersURL: URL { folder.appendingPathComponent("grant-offers.json") }
    public var logURL: URL { folder.appendingPathComponent("grants.jsonl") }
    /// Every card the guard showed in a Daisy chat (hermes/daisy/guard/asks.py).
    public var asksURL: URL { folder.appendingPathComponent("asks.jsonl") }
    var lockURL: URL { folder.appendingPathComponent(".grants.lock") }
    let lockWait: TimeInterval

    public init(folder: URL = GrantsFile.defaultFolder(), lockWait: TimeInterval = 2) {
        self.folder = folder; self.lockWait = lockWait
    }

    /// `$HERMES_HOME/daisy`, else `~/.hermes/daisy`, the same folder as roles.json.
    public static func defaultFolder(environment: [String: String] = [:]) -> URL {
        WorkerRoles.defaultURL(environment: environment).deletingLastPathComponent()
    }

    /// Every grant on file, live or not, in file order. Unreadable means none.
    public func grants() -> [StandingGrant] { entries().compactMap(StandingGrant.init(json:)) }

    public func add(_ grant: JSONValue) throws {
        try change { entries in entries.append(grant) }
    }

    /// Puts a grant back when nothing with its id is on file. False when it was already there.
    @discardableResult
    public func restore(_ grant: JSONValue) throws -> Bool {
        guard let id = grant["id"]?.stringValue, !id.isEmpty else { return false }
        var added = false
        try change { entries in
            guard !entries.contains(where: { $0["id"]?.stringValue == id }) else { return }
            entries.append(grant)
            added = true
        }
        return added
    }

    /// Takes one grant out. False when it wasn't there.
    @discardableResult
    public func revoke(_ id: String) throws -> Bool {
        var found = false
        try change { entries in
            let before = entries.count
            entries.removeAll { $0["id"]?.stringValue == id }
            found = entries.count != before
        }
        return found
    }

    /// Takes off the request grants of one session (every session with nil): its request is over.
    public func endRequests(session: String? = nil) throws {
        try change { entries in
            entries.removeAll { entry in
                entry["duration"]?.stringValue == "request" && (session == nil || entry["session"]?.stringValue == session)
            }
        }
    }

    /// The offer for this card, when the guard made one: matched by the card's exact text, which the
    /// guard sent as "title — detail".
    public func offer(for approval: AgentApproval, now: Date = Date()) -> GrantOffer? {
        let text = approval.detail.map { approval.title + " — " + $0 } ?? approval.title
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        guard let data = try? Data(contentsOf: offersURL),
              let file = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        for entry in (file["offers"]?.arrayValue ?? []).reversed() {
            guard entry["digest"]?.stringValue == digest,
                  let session = entry["session"]?.stringValue, !session.isEmpty,
                  let turn = entry["turn"]?.stringValue, !turn.isEmpty,
                  let grant = entry["grant"], case .object = grant else { continue }
            let at = Date(timeIntervalSince1970: entry["at"]?.numberValue ?? 0)
            guard now.timeIntervalSince(at) < Self.offerLimit else { return nil }
            return GrantOffer(session: session, turn: turn, covers: (grant["covers"]?.arrayValue ?? []).compactMap(\.stringValue),
                              grant: grant, at: at)
        }
        return nil
    }

    /// A request-only grant for the rest of the offer's turn: what "Yes to all like this" gives.
    public func grant(for offer: GrantOffer, title: String, now: Date = Date()) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        if case .object(let scope) = offer.grant {
            for key in ["tools", "app", "scripts", "pins", "covers"] { fields[key] = scope[key] }
        }
        fields["id"] = .string(Self.newID())
        fields["what"] = .string("Yes to all like this: " + title)
        fields["duration"] = "request"
        fields["session"] = .string(offer.session)
        fields["turn"] = .string(offer.turn)
        fields["given"] = .number(now.timeIntervalSince1970)
        fields["expires"] = .number(now.addingTimeInterval(Self.requestLimit).timeIntervalSince1970)
        fields["by"] = "card"
        return .object(fields)
    }

    /// Steps that ran under a grant since `date`, oldest first, optionally in one session only.
    public func log(since date: Date, session: String? = nil) -> [GrantLogEntry] {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let entry = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                  let seconds = entry["at"]?.numberValue else { return nil }
            let at = Date(timeIntervalSince1970: seconds)
            let found = GrantLogEntry(at: at, session: entry["session"]?.stringValue ?? "", turn: entry["turn"]?.stringValue ?? "",
                                      grant: entry["grant"]?.stringValue ?? "", tool: entry["tool"]?.stringValue ?? "",
                                      title: entry["title"]?.stringValue ?? "")
            guard at >= date, session == nil || found.session == session else { return nil }
            return found
        }
    }

    /// "g-" and 12 hex characters, like the guard's.
    static func newID() -> String {
        "g-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
    }

    // MARK: The file

    private func entries() -> [JSONValue] {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
        return (file["grants"]?.arrayValue ?? []).filter { if case .object = $0 { return true }; return false }
    }

    /// Reads, changes and writes grants.json under the shared lock. Request grants past their backstop
    /// are dropped on the way. Nothing to change, nothing is written.
    func change(_ edit: (inout [JSONValue]) throws -> Void) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(lockURL.path, O_RDWR | O_CREAT, 0o600)
        guard lock >= 0 else { throw DaisyError.message("Couldn't open \(lockURL.lastPathComponent).") }
        defer { close(lock) }
        let deadline = Date().addingTimeInterval(lockWait)
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else {
                throw DaisyError.message("The standing permissions file is busy. Try again.")
            }
            usleep(20_000)
        }
        defer { flock(lock, LOCK_UN) }
        let now = Date().timeIntervalSince1970
        let before = entries()
        var current = before.filter { entry in
            entry["duration"]?.stringValue == "forever"
                || (entry["duration"]?.stringValue == "request" && (entry["expires"]?.numberValue ?? 0) > now)
        }
        try edit(&current)
        guard current != before else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(JSONValue.object(["version": .number(Double(Self.version)), "grants": .array(current)]))
        try write(data)
    }

    private func write(_ data: Data) throws {
        let temporary = folder.appendingPathComponent(".grants.json.\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw DaisyError.message("Couldn't write \(url.lastPathComponent).") }
        var written = true
        data.withUnsafeBytes { buffer in
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

/// The app's side of standing permissions: the live list, Revoke, "Yes to all like this" on a
/// conversation card, taking request grants off when their request ends, and what ran under one. The
/// Permissions list (PermissionStore) reads the same files.
@MainActor public final class GrantStore: ObservableObject {
    /// Live grants, newest first.
    @Published public private(set) var grants: [StandingGrant] = []
    /// The last change that didn't go through, for Setup.
    @Published public private(set) var problem: String?
    public let file: GrantsFile

    public init(file: GrantsFile = GrantsFile()) {
        self.file = file
        reload()
    }

    public func reload(now: Date = Date()) {
        let live = file.grants().filter { $0.isLive(at: now) }.sorted { $0.given > $1.given }
        if live != grants { grants = live }
    }

    public func revoke(_ id: String) {
        PermissionStore.forget(id)
        attempt("turn that off") { _ = try file.revoke(id) }
    }

    /// What "Yes to all like this" would give for this card, or nil when it can't be offered.
    public func offer(for approval: AgentApproval) -> GrantOffer? { file.offer(for: approval) }

    /// Adds the request grant for an offer. False when it couldn't be written.
    @discardableResult
    public func yesToAll(_ offer: GrantOffer, title: String, now: Date = Date()) -> Bool {
        attempt("save “Yes to all like this”") { try file.add(file.grant(for: offer, title: title, now: now)) }
    }

    /// A request is over: its request grants come off (one session's, or every session's with nil).
    public func endRequests(session: String? = nil) {
        attempt("end this request's permissions") { try file.endRequests(session: session) }
    }

    /// Lines for a turn's decisions: "Done under your OK: Add to the note “Essay”".
    public func doneUnderGrant(since date: Date, session: String? = nil) -> [String] {
        file.log(since: date, session: session).map { "Done under your OK: " + $0.title }
    }

    @discardableResult
    private func attempt(_ what: String, _ work: () throws -> Void) -> Bool {
        defer { reload() }
        do {
            try work()
            problem = nil
            return true
        } catch {
            problem = "Couldn't \(what): \(error.localizedDescription)"
            return false
        }
    }
}
