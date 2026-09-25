import Foundation
import JarvisCore

private final class MockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, text) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
final class OllamaTests {
    func client() -> OllamaClient { let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]; return OllamaClient(configuration: config) }
    func tearDown() { MockProtocol.handler = nil }
    func testCloudTagRejectedBeforeNetwork() async throws {
        MockProtocol.handler = { _ in fail("Cloud tag must not make a request"); return (500, "") }
        do { try await client().verifyLocal(model: "qwen3.5:cloud"); fail() } catch { }
    }
    func testRemoteAliasRejected() async throws {
        MockProtocol.handler = { _ in (200, #"{"details":{"parameter_size":"4B"},"remote_host":"https://ollama.com","remote_model":"remote"}"#) }
        do { try await client().verifyLocal(model: "innocent-name"); fail() } catch { }
    }
    func testErrorsNeverEchoServerContent() async throws {
        MockProtocol.handler = { _ in (500, "secret token and personal data") }
        do { _ = try await client().models(); fail() } catch { expectFalse(error.localizedDescription.contains("secret")) }
    }
    func testMalformedAndIncompleteResponsesFail() async throws {
        MockProtocol.handler = { _ in (200, #"{"message":{"role":"assistant","content":"done"},"done":false}"#) }
        do { _ = try await client().chat(model: "local", messages: [], capabilities: []); fail() } catch { }
        MockProtocol.handler = { _ in (200, "not JSON") }
        do { _ = try await client().chat(model: "local", messages: [], capabilities: []); fail() } catch { }
    }
    func testSpokenHintReachesSystemPromptOnlyWhenSpeaking() async throws {
        final class Seen: @unchecked Sendable { var systems: [String] = [] }
        let seen = Seen()
        MockProtocol.handler = { request in
            if request.url!.path == "/api/show" { return (200, #"{"details":{"parameter_size":"4B"}}"#) }
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? request.httpBodyStream.map { stream -> Data in
                stream.open(); defer { stream.close() }
                var data = Data(); var buffer = [UInt8](repeating: 0, count: 65536)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
                return data
            } ?? Data()) as! [String: Any]
            let messages = body["messages"] as! [[String: Any]]
            seen.systems.append(messages.first { $0["role"] as? String == "system" }?["content"] as? String ?? "")
            return (200, #"{"done":true,"message":{"role":"assistant","content":"ok"}}"#)
        }
        let registry = try CapabilityRegistry(capabilities: [])
        _ = try await AssistantEngine(client: client()).respond(text: "hi", history: [], memories: [], model: "local", registry: registry)
        _ = try await AssistantEngine(client: client()).respond(text: "hi", history: [], memories: [], model: "local", registry: registry, spoken: true)
        expectEqual(seen.systems.count, 2)
        expectFalse(seen.systems[0].contains("read aloud"))
        expectTrue(seen.systems[1].contains("read aloud"))
    }
    func testUnsupportedModelToolCannotExecute() async throws {
        MockProtocol.handler = { request in
            if request.url!.path == "/api/show" { return (200, #"{"details":{"parameter_size":"4B"}}"#) }
            return (200, #"{"done":true,"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"shell","arguments":{"command":"whoami"}}}]}}"#)
        }
        let reply = try await AssistantEngine(client: client()).respond(text: "hello", history: [], memories: [], model: "local", registry: try CapabilityRegistry(capabilities: []))
        expectEqual(reply.receipts.count, 1)
        expectEqual(reply.receipts.first?.status, .blocked)
    }
}
