import Foundation
import DaisyCore

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
