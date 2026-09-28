import Foundation

/// How Daisy hears. Meant to live in `Configuration.speechInput` (see NEEDS.md). Every field is
/// optional so older settings files decode; nil means the default.
public struct SpeechInputSettings: Codable, Sendable, Equatable {
    /// Apple's on-device recognizer (macOS 26) first, Whisper as the fallback. False: Whisper only.
    public var appleSpeech: Bool?
    /// Language for Apple's recognizer, as a BCP 47 tag. Whisper stays English.
    public var locale: String?
    /// Silero voice activity detection when its model is installed. False: the energy endpointer only.
    public var voiceActivity: Bool?
    /// The trained "hey daisy" model as the first stage when Runtime/speech/hey_daisy.onnx exists.
    public var wakeWordModel: Bool?
    /// How sure the wake word model has to be, 0 to 1.
    public var wakeWordThreshold: Double?
    public init() {}

    public var usesAppleSpeech: Bool { appleSpeech ?? true }
    public var localeIdentifier: String { locale ?? "en-US" }
    public var usesVoiceActivity: Bool { voiceActivity ?? true }
    public var usesWakeWordModel: Bool { wakeWordModel ?? true }
    public var wakeThreshold: Float { Float(min(max(wakeWordThreshold ?? 0.5, 0.05), 0.99)) }
}

public enum SpeechRecognizerKind: String, Sendable, Equatable { case apple, whisper }

/// Where Apple's recognizer stands on this Mac.
public enum AppleSpeechState: Equatable, Sendable {
    case unknown
    case ready
    /// Apple is installing its model for Daisy. The fraction is nil until Apple reports one.
    case downloading(Double?)
    /// The language is supported but its model isn't set up for Daisy yet.
    case needsDownload
    /// Why Apple's recognizer isn't used: an older macOS, the language, a setting, an error.
    case unavailable(String)
}

/// What the Settings screen shows about speech in.
public struct SpeechRecognitionStatus: Equatable, Sendable {
    public var active: SpeechRecognizerKind
    public var apple: AppleSpeechState
    public init(active: SpeechRecognizerKind, apple: AppleSpeechState) { self.active = active; self.apple = apple }
    public var summary: String {
        switch apple {
        case .ready: return "Apple on-device speech recognition, with Whisper as the fallback."
        case .unknown: return "Whisper for now; checking Apple's on-device recognizer."
        case .downloading(let fraction):
            let percent = fraction.map { " (\(Int(($0 * 100).rounded()))%)" } ?? ""
            return "Whisper for now; Apple's speech model is installing\(percent)."
        case .needsDownload: return "Whisper for now; Apple's speech model installs from Apple the first time it's needed."
        case .unavailable(let reason): return "Whisper. Apple's recognizer isn't in use: \(reason)"
        }
    }
}

/// One utterance streamed to a recognizer as 16 kHz mono samples.
public protocol SpeechStream: AnyObject, Sendable {
    /// Samples in order. Never blocks.
    func append(_ samples: [Int16])
    /// Ends the audio and returns the final transcript (empty when nothing was said).
    func finish() async throws -> String
    /// Drops the utterance.
    func cancel() async
}

/// A recognizer that runs in this process (Apple's). Whisper is reached through SpeechRuntime.
protocol OnDeviceRecognizer: Sendable {
    func transcribe(file: URL) async throws -> String
    func stream(onUpdate: @escaping @Sendable (String) -> Void) async throws -> any SpeechStream
    /// Loads the model so the first utterance doesn't wait for it.
    func warmUp() async
}

/// Whisper can't stream, so this keeps the audio and transcribes all of it at the end.
public final class RecordedSpeechStream: SpeechStream, @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Int16] = []
    private let transcribe: @Sendable (URL) async throws -> String

    public init(transcribe: @escaping @Sendable (URL) async throws -> String) { self.transcribe = transcribe }
    public var recorded: [Int16] { lock.withLock { samples } }

    public func append(_ more: [Int16]) { lock.withLock { samples.append(contentsOf: more) } }
    public func finish() async throws -> String {
        let audio = recorded
        guard Double(audio.count) / MicDownsampler.sampleRate >= 0.3 else { return "" }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("daisy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("input.wav")
        try WAVFile.write(samples: audio, sampleRate: Int(MicDownsampler.sampleRate), to: url)
        return try await transcribe(url)
    }
    public func cancel() async { lock.withLock { samples = [] } }
}

/// Apple's stream with a recording of the same audio kept for Whisper, used when Apple fails, or
/// comes back empty before it has ever heard anything (the way SFSpeechRecognizer once failed here).
public final class FallbackSpeechStream: SpeechStream, @unchecked Sendable {
    public enum Outcome: Sendable, Equatable { case heard, empty(whisperHeard: Bool), failed(String) }
    private let primary: any SpeechStream
    private let backup: RecordedSpeechStream
    private let retryEmpty: Bool
    private let report: @Sendable (Outcome) async -> Void

    /// `retryEmpty`: an empty result from `primary` goes to Whisper too. `report` hears how the primary did.
    public init(primary: any SpeechStream, backup: RecordedSpeechStream, retryEmpty: Bool, report: @escaping @Sendable (Outcome) async -> Void) {
        self.primary = primary; self.backup = backup; self.retryEmpty = retryEmpty; self.report = report
    }
    public func append(_ samples: [Int16]) {
        backup.append(samples)
        primary.append(samples)
    }
    public func finish() async throws -> String {
        let text: String
        do { text = try await primary.finish() }
        catch is CancellationError { await backup.cancel(); throw CancellationError() }
        catch {
            await report(.failed(error.localizedDescription))
            return try await backup.finish()
        }
        if !text.isEmpty || !retryEmpty {
            if !text.isEmpty { await report(.heard) }
            await backup.cancel()
            return text
        }
        let second = (try? await backup.finish()) ?? ""
        await report(.empty(whisperHeard: !second.isEmpty))
        return second
    }
    public func cancel() async {
        await primary.cancel()
        await backup.cancel()
    }
}

/// Runs `operation`, giving up with an error after `seconds` even if the operation never notices
/// it was cancelled (a task group would wait for it). The abandoned operation is cancelled.
func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ message: String, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let gate = ResumeOnce<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            gate.arm(continuation)
            guard !gate.settled else { return }
            let work = Task {
                do { gate.resume(.success(try await operation())) } catch { gate.resume(.failure(error)) }
            }
            gate.work = work
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                if gate.resume(.failure(DaisyError.message(message))) { work.cancel() }
            }
        }
    } onCancel: {
        if gate.resume(.failure(CancellationError())) { gate.work?.cancel() }
    }
}

private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var early: Result<T, Error>?
    private var done = false
    private var task: Task<Void, Never>?
    var work: Task<Void, Never>? {
        get { lock.withLock { task } }
        set { lock.withLock { task = newValue } }
    }
    var settled: Bool { lock.withLock { done } }
    func arm(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let early { lock.unlock(); continuation.resume(with: early); return }
        self.continuation = continuation
        lock.unlock()
    }
    /// True for the call that settled it.
    @discardableResult func resume(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        guard !done else { lock.unlock(); return false }
        done = true
        guard let waiting = continuation else { early = result; lock.unlock(); return true }
        continuation = nil
        lock.unlock()
        waiting.resume(with: result)
        return true
    }
}

/// Joins recognizer segments with one space where they meet without one.
func joinTranscript(_ head: String, _ tail: String) -> String {
    guard !head.isEmpty else { return tail }
    guard !tail.isEmpty else { return head }
    if head.last?.isWhitespace == true || tail.first?.isWhitespace == true { return head + tail }
    return head + " " + tail
}
