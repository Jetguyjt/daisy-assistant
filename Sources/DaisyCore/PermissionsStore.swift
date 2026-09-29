import Darwin
import Foundation

/// The Permissions list in the Capabilities tab: rows built from asks.jsonl, grants.json and grants.jsonl
/// (see Permissions), a switch per row that turns on a forever grant for exactly that row's scope, and
/// turning any standing OK off.
@MainActor public final class PermissionStore: ObservableObject {
    @Published public private(set) var rows: [PermissionRow] = []
    /// The last switch that didn't go through.
    @Published public private(set) var problem: String?
    public let file: GrantsFile
    let home: String
    /// How long a switch turned on here is kept on if the guard takes it back (below).
    static let keepOnFor: TimeInterval = 600
    private var stamps: [Stamp?] = []
    private var built = Date.distantPast
    /// Switches turned on lately, by grant id. Kept past this store (the list is rebuilt each time the tab
    /// opens), and by folder, so one store only ever puts back its own file's.
    private static var turnedOn: [String: (folder: String, grant: JSONValue, until: Date)] = [:]

    public init(file: GrantsFile = GrantsFile(), home: String = NSHomeDirectory()) {
        self.file = file
        self.home = home
        reload()
    }

    public func rows(_ group: PermissionRow.Group) -> [PermissionRow] { rows.filter { $0.group == group } }

    /// Builds the list again when one of its files changed, or a minute on (the window moves). Cheap
    /// enough to call every couple of seconds while the list is showing.
    public func refresh(now: Date = Date()) {
        guard files() != stamps || now.timeIntervalSince(built) > 60 else { return }
        reload(now: now)
    }

    public func reload(now: Date = Date()) {
        stamps = files()
        built = now
        keepSwitchesOn(now: now)
        let file = self.file
        let since = now.addingTimeInterval(-Permissions.window)
        let fresh = Permissions.rows(asks: file.asks(since: since), grants: file.grants(), log: file.log(since: since), now: now,
                                     home: home, changed: { !$0.scripts.isEmpty && !file.scriptsHold($0) })
        if fresh != rows { rows = fresh }
    }

    /// Turns an asked-often row on: a forever grant for exactly its scope, marked as given in settings.
    /// False when it couldn't be written (the reason is in `problem`).
    @discardableResult
    public func turnOn(_ row: PermissionRow, now: Date = Date()) -> Bool {
        guard row.group == .often, let scope = row.scope else { return false }
        return attempt("turn that on") {
            if file.grants().contains(where: { $0.isLive(at: now) && $0.forever && $0.covers(scope) }) { return }
            let grant = try file.foreverGrant(for: scope, label: row.label, now: now, home: home)
            try file.add(grant)
            if let id = grant["id"]?.stringValue {
                Self.turnedOn[id] = (file.folder.path, grant, now.addingTimeInterval(Self.keepOnFor))
            }
        }
    }

    /// Turns a standing OK off, whoever gave it. The next step like it gets a card again.
    @discardableResult
    public func turnOff(_ row: PermissionRow) -> Bool {
        guard row.isOn, let id = row.grantID else { return false }
        Self.turnedOn[id] = nil
        return attempt("turn that off") { _ = try file.revoke(id) }
    }

    @discardableResult
    public func set(_ row: PermissionRow, on: Bool) -> Bool { on ? turnOn(row) : turnOff(row) }

    /// The guard undoes a forever grant that appears while one of Daisy's steps is running (sealed.py),
    /// and it can't tell this switch from a tool writing the file. So a switch turned on here in the last
    /// few minutes, and not turned off here since, is put back if it went missing.
    private func keepSwitchesOn(now: Date) {
        Self.turnedOn = Self.turnedOn.filter { $0.value.until > now }
        for entry in Self.turnedOn.values where entry.folder == file.folder.path { _ = try? file.restore(entry.grant) }
    }

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

    private func files() -> [Stamp?] { [file.asksURL, file.url, file.logURL].map(Self.stamp) }

    struct Stamp: Equatable {
        let seconds: Int
        let nanoseconds: Int
        let size: Int64
        let inode: UInt64
    }

    static func stamp(_ url: URL) -> Stamp? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return Stamp(seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec, size: Int64(info.st_size),
                     inode: UInt64(info.st_ino))
    }
}
