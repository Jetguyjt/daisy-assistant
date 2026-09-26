import Foundation
import JarvisCore

/// The original on-device engine (Ollama plus the Swift tool loop), kept as an optional fallback
/// behind the same interface as Hermes. Only used when chosen in Setup.
final class LocalBackend: AgentBackend, @unchecked Sendable {
    /// Everything a local turn needs from the app, gathered on the main actor.
    struct Context: Sendable {
        let configuration: Configuration
        let registry: CapabilityRegistry
        let history: [ChatMessage]
        let memories: [Memory]
        let store: MemoryStore?
    }
    let name = "Local"
    private let runtime = LocalRuntime()
    private let client = OllamaClient()
    private let context: @Sendable (String) async throws -> Context

    init(context: @escaping @Sendable (String) async throws -> Context) { self.context = context }

    func connect() async -> AgentLink {
        do {
            let current = try await context("")
            try await runtime.ensureRunning(configuration: current.configuration)
            try await client.verifyLocal(model: current.configuration.model)
            return .ready(detail: current.configuration.model)
        } catch is CancellationError {
            return .starting
        } catch {
            return .offline(error.localizedDescription)
        }
    }

    /// Attachments aren't supported here; the composer hides them for this backend.
    func send(_ prompt: AgentPrompt) -> AsyncThrowingStream<AgentEvent, Error> {
        let text = prompt.text
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let current = try await self.context(text)
                    if let command = try MemoryCommand.parse(text) {
                        guard let store = current.store else { throw JarvisError.message("Memory storage is unavailable. Restart after fixing the setup error.") }
                        let memory = try await store.put(key: command.key, value: command.value, source: "Explicit user request: \(text)")
                        continuation.yield(.text("Remembered: \(memory.value)"))
                        continuation.yield(.finished(stopReason: "end_turn"))
                        continuation.finish()
                        return
                    }
                    // Always preflight, even if the badge was green. Never replay an action after dispatch.
                    try await self.runtime.ensureRunning(configuration: current.configuration)
                    try await self.client.verifyLocal(model: current.configuration.model)
                    let result = try await AssistantEngine(client: self.client).respond(
                        text: text, history: current.history, memories: current.memories, model: current.configuration.model,
                        registry: current.registry, spoken: current.configuration.speakResponses,
                        onProgress: { step in continuation.yield(.tool(AgentToolActivity(id: UUID().uuidString, title: step, state: .running))) })
                    continuation.yield(.receipts(result.receipts))
                    continuation.yield(.text(result.text))
                    continuation.yield(.finished(stopReason: "end_turn"))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Cancelling the event stream cancels the turn.
    func cancel() async { }
    /// Local changes use review cards in the transcript instead of approval requests.
    func resolve(approval id: String, optionID: String?) async { }
    func newSession() async { }
    func history() async -> [AgentMessage] { [] }
    func sessions() async -> [AgentSession] { [] }
    func open(session id: String) async -> [AgentMessage]? { nil }
    func shutdown() async { await runtime.shutdown() }
    func models() async -> [String] { (try? await client.models()) ?? [] }
}
