import Foundation

/// A Kokoro voice, or a blend of several written as "af_heart:0.7,af_bella:0.3".
public struct LocalVoice: Identifiable, Sendable, Equatable {
    public enum Accent: String, Sendable { case american = "American", british = "British" }
    public let id: String
    public let name: String
    public let accent: Accent
    public let female: Bool
    public var isBlend: Bool { id.contains(",") }
}

/// One voice in a voice setting and its share, from 0 to 1.
public struct VoicePart: Equatable, Sendable {
    public let voice: String
    public let weight: Double
}

public enum NaturalSpeech {
    /// Kokoro's only A-graded voice.
    public static let defaultVoice = "af_heart"
    /// 70% Heart and 30% Bella (A-).
    public static let heartBellaBlend = "af_heart:0.7,af_bella:0.3"
    public static let speeds: ClosedRange<Double> = 0.75...1.3
    /// The blend, then every English voice in voices-v1.0.bin: American, then British.
    public static let voices: [LocalVoice] = [LocalVoice(id: heartBellaBlend, name: "Heart + Bella blend", accent: .american, female: true)]
        + [("af_", "Alloy Aoede Bella Heart Jessica Kore Nicole Nova River Sarah Sky"),
           ("am_", "Adam Echo Eric Fenrir Liam Michael Onyx Puck Santa"),
           ("bf_", "Alice Emma Isabella Lily"),
           ("bm_", "Daniel Fable George Lewis")].flatMap { prefix, names in
            names.split(separator: " ").map { name in
                let accent: LocalVoice.Accent = prefix.hasPrefix("a") ? .american : .british
                return LocalVoice(id: prefix + name.lowercased(), name: "\(name) · \(accent.rawValue)", accent: accent, female: prefix.hasSuffix("f_"))
            }
        }

    /// Reads a voice setting: one voice id, or a comma-separated blend with optional weights
    /// ("af_heart:0.7,af_bella:0.3"; no weight counts as 1). Weights come back scaled to add up
    /// to 1. synthesize.py reads the same format and checks the names against the voices file.
    public static func blend(_ setting: String) throws -> [VoicePart] {
        var parts: [VoicePart] = []
        for item in setting.split(separator: ",", omittingEmptySubsequences: false) {
            let pieces = item.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let name = pieces[0].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw DaisyError.message("The voice setting \"\(setting)\" has an empty entry.") }
            guard voices.contains(where: { $0.id == name && !$0.isBlend }) else { throw DaisyError.message("\"\(name)\" is not a Kokoro voice Daisy knows.") }
            guard !parts.contains(where: { $0.voice == name }) else { throw DaisyError.message("\"\(name)\" is listed twice in the voice setting.") }
            var weight = 1.0
            if pieces.count > 1 {
                guard let value = Double(pieces[1].trimmingCharacters(in: .whitespaces)), value.isFinite, value > 0 else {
                    throw DaisyError.message("The weight for \(name) must be a number above zero.")
                }
                weight = value
            }
            parts.append(VoicePart(voice: name, weight: weight))
        }
        let total = parts.reduce(0) { $0 + $1.weight }
        return parts.map { VoicePart(voice: $0.voice, weight: $0.weight / total) }
    }

    /// "Heart" for af_heart, "Heart + Bella" for a blend of the two, the setting itself otherwise.
    public static func shortName(for setting: String) -> String {
        guard let parts = try? blend(setting) else { return setting }
        return parts.map { part in
            voices.first { $0.id == part.voice }?.name.components(separatedBy: " ").first ?? part.voice
        }.joined(separator: " + ")
    }

    public static var runtime: URL { Configuration.dataDirectory.appendingPathComponent("Runtime/voice") }
    public static var python: URL { runtime.appendingPathComponent("venv/bin/python") }
    public static var script: URL { runtime.appendingPathComponent("synthesize.py") }
    public static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: python.path)
            && [script, runtime.appendingPathComponent("kokoro-v1.0.onnx"), runtime.appendingPathComponent("voices-v1.0.bin")]
                .allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }
    static func check(voice: String, speed: Double) throws {
        guard speeds.contains(speed) else { throw DaisyError.message("Choose a speaking speed between 0.75 and 1.3 in Settings.") }
        do { _ = try blend(voice) } catch {
            throw DaisyError.message("Choose a supported local voice in Settings. \(error.localizedDescription)")
        }
    }
    static func validate(voice: String, speed: Double) throws {
        try check(voice: voice, speed: speed)
        guard isInstalled else {
            throw DaisyError.message("The natural voice is not installed. Run scripts/setup-voice.sh. Your answer is still available as text.")
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
        try check(voice: voice, speed: speed)
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
    private let arguments: [String]
    private var process: Process?
    private var input: FileHandle?
    private var reader: Task<Void, Never>?
    private var buffer = Data()
    private var pending: CheckedContinuation<[String: Any], Error>?
    private var deadline: Task<Void, Never>?
    private var connectionID = UUID()

    /// `arguments` go after `--serve`, e.g. `--models <folder>` for a synthesize.py that isn't the installed one.
    public init(python: URL = NaturalSpeech.python, script: URL = NaturalSpeech.script, arguments: [String] = []) {
        self.python = python; self.script = script; self.arguments = arguments
    }
    public var isRunning: Bool { process?.isRunning == true }

    /// Starts the process so the model is loading before the first sentence is needed.
    public func warmUp() {
        guard !isRunning else { return }
        try? start()
    }
    private func start() throws {
        guard FileManager.default.isExecutableFile(atPath: python.path), FileManager.default.fileExists(atPath: script.path) else {
            throw DaisyError.message("The natural voice is not installed.")
        }
        let child = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe()
        child.executableURL = python
        child.arguments = [script.path, "--serve"] + arguments
        child.standardInput = stdinPipe; child.standardOutput = stdoutPipe; child.standardError = FileHandle.nullDevice
        child.currentDirectoryURL = script.deletingLastPathComponent()
        // A worker that dies must not take Daisy with it: writing to its closed pipe would raise SIGPIPE.
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try ChildProcesses.shared.launch(child, label: "voice worker")
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
        guard pending == nil else { throw DaisyError.message("The voice worker is busy.") }
        let request: [String: Any] = ["text": String(text.prefix(2200)), "voice": voice, "speed": speed, "output": output.path]
        var line = try JSONSerialization.data(withJSONObject: request)
        line.append(10)
        let reply: [String: Any] = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                deadline = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 90_000_000_000) } catch { return }
                    await self?.fail(DaisyError.message("The voice worker timed out."))
                }
                do { try input?.write(contentsOf: line) } catch { fail(error) }
            }
        }, onCancel: { Task { await self.fail(CancellationError()) } })
        if let error = reply["error"] as? String { throw DaisyError.message("The voice worker failed: \(error)") }
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
        pending?.resume(throwing: DaisyError.message("The voice worker stopped.")); pending = nil
        process = nil; input = nil
    }
    public func stop() async {
        connectionID = UUID()
        deadline?.cancel(); deadline = nil
        pending?.resume(throwing: DaisyError.message("The voice worker stopped.")); pending = nil
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
