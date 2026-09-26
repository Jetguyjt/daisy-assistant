import Foundation
import JarvisCore

/// Runs the Hermes backend against a scripted stand-in for `hermes-acp` that speaks the same
/// ACP messages the installed Hermes sends (captured from its source). No model, no network.
final class HermesTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-\(UUID().uuidString)")
    var agent: URL { root.appendingPathComponent("fake-hermes-acp") }

    func setUp() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.fixture.write(to: agent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agent.path)
    }
    func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func backend(_ environment: [String: String] = [:]) -> HermesBackend {
        HermesBackend(settings: .init(executable: agent, workingDirectory: root,
                                      sessionFile: root.appendingPathComponent("session"), environment: environment))
    }

    private struct Turn { var text = ""; var tools: [AgentToolActivity] = []; var approvals: [AgentApproval] = []; var stop: String? }

    private func run(_ hermes: HermesBackend, _ prompt: String, answer: ((AgentApproval) -> String?)? = nil) async throws -> Turn {
        var turn = Turn()
        for try await event in hermes.send(prompt) {
            switch event {
            case .text(let text): turn.text += text
            case .tool(let tool): turn.tools.append(tool)
            case .approval(let approval):
                turn.approvals.append(approval)
                await hermes.resolve(approval: approval.id, optionID: answer?(approval))
            case .finished(let reason): turn.stop = reason
            default: break
            }
        }
        return turn
    }

    func testBasicReasoningStreamsThroughHermes() async throws {
        let hermes = backend()
        let link = await hermes.connect()
        expectEqual(link, .ready(detail: "gpt-test · ChatGPT"))
        let turn = try await run(hermes, "What is 37 × 18?")
        expectEqual(turn.text, "37 × 18 is 666.")
        expectEqual(turn.stop, "end_turn")
        await hermes.shutdown()
    }

    func testFileSearchShowsAsPlainActivity() async throws {
        let hermes = backend()
        let turn = try await run(hermes, "Find my resume.")
        expectEqual(turn.tools.map(\.title), ["Searching your files", "Searching your files"])
        expectEqual(turn.tools.map(\.state), [.running, .completed])
        expectEqual(turn.tools.first?.detail, "resume")
        expectTrue(turn.text.contains("Resume.pdf"))
        await hermes.shutdown()
    }

    func testSendingAMessageWaitsForApproval() async throws {
        let hermes = backend()
        let allowed = try await run(hermes, "Text Dad that I'll be home at 6.") { approval in
            approval.options.first { $0.kind == .allowOnce }?.id
        }
        expectEqual(allowed.approvals.first?.title, "Send an iMessage to Dad")
        expectEqual(allowed.approvals.first?.detail, "“I'll be home at 6.”")
        expectEqual(allowed.text, "Sent.")
        let denied = try await run(hermes, "Text Dad that I'll be home at 6.") { _ in nil }
        expectEqual(denied.text, "Not sent.")
        await hermes.shutdown()
    }

    func testCancelStopsTheTurnAndTheNextOneStillWorks() async throws {
        let hermes = backend()
        var sawText = false
        for try await event in hermes.send("Take the slow road.") {
            if case .text = event { sawText = true; break }
        }
        expectTrue(sawText)
        let next = try await run(hermes, "What is 37 × 18?")
        expectEqual(next.text, "37 × 18 is 666.")
        await hermes.shutdown()
    }

    func testMessagesUpTo100KBGoThroughAndLargerOnesDont() async throws {
        let hermes = backend()
        let big = "BIG:" + String(repeating: "a", count: HermesBackend.maxRequestBytes - 4)
        let turn = try await run(hermes, big)
        expectEqual(turn.text, "got \(HermesBackend.maxRequestBytes) bytes")
        do {
            _ = try await run(hermes, big + "a")
            fail("a message over 100 KB should be refused")
        } catch { expectTrue(error.localizedDescription.contains("100 KB")) }
        await hermes.shutdown()
    }

    func testChatListAndReopeningAnEarlierChat() async throws {
        let hermes = backend(["FAKE_KNOWN_SESSION": "s-known"])
        let chats = await hermes.sessions()
        expectEqual(chats.map(\.id), ["s-known", "s-old"])
        expectEqual(chats.map(\.title), ["Math", "Untitled chat"])
        let messages = await hermes.open(session: "s-known")
        expectEqual(messages, [AgentMessage(role: "user", text: "What's 2+2?"), AgentMessage(role: "assistant", text: "It's 4.")])
        let saved = try String(contentsOf: root.appendingPathComponent("session"), encoding: .utf8)
        expectEqual(saved, "s-known")
        let missing = await hermes.open(session: "s-gone")
        expectEqual(missing, nil)
        await hermes.shutdown()
    }

    func testAttachmentsReachHermesAsContentBlocks() async throws {
        let hermes = backend()
        var text = ""
        let prompt = AgentPrompt(text: "ATTACH", attachments: [
            .image(name: "shot.png", mimeType: "image/png", data: Data([1, 2, 3])),
            .document(name: "notes.pdf", uri: "file:///tmp/notes.pdf", text: "hello"),
            .file(URL(fileURLWithPath: "/tmp/plan.txt"))])
        for try await event in hermes.send(prompt) { if case .text(let chunk) = event { text += chunk } }
        expectEqual(text, "image,resource,resource_link,text")
        await hermes.shutdown()
    }

    func testMissingSignInAndProviderBecomeSetupSteps() async throws {
        let signedOut = backend(["FAKE_AUTH": "none"])
        if case .needsSetup(let issue) = await signedOut.connect() {
            expectEqual(issue.command, HermesBackend.signInCommand)
        } else { fail("expected a sign-in step") }
        await signedOut.shutdown()
        let noProvider = backend(["FAKE_NO_PROVIDER": "1"])
        if case .needsSetup(let issue) = await noProvider.connect() {
            expectEqual(issue.command, "hermes model")
        } else { fail("expected a provider step") }
        await noProvider.shutdown()
        let missing = HermesBackend(settings: .init(executable: root.appendingPathComponent("nope"), workingDirectory: root,
                                                    sessionFile: root.appendingPathComponent("s")))
        if case .needsSetup(let issue) = await missing.connect() { expectEqual(issue.command, HermesBackend.installCommand) }
        else { fail("expected an install step") }
    }

    func testResumedSessionReplaysHistoryAndUnknownOnesStartFresh() async throws {
        try Data("s-known".utf8).write(to: root.appendingPathComponent("session"))
        let resumed = backend(["FAKE_KNOWN_SESSION": "s-known"])
        _ = await resumed.connect()
        let history = await resumed.history()
        expectEqual(history, [AgentMessage(role: "user", text: "What's 2+2?"), AgentMessage(role: "assistant", text: "It's 4.")])
        await resumed.shutdown()
        try Data("s-gone".utf8).write(to: root.appendingPathComponent("session"))
        let fresh = backend()
        _ = await fresh.connect()
        let saved = try String(contentsOf: root.appendingPathComponent("session"), encoding: .utf8)
        expectEqual(saved, "s-1")
        let empty = await fresh.history()
        expectEqual(empty, [])
        await fresh.shutdown()
    }

    static let fixture = #"""
    #!/usr/bin/python3
    import json, os, sys
    out = sys.stdout
    def send(obj):
        out.write(json.dumps(obj) + "\n"); out.flush()
    def update(sid, upd):
        send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": upd}})
    def chunk(sid, text):
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}})
    models = {"currentModelId": "openai-codex:gpt-test", "availableModels": []}
    counter = 0
    out.write("startup chatter that is not JSON\n"); out.flush()
    lines = iter(sys.stdin.readline, "")
    for line in lines:
        msg = json.loads(line)
        method, mid, params = msg.get("method"), msg.get("id"), msg.get("params", {})
        sys.stderr.write("got %s\n" % method)
        if method == "initialize":
            methods = [{"id": "hermes-setup", "name": "Configure Hermes provider", "type": "terminal", "args": ["--setup"]}]
            if os.environ.get("FAKE_AUTH", "ok") == "ok":
                methods.insert(0, {"id": "openai-codex", "name": "openai-codex runtime credentials"})
            send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": 1, "agentCapabilities": {"loadSession": True}, "authMethods": methods}})
        elif method == "session/new":
            if os.environ.get("FAKE_NO_PROVIDER"):
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32603, "message": "Internal error",
                      "data": {"details": "No LLM provider configured. Run `hermes model` to select a provider."}}})
            else:
                counter += 1
                send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": "s-%d" % counter, "models": models, "modes": {"currentModeId": "default"}}})
        elif method == "session/load":
            sid = params["sessionId"]
            if sid == os.environ.get("FAKE_KNOWN_SESSION"):
                update(sid, {"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": "What's 2+2?"}})
                chunk(sid, "It's "); chunk(sid, "4.")
                send({"jsonrpc": "2.0", "id": mid, "result": {"models": models, "modes": {}}})
            else:
                send({"jsonrpc": "2.0", "id": mid, "result": {}})
        elif method == "session/list":
            send({"jsonrpc": "2.0", "id": mid, "result": {"sessions": [
                  {"sessionId": "s-old", "cwd": params.get("cwd"), "title": "", "updatedAt": "2026-09-24T10:00:00Z"},
                  {"sessionId": "s-known", "cwd": params.get("cwd"), "title": "Math", "updatedAt": "2026-09-25T10:00:00.250Z"}]}})
        elif method == "session/prompt":
            sid = params["sessionId"]; blocks = params["prompt"]; reason = "end_turn"
            text = next((b.get("text", "") for b in blocks if b.get("type") == "text"), "")
            if text == "ATTACH":
                chunk(sid, ",".join(b["type"] for b in blocks))
            elif text.startswith("BIG:"):
                chunk(sid, "got %d bytes" % len(text.encode("utf-8")))
            elif "37" in text:
                update(sid, {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "hidden reasoning"}})
                chunk(sid, "37 × 18 "); chunk(sid, "is 666.")
            elif "resume" in text:
                update(sid, {"sessionUpdate": "tool_call", "toolCallId": "tc-1", "title": "search_files: resume", "kind": "search"})
                update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "tc-1", "kind": "search", "status": "completed"})
                chunk(sid, "Found Resume.pdf in Documents.")
            elif "Text Dad" in text:
                send({"jsonrpc": "2.0", "id": 0, "method": "session/request_permission", "params": {"sessionId": sid,
                      "toolCall": {"toolCallId": "perm-check-1", "title": "x", "kind": "execute", "status": "pending",
                                   "rawInput": {"command": "<terminal> (plugin approval rule)",
                                                "description": "Send an iMessage to Dad — “I'll be home at 6.”"}},
                      "options": [{"optionId": "allow_once", "name": "Allow once", "kind": "allow_once"},
                                  {"optionId": "deny", "name": "Deny", "kind": "reject_once"}]}})
                answer = json.loads(next(lines))
                outcome = answer.get("result", {}).get("outcome", {})
                chunk(sid, "Sent." if outcome.get("optionId") == "allow_once" else "Not sent.")
            elif "slow" in text:
                chunk(sid, "Working on it")
                following = json.loads(next(lines))
                reason = "cancelled" if following.get("method") == "session/cancel" else "end_turn"
            else:
                chunk(sid, "ok")
            send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": reason}})
        elif mid is not None and method is not None:
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "Method not found"}})
    """#
}
