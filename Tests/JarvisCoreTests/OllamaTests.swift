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
