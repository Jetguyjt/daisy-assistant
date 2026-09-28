import Foundation
import DaisyCore

private actor BrowserFixture: BrowserTransport {
    var count = 40
    var calls = [String]()
    var textOnly = false
    func setTextOnly(_ value: Bool) { textOnly = value }
    func call(_ name: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        calls.append(name)
        if textOnly && name != "take_snapshot" {
            if name == "new_page" { count += 1 }
            let lines = ["## Pages"] + (1...count).map { "\($0): Fixture \($0) (https://example.com/\($0))" + ($0 == 1 ? " [selected]" : "") }
            return .object(["content": .array([.object(["type": "text", "text": .string(lines.joined(separator: "\n"))])])])
        }
        if name == "new_page" { count += 1 }
        if name == "take_snapshot" { return .object(["content": .array([.object(["type": "text", "text": .string(String(repeating: "Synthetic page text. ", count: 300))])])]) }
        return .object(["structuredContent": .object(["pages": .array((1...count).map { i in
            .object(["id": .number(Double(i)), "url": .string("https://example.com/\(i)"), "title": .string("Fixture \(i)")])
        })])])
    }
}
final class WorkspaceTests {
    func testReviewDoesNotWriteAndStaleTaskCannotOverwrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TaskStore(url: root.appendingPathComponent("tasks.json"))
        let session = CapabilitySession(registry: try CapabilityRegistry(providers: [TaskCapabilityProvider(store: store)]))
        let proposal = try await session.execute(.init(name: "prepare_task", arguments: ["title": "Synthetic essay", "project": "Test", "due": "2026-10-01"]))
        expectEqual(proposal.status, .succeeded)
        let empty = await store.all(); expectTrue(empty.isEmpty)
        let review = try unwrap(proposal.output.review); _ = try await review.commit()
        let items = await store.all(); expectEqual(items.count, 1)
        let saved = try unwrap(items.first)
        let duplicate = Task { try await review.commit() }
        do { _ = try await duplicate.value; fail("Duplicate review overwrote task") } catch { }
        let loaded = try TaskStore(url: root.appendingPathComponent("tasks.json")); let persisted = await loaded.all(); expectEqual(persisted, items)
        var changed = saved; changed.notes = "Newer user edit"; _ = try await store.save(changed, expectedRevision: saved.revision)
        do { _ = try await store.save(saved, expectedRevision: saved.revision); fail("Stale update succeeded") } catch { }
        expectThrows(try WorkItem(title: "Test", due: "2026-02-30").validate())
    }
    func testDraftReviewCannotOverwriteOrEscapeFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = CapabilitySession(registry: try CapabilityRegistry(providers: [DraftCapabilityProvider(root: root)]))
        let result = try await session.execute(.init(name: "prepare_file", arguments: ["filename": "fixture.py", "content": "print('fixture')\n"]))
        let review = try unwrap(result.output.review)
        let target = root.appendingPathComponent("fixture.py")
        expectFalse(FileManager.default.fileExists(atPath: target.path)); _ = try await review.commit()
        try expectEqual(try String(contentsOf: target), "print('fixture')\n")
        do { _ = try await review.commit(); fail("Overwrote existing file") } catch { }
        for name in ["../escape.txt", ".hidden", "subdir/test.txt", "bad:name"] { expectThrows(try DraftFile.destination(root: root, name: name)) }
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        expectThrows(try DraftFile.write(root: root, name: "link.txt", text: "changed"))
        try expectEqual(try String(contentsOf: target), "print('fixture')\n")
    }
    func testBrowserTabsParseTextPageListWithoutStructuredContent() async throws {
        let text = """
        Note: the browser was reconnected.
        ## Pages
        0: Gmail - Inbox (12) - me@example.com (https://mail.google.com/mail/u/0/#inbox) [selected]
        1: https://example.com/
        2: Bar (baz) - Wikipedia (https://en.wikipedia.org/wiki/Bar_(baz)) isolatedContext=work
        3: New Tab (chrome://newtab/)
        ## Extension Pages
        7: Helper (chrome-extension://abcdef/popup.html)
        """
        let pages = BrowserAccess.pages(fromText: text)
        expectEqual(pages.map(\.id), [0, 1, 2, 3])
        expectEqual(pages[0].title, "Gmail - Inbox (12) - me@example.com")
        expectEqual(pages[0].url, "https://mail.google.com/mail/u/0/#inbox")
        expectEqual(pages[1].title, ""); expectEqual(pages[1].url, "https://example.com/")
        expectEqual(pages[2].url, "https://en.wikipedia.org/wiki/Bar_(baz)"); expectEqual(pages[2].title, "Bar (baz) - Wikipedia")
        expectThrows(try BrowserAccess.pages(in: .object(["content": .array([.object(["type": "text", "text": "No pages here"])])])))
        let fixture = BrowserFixture(); await fixture.setTextOnly(true)
        let session = CapabilitySession(registry: try CapabilityRegistry(providers: [BrowserCapabilityProvider(connection: fixture, available: true)]))
        let tabs = try await session.execute(.init(name: "browser_tabs", arguments: ["query": "Fixture 4"]))
        expectEqual(tabs.status, .succeeded)
        let tabsJSON = try tabs.output.data.json()   // JSONSerialization escapes slashes, so match titles
        expectTrue(tabsJSON.contains("Fixture 4\"")); expectTrue(tabsJSON.contains("Fixture 40")); expectFalse(tabsJSON.contains("Fixture 5"))
        let opened = try await session.execute(.init(name: "browser_open", arguments: ["url": "https://example.com/new"]))
        expectEqual(opened.status, .succeeded)
        let openedJSON = try opened.output.data.json()
        expectTrue(openedJSON.contains("Fixture 41")); expectFalse(openedJSON.contains("Fixture 40"))
    }
    func testBrowserPaginationNewTabAndIDValidation() async throws {
        let fake = BrowserFixture()
        let access = BrowserAccess(transport: fake)
        do { _ = try await access.read(page: 1, offset: 0); fail("Accepted invented tab") } catch { }
        let result = try await access.open("https://example.com/new")
        let json = try result.data.json(); expectTrue(json.contains("41")); expectFalse(json.contains("Fixture 1\""))
        let text = try await access.read(page: 41, offset: 0); try expectTrue(try text.data.json().contains("next_offset"))
        let tabs = try await access.tabs(query: "Fixture", offset: 36); try expectTrue(try tabs.data.json().contains("Fixture 40"))
        for raw in ["javascript:alert(1)", "file:///etc/passwd", "https://secret:password@example.com/"] { expectThrows(try BrowserAccess.validatedURL(raw)) }
        try expectEqual(try BrowserAccess.validatedURL("https://example.com/").host, "example.com")
    }
    func testProjectSnapshotReadsGitStatusBranchAndNotes() async throws {
        let git = URL(fileURLWithPath: "/usr/bin/git")
        guard FileManager.default.isExecutableFile(atPath: git.path) else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await LocalProcess.capture(executable: git, arguments: ["init", "-b", "main", root.path], timeout: 10)
        try "Ship v1 tomorrow.\nNext step: draft essay outline.".write(to: root.appendingPathComponent("plan.md"), atomically: true, encoding: .utf8)
        try "scratch".write(to: root.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        let memories = [Memory(key: "active_projects", value: "fixture: \(root.path)", source: "test", updatedAt: Date(), revision: 1)]
        let provider = ProjectSnapshotCapabilityProvider(memories: memories, git: git)
        let session = CapabilitySession(registry: try CapabilityRegistry(providers: [provider]))
        let receipt = try await session.execute(.init(name: "project_state", arguments: ["name": .string("fixture")]))
        expectEqual(receipt.status, .succeeded)
        let json = try receipt.output.data.json()
        expectTrue(json.contains("main"))
        expectTrue(json.contains("Ship v1 tomorrow"))
        expectTrue(json.contains("untracked"))
        expectTrue(json.contains("plan.md"))
    }
    func testProjectSnapshotBlockedWithoutActiveProjectsMemory() async throws {
        let provider = ProjectSnapshotCapabilityProvider(memories: [])
        let registry = try CapabilityRegistry(providers: [provider])
        expectTrue(registry.modelDefinitions.isEmpty)
        let session = CapabilitySession(registry: registry)
        let receipt = try await session.execute(.init(name: "project_state", arguments: [:]))
        expectEqual(receipt.status, .blocked)
    }
    func testChromeHealthKeepsSlowAdapterAndDropsDeadAdapter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("chrome_fixture.py")
        try """
        import json, sys, time
        mode = sys.argv[1]; calls = 0
        for line in sys.stdin:
            msg = json.loads(line)
            if 'id' not in msg: continue
            if msg.get('method') == 'tools/call':
                calls += 1
                if calls > 1 and mode == 'die': sys.exit(0)
                if calls > 1: time.sleep(3)
            sys.stdout.write(json.dumps({'jsonrpc':'2.0','id':msg['id'],'result':{'content':[]}})+'\\n'); sys.stdout.flush()
        """.write(to: script, atomically: true, encoding: .utf8)
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        let slow = ChromeConnection()
        try await slow.connect(executable: python, arguments: [script.path, "slow"])
        let slowConnected = await slow.connected; expectTrue(slowConnected)
        let slowHealth = await slow.health(timeout: 0.5); expectEqual(slowHealth, ChromeConnection.Health.slow)
        let stillConnected = await slow.connected; expectTrue(stillConnected)
        await slow.disconnect()
        let dying = ChromeConnection()
        try await dying.connect(executable: python, arguments: [script.path, "die"])
        let dyingHealth = await dying.health(timeout: 3); expectEqual(dyingHealth, ChromeConnection.Health.lost)
        let dyingConnected = await dying.connected; expectFalse(dyingConnected)
    }
    func testMCPCapturesAdapterStderr() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("stderr_fixture.py")
        try """
        import json, sys
        sys.stderr.write("adapter warmup line\\n"); sys.stderr.flush()
        for line in sys.stdin:
            msg=json.loads(line)
            if 'id' not in msg: continue
            reply={'jsonrpc':'2.0','id':msg['id'],'result':{'ok':True}}
            sys.stdout.write(json.dumps(reply)+'\\n'); sys.stdout.flush()
        """.write(to: script, atomically: true, encoding: .utf8)
        let connection = MCPConnection()
        try await connection.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path])
        try await Task.sleep(nanoseconds: 200_000_000)
        let tail = await connection.recentStderr()
        expectTrue(tail.contains("adapter warmup"))
        let stage = await connection.stage
        expectEqual(stage, MCPConnection.Stage.ready)
        await connection.stop()
    }
    func testMCPProtocolTimeoutCancellationAndRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("fixture.py")
        try """
        import json, sys
        for line in sys.stdin:
            msg=json.loads(line)
            if 'id' not in msg: continue
            if msg['method']=='hang': continue
            reply={'jsonrpc':'2.0','id':msg['id'],'result':{'fixture':True}}
            wire=json.dumps(reply)+'\\n'
            sys.stdout.write(wire[:8]);sys.stdout.flush()
            sys.stdout.write(wire[8:]);sys.stdout.flush()
        """.write(to: script, atomically: true, encoding: .utf8)
        let connection = MCPConnection()
        let executable = URL(fileURLWithPath: "/usr/bin/python3")
        try await connection.start(executable: executable, arguments: [script.path])
        let result = try await connection.request(method: "fixture", parameters: .object([:]))
        expectEqual(result, .object(["fixture": .bool(true)]))
        do { _ = try await connection.request(method: "hang", parameters: .object([:]), timeout: 0.1); fail("Timeout did not fire") } catch { }
        let pending = Task { try await connection.request(method: "hang", parameters: .object([:])) }
        try await Task.sleep(nanoseconds: 30_000_000); pending.cancel()
        do { _ = try await pending.value; fail("Cancel failed") } catch is CancellationError { }
        await connection.stop()
        try await connection.start(executable: executable, arguments: [script.path])
        let restarted = try await connection.request(method: "fixture", parameters: .object([:]))
        expectEqual(restarted, result); await connection.stop()
    }
}
