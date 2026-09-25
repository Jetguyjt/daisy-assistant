import Foundation

public struct LocalVoice: Identifiable, Sendable {
    public let id: String
    public let name: String
}

public enum NaturalSpeech {
    public static let voices: [LocalVoice] = [
        .init(id: "bm_george", name: "George · British"),
        .init(id: "bm_fable", name: "Fable · British"),
        .init(id: "am_michael", name: "Michael · American"),
        .init(id: "af_heart", name: "Heart · American"),
        .init(id: "bf_emma", name: "Emma · British")
    ]
    public static var runtime: URL { Configuration.dataDirectory.appendingPathComponent("Runtime/voice") }
    public static var python: URL { runtime.appendingPathComponent("venv/bin/python") }
    public static var script: URL { runtime.appendingPathComponent("synthesize.py") }
    public static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: python.path)
            && [script, runtime.appendingPathComponent("kokoro-v1.0.onnx"), runtime.appendingPathComponent("voices-v1.0.bin")]
                .allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }
    static func validate(voice: String, speed: Double) throws {
        guard voices.contains(where: { $0.id == voice }), (0.75...1.3).contains(speed) else {
            throw JarvisError.message("Choose a supported local voice and speaking speed in Settings.")
        }
        guard isInstalled else {
            throw JarvisError.message("The natural voice is not installed. Run scripts/setup-voice.sh. Your answer is still available as text.")
        }
    }
    /// One-shot synthesis: a fresh Python process per call, the model loaded each time.
    public static func synthesize(text: String, voice: String, speed: Double, input: URL, output: URL) async throws {
        try validate(voice: voice, speed: speed)
        try Task.checkCancellation()
        try String(text.prefix(2200)).write(to: input, atomically: true, encoding: .utf8)
        try await LocalProcess.run(executable: python, arguments: [script.path, "--input", input.path, "--output", output.path,
            "--voice", voice, "--speed", String(speed)], timeout: 90)
        try Task.checkCancellation()
    }
    /// Warm worker first, one-shot process if the worker is unavailable.
    public static func synthesize(text: String, voice: String, speed: Double, output: URL, worker: SpeechWorker?) async throws {
        if let worker {
            do { _ = try await worker.synthesize(text: text, voice: voice, speed: speed, output: output); return }
            catch is CancellationError { throw CancellationError() }
            catch { }
        }
        let input = output.deletingPathExtension().appendingPathExtension("txt")
        try await synthesize(text: text, voice: voice, speed: speed, input: input, output: output)
    }
}

/// A long-lived Kokoro process speaking one JSON line per request over stdin and stdout, so the
/// model loads once per app session instead of once per sentence. Requests are serialized.
public actor SpeechWorker {
    private let python: URL
    private let script: URL
    private var process: Process?
    private var input: FileHandle?
    private var reader: Task<Void, Never>?
    private var buffer = Data()
    private var pending: CheckedContinuation<[String: Any], Error>?
    private var deadline: Task<Void, Never>?
    private var connectionID = UUID()

    public init(python: URL = NaturalSpeech.python, script: URL = NaturalSpeech.script) {
        self.python = python; self.script = script
    }
    public var isRunning: Bool { process?.isRunning == true }

    /// Starts the process so the model is loading before the first sentence is needed.
    public func warmUp() {
        guard !isRunning else { return }
        try? start()
    }
    private func start() throws {
        guard FileManager.default.isExecutableFile(atPath: python.path), FileManager.default.fileExists(atPath: script.path) else {
            throw JarvisError.message("The natural voice is not installed.")
        }
        let child = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe()
        child.executableURL = python
        child.arguments = [script.path, "--serve"]
        child.standardInput = stdinPipe; child.standardOutput = stdoutPipe; child.standardError = FileHandle.nullDevice
        child.currentDirectoryURL = script.deletingLastPathComponent()
        try child.run()
        process = child; input = stdinPipe.fileHandleForWriting; buffer = Data()
        connectionID = UUID(); let token = connectionID
        let output = stdoutPipe.fileHandleForReading
        reader = Task.detached { [weak self] in
            while !Task.isCancelled {
                let data = output.availableData
                if data.isEmpty { break }
                await self?.receive(data, token: token)
            }
            await self?.closed(token: token)
        }
    }
    public func synthesize(text: String, voice: String, speed: Double, output: URL) async throws -> TimeInterval {
        try Task.checkCancellation()
        if !isRunning { try start() }
        guard pending == nil else { throw JarvisError.message("The voice worker is busy.") }
        let request: [String: Any] = ["text": String(text.prefix(2200)), "voice": voice, "speed": speed, "output": output.path]
        var line = try JSONSerialization.data(withJSONObject: request)
        line.append(10)
        let reply: [String: Any] = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                deadline = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 90_000_000_000) } catch { return }
                    await self?.fail(JarvisError.message("The voice worker timed out."))
                }
                do { try input?.write(contentsOf: line) } catch { fail(error) }
            }
        }, onCancel: { Task { await self.fail(CancellationError()) } })
        if let error = reply["error"] as? String { throw JarvisError.message("The voice worker failed: \(error)") }
        return reply["seconds"] as? Double ?? 0
    }
    private func receive(_ data: Data, token: UUID) {
        guard token == connectionID else { return }
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer[..<end]; buffer.removeSubrange(...end)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            deadline?.cancel(); deadline = nil
            pending?.resume(returning: object); pending = nil
        }
    }
    private func fail(_ error: Error) {
        deadline?.cancel(); deadline = nil
        pending?.resume(throwing: error); pending = nil
        // A cancelled or timed-out request leaves the worker mid-sentence; restart it next time.
        Task { await stop() }
    }
    private func closed(token: UUID) {
        guard token == connectionID else { return }
        deadline?.cancel(); deadline = nil
        pending?.resume(throwing: JarvisError.message("The voice worker stopped.")); pending = nil
        process = nil; input = nil
    }
    public func stop() async {
        connectionID = UUID()
        deadline?.cancel(); deadline = nil
        pending?.resume(throwing: JarvisError.message("The voice worker stopped.")); pending = nil
        try? input?.close(); input = nil
        reader?.cancel(); reader = nil
        if let child = process, child.isRunning {
            child.terminate()
            for _ in 0..<20 {
                if !child.isRunning { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        process = nil; buffer = Data()
    }
}
