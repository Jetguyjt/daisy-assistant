import Foundation
import DaisyCore

final class TaskStoreTests {
    private var root: URL!
    private var url: URL { root.appendingPathComponent("tasks.json") }

    func setUp() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("daisy-tasks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testOldFilesDecodeWithoutLosingATask() async throws {
        try taskFixture("legacy-tasks.json").write(to: url)
        let store = try TaskStore(url: url)
        let items = await store.all()
        expectEqual(items.count, 3)
        let byTitle = Dictionary(uniqueKeysWithValues: items.map { ($0.title, $0) })
        expectEqual(byTitle["Outline the physics lab report"]?.status, .todo)
        expectEqual(byTitle["Practice essay draft"]?.status, .inProgress)
        expectEqual(byTitle["Sign up for the SAT"]?.status, .done)
        expectTrue(items.allSatisfy { $0.parent == nil && $0.order == 0 })
        expectEqual(byTitle["Outline the physics lab report"]?.updatedAt, Date(timeIntervalSinceReferenceDate: 780000000.25))
        expectEqual(byTitle["Practice essay draft"]?.notes, "First paragraph is rough.")
    }

    func testOddFileReadsLikeThePlugin() throws {
        struct Expected: Decodable {
            struct Entry: Decodable { let id, title, project, due, status, notes: String; let parent: String?; let revision, order: Int }
            let tasks: [Entry]
        }
        try taskFixture("odd-tasks.json").write(to: url)
        let items = try TaskFile.read(url)
        let expected = try JSONDecoder().decode(Expected.self, from: try taskFixture("odd-tasks-expected.json")).tasks
        expectEqual(items.count, expected.count)
        for (item, want) in zip(items, expected) {
            expectEqual(item.id.uuidString, want.id); expectEqual(item.title, want.title); expectEqual(item.project, want.project)
            expectEqual(item.parent?.uuidString, want.parent); expectEqual(item.due, want.due); expectEqual(item.status.rawValue, want.status)
            expectEqual(item.notes, want.notes); expectEqual(item.revision, want.revision); expectEqual(item.order, want.order)
        }
        expectEqual(TaskFile.stableID("school-list").uuidString, "5889073B-27DB-5E8C-B26D-1FFA513015B2")
    }

    func testPluginWrittenFileReads() throws {
        try taskFixture("plugin-written.json").write(to: url)
        let items = try TaskFile.read(url)
        expectEqual(items.map(\.title), ["Harbor State", "Harbor short answers", "Harbor community essay", "Return library books"])
        expectEqual(items.map(\.status), [.todo, .todo, .needsReview, .waiting])
        expectEqual(items[1].parent, items[0].id); expectEqual(items[2].parent, items[0].id); expectEqual(items[3].parent, nil)
        expectEqual(items.map(\.order), [1, 2, 3, 4]); expectEqual(items[2].revision, 2)
        expectTrue(items.allSatisfy { $0.updatedAt > Date(timeIntervalSince1970: 1_790_000_000) })
        expectEqual(items[2].due, "2026-11-01")
    }

