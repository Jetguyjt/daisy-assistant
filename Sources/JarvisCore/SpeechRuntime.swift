import Foundation

/// Owned whisper-server child so the Whisper model loads once instead of once per utterance.
/// Same shape as LocalRuntime: preflight, coalesced startup, shutdown only of what we started.
/// Transcription falls back to the one-shot whisper-cli path when the server is unavailable.
public actor SpeechRuntime {
    public static let endpoint = URL(string: "http://127.0.0.1:11437")!
    private var process: Process?
    private var startup: Task<Void, Error>?
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }
    /// Homebrew installs whisper-server beside whisper-cli.
    public static func serverExecutable(near cli: String) -> URL {
        URL(fileURLWithPath: cli).deletingLastPathComponent().appendingPathComponent("whisper-server")
    }
    public func isReachable() async -> Bool {
        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 1
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }
    public func ensureRunning(configuration: Configuration) async throws {
        try Task.checkCancellation()
        if await isReachable() { return }
        if let startup { try await startup.value; return }
        let server = Self.serverExecutable(near: configuration.whisperExecutable)
        guard FileManager.default.isExecutableFile(atPath: server.path) else {
            throw JarvisError.message("whisper-server is not installed next to whisper-cli.")
        }
        guard FileManager.default.fileExists(atPath: configuration.whisperModel) else {
            throw JarvisError.message("The Whisper model is missing. Run scripts/download-models.sh.")
        }
        if process?.isRunning != true {
            let child = Process()
            child.executableURL = server
            child.arguments = ["-m", configuration.whisperModel, "--host", "127.0.0.1", "--port", "11437", "-t", "4", "-l", "en"]
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run()
            process = child
        }
        let task = Task {
            for _ in 0..<80 {
                try Task.checkCancellation()
                if await self.isReachable() { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw JarvisError.message("whisper-server did not become ready.")
        }
        startup = task
        defer { startup = nil }
        try await task.value
    }
    /// One multipart POST; the server answers `{"text": "..."}`.
    public func transcribe(audio: URL) async throws -> String {
        try Task.checkCancellation()
        let boundary = "jarvis-\(UUID().uuidString)"
        var request = URLRequest(url: Self.endpoint.appendingPathComponent("inference"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("response_format", "json")
        field("temperature", "0.0")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"input.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(try Data(contentsOf: audio))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else {
            throw JarvisError.message("whisper-server returned an invalid response.")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Server first, one-shot CLI second. Both yield the same plain text.
    public func transcribe(audio: URL, configuration: Configuration) async throws -> String {
        let text: String
        do {
            try await ensureRunning(configuration: configuration)
            text = try await transcribe(audio: audio)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            text = try await SpeechDecoder.transcribe(audio: audio, executable: URL(fileURLWithPath: configuration.whisperExecutable),
                                                     model: URL(fileURLWithPath: configuration.whisperModel))
        }
        guard !text.isEmpty, !text.contains("[BLANK_AUDIO]") else {
            throw JarvisError.message("No speech was detected. Say a few words, then pause. Check the input meter and microphone in Settings if it stays quiet.")
        }
        return text
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
