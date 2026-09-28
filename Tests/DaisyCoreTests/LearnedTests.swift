import Foundation
import DaisyCore

/// The Learned feed and the edits behind Undo and Edit: Hermes's file format to the code point, its
/// lock, its drift guard and its limits, all on temporary folders.
final class LearnedTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("learned-\(UUID().uuidString)")
    var memories: URL { root.appendingPathComponent("memories") }
    var files: HermesMemoryFiles { HermesMemoryFiles(directory: memories) }
    var user: URL { memories.appendingPathComponent("USER.md") }
    var notes: URL { memories.appendingPathComponent("MEMORY.md") }
    var log: URL { root.appendingPathComponent("daisy/learned.jsonl") }
    var state: URL { root.appendingPathComponent("learned.json") }

    func setUp() throws {
        try FileManager.default.createDirectory(at: memories, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func write(_ text: String, to url: URL) throws { try Data(text.utf8).write(to: url) }
    private func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "(unreadable)" }
    private func logLines(_ lines: [[String: Any]]) throws {
        let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try write(text, to: log)
    }

    func testParseMatchesHermesSplit() {
        expectEqual(HermesMemory.parse("a\n§\nb\n§\n\n§\n  c  \n"), ["a", "b", "c"])
        // Only the full delimiter splits; a bare "§" line is an entry, as in Hermes.
        expectEqual(HermesMemory.parse("a\n§\n§\n§\nb"), ["a", "§", "b"])
        expectEqual(HermesMemory.parse("a §\nb"), ["a §\nb"])
        // Python's strip() also takes the \x1c–\x1f separators and no-break spaces.
        expectEqual(HermesMemory.strip("\u{1F}\u{A0} likes tea \u{3000}\n"), "likes tea")
        expectEqual(HermesMemory.render(["a", "b"]), "a\n§\nb")
        // Hermes counts code points: an emoji is 1, "e" plus a combining accent is 2.
        expectEqual(HermesMemory.length("🙂"), 1)
        expectEqual(HermesMemory.length("e\u{301}"), 2)
        expectFalse(HermesMemory.same("é", "e\u{301}"))
        expectEqual(HermesMemory.unique(["a", "b", "a"]), ["a", "b"])
    }

    func testEditWritesTheCleanFormHermesExpects() throws {
        try write("Likes tea\n§\nPlays tennis\n§\nUses Outlook\n", to: user)
        try files.edit(.user) { entries in entries.removeAll { $0 == "Plays tennis" } }
        expectEqual(read(user), "Likes tea\n§\nUses Outlook")
        let mode = try FileManager.default.attributesOfItem(atPath: user.path)[.posixPermissions] as? Int
        expectEqual(mode, 0o600)
        try expectEqual(FileManager.default.contentsOfDirectory(atPath: memories.path).filter { $0.hasSuffix(".tmp") }, [])
        // Nothing changed means nothing written.
        let before = try FileManager.default.attributesOfItem(atPath: user.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.01)
        try files.edit(.user) { _ in }
        try expectEqual(FileManager.default.attributesOfItem(atPath: user.path)[.modificationDate] as? Date, before)
        // A missing file starts empty, and a byte-order mark is dropped the way Hermes drops it.
        try files.edit(.memory) { entries in entries.append("Josh's repos live in ~/projects") }
        expectEqual(read(notes), "Josh's repos live in ~/projects")
        try write("\u{FEFF}First\n§\nSecond", to: user)
        try expectEqual(files.entries(.user), ["First", "Second"])
    }

    func testASymlinkedFileStaysASymlink() throws {
        let elsewhere = root.appendingPathComponent("synced")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let real = elsewhere.appendingPathComponent("USER.md")
        try write("Likes tea\n§\nPlays tennis", to: real)
        try FileManager.default.createSymbolicLink(at: user, withDestinationURL: real)
        try files.edit(.user) { $0.removeLast() }
        try expectEqual(FileManager.default.destinationOfSymbolicLink(atPath: user.path), real.path)
        expectEqual(read(real), "Likes tea")
        try expectEqual(FileManager.default.contentsOfDirectory(atPath: elsewhere.path), ["USER.md"])
    }

    func testEditLeavesUntidyAndUnreadableFilesAlone() throws {
        for untidy in ["Likes tea  \n§\n\n§\nPlays tennis", "Likes tea\n§\n" + String(repeating: "x", count: 1400)] {
            try write(untidy, to: user)
            do { try files.edit(.user) { $0.append("New") }; fail("an untidy file was edited") }
            catch { expectEqual(error as? HermesMemoryError, .untidy(file: "USER.md")) }
            expectEqual(read(user), untidy)
        }
        try Data([0x41, 0xFF, 0x42]).write(to: user)
        do { try files.edit(.user) { $0.append("New") }; fail("an unreadable file was edited") }
        catch { expectEqual(error as? HermesMemoryError, .unreadable(file: "USER.md")) }
        try expectEqual(Data(contentsOf: user), Data([0x41, 0xFF, 0x42]))
    }

    func testEditKeepsToTheLimits() throws {
        let small = HermesMemoryFiles(directory: memories, limits: [.user: 40])
        try write("Likes tea", to: user)
        do { try small.edit(.user) { $0.append(String(repeating: "y", count: 41)) }; fail("too long") }
        catch { expectEqual(error as? HermesMemoryError, .tooLong(file: "USER.md", length: 41, limit: 40)) }
        do { try small.edit(.user) { $0.append(String(repeating: "y", count: 30)) }; fail("over the limit") }
        catch { expectEqual(error as? HermesMemoryError, .full(file: "USER.md", total: 42, limit: 40)) }
        try small.edit(.user) { $0.append(String(repeating: "y", count: 28)) }
        expectEqual(HermesMemory.length(read(user)), 40)
        // A file that's over a lowered limit can still shrink.
        let tighter = HermesMemoryFiles(directory: memories, limits: [.user: 30])
        try write("Likes tea\n§\nPlays tennis every week\n§\nX", to: user)
        try tighter.edit(.user) { $0.removeLast() }
        expectEqual(read(user), "Likes tea\n§\nPlays tennis every week")
        // Entries that can't round-trip are refused.
        for bad in ["", "   ", "ends with\n§", "has\n§\ninside"] {
            do { try files.edit(.user) { $0.insert(bad, at: 0) }; fail("accepted \(bad.debugDescription)") }
            catch { expectEqual(error as? HermesMemoryError, .badEntry) }
        }
        expectEqual(read(user), "Likes tea\n§\nPlays tennis every week")
    }

    func testEditWaitsForHermesLockAndReadsInsideIt() throws {
        try write("Likes tea", to: user)
        let lock = open(user.path + ".lock", O_RDWR | O_CREAT, 0o644)
        defer { close(lock) }
        expectEqual(flock(lock, LOCK_EX), 0)
        var impatient = files
        impatient.lockWait = 0.2
        do { try impatient.edit(.user) { $0.append("New") }; fail("edited while Hermes held the lock") }
        catch { expectEqual(error as? HermesMemoryError, .busy) }
        // Hermes writes while holding the lock; the edit that was waiting sees Hermes's version.
        let waiting = files
        let done = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var seen: [String] = [] }
        let box = Box()
        DispatchQueue.global().async {
            _ = try? waiting.edit(.user) { entries in box.seen = entries; entries.append("Daisy's edit") }
            done.signal()
        }
        Thread.sleep(forTimeInterval: 0.1)
        try write("Likes tea\n§\nWritten by Hermes", to: user)
        flock(lock, LOCK_UN)
        expectEqual(done.wait(timeout: .now() + 5), .success)
        expectEqual(box.seen, ["Likes tea", "Written by Hermes"])
        expectEqual(read(user), "Likes tea\n§\nWritten by Hermes\n§\nDaisy's edit")
    }

    func testHermesDriftCheckAcceptsWhatDaisyWrites() throws {
        // Hermes's own check (MemoryStore._detect_external_drift) in Python, on files Daisy wrote with
        // odd whitespace, emoji and accents in them.
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return }
        try write("\u{1F}Likes tea 🍵\n§\ncafe\u{301} owner", to: user)
        try files.edit(.user) { entries in
            entries.append("  Speaks Malayalam\u{A0}")
            entries.append("Line one\nline two")
        }
        let check = """
        import sys
        raw = open(sys.argv[1], encoding="utf-8-sig").read()
        parsed = [e for e in (x.strip() for x in raw.split("\\n§\\n")) if e]
        clean = not raw.strip() or (raw.strip() == "\\n§\\n".join(parsed) and max(map(len, parsed), default=0) <= int(sys.argv[2]))
        print("clean" if clean else "drift", len("\\n§\\n".join(parsed)))
        """
        let script = root.appendingPathComponent("drift.py")
        try write(check, to: script)
        let process = Process()
        process.executableURL = python
        process.arguments = [script.path, user.path, "1375"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run(); process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        expectEqual(output, "clean \(HermesMemory.length(read(user)))")
    }

    func testLimitsComeFromHermesConfig() throws {
        try write("model:\n  default: x\nmemory:\n  memory_enabled: true\n  memory_char_limit: 3000  # bigger\n  user_char_limit: 1500\ndisplay:\n  user_char_limit: 9\n",
                  to: root.appendingPathComponent("config.yaml"))
        let limits = HermesMemory.limits(home: root)
        expectEqual(limits[.memory], 3000)
        expectEqual(limits[.user], 1500)
        expectEqual(HermesMemory.limits(home: root.appendingPathComponent("nowhere")), [:])
        expectEqual(HermesMemoryFiles(directory: memories).limit(.user), 1375)
    }

    func testFeedShowsWhatHermesDidOnItsOwn() {
        var state = LearnedState()
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        // The first look is the baseline: what's there already isn't news.
        var items = LearnedFeed.build(current: [.user: ["Is in high school"], .memory: []], records: [], state: &state, now: start)
        expectTrue(items.isEmpty)

        let later = start.addingTimeInterval(3600)
        let records = [
            LearnedRecord(at: later, origin: "assistant_tool", target: .user, action: .add, entry: "Prefers short answers"),
            LearnedRecord(at: later.addingTimeInterval(1), origin: "background_review", target: .user, action: .add, entry: "Uses Gmail for mail"),
            LearnedRecord(at: later.addingTimeInterval(2), origin: "background_review", target: .memory, action: .replace,
                          entry: "Repos live in ~/code", oldText: "projects", was: "Repos live in ~/projects"),
            LearnedRecord(at: later.addingTimeInterval(3), origin: "background_review", target: .user, action: .remove,
                          oldText: "high school", was: "Is in high school"),
            LearnedRecord(at: later.addingTimeInterval(4), origin: "background_review", target: .user, action: .remove, oldText: "tennis")
        ]
        let current: [HermesMemory.Target: [String]] = [
            .user: ["Prefers short answers", "Uses Gmail for mail", "Has a sister named Priya"],
            .memory: ["Repos live in ~/code"]
        ]
        items = LearnedFeed.build(current: current, records: records, state: &state, now: later.addingTimeInterval(10))
        expectEqual(items.map(\.kind), [.learned, .forgot, .forgot, .changed, .learned])
        expectEqual(items.map(\.text), ["Has a sister named Priya", "tennis", "Is in high school", "Repos live in ~/code", "Uses Gmail for mail"])
        // The conversation's own save isn't in the feed; the one nothing logged is, marked as such.
        expectFalse(items.contains { $0.text == "Prefers short answers" })
        expectEqual(items.first?.origin, nil)
        expectEqual(items.last?.origin, "background_review")
        expectEqual(items[3].previous, "Repos live in ~/projects")
        expectEqual(items.map(\.canUndo), [true, false, true, true, true])
        expectFalse(items[1].exact)

        // Keep takes an item off; entries Daisy wrote itself never show.
        state.kept.append(items[4].id)
        state.mine["user"] = ["Has a sister named Priya": later]
        let after = LearnedFeed.build(current: current, records: records, state: &state, now: later.addingTimeInterval(20))
        expectEqual(after.map(\.text), ["tennis", "Is in high school", "Repos live in ~/code"])

        // A forgotten entry that's back isn't forgotten, and old removals drop off.
        var back = current
        back[.user]?.append("Is in high school")
        let returned = LearnedFeed.build(current: back, records: records, state: &state, now: later.addingTimeInterval(30))
        expectFalse(returned.contains { $0.kind == .forgot && $0.text == "Is in high school" })
        let month = LearnedFeed.build(current: back, records: records, state: &state, now: later.addingTimeInterval(31 * 86_400))
        expectFalse(month.contains { $0.kind == .forgot })
    }

    func testFeedRecoversAWholeEntryFromWhatItSawBefore() {
        var state = LearnedState()
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        _ = LearnedFeed.build(current: [.user: ["Uses Outlook for mail", "Plays tennis"]], records: [], state: &state, now: start)
        // The plugin couldn't tell which entry went (something else wrote at the same time), but Daisy
        // saw the whole entry before, and only one entry that's gone contains the fragment.
        let records = [LearnedRecord(at: start.addingTimeInterval(60), origin: "background_review", target: .user, action: .replace,
                                     entry: "Uses Gmail for mail", oldText: "Outlook")]
        let items = LearnedFeed.build(current: [.user: ["Uses Gmail for mail", "Plays tennis"]], records: records, state: &state,
                                      now: start.addingTimeInterval(61))
        expectEqual(items.first?.previous, "Uses Outlook for mail")
        expectTrue(items.first?.canUndo ?? false)
    }

    @MainActor
    func testUndoEditAndKeepThroughTheModel() async throws {
        try write("Is in high school\n§\nUses Outlook for mail\n§\nPlays tennis", to: user)
        let learned = LearnedMemory(files: files, log: log, state: state)
        learned.refresh()
        expectTrue(learned.items.isEmpty)

        // Hermes's review, as the plugin would log it.
        try write("Is in high school\n§\nUses Gmail for mail\n§\nLikes jazz", to: user)
        let now = Date().timeIntervalSince1970
        try logLines([
            ["v": 1, "at": now, "origin": "background_review", "target": "user", "action": "replace", "entry": "Uses Gmail for mail",
             "old_text": "Outlook", "was": "Uses Outlook for mail"],
            ["v": 1, "at": now + 1, "origin": "background_review", "target": "user", "action": "remove", "old_text": "tennis", "was": "Plays tennis"],
            ["v": 1, "at": now + 2, "origin": "background_review", "target": "user", "action": "add", "entry": "Likes jazz"]
        ])
        learned.refresh()
        expectEqual(learned.items.map(\.kind), [.learned, .forgot, .changed])

        // Undo a learned entry: it's gone from the file and the feed.
        let jazz = try unwrap(learned.items.first { $0.text == "Likes jazz" })
        let undidJazz = await learned.undo(jazz)
        expectTrue(undidJazz)
        expectEqual(read(user), "Is in high school\n§\nUses Gmail for mail")
        // Undo a change: the old entry is back where it was, and doesn't come back as news.
        let gmail = try unwrap(learned.items.first { $0.kind == .changed })
        let undidGmail = await learned.undo(gmail)
        expectTrue(undidGmail)
        expectEqual(read(user), "Is in high school\n§\nUses Outlook for mail")
        // Put back what it forgot.
        let tennis = try unwrap(learned.items.first { $0.kind == .forgot })
        let putBack = await learned.undo(tennis)
        expectTrue(putBack)
        expectEqual(read(user), "Is in high school\n§\nUses Outlook for mail\n§\nPlays tennis")
        expectTrue(learned.items.isEmpty)

        // Edit: the user's words replace Hermes's, and it's theirs from then on.
        try write("Is in high school\n§\nUses Outlook for mail\n§\nPlays tennis\n§\nLoves anchovies", to: user)
        try logLines([["v": 1, "at": Date().timeIntervalSince1970, "origin": "background_review", "target": "user", "action": "add",
                       "entry": "Loves anchovies"]])
        learned.refresh()
        let anchovies = try unwrap(learned.items.first)
        let edited = await learned.edit(anchovies, to: "  Likes anchovies on pizza, nowhere else ")
        expectTrue(edited)
        expectEqual(read(user), "Is in high school\n§\nUses Outlook for mail\n§\nPlays tennis\n§\nLikes anchovies on pizza, nowhere else")
        expectTrue(learned.items.isEmpty)
        let blank = await learned.edit(anchovies, to: "   ")
        expectFalse(blank)

        // Undoing something that's no longer there says so and changes nothing.
        let gone = await learned.undo(anchovies)
        expectFalse(gone)
        expectEqual(learned.problem, "That entry isn't in USER.md anymore.")

        // Keep: the entry stays, the item goes, and stays gone after a reload.
        try write("Is in high school\n§\nPrefers dark mode", to: user)
        try logLines([["v": 1, "at": Date().timeIntervalSince1970, "origin": "background_review", "target": "user", "action": "add",
                       "entry": "Prefers dark mode"]])
        learned.refresh()
        let dark = try unwrap(learned.items.first)
        learned.keep(dark)
        expectTrue(learned.items.isEmpty)
        let reopened = LearnedMemory(files: files, log: log, state: state)
        reopened.refresh()
        expectTrue(reopened.items.isEmpty)
        expectEqual(read(user), "Is in high school\n§\nPrefers dark mode")
        let mode = try FileManager.default.attributesOfItem(atPath: state.path)[.posixPermissions] as? Int
        expectEqual(mode, 0o600)
    }

    func testLogLinesDecodeAndBadOnesAreSkipped() throws {
        try write(#"{"v":1,"at":1790000000.5,"origin":"background_review","target":"user","file":"USER.md","action":"replace","entry":"New","old_text":"Old","was":"Old one","session":"s","call":"c","op":0}"# + "\n"
                  + "{ torn line\n"
                  + #"{"v":1,"at":1790000001,"origin":"assistant_tool","target":"elsewhere","action":"add","entry":"x"}"# + "\n"
                  + #"{"v":1,"at":1789999999,"target":"memory","action":"add","entry":"Earlier"}"#, to: log)
        let records = LearnedLog.read(log)
        expectEqual(records.map(\.entry), ["Earlier", "New"])
        expectEqual(records.last?.oldText, "Old")
        expectEqual(records.last?.was, "Old one")
        expectTrue(records.last?.onItsOwn ?? false)
        expectEqual(records.first?.origin, "unknown")
        expectEqual(LearnedLog.read(root.appendingPathComponent("missing.jsonl")), [])
    }
}
