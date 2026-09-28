import Foundation
import CoreGraphics
import CoreText
import DaisyCore

private actor Counter {
    var value = 0
    func increment() { value += 1 }
}
private actor ScriptedModel: LocalLanguageModel {
    var replies: [OllamaReply]
    var observed: [[ChatMessage]] = []
    init(_ replies: [OllamaReply]) { self.replies = replies }
    func verifyLocal(model: String) async throws { }
    func chat(model: String, messages: [ChatMessage], capabilities: [CapabilityDefinition]) async throws -> OllamaReply {
        observed.append(messages)
        guard !replies.isEmpty else { throw DaisyError.message("No scripted response remaining.") }
        return replies.removeFirst()
    }
}
private struct TestProvider: CapabilityProvider {
    let entries: [Capability]
    func capabilities() -> [Capability] { entries }
}

final class CapabilityTests {
    func tearDown() { }
    private func tool(_ name: String, effect: CapabilityEffect = .readOnly, unavailable: String? = nil,
                      counter: Counter) -> Capability {
        Capability(.init(name: name, title: name, provider: "Test adapter", description: "Synthetic test capability",
            parameters: .object(properties: ["value": .number], required: ["value"]), effect: effect), unavailableReason: unavailable) { args in
                await counter.increment(); return .init(summary: "Verified fixture result", data: .object(args))
            }
    }
    func testIndependentAdaptersComposeWithoutEngineChanges() async throws {
        let counter = Counter()
        let registry = try CapabilityRegistry(providers: [
            TestProvider(entries: [tool("first_adapter", counter: counter)]),
            TestProvider(entries: [tool("second_adapter", counter: counter)])
        ])
        let model = ScriptedModel([
            .init(message: .init(role: "assistant", content: "", toolCalls: [.init(name: "first_adapter", arguments: ["value": .number(12)])])),
            .init(message: .init(role: "assistant", content: "", toolCalls: [.init(name: "second_adapter", arguments: ["value": .number(24)])])),
            .init(message: .init(role: "assistant", content: "Combined both results."))
        ])
        let result = try await AssistantEngine(client: model).respond(text: "Combine these providers", history: [], memories: [], model: "test", registry: registry)
        expectEqual(result.receipts.map(\.tool), ["first_adapter", "second_adapter"])
        expectTrue(result.receipts.allSatisfy { $0.status == .succeeded })
        let observations = await model.observed
        expectEqual(observations.count, 3)
        expectEqual(observations[2].filter { $0.role == "tool" }.map(\.tool_name), ["first_adapter", "second_adapter"])
        let count = await counter.value; expectEqual(count, 2)
    }
    func testPolicyAndSchemaCannotBeOverriddenByArguments() async throws {
        let counter = Counter()
        let registry = try CapabilityRegistry(capabilities: [tool("disabled", unavailable: "Disabled by user", counter: counter),
            tool("send_message", effect: .communicatesExternally, counter: counter), tool("read_test", counter: counter)])
        expectEqual(registry.modelDefinitions.map(\.name), ["read_test"])
        let session = CapabilitySession(registry: registry)
        let disabled = try await session.execute(.init(name: "disabled", arguments: ["value": .number(1)]))
        let send = try await session.execute(.init(name: "send_message", arguments: ["value": .number(1), "approved": .bool(true)]))
        let invalid = try await session.execute(.init(name: "read_test", arguments: ["value": "wrong type"]))
        let extra = try await session.execute(.init(name: "read_test", arguments: ["value": .number(1), "root": "/"]))
        expectEqual(disabled.status, .blocked); expectEqual(send.status, .blocked)
        expectEqual(invalid.status, .failed); expectEqual(extra.status, .failed)
        let count = await counter.value; expectEqual(count, 0)
    }
    func testDuplicateCallsReuseReceiptAndStopLoop() async throws {
        let counter = Counter()
        let registry = try CapabilityRegistry(capabilities: [tool("read_test", counter: counter)])
        let call = ToolCall(name: "read_test", arguments: ["value": .number(1)])
        let session = CapabilitySession(registry: registry)
        let first = try await session.execute(call); let second = try await session.execute(call)
        expectEqual(first.id, second.id)
        let count = await counter.value; expectEqual(count, 1)
        let reply = OllamaReply(message: .init(role: "assistant", content: "", toolCalls: [call]))
        let model = ScriptedModel([reply, reply])
        let result = try await AssistantEngine(client: model).respond(text: "test", history: [], memories: [], model: "test", registry: registry)
        expectEqual(result.receipts.count, 1); expectTrue(result.text.contains("repeated"))
    }
    func testCancellationDoesNotReportSuccess() async throws {
        let capability = Capability(.init(name: "slow", title: "Slow", provider: "Test", description: "Test",
            parameters: .object(properties: [:], required: []))) { _ in
                try await Task.sleep(nanoseconds: 20_000_000_000)
                return .init(summary: "should not complete")
            }
        let session = CapabilitySession(registry: try CapabilityRegistry(capabilities: [capability]))
        let work = Task { try await session.execute(.init(name: "slow", arguments: [:])) }
        try await Task.sleep(nanoseconds: 50_000_000); work.cancel()
        do { _ = try await work.value; fail("Expected cancellation") } catch is CancellationError { }
        let receipts = await session.receipts(); expectTrue(receipts.isEmpty)
    }
    func testReadFileRequiresGrantAndReference() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "Synthetic project next step: draw a diagram.".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let blocked = CapabilitySession(registry: try BuiltInCapabilities.registry(root: root, allowFiles: true, memories: []))
        let denied = try await blocked.execute(.init(name: "read_text_file", arguments: ["reference": .string(root.appendingPathComponent("notes.txt").path)]))
        expectEqual(denied.status, .blocked)
        let session = CapabilitySession(registry: try BuiltInCapabilities.registry(root: root, allowFiles: true, memories: [], permissions: ["read_text_file": true]))
        let forged = try await session.execute(.init(name: "read_text_file", arguments: ["reference": "/etc/passwd"]))
        expectEqual(forged.status, .failed)
        let found = try await session.execute(.init(name: "search_files", arguments: ["query": "notes"]))
        guard case .object(let data) = found.output.data, case .array(let files) = data["files"], case .object(let first) = files.first,
              let reference = first["reference"] else { fail("Missing reference"); return }
        let read = try await session.execute(.init(name: "read_text_file", arguments: ["reference": reference]))
        expectEqual(read.status, .succeeded)
        try expectTrue(read.output.data.json().contains("draw a diagram"))
    }
    func testArithmeticAndNestedJSONValidation() throws {
        try expectEqual(Arithmetic.evaluate("(125 * 0.18) + 2"), 24.5)
        expectThrows(try Arithmetic.evaluate("1 / 0"))
        expectThrows(try Arithmetic.evaluate("system('whoami')"))
        expectThrows(try Arithmetic.evaluate("1+"))
        let schema = ValueSchema.object(properties: ["items": .array(.boolean, maxItems: 2)], required: ["items"])
        try schema.validate(.object(["items": .array([.bool(true), .bool(false)])]))
        expectThrows(try schema.validate(.object(["items": .array([.string("true")])])))
    }
    func testDuplicateRegistrationRejected() throws {
        let counter = Counter(); let entry = tool("same", counter: counter)
        expectThrows(try CapabilityRegistry(capabilities: [entry, entry]))
    }
    func testReadFileHandlesPDF() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("fixture.pdf")
        try Self.makeFixturePDF(text: "Synthetic PDF fixture used for the read_text_file test.").write(to: target)
        let session = CapabilitySession(registry: try BuiltInCapabilities.registry(
            root: root, allowFiles: true, memories: [], permissions: ["read_text_file": true]))
        let searched = try await session.execute(.init(name: "search_files", arguments: ["query": "fixture"]))
        guard case .object(let data) = searched.output.data,
              case .array(let files) = data["files"],
              case .object(let first) = files.first,
              let reference = first["reference"] else { fail("Missing PDF reference"); return }
        let read = try await session.execute(.init(name: "read_text_file", arguments: ["reference": reference]))
        expectEqual(read.status, .succeeded)
        try expectTrue(try read.output.data.json().contains("Synthetic PDF fixture"))
        try expectTrue(try read.output.data.json().contains("\"pages\":1"))
    }
    func testLocalProcessCaptureReturnsStdout() async throws {
        let echo = URL(fileURLWithPath: "/bin/echo")
        let output = try await LocalProcess.capture(executable: echo, arguments: ["daisy", "capture"])
        expectEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "daisy capture")
    }
    func testLocalProcessCaptureThrowsOnNonzeroExit() async throws {
        let falseBin = URL(fileURLWithPath: "/usr/bin/false")
        do { _ = try await LocalProcess.capture(executable: falseBin, arguments: []); fail("expected nonzero-exit error") }
        catch { }
    }
    private static func makeFixturePDF(text: String) -> Data {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        let path = CGPath(rect: CGRect(x: 50, y: 50, width: 512, height: 692), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
    func testLexicalMissKeepsSavedPreferenceAvailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MemoryStore(url: root.appendingPathComponent("memory.sqlite"))
        try await store.put(key: "response_style", value: "Keep responses short, at most two sentences.", source: "Synthetic test")
        let session = CapabilitySession(registry: try BuiltInCapabilities.registry(root: nil, allowFiles: false,
            memories: [], memoryStore: store))
        let found = try await session.execute(.init(name: "search_memories", arguments: ["query": "preferred length"]))
        expectEqual(found.status, .succeeded)
        try expectTrue(found.output.data.json().contains("two sentences"))
        try expectTrue(found.output.data.json().contains("recent_fallback\":true"))
        try await store.delete(key: "response_style")
        let fresh = CapabilitySession(registry: try BuiltInCapabilities.registry(root: nil, allowFiles: false, memories: [], memoryStore: store))
        let gone = try await fresh.execute(.init(name: "search_memories", arguments: ["query": "preferred length"]))
        try expectFalse(gone.output.data.json().contains("two sentences"))
    }
}
