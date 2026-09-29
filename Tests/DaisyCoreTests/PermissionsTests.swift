import CryptoKit
import Darwin
import Foundation
import DaisyCore

/// The Permissions list against a throwaway $HERMES_HOME/daisy: rows grouped from asks.jsonl, grants.json
/// and grants.jsonl, the thresholds, labels, locked rows, switches writing and revoking forever grants, and
/// old or missing files. The file formats follow hermes/daisy/guard/asks.py and grants.py.
final class PermissionsTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("permissions-\(UUID().uuidString)")
    var folder: URL { root.appendingPathComponent("daisy") }
    /// The temp folder as realpath(3) spells it (/private/var/...), which is how the guard logs scripts.
    var home: String { real(root.path) }
    let now = Date()

    func setUp() throws { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func real(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func line(_ tool: String, daysAgo: Double = 0, title: String = "", grantable: Bool = true, scope: String? = nil,
                      app: String = "", script: String = "", why: String = "", reason: String = "", risk: String = "write") -> String {
        var fields: [String: Any] = ["at": now.timeIntervalSince1970 - daysAgo * 86400 - 1, "session": "acp-1", "tool": tool,
                                     "title": title.isEmpty ? "Use \(tool)" : title, "risk": risk, "grantable": grantable]
        if grantable { fields["scope"] = scope ?? tool }
        if !app.isEmpty { fields["app"] = app }
        if !script.isEmpty { fields["script"] = script }
        if !why.isEmpty { fields["why"] = why; fields["reason"] = reason }
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func writeAsks(_ lines: [String]) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: folder.appendingPathComponent("asks.jsonl"))
    }

    private func stored() -> [JSONValue] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("grants.json")),
              let file = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
        return file["grants"]?.arrayValue ?? []
    }

    private func rows() -> [PermissionRow] {
        let file = GrantsFile(folder: folder)
        let since = now.addingTimeInterval(-Permissions.window)
        return Permissions.rows(asks: file.asks(since: since), grants: file.grants(), log: file.log(since: since), now: now, home: home)
    }

    func testRowsComeFromWhatWasAsked() throws {
        expectEqual(Permissions.minimumAsks, 3)
        expectEqual(Permissions.window, 14 * 86400)
        let doc = "Add text to the end of “Essay”"
        try writeAsks([
            line("docs_write", title: doc), line("docs_write", daysAgo: 2, title: doc), line("docs_write", daysAgo: 13, title: doc),
            line("notes_append", title: "Add to the note “Ideas”"), line("notes_append", daysAgo: 1),
            line("reminders_add"), line("reminders_add", daysAgo: 1), line("reminders_add", daysAgo: 15), line("reminders_add", daysAgo: 20),
            line("gmail_send", title: "Send an email to Dad", grantable: false, why: "send", reason: "Sends always ask", risk: "send"),
            line("gmail_send", daysAgo: 1, grantable: false, why: "send", reason: "Sends always ask", risk: "send"),
            line("gmail_send", daysAgo: 3, grantable: false, why: "send", reason: "Sends always ask", risk: "send"),
            line("gmail_send", daysAgo: 4, grantable: false, why: "send", reason: "Sends always ask", risk: "send"),
        ])
        let all = rows()
        expectEqual(all.map(\.group), [.often, .locked])
        let often = try unwrap(all.first)
        expectEqual(often.label, "Add to Google Docs")
        expectEqual(often.count, 3)
        expectEqual(often.scope?.key, "docs_write")
        expectFalse(often.isOn)
        expectTrue(often.canSwitch)
        // Two asks, or four with two of them past the window, isn't often.
        expectFalse(all.contains { $0.label.contains("notes") || $0.label.contains("reminders") })

        let locked = try unwrap(all.last)
        expectEqual(locked.label, "Send emails")
        expectEqual(locked.reason, "Sends always ask")
        expectEqual(locked.count, 4)
        expectFalse(locked.isOn)
        expectFalse(locked.canSwitch)
        expectEqual(locked.scope, nil)
        expectLess(abs(try unwrap(locked.last).timeIntervalSince1970 - (now.timeIntervalSince1970 - 1)), 0.01)

        // The most asked comes first.
        try writeAsks((0..<5).map { _ in line("notes_append") } + (0..<3).map { _ in line("docs_write") })
        expectEqual(rows().map(\.label), ["Add to Apple Notes", "Add to Google Docs"])
    }

    func testEachKindOfScopeGetsItsOwnRowAndName() throws {
        let tools = root.appendingPathComponent("essays")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try Data("print('x')\n".utf8).write(to: tools.appendingPathComponent("format.py"))
        let script = real(tools.appendingPathComponent("format.py").path)
        let three: (String) -> [String] = { text in Array(repeating: text, count: 3) }
        try writeAsks(
            three(line("computer_act", title: "Click the “Bold” button in Pages", scope: "computer_act@pages", app: "Pages", risk: "ui"))
            + three(line("computer_act", title: "Type in Mail", scope: "computer_act@mail", app: "Mail", risk: "ui"))
            + three(line("terminal", title: "Run the script \(script)", scope: "script:" + script, script: script, risk: "run"))
            + three(line("mcp__notion__update_page", title: "Update a Notion page"))
            + [line("mcp__sheets__add_row", title: "Add a row to “Budget”"), line("mcp__sheets__add_row", title: "Add a row to “Trips”"),
               line("mcp__sheets__add_row", title: "Add a row to “Budget”")]
            + [line("terminal", title: "Install ffmpeg with brew", grantable: false, why: "install", reason: "Installs always ask", risk: "run"),
               line("terminal", title: "Install jq with brew", grantable: false, why: "install", reason: "Installs always ask", risk: "run"),
               line("terminal", title: "Install requests with pip", grantable: false, why: "install", reason: "Installs always ask", risk: "run")]
            + three(line("terminal", title: "Delete in Google Drive", grantable: false, why: "delete", reason: "Deletes always ask", risk: "delete"))
        )
        let byLabel = Dictionary(rows().map { ($0.label, $0) }, uniquingKeysWith: { first, _ in first })
        expectEqual(Set(byLabel.keys), ["Click and type in Pages", "Click and type in Mail", "Run ~/essays/format.py",
                                        "Update page in Notion", "Add row in Sheets", "Install software", "Delete in Google Drive"])
        expectEqual(byLabel["Click and type in Pages"]?.scope?.app, "Pages")
        expectEqual(byLabel["Click and type in Pages"]?.lines, ["Send, delete or share buttons, Return and shortcuts in Pages still ask."])
        expectEqual(byLabel["Run ~/essays/format.py"]?.scope?.script, script)
        expectEqual(byLabel["Install software"]?.reason, "Installs always ask")
        expectEqual(byLabel["Install software"]?.group, .locked)
        expectEqual(byLabel["Delete in Google Drive"]?.group, .locked)
    }

    func testLabels() {
        expectEqual(PermissionLabels.label(tool: "notes_append"), "Add to Apple Notes")
        expectEqual(PermissionLabels.label(tool: "computer_act", app: "Pages"), "Click and type in Pages")
        expectEqual(PermissionLabels.label(tool: "x", script: "/Users/someone/essays/format.py", home: "/Users/someone"),
                    "Run ~/essays/format.py")
        expectEqual(PermissionLabels.label(tool: "x", script: "/opt/tools/fix.sh", home: "/Users/someone"), "Run /opt/tools/fix.sh")
        expectEqual(PermissionLabels.label(tool: "mcp__notion__update_page"), "Update page in Notion")
        expectEqual(PermissionLabels.label(tool: "mcp_linear_create_issue"), "Linear create issue")
        // A tool Daisy doesn't know by name is named from what its cards said.
        expectEqual(PermissionLabels.label(tool: "trips_write", titles: ["Add a stop to “Lisbon”", "Add a stop to “Porto”"]), "Add a stop")
        expectEqual(PermissionLabels.label(tool: "trips_write", titles: ["Plan: Lisbon", "Plan: Lisbon"]), "Plan: Lisbon")
        expectEqual(PermissionLabels.label(tool: "trips_write", titles: ["Book a flight: Lisbon", "Book a flight: Porto"]), "Book a flight")
        expectEqual(PermissionLabels.label(tool: "terminal", why: "command", titles: ["Run npm test", "Start a server"]), "Run commands")
        expectEqual(PermissionLabels.label(tool: "odd_tool", titles: ["Frobnicate", "Twiddle"]), "Twiddle")
        expectEqual(PermissionLabels.label(tool: "odd_tool"), "Odd tool")
    }

    func testForeverGrantsAreOnAndCoverWhatWasAsked() throws {
        let file = GrantsFile(folder: folder)
        try file.add(["id": "g-daisy", "what": "from now on add my tasks", "duration": "forever", "tools": ["tasks_add"],
                      "app": "", "scripts": [], "pins": [:], "covers": ["Use tasks_add (tasks_add)"],
                      "given": .number(now.timeIntervalSince1970 - 100), "by": "daisy"])
        try file.add(["id": "g-req", "what": "Yes to all like this: Add to “Essay”", "duration": "request", "tools": ["docs_write"],
                      "session": "s1", "turn": "t1", "covers": ["Add to Google Docs (docs_write)"],
                      "given": .number(now.timeIntervalSince1970), "expires": .number(now.timeIntervalSince1970 + 600), "by": "card"])
        try writeAsks((0..<4).map { _ in line("tasks_add", risk: "own") } + (0..<3).map { _ in line("docs_write") })
        let log = [
            "{\"at\": \(now.timeIntervalSince1970 - 50), \"session\": \"s1\", \"turn\": \"t1\", \"grant\": \"g-daisy\", \"tool\": \"tasks_add\", \"title\": \"Add a task\"}",
            "{\"at\": \(now.timeIntervalSince1970 - 20), \"session\": \"s1\", \"turn\": \"t1\", \"grant\": \"g-daisy\", \"tool\": \"tasks_add\", \"title\": \"Add a task\"}",
            "{\"at\": \(now.timeIntervalSince1970 - 30 * 86400), \"session\": \"s0\", \"turn\": \"t0\", \"grant\": \"g-daisy\", \"tool\": \"tasks_add\", \"title\": \"Add a task\"}",
        ]
        try Data((log.joined(separator: "\n") + "\n").utf8).write(to: file.logURL)
        let all = rows()
        expectEqual(all.map(\.group), [.allowed, .request, .often])
        let allowed = try unwrap(all.first)
        expectEqual(allowed.label, "“from now on add my tasks”")
        expectEqual(allowed.lines, ["Use tasks_add (tasks_add)"])
        expectEqual(allowed.count, 2)
        expectEqual(allowed.grantID, "g-daisy")
        expectTrue(allowed.isOn && allowed.canSwitch)
        // tasks_add was asked 4 times, but a forever grant covers it: it's only listed as on.
        expectFalse(all.contains { $0.group == .often && $0.scope?.tool == "tasks_add" })
        // A request grant doesn't take a row out of asked often.
        expectEqual(all.last?.scope?.tool, "docs_write")
        expectEqual(all[1].label, "Yes to all like this: Add to “Essay”")
    }

    @MainActor
    func testSwitchOnWritesAForeverGrantAndOffRevokesIt() throws {
        try writeAsks((0..<3).map { _ in line("docs_write") }
                      + (0..<3).map { _ in line("computer_act", scope: "computer_act@pages", app: "Pages", risk: "ui") })
        let store = PermissionStore(file: GrantsFile(folder: folder), home: home)
        let docs = try unwrap(store.rows(.often).first { $0.scope?.tool == "docs_write" })
        expectTrue(store.turnOn(docs, now: now))
        expectEqual(store.problem, nil)
        let saved = try unwrap(stored().first)
        expectEqual(saved["duration"], "forever")
        expectEqual(saved["by"], "settings")
        expectEqual(saved["tools"], ["docs_write"])
        expectEqual(saved["app"], "")
        expectEqual(saved["scripts"], [])
        expectEqual(saved["pins"], .object([:]))
        expectEqual(saved["covers"], ["Add to Google Docs (docs_write)"])
        expectEqual(saved["what"], "Add to Google Docs")
        expectEqual(saved["given"]?.numberValue, now.timeIntervalSince1970)
        expectEqual(saved["session"], nil)
        expectTrue(saved["id"]?.stringValue?.hasPrefix("g-") == true)
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("grants.json").path)
        expectEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        // Now it's on, and no longer asked often.
        let on = try unwrap(store.rows(.allowed).first)
        expectEqual(on.label, "Add to Google Docs")
        expectEqual(on.lines, [])
        expectFalse(store.rows(.often).contains { $0.scope?.tool == "docs_write" })
        // The same switch again (a list that hadn't caught up) doesn't add a second one.
        expectTrue(store.turnOn(docs, now: now))
        expectEqual(stored().count, 1)

        let pages = try unwrap(store.rows(.often).first { $0.scope?.tool == "computer_act" })
        store.set(pages, on: true)
        let click = try unwrap(stored().last)
        expectEqual(click["tools"], ["computer_act"])
        expectEqual(click["app"], "Pages")
        expectEqual(click["covers"], ["Click and type in Pages (computer_act)",
                                      "Clicks on send, delete or share buttons, Return, shortcuts and line breaks in Pages still ask."])

        // Off revokes it, and it's back to asked often.
        store.set(on, on: false)
        expectEqual(stored().count, 1)
        expectTrue(store.rows(.often).contains { $0.scope?.tool == "docs_write" })
        expectEqual(store.rows(.allowed).map(\.label), ["Click and type in Pages"])
        // Rows that can't switch don't.
        expectFalse(store.turnOff(pages))
        expectFalse(store.turnOn(on))
    }

    @MainActor
    func testASwitchTheGuardTookBackIsPutBack() throws {
        try writeAsks((0..<3).map { _ in line("notes_append") })
        let file = GrantsFile(folder: folder)
        let store = PermissionStore(file: file, home: home)
        store.turnOn(try unwrap(store.rows(.often).first))
        let id = try unwrap(store.rows(.allowed).first?.grantID)
        // What sealed.py does when a forever grant shows up while one of Daisy's steps runs.
        try Data("{\"version\": 1, \"grants\": []}".utf8).write(to: file.url)
        store.reload()
        expectEqual(store.rows(.allowed).first?.grantID, id)
        // Nothing is written when there's nothing to put back.
        let stamp = try FileManager.default.attributesOfItem(atPath: file.url.path)[.modificationDate] as? Date
        usleep(20_000)
        store.reload()
        try expectEqual(FileManager.default.attributesOfItem(atPath: file.url.path)[.modificationDate] as? Date, stamp)
        // A new list (the tab opened again) keeps doing it.
        try Data("{\"version\": 1, \"grants\": []}".utf8).write(to: file.url)
        let again = PermissionStore(file: file, home: home)
        expectEqual(again.rows(.allowed).first?.grantID, id)
        // Turned off here, it stays off.
        again.turnOff(try unwrap(again.rows(.allowed).first))
        again.reload()
        store.reload()
        expectEqual(stored().count, 0)
        expectEqual(again.rows(.allowed).count, 0)
        // Nor when it's turned off anywhere else in the app.
        again.turnOn(try unwrap(again.rows(.often).first))
        let other = try unwrap(again.rows(.allowed).first?.grantID)
        GrantStore(file: file).revoke(other)
        again.reload()
        expectEqual(stored().count, 0)
    }

    @MainActor
    func testScriptSwitchesArePinnedAsTheyAreNow() throws {
        let tools = root.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try Data("import helper\n".utf8).write(to: tools.appendingPathComponent("fix.py"))
        try Data("def fix(): pass\n".utf8).write(to: tools.appendingPathComponent("helper.py"))
        try Data("not a script".utf8).write(to: tools.appendingPathComponent("notes.txt"))
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: tools.appendingPathComponent("run"))
        chmod(tools.appendingPathComponent("run").path, 0o755)
        let place = real(tools.path)
        let script = place + "/fix.py"
        try writeAsks((0..<3).map { _ in line("terminal", title: "Run the script \(script)", scope: "script:" + script, script: script, risk: "run") })
        let file = GrantsFile(folder: folder)
        let store = PermissionStore(file: file, home: home)
        let row = try unwrap(store.rows(.often).first)
        expectEqual(row.label, "Run ~/tools/fix.py")
        expectTrue(store.turnOn(row))
        let saved = try unwrap(stored().first)
        expectEqual(saved["tools"], [])
        expectEqual(saved["scripts"], [.string(script)])
        let digest: (String) -> JSONValue = { name in
            .string(SHA256.hash(data: FileManager.default.contents(atPath: place + "/" + name)!).map { String(format: "%02x", $0) }.joined())
        }
        expectEqual(saved["pins"], .object([script: digest("fix.py"), place + "/helper.py": digest("helper.py"), place + "/run": digest("run")]))
        let grant = try unwrap(file.grants().first)
        expectTrue(file.scriptsHold(grant))
        expectEqual(store.rows(.allowed).first?.reason, "")
        expectEqual(store.rows(.allowed).first?.lines, ["Held to how it was when you turned it on. If it changes, it asks again."])

        // Changed since: the guard asks again, and the list says so.
        try Data("import smtplib\n".utf8).write(to: tools.appendingPathComponent("helper.py"))
        expectFalse(file.scriptsHold(grant))
        store.reload()
        expectTrue(store.rows(.allowed).first?.reason.hasPrefix("Changed since you turned it on") == true)
        try Data("def fix(): pass\n".utf8).write(to: tools.appendingPathComponent("helper.py"))
        expectTrue(file.scriptsHold(grant))
        try Data("print('new')\n".utf8).write(to: tools.appendingPathComponent("new.py"))
        expectFalse(file.scriptsHold(grant))

        // Gone, or in Daisy's own settings, it can't be turned on.
        expectThrows(try file.scriptPins(place + "/missing.py"))
        try Data("x = 1\n".utf8).write(to: folder.appendingPathComponent("evil.py"))
        expectThrows(try file.scriptPins(real(folder.path) + "/evil.py"))
        expectThrows(try file.scriptPins("relative/fix.py"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("evil.py"))
        store.turnOff(try unwrap(store.rows(.allowed).first))
        try FileManager.default.removeItem(at: tools.appendingPathComponent("fix.py"))
        store.reload()
        let gone = try unwrap(store.rows(.often).first)
        expectFalse(store.turnOn(gone))
        expectTrue(store.problem?.contains("isn't where it was") == true)
        expectEqual(stored().count, 0)
    }

    @MainActor
    func testNothingAlwaysAskingGetsASwitch() throws {
        // A line that says a send could be granted (hand-edited, say) still gets no switch.
        try writeAsks((0..<3).map { _ in line("gmail_send", risk: "send") }
                      + (0..<3).map { _ in line("drive_delete", risk: "delete") }
                      + (0..<3).map { _ in line("approval_grant", risk: "share") }
                      + (0..<3).map { _ in line("terminal", title: "Run npm test", risk: "run") }
                      + (0..<3).map { _ in line("computer_act", scope: "computer_act@terminal", app: "Terminal", risk: "ui") }
                      + (0..<3).map { _ in line("docs_write", scope: "sheets_write") })
        let store = PermissionStore(file: GrantsFile(folder: folder), home: home)
        expectEqual(store.rows(.often), [])
        expectEqual(store.rows(.locked).count, 6)
        expectTrue(store.rows(.locked).allSatisfy { !$0.canSwitch && $0.reason == "This always asks" })
        for row in store.rows(.locked) { expectFalse(store.turnOn(row)) }
        expectEqual(stored().count, 0)
    }

    @MainActor
    func testOldOrMissingFiles() throws {
        // Nothing there at all.
        let empty = PermissionStore(file: GrantsFile(folder: root.appendingPathComponent("nowhere")), home: home)
        expectEqual(empty.rows, [])
        expectEqual(empty.problem, nil)

        // A grants.json from before "by" and scopes were written down, broken and odd lines in asks.jsonl,
        // and no grants.jsonl.
        try Data("""
        {"version": 1, "grants": [{"id": "g-old", "what": "edit my docs", "duration": "forever", "given": 1},
                                  {"id": "g-bare", "duration": "forever", "tools": ["notes_append"]},
                                  {"duration": "forever", "what": "no id"}, "junk"]}
        """.utf8).write(to: folder.appendingPathComponent("grants.json"))
        try writeAsks(["not json", "{\"at\": 1}", "{\"tool\": \"docs_write\"}", "[]",
                       line("docs_write"), line("docs_write"), "{\"at\": \(now.timeIntervalSince1970), \"tool\": \"docs_write\", \"grantable\": true, \"scope\": \"docs_write\"}",
                       "{\"at\": \(now.timeIntervalSince1970), \"tool\": \"notes_create\"}", "{\"at\": \(now.timeIntervalSince1970), \"tool\": \"notes_create\"}",
                       "{\"at\": \(now.timeIntervalSince1970), \"tool\": \"notes_create\"}", "{\"at\": \(now.timeIntervalSince1970), \"tool\": \"docs"])
        let store = PermissionStore(file: GrantsFile(folder: folder), home: home)
        expectEqual(store.rows(.allowed).map(\.label), ["“edit my docs”", "Add to Apple Notes"])
        expectEqual(store.rows(.allowed).map(\.count), [0, 0])
        expectEqual(store.rows(.often).map(\.label), ["Add to Google Docs"])
        expectEqual(store.rows(.often).first?.count, 3)
        // A line with no say on whether it could be covered counts as always asking.
        expectEqual(store.rows(.locked).map(\.label), ["Create Apple Notes"])
        expectEqual(store.rows(.locked).first?.reason, "This always asks")
        store.turnOff(try unwrap(store.rows(.allowed).first))
        expectEqual(store.rows(.allowed).map(\.label), ["Add to Apple Notes"])
    }
}
