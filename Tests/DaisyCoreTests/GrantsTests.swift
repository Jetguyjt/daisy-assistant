import CryptoKit
import Foundation
import DaisyCore

/// Standing permissions on the app's side, against a throwaway folder: grants.json read, written and
/// revoked the safe way, the guard's offers matched to their cards, "Yes to all like this" and the end of
/// a request. The files follow hermes/daisy/guard/grants.py.
final class GrantsTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("grants-\(UUID().uuidString)")
    var folder: URL { root.appendingPathComponent("daisy") }

    func setUp() throws { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func stored() -> [JSONValue] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("grants.json")),
              let file = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
        return file["grants"]?.arrayValue ?? []
    }

    private func forever(_ id: String) -> JSONValue {
        ["id": .string(id), "what": "from now on add my tasks", "duration": "forever", "tools": ["tasks_add"],
         "covers": ["Use tasks_add (tasks_add)"], "given": .number(Date().timeIntervalSince1970), "by": "daisy",
         "pins": ["/tmp/x.py": "abc123"]]
    }

    private func request(_ id: String, session: String = "s1", expires: Date = Date().addingTimeInterval(600)) -> JSONValue {
        ["id": .string(id), "what": "edit these", "duration": "request", "tools": ["docs_write"], "session": .string(session),
         "turn": "t1", "covers": ["Add to Google Docs (docs_write)"], "given": .number(Date().timeIntervalSince1970),
         "expires": .number(expires.timeIntervalSince1970), "by": "daisy"]
    }

    /// An offer the way the guard writes one, for the card text "title — detail".
    private func offer(title: String, detail: String?, at: Date = Date()) throws {
        let text = detail.map { title + " — " + $0 } ?? title
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let offers: JSONValue = ["version": .number(1), "offers": [[
            "digest": .string(digest), "session": "acp-1", "turn": "acp-1:acp-1:ab12cd34", "at": .number(at.timeIntervalSince1970),
            "grant": ["tools": ["notes_append"], "app": "", "scripts": [], "pins": [:], "covers": ["Add to notes (notes_append)"]]]]]
        try JSONEncoder().encode(offers).write(to: folder.appendingPathComponent("grant-offers.json"))
    }

    func testFileReadWriteAndRevoke() throws {
        let file = GrantsFile(folder: folder)
        expectEqual(file.grants(), [])
        try file.add(forever("g-1"))
        try file.add(request("g-2"))
        expectEqual(file.grants().map(\.id), ["g-1", "g-2"])
        let saved = try unwrap(file.grants().first)
        expectTrue(saved.forever && !saved.fromCard && saved.isLive())
        expectEqual(saved.covers, ["Use tasks_add (tasks_add)"])
        expectEqual(saved.lasts, "From now on")
        // Its scope, as the guard reads it.
        expectEqual(saved.by, "daisy")
        expectEqual(saved.tools, ["tasks_add"])
        expectEqual(saved.app, "")
        expectEqual(saved.scripts, [])
        expectEqual(saved.pins, ["/tmp/x.py": "abc123"])
        let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
        expectEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".tmp") }
        expectEqual(leftovers, [])

        try expectTrue(file.revoke("g-2"))
        try expectFalse(file.revoke("g-2"))
        expectEqual(file.grants().map(\.id), ["g-1"])
        // What the app doesn't use stays as the guard wrote it.
        expectEqual(stored().first?["pins"], ["/tmp/x.py": "abc123"])

        // A request grant past its backstop goes on the next write, and never counts as live.
        try file.add(request("g-old", expires: Date().addingTimeInterval(-5)))
        try expectFalse(unwrap(file.grants().last).isLive())
        try expectFalse(file.revoke("g-nothing"))
        expectEqual(file.grants().map(\.id), ["g-1"])
        try FileManager.default.removeItem(at: file.url)
        try Data("{\"version\": 1, \"grants\": [{\"id\": \"g-3\", \"duration\": \"request\", \"expires\": 1}]}".utf8).write(to: file.url)
        try expectFalse(unwrap(file.grants().first).isLive())
        try Data("{broken".utf8).write(to: file.url)
        expectEqual(file.grants(), [])
    }

    func testRequestsEndPerSessionOrAll() throws {
        let file = GrantsFile(folder: folder)
        try file.add(forever("g-keep"))
        try file.add(request("g-a", session: "a"))
        try file.add(request("g-b", session: "b"))
        try file.endRequests(session: "a")
        expectEqual(file.grants().map(\.id), ["g-keep", "g-b"])
        try file.endRequests()
        expectEqual(file.grants().map(\.id), ["g-keep"])
    }

    func testWritesWaitForTheGuardsLock() throws {
        let file = GrantsFile(folder: folder, lockWait: 0.2)
        let held = open(folder.appendingPathComponent(".grants.lock").path, O_RDWR | O_CREAT, 0o600)
        defer { close(held) }
        expectEqual(flock(held, LOCK_EX), 0)
        expectThrows(try file.add(forever("g-1")))
        expectEqual(file.grants(), [])
        flock(held, LOCK_UN)
        try file.add(forever("g-1"))
        expectEqual(file.grants().map(\.id), ["g-1"])
    }

    func testOffersMatchTheCardsExactText() throws {
        let file = GrantsFile(folder: folder)
        try offer(title: "Add to the note “Essay”", detail: "Note: Essay\nAdding at the end:\nhi — there")
        let card = AgentApproval(id: "1", title: "Add to the note “Essay”", detail: "Note: Essay\nAdding at the end:\nhi — there", options: [])
        let found = try unwrap(file.offer(for: card))
        expectEqual(found.session, "acp-1")
        expectEqual(found.turn, "acp-1:acp-1:ab12cd34")
        expectEqual(found.covers, ["Add to notes (notes_append)"])
        expectEqual(file.offer(for: AgentApproval(id: "2", title: "Add to the note “Essay”", detail: "Note: Essay\nsomething else", options: [])), nil)
        expectEqual(file.offer(for: AgentApproval(id: "3", title: "Send an email to Dad", detail: nil, options: [])), nil)
        expectEqual(file.offer(for: card, now: Date().addingTimeInterval(GrantsFile.offerLimit + 1)), nil)
    }

    @MainActor
    func testYesToAllGrantsTheRestOfTheRequest() async throws {
        let store = GrantStore(file: GrantsFile(folder: folder))
        var answers: [String: String?] = [:]
        let queue = ApprovalQueue { id, option in answers[id] = option }
        queue.grants = store
        var outcomes: [ApprovalQueue.Outcome] = []
        queue.onDecision = { item, outcome in outcomes.append(outcome); expectTrue(item.allowedAll) }
        let options = [AgentApproval.Option(id: "allow_once", name: "Allow once", kind: .allowOnce),
                       AgentApproval.Option(id: "deny", name: "Deny", kind: .rejectOnce)]
        try offer(title: "Add to the note “Essay”", detail: "Note: Essay")
        queue.add(AgentApproval(id: "c1", title: "Add to the note “Essay”", detail: "Note: Essay", options: options), from: .conversation)
        queue.add(AgentApproval(id: "j1", title: "Add to the note “Essay”", detail: "Note: Essay", options: options), from: .job(UUID()))
        queue.add(AgentApproval(id: "c2", title: "Send an email to Dad", detail: "hi", options: options), from: .conversation)
        expectTrue(queue.items.first { $0.id == "c1" }?.offer != nil)
        expectEqual(queue.items.first { $0.id == "j1" }?.offer, nil)
        expectEqual(queue.items.first { $0.id == "c2" }?.offer, nil)

        queue.answerAll("c2")
        expectEqual(queue.items.count, 3)
        queue.answerAll("c1")
        for _ in 0..<50 where answers["c1"] == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        expectEqual(answers["c1"], "allow_once")
        expectEqual(outcomes, [.allowed])
        expectEqual(queue.items.map(\.id), ["j1", "c2"])

        let saved = try unwrap(stored().first)
        expectEqual(saved["duration"], "request")
        expectEqual(saved["session"], "acp-1")
        expectEqual(saved["turn"], "acp-1:acp-1:ab12cd34")
        expectEqual(saved["tools"], ["notes_append"])
        expectEqual(saved["by"], "card")
        expectEqual(saved["what"], "Yes to all like this: Add to the note “Essay”")
        let grant = try unwrap(store.grants.first)
        expectTrue(grant.fromCard && !grant.forever && grant.isLive())
        expectLess(try unwrap(grant.expires).timeIntervalSinceNow, GrantsFile.requestLimit + 1)

        // The request ends: its grants come off, anything given for good stays.
        try store.file.add(forever("g-forever"))
        store.endRequests()
        expectEqual(store.grants.map(\.id), ["g-forever"])
        store.revoke("g-forever")
        expectEqual(store.grants, [])
        expectEqual(store.problem, nil)
    }

    @MainActor
    func testNoGrantStoreNoButton() throws {
        try offer(title: "Add to the note “Essay”", detail: "Note: Essay")
        let queue = ApprovalQueue { _, _ in }
        queue.add(AgentApproval(id: "c1", title: "Add to the note “Essay”", detail: "Note: Essay",
                                options: [AgentApproval.Option(id: "allow_once", name: "Allow once", kind: .allowOnce)]), from: .conversation)
        expectEqual(queue.items.first?.offer, nil)
        queue.answerAll("c1")
        expectEqual(queue.items.count, 1)
        queue.withdrawAll()
    }

    @MainActor
    func testWhatRanUnderAGrant() throws {
        let store = GrantStore(file: GrantsFile(folder: folder))
        let now = Date().timeIntervalSince1970
        let lines = [
            "{\"at\": \(now - 100), \"session\": \"s1\", \"turn\": \"t0\", \"grant\": \"g-1\", \"tool\": \"docs_write\", \"title\": \"Add to “Old”\"}",
            "{\"at\": \(now), \"session\": \"s1\", \"turn\": \"t1\", \"grant\": \"g-1\", \"tool\": \"docs_write\", \"title\": \"Add to “Essay”\"}",
            "not json",
            "{\"at\": \(now + 1), \"session\": \"s2\", \"turn\": \"t9\", \"grant\": \"g-2\", \"tool\": \"notes_append\", \"title\": \"Add to the note “Ideas”\"}",
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: store.file.logURL)
        let since = Date(timeIntervalSince1970: now - 10)
        expectEqual(store.file.log(since: since).map(\.tool), ["docs_write", "notes_append"])
        expectEqual(store.doneUnderGrant(since: since, session: "s1"), ["Done under your OK: Add to “Essay”"])
        expectEqual(store.doneUnderGrant(since: Date(timeIntervalSince1970: now + 5)), [])
    }
}
