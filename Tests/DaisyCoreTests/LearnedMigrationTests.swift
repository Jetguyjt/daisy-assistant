import Foundation
import DaisyCore

/// One memory store: the old SQLite memories move into Hermes's files once, nothing is cut to fit,
/// and the old store stops taking new memories while Hermes keeps them.
final class LearnedMigrationTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString)")
    var memories: URL { root.appendingPathComponent("hermes/memories") }
    var marker: URL { root.appendingPathComponent("daisy/hermes-memory-move.json") }

    func setUp() throws { try FileManager.default.createDirectory(at: memories, withIntermediateDirectories: true) }
    func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func read(_ name: String) -> String {
        (try? String(contentsOf: memories.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    private func memory(_ key: String, _ value: String, _ age: TimeInterval) -> Memory {
        Memory(key: key, value: value, source: "test", updatedAt: Date(timeIntervalSince1970: 1_780_000_000 - age), revision: 1)
    }

    func testEntriesReadLikeHermesEntries() {
        expectEqual(LearnedMigration.entry(for: memory("note.3fa2c1d0", "  Josh's paper is due mid-October. ", 0)), "Josh's paper is due mid-October.")
        expectEqual(LearnedMigration.entry(for: memory("response_style", "Keep it short.", 0)), "Response style: Keep it short.")
        expectEqual(LearnedMigration.entry(for: memory("active_projects", "carScrapingML: ~/projects/carScrapingML", 0)),
                    "Active projects: carScrapingML: ~/projects/carScrapingML")
    }

    func testOldMemoriesMoveOnceInHermesFormat() throws {
        try Data("Is in high school".utf8).write(to: memories.appendingPathComponent("USER.md"))
        let files = HermesMemoryFiles(directory: memories)
        let old = [memory("response_style", "Keep it short.", 100), memory("note.aa11", "Is in high school", 50),
                   memory("note.bb22", "Uses Gmail, not Outlook.", 10)]
        let report = try unwrap(try LearnedMigration.run(memories: old, files: files, marker: marker))
        // Oldest first, after what was there; the one Hermes already had isn't added twice.
        expectEqual(read("USER.md"), "Is in high school\n§\nResponse style: Keep it short.\n§\nUses Gmail, not Outlook.")
        expectEqual(report.moved.map(\.key), ["response_style", "note.bb22"])
        expectEqual(report.alreadyThere, ["note.aa11"])
        expectTrue(report.left.isEmpty)
        expectEqual(report.summary, "Moved 2 old memories into Hermes's memory. 1 was already there.")
        let mode = try FileManager.default.attributesOfItem(atPath: marker.path)[.posixPermissions] as? Int
        expectEqual(mode, 0o600)
        // Once only.
        try expectEqual(LearnedMigration.run(memories: old + [memory("note.cc33", "New", 0)], files: files, marker: marker), nil)
        expectEqual(read("USER.md"), "Is in high school\n§\nResponse style: Keep it short.\n§\nUses Gmail, not Outlook.")
    }

    func testWhatDoesNotFitIsReportedNeverCut() throws {
        let files = HermesMemoryFiles(directory: memories, limits: [.user: 60, .memory: 80])
        let long = String(repeating: "x", count: 90)
        let old = [memory("note.a", String(repeating: "a", count: 40), 40),   // fits USER.md
                   memory("note.b", String(repeating: "b", count: 40), 30),   // USER.md is full: MEMORY.md
                   memory("note.c", String(repeating: "c", count: 35), 20),   // newest two get the room first
                   memory("note.d", long, 10),                                 // longer than any file holds
                   memory("note.e", "has\n§\na delimiter", 5)]
        let report = try unwrap(try LearnedMigration.run(memories: old, files: files, marker: marker))
        expectEqual(report.moved.map(\.key), ["note.c", "note.b"])
        expectEqual(report.moved.map(\.target), [.user, .memory])
        expectEqual(read("USER.md"), String(repeating: "c", count: 35))
        expectEqual(read("MEMORY.md"), String(repeating: "b", count: 40))
        expectEqual(Set(report.left.map(\.key)), ["note.a", "note.d", "note.e"])
        expectEqual(report.left.first { $0.key == "note.a" }?.text, String(repeating: "a", count: 40))
        expectTrue(report.left.first { $0.key == "note.d" }?.reason.contains("90 characters") ?? false)
        expectFalse(read("USER.md").contains("x") || read("MEMORY.md").contains("x"))
        expectTrue(report.summary.contains("3 didn't fit and stay in the on-device list"))
    }

    func testAnUntidyFileStopsTheMoveWithoutAMarker() throws {
        let untidy = "Is in high school  \n§\n\n§\nhand edit"
        try Data(untidy.utf8).write(to: memories.appendingPathComponent("USER.md"))
        do {
            _ = try LearnedMigration.run(memories: [memory("note.a", "Likes jazz", 0)], files: HermesMemoryFiles(directory: memories), marker: marker)
            fail("moved into an untidy file")
        } catch { expectEqual(error as? HermesMemoryError, .untidy(file: "USER.md")) }
        expectFalse(FileManager.default.fileExists(atPath: marker.path))
        expectEqual(read("USER.md"), untidy)
    }

    @MainActor
    func testMovedMemoriesArentNewsInTheFeed() async throws {
        let store = try MemoryStore(url: root.appendingPathComponent("daisy/memory.sqlite"))
        try await store.put(key: "response_style", value: "Keep it short.", source: "test")
        let learned = LearnedMemory(files: HermesMemoryFiles(directory: memories), log: root.appendingPathComponent("learned.jsonl"),
                                    state: root.appendingPathComponent("daisy/learned.json"))
        learned.refresh()
        let report = await learned.moveOldMemories(from: store, marker: marker, hermesHome: root.appendingPathComponent("hermes"))
        expectEqual(report?.moved.map(\.text), ["Response style: Keep it short."])
        expectEqual(read("USER.md"), "Response style: Keep it short.")
        expectTrue(learned.items.isEmpty)
        // No Hermes folder yet: nothing happens and it'll try again later.
        let elsewhere = root.appendingPathComponent("second-marker.json")
        let skipped = await learned.moveOldMemories(from: store, marker: elsewhere, hermesHome: root.appendingPathComponent("no-hermes"))
        expectEqual(skipped, nil)
        expectFalse(FileManager.default.fileExists(atPath: elsewhere.path))
    }

    func testOldStoreRefusesNewMemoriesWhileHermesKeepsThem() async throws {
        let store = try MemoryStore(url: root.appendingPathComponent("daisy/memory.sqlite"))
        try await store.put(key: "a", value: "one", source: "test")
        await store.refuseWrites(MemoryStore.keptByHermes)
        let accepts = await store.acceptsWrites
        expectFalse(accepts)
        do { try await store.put(key: "b", value: "two", source: "test"); fail("wrote while Hermes keeps memory") }
        catch { expectEqual(error.localizedDescription, MemoryStore.keptByHermes) }
        // Reading and deleting still work.
        let kept = try await store.all()
        expectEqual(kept.map(\.key), ["a"])
        try await store.delete(key: "a")
        let emptied = try await store.all()
        expectEqual(emptied.count, 0)
        await store.refuseWrites(nil)
        try await store.put(key: "c", value: "three", source: "test")
        let reopened = try await store.all()
        expectEqual(reopened.map(\.key), ["c"])
    }
}
