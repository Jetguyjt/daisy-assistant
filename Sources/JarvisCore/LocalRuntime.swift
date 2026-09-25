import Foundation

/// Owned by the desktop app, not a terminal/dev session. Preflight before every request;
/// coalesce concurrent startup attempts and restart only before executing user work.
public actor LocalRuntime {
    private let client: OllamaClient
    private var process: Process?
    private var startup: Task<Void, Error>?
    public init(client: OllamaClient = OllamaClient()) { self.client = client }
    public func ensureRunning(configuration: Configuration) async throws {
        try Task.checkCancellation()
        if await client.isReachable() { return }
        try Task.checkCancellation()
        if let startup { try await startup.value; return }
        guard FileManager.default.isExecutableFile(atPath: configuration.ollamaExecutable) else {
            throw JarvisError.message("Ollama is missing at the configured path. Run scripts/setup.sh or fix Settings.")
        }
        guard !configuration.ollamaModels.isEmpty,
              FileManager.default.fileExists(atPath: configuration.ollamaModels) else {
            throw JarvisError.message("The local model folder is missing. Check Settings or run scripts/download-models.sh.")
        }
        if process?.isRunning != true {
            let child = Process(); child.executableURL = URL(fileURLWithPath: configuration.ollamaExecutable)
            child.arguments = ["serve"]
            var env = ProcessInfo.processInfo.environment
            env["OLLAMA_HOST"] = "127.0.0.1:11435"; env["OLLAMA_NO_CLOUD"] = "1"
            env["OLLAMA_MODELS"] = configuration.ollamaModels
            env["OLLAMA_NUM_PARALLEL"] = "1"; env["OLLAMA_CONTEXT_LENGTH"] = "16384"
            env["OLLAMA_DEBUG_LOG_REQUESTS"] = "false"
            child.environment = env; child.standardInput = FileHandle.nullDevice
            child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            try child.run(); process = child
        }
        let client = self.client
        let task = Task {
            for _ in 0..<50 {
                try Task.checkCancellation()
                if await client.isReachable() { return }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            throw JarvisError.message("The local engine did not become ready. Check the Ollama executable and model paths in Settings.")
        }
        startup = task
        defer { startup = nil }
        try await task.value
        try Task.checkCancellation()
    }
    public func shutdown() async {
        startup?.cancel(); startup = nil
        if let child = process, child.isRunning {
            child.terminate()
            for _ in 0..<20 {
                if !child.isRunning { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        process = nil
    }
}
