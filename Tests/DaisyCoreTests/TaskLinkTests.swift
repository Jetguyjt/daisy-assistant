import Foundation
import DaisyCore

final class TaskLinkTests {
    private var root: URL!

    func setUp() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("daisy-links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func tearDown() { try? FileManager.default.removeItem(at: root) }

    private struct Cases: Decodable {
        struct Detect: Decodable {
            let text: String
            let none: Bool?
            let kind, title, url, path, fileId, eventId, calendarId, threadId, noteId, reminderId: String?
        }
        struct Built: Decodable { let kind: String; let url: String; let fileId, eventId, calendarId, start, threadId, messageId: String? }
        let detect: [Detect]
        let built: [Built]
    }

    func testPastesPickTheirKindLikeThePlugin() throws {
        let cases = try JSONDecoder().decode(Cases.self, from: try taskFixture("link-cases.json"))
        for want in cases.detect {
            let got = TaskLink.detect(want.text)
            if want.none == true {
                if got != nil { fail("“\(want.text)” should not be a link, got \(got!.kind)") }
                continue
            }
            guard let got else { fail("“\(want.text)” wasn't read as a link"); continue }
            let pairs: [(String?, String, String)] = [(want.kind, got.kind.rawValue, "kind"), (want.title, got.title, "title"),
                (want.url, got.url, "url"), (want.path, got.path, "path"), (want.fileId, got.fileID, "fileId"),
                (want.eventId, got.eventID, "eventId"), (want.calendarId, got.calendarID, "calendarId"),
                (want.threadId, got.threadID, "threadId"), (want.noteId, got.noteID, "noteId"), (want.reminderId, got.reminderID, "reminderId")]
            for (expected, actual, field) in pairs where expected != nil && expected != actual {
                fail("“\(want.text)” \(field): \(actual) != \(expected!)")
            }
            expectTrue(got.bookmark == nil)
            try got.validate()
        }
        let home = try unwrap(TaskLink.detect("~/Documents/College/essay.pdf"))
        expectEqual(home.kind, .file)
        expectEqual(home.path, NSHomeDirectory() + "/Documents/College/essay.pdf")
    }

    func testLinksMadeFromIdsMatchThePlugin() throws {
        let cases = try JSONDecoder().decode(Cases.self, from: try taskFixture("link-cases.json"))
        for want in cases.built {
            let kind = try unwrap(TaskLink.Kind(rawValue: want.kind))
            let built = TaskLink.builtURL(kind: kind, fileID: want.fileId ?? "", eventID: want.eventId ?? "", calendarID: want.calendarId ?? "",
                                          start: want.start ?? "", threadID: want.threadId ?? "", messageID: want.messageId ?? "")
            expectEqual(built, want.url)
            let link = TaskLink(kind: kind, fileID: want.fileId ?? "", eventID: want.eventId ?? "", calendarID: want.calendarId ?? "",
                                start: want.start ?? "", threadID: want.threadId ?? "", messageID: want.messageId ?? "")
            expectEqual(link.webLink, want.url)
            expectTrue(link.url.isEmpty)
        }
        expectEqual(TaskLink(kind: .note, noteID: "x-coredata://00000000-0000-4000-8000-00000000AAAA/ICNote/p101").webLink, "")
    }

    func testBookmarksFindAMovedFile() throws {
        let original = root.appendingPathComponent("Why Harvard.txt")
        try Data("draft".utf8).write(to: original)
        let link = TaskLink.file(path: original.path).refreshed()
        expectTrue(link.bookmark != nil)
        expectEqual(link.title, "Why Harvard.txt")
        let folder = root.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let moved = folder.appendingPathComponent("Why Harvard final.txt")
        try FileManager.default.moveItem(at: original, to: moved)
        let found = try unwrap(link.resolvedFile())
        expectEqual(found.resolvingSymlinksInPath().path, moved.resolvingSymlinksInPath().path)
        let followed = link.refreshed()
        expectEqual(URL(fileURLWithPath: followed.path).resolvingSymlinksInPath().path, moved.resolvingSymlinksInPath().path)
        expectTrue(followed.bookmark != nil)
        // The stored form keeps the bookmark, and it still works after a round trip.
        let reread = try JSONDecoder().decode(TaskLink.self, from: try JSONEncoder().encode(followed))
        expectEqual(reread, followed)
        expectEqual(reread.resolvedFile()?.resolvingSymlinksInPath().path, moved.resolvingSymlinksInPath().path)
        // A path alone (what Hermes adds) works while the file is there, and gets a bookmark on refresh.
        let plain = TaskLink.file(path: moved.path)
        expectEqual(plain.resolvedFile()?.path, moved.path)
        expectTrue(plain.refreshed().bookmark != nil)
        try FileManager.default.removeItem(at: moved)
        expectTrue(link.resolvedFile() == nil)
        expectTrue(plain.resolvedFile() == nil)
        expectEqual(plain.refreshed(), plain)
    }

    func testLinksAreCheckedAndReadLeniently() throws {
        expectThrows(try TaskLink(kind: .url, url: "javascript:alert(1)").validate())
        expectThrows(try TaskLink(kind: .url, url: "").validate())
        expectThrows(try TaskLink(kind: .file, path: "relative/path.pdf").validate())
        expectThrows(try TaskLink(kind: .note, noteID: "not a note").validate())
        expectThrows(try TaskLink(kind: .reminder, reminderID: "").validate())
        expectThrows(try TaskLink(kind: .url, title: String(repeating: "x", count: 201), url: "https://example.com").validate())
        try TaskLink(kind: .googleDoc, fileID: "1AbCdEfGhIjKlMnOpQrStUv").validate()
        try TaskLink(kind: .calendarEvent, eventID: "abc123def456", calendarID: "primary").validate()
        var item = WorkItem(title: "Too many links")
        item.links = (0...TaskLink.perItem).map { TaskLink(kind: .url, url: "https://example.com/\($0)") }
        expectThrows(try item.validate())

        let raw = #"""
        [{"kind": "someday_kind", "url": "https://example.com/x"},
         {"kind": "someday_kind", "path": "/tmp/notes.txt", "title": "Notes"},
         {"kind": "file"},
         {"title": "nothing to point at"},
         {"id": "custom-link-1", "kind": "url", "url": "https://example.com/y", "bookmark": ""}]
        """#
        let item2 = try JSONDecoder().decode(WorkItem.self, from: Data(#"{"title": "Odd links", "links": \#(raw)}"#.utf8))
        expectEqual(item2.links.map(\.kind), [.url, .file, .file, .url])
        expectEqual(item2.links[0].title, "example.com")
        expectEqual(item2.links[1].title, "Notes")
        expectEqual(item2.links[3].id, TaskFile.stableID("custom-link-1"))
        expectTrue(item2.links[3].bookmark == nil)
        // No id: a stable one, the same every time (and the same the plugin makes).
        let again = try JSONDecoder().decode(WorkItem.self, from: Data(#"{"title": "Odd links", "links": \#(raw)}"#.utf8))
        expectEqual(again.links.map(\.id), item2.links.map(\.id))
        expectEqual(item2.links[0].id, TaskFile.stableID("link:https://example.com/x\n\n"))
    }

    func testTasksKeepTheirLinks() async throws {
        let url = root.appendingPathComponent("tasks.json")
        let store = try TaskStore(url: url)
        let doc = try unwrap(TaskLink.detect("https://docs.google.com/document/d/1AbCdEfGhIjKlMnOpQrStUv/edit"))
        let event = TaskLink(kind: .calendarEvent, title: "Interview", eventID: "abc123def456", calendarID: "primary", start: "2026-10-02")
        let saved = try await store.save(WorkItem(title: "Why Harvard", links: [doc, event]), expectedRevision: 0)
        expectEqual(saved.links, [doc, event])
        let reread = try TaskFile.read(url)
        expectEqual(reread.first?.links, [doc, event])
        let text = try String(contentsOf: url)
        expectTrue(text.contains(#""fileId" : "1AbCdEfGhIjKlMnOpQrStUv""#))
        expectFalse(text.contains(#""path" : """#))
        var bad = saved; bad.links.append(TaskLink(kind: .url, url: "ftp://example.com"))
        do { _ = try await store.save(bad, expectedRevision: saved.revision); fail("Saved a link that isn't a web link") } catch { }
    }
}