    func testAppWritesTheSharedFormat() throws {
        let fixture = try taskFixture("app-written.json")
        let items = try JSONDecoder().decode([WorkItem].self, from: fixture)
        expectEqual(items.map(\.title), ["Harvard", "Why Harvard", "Old idea"])
        let written = try JSONSerialization.jsonObject(with: try TaskFile.encode(items)) as? NSArray
        let wanted = try JSONSerialization.jsonObject(with: fixture) as? NSArray
        expectEqual(written, wanted)
        let text = String(decoding: try TaskFile.encode(items), as: UTF8.self)
        expectEqual(text, String(decoding: fixture, as: UTF8.self))
        var harvard = items[0]; harvard.updatedAt = Date(timeIntervalSince1970: 1_790_000_000.9996)
        let rounded = String(decoding: try TaskFile.encode([harvard]), as: UTF8.self)
        expectTrue(rounded.contains(#""updatedAt" : "2026-09-21T14:13:21.000Z""#))
        expectFalse(rounded.contains("\"parent\""))
    }

    func testCustomStatusIsKeptInNotesAndSavedAsALabel() async throws {
        try Data(#"[{"id": "B7E1C0A2-0000-4000-8000-000000000001", "title": "Scholarship essay", "status": "almost there", "revision": 1, "order": 1}]"#.utf8).write(to: url)
        let store = try TaskStore(url: url)
        let first = try unwrap(await store.all().first)
        expectEqual(first.status, .todo); expectEqual(first.notes, "Status: almost there")
        try await store.save(WorkItem(title: "Another"), expectedRevision: 0)
        let raw = try String(contentsOf: url)
        expectFalse(raw.contains(#""status" : "almost there""#))
        let reread = try TaskFile.read(url)
        expectEqual(reread.first?.status, .todo); expectEqual(reread.first?.notes, "Status: almost there")
    }

    func testSubtasksNestSaveAndDeleteTogether() async throws {
        let store = try TaskStore(url: url)
        let school = try await store.save(WorkItem(title: "Harvard", project: "College Applications"), expectedRevision: 0)
        let essay = try await store.save(WorkItem(title: "Why Harvard", project: "College Applications", parent: school.id), expectedRevision: 0)
        let part = try await store.save(WorkItem(title: "Outline", parent: essay.id), expectedRevision: 0)
        let other = try await store.save(WorkItem(title: "Return library books"), expectedRevision: 0)
        expectEqual([school.order, essay.order, part.order, other.order], [1, 2, 3, 4])
        let all = await store.all()
        expectEqual(Set(TaskTree.descendants(of: school.id, in: all).map(\.title)), ["Why Harvard", "Outline"])
        var loop = school; loop.parent = part.id
        do { try await store.save(loop, expectedRevision: school.revision); fail("Saved a task under its own subtask") } catch { }
        var lost = other; lost.parent = UUID()
        do { try await store.save(lost, expectedRevision: other.revision); fail("Saved a task under one that doesn't exist") } catch { }
        var itself = other; itself.parent = other.id
        expectThrows(try itself.validate())
        try await store.delete(school)
        let left = await store.all()
        expectEqual(left.map(\.title), ["Return library books"])
        try expectEqual(try TaskFile.read(url).map(\.title), ["Return library books"])
    }

    func testTwoWritersKeepEachOthersChanges() async throws {
        let app = try TaskStore(url: url), other = try TaskStore(url: url)
        let mine = try await app.save(WorkItem(title: "From the app"), expectedRevision: 0)
        _ = try await other.save(WorkItem(title: "From elsewhere"), expectedRevision: 0)
        let both = await app.all()
        expectEqual(Set(both.map(\.title)), ["From the app", "From elsewhere"])
        let staleCopy = try unwrap(await other.item(mine.id))
        var edited = mine; edited.status = .done
        _ = try await app.save(edited, expectedRevision: mine.revision)
        var stale = staleCopy; stale.notes = "An older edit"
        do { try await other.save(stale, expectedRevision: staleCopy.revision); fail("A stale edit overwrote a newer one") } catch { }
        let onDisk = try TaskFile.read(url).first { $0.id == mine.id }
        expectEqual(onDisk?.status, .done); expectEqual(onDisk?.notes, ""); expectEqual(onDisk?.revision, 2)
        let otherView = await other.item(mine.id)
        expectEqual(otherView?.status, .done)
    }

    func testWaitsForTheLockAndReadsAgainInsideIt() async throws {
        let store = try TaskStore(url: url)
        let holder = try hold(seconds: 0.6, writing: #"[{"id": "8C1F6E2A-1D3B-4C5D-9E7F-0A1B2C3D4E5F", "title": "From Hermes", "status": "needs_review", "revision": 1, "order": 1}]"#)
        let started = Date()
        let saved = try await store.save(WorkItem(title: "From the app"), expectedRevision: 0)
        let waited = Date().timeIntervalSince(started)
        holder.waitUntilExit()
        expectTrue(waited >= 0.3)
        try expectEqual(try TaskFile.read(url).map(\.title), ["From Hermes", "From the app"])
        expectEqual(saved.order, 2)
        let theirs = await store.all().first { $0.title == "From Hermes" }
        expectEqual(theirs?.status, .needsReview)
    }

    func testABusyLockFailsWithoutWriting() throws {
        try TaskFile.write([WorkItem(title: "Keep me")], to: url)
        let before = try Data(contentsOf: url)
        let holder = try hold(seconds: 3, writing: nil)
        defer { holder.terminate(); holder.waitUntilExit() }
        expectThrows(try TaskFile.withLock(url, wait: 0.2) { try TaskFile.write([], to: url) })
        try expectEqual(try Data(contentsOf: url), before)
    }

    func testWritesArePrivateAndLeaveNothingBehind() async throws {
        let store = try TaskStore(url: url)
        for n in 0..<5 { try await store.save(WorkItem(title: "Task \(n)"), expectedRevision: 0) }
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        expectEqual(mode, 0o600)
        let lockMode = try FileManager.default.attributesOfItem(atPath: url.path + ".lock")[.posixPermissions] as? Int
        expectEqual(lockMode, 0o600)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        expectEqual(names, ["tasks.json", "tasks.json.lock"])
    }

    func testAnUnreadableFileIsNeverWrittenOver() async throws {
        let store = try TaskStore(url: url)
        try Data("{not json".utf8).write(to: url)
        do { try await store.save(WorkItem(title: "New"), expectedRevision: 0); fail("Wrote over a broken file") } catch { }
        try expectEqual(try String(contentsOf: url), "{not json")
        expectThrows(try TaskStore(url: url))
    }

    func testWatchingSeesAnotherWriter() async throws {
        let store = try TaskStore(url: url)
        let other = try TaskStore(url: url)
        let seen = Task { () -> Bool in
            for await _ in store.changes(poll: 0.3) { return true }
            return false
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        try await other.save(WorkItem(title: "Added by the plugin"), expectedRevision: 0)
        let noticed = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await seen.value }
            group.addTask { try? await Task.sleep(nanoseconds: 3_000_000_000); return false }
            let first = await group.next() ?? false
            group.cancelAll(); seen.cancel()
            return first
        }
        expectTrue(noticed)
        let titles = await store.all().map(\.title)
        expectEqual(titles, ["Added by the plugin"])
        // Stopping the watch ends the stream.
        let stopped = Task { () -> Bool in
            for await _ in store.changes(poll: 0.3) { }
            return true
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        stopped.cancel()
        let ended = await stopped.value
        expectTrue(ended)
    }

    func testOnDeviceToolsKnowStatusesAndParents() async throws {
        let store = try TaskStore(url: url)
        let school = try await store.save(WorkItem(title: "Harvard", project: "College Applications"), expectedRevision: 0)
        let session = CapabilitySession(registry: try CapabilityRegistry(providers: [TaskCapabilityProvider(store: store)]))
        let prepared = try await session.execute(.init(name: "prepare_task", arguments: [
            "title": "Why Harvard", "status": "needs_review", "parent": .string(school.id.uuidString)]))
        expectEqual(prepared.status, .succeeded)
        let review = try unwrap(prepared.output.review)
        expectTrue(review.preview.contains("Under: Harvard")); expectTrue(review.preview.contains("Status: Needs review"))
        _ = try await review.commit()
        let essay = try unwrap(await store.all().first { $0.title == "Why Harvard" })
        expectEqual(essay.parent, school.id); expectEqual(essay.status, .needsReview); expectEqual(essay.project, "College Applications")
        let listed = try await session.execute(.init(name: "list_tasks", arguments: ["query": "Why Harvard"]))
        let json = try listed.output.data.json()
        expectTrue(json.contains(#""status":"needs_review""#)); expectTrue(json.contains(#""status_name":"Needs review""#))
        expectTrue(json.contains(school.id.uuidString))
        let badStatus = try await session.execute(.init(name: "prepare_task", arguments: ["title": "X", "status": "planned"]))
        expectTrue(badStatus.status != .succeeded)
    }

    /// A second process holding the lock (as Hermes's plugin does while it writes), writing the file while
    /// it has it when `body` is given. Returns once the lock is held.
    private func hold(seconds: Double, writing body: String?) throws -> Process {
        let script = """
        import fcntl, os, sys, time
        fd = os.open(sys.argv[1] + ".lock", os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        if sys.argv[3]:
            open(sys.argv[1], "w").write(sys.argv[3])
        print("locked", flush=True)
        time.sleep(float(sys.argv[2]))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, url.path, String(seconds), body ?? ""]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        guard line.hasPrefix("locked") else { throw DaisyError.message("The lock holder didn't start: \(line)") }
        return process
    }
}
