import AppKit
import AVFoundation
import JarvisCore

/// Microphone capture and speech playback on one AVAudioEngine. Voice processing (Apple's echo
/// cancellation) is enabled on the input so the mic can hear the user while Jarvis speaks. That
/// only cancels audio played through the same engine, so speech goes through a player node while
/// the engine runs and falls back to AVAudioPlayer when it does not.
@MainActor final class AudioController: ObservableObject {
    struct Chunk: Sendable { let samples: [Int16]; let power: Float; let duration: TimeInterval }
    @Published var level: Double = 0
    @Published var elapsed: TimeInterval = 0
    @Published private(set) var engineRunning = false
    /// True when Apple voice processing accepted the input device; barge-in relies on it.
    private(set) var echoCancellation = false
    /// Power in dBFS and duration of each 16 kHz chunk, delivered on the main actor.
    var onChunk: ((Float, TimeInterval) -> Void)?
    /// The engine stopped because a device changed; the owner decides whether to restart.
    var onEngineLost: (() -> Void)?
    /// Warm Kokoro process; nil means one process per sentence.
    var speechWorker: SpeechWorker?

    static let sampleRate = 16000.0
    private static let preRollSeconds: TimeInterval = 1.5
    private var session: MicrophoneSession?
    private let bridge = TapBridge()
    private var preRoll: [Chunk] = []
    private var capture: [Int16]?
    private var gate: PlaybackGate?
    private var fallback: AVAudioPlayer?
    private var configurationObserver: NSObjectProtocol?

    init() {
        bridge.deliver = { [weak self] chunk in Task { @MainActor in self?.ingest(chunk) } }
        bridge.levelSink = { [weak self] power in Task { @MainActor in self?.level = Self.meter(power) } }
    }
    var microphoneStatus: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "Microphone permission granted"
        case .denied, .restricted: return "Microphone permission blocked in System Settings"
        case .notDetermined: return "Microphone permission will be requested on first use"
        @unknown default: return "Microphone permission unknown"
        }
    }
    var inputDeviceName: String { AVCaptureDevice.default(for: .audio)?.localizedName ?? "No default audio input device detected" }
    var capturing: Bool { capture != nil }
    static func meter(_ power: Float) -> Double { min(1, Double(pow(10, power / 30))) }

    func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    // MARK: Engine

    func startEngine() throws {
        if let session, session.engine.isRunning { return }
        session?.stop(); session = nil
        bridge.reset()
        let bridge = self.bridge
        let started = try MicrophoneEngine.start(preferVoiceProcessing: true) { buffer in bridge.handle(buffer) }
        session = started
        echoCancellation = started.voiceProcessing
        engineRunning = true
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: started.engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.engineConfigurationChanged() }
        }
    }
    private func engineConfigurationChanged() {
        guard engineRunning else { return }
        stopEngine()
        onEngineLost?()
    }
    func stopEngine() {
        stopPlayback()
        capture = nil; preRoll = []
        session?.stop(); session = nil
        engineRunning = false; level = 0; elapsed = 0
    }

    // MARK: Capture

    private func ingest(_ chunk: Chunk) {
        preRoll.append(chunk)
        var total = preRoll.reduce(0) { $0 + $1.duration }
        while total > Self.preRollSeconds, !preRoll.isEmpty { total -= preRoll.removeFirst().duration }
        if capture != nil {
            capture?.append(contentsOf: chunk.samples)
            elapsed = Double(capture?.count ?? 0) / Self.sampleRate
            level = Self.meter(chunk.power)
        }
        onChunk?(chunk.power, chunk.duration)
    }
    /// Starts an utterance, seeded with up to `seconds` of audio already heard (the wake phrase
    /// and whatever followed it). Returns those chunks' readings so the caller can feed its endpointer.
    @discardableResult
    func beginCapture(preRoll seconds: TimeInterval) -> [(power: Float, duration: TimeInterval)] {
        var kept: [Chunk] = []
        var total = 0.0
        for chunk in preRoll.reversed() {
            if total >= seconds { break }
            kept.insert(chunk, at: 0); total += chunk.duration
        }
        capture = kept.flatMap(\.samples)
        elapsed = Double(capture?.count ?? 0) / Self.sampleRate
        return kept.map { ($0.power, $0.duration) }
    }
    /// Writes the utterance for whisper. The caller owns the returned folder.
    func endCapture() throws -> URL {
        guard let samples = capture else { throw JarvisError.message("No recording is active.") }
        capture = nil; elapsed = 0; level = 0
        guard Double(samples.count) / Self.sampleRate >= 0.35 else {
            throw JarvisError.message("Recording was too short. Say a few words, then pause.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent("input.wav")
        try WAVFile.write(samples: samples, sampleRate: Int(Self.sampleRate), to: url)
        return url
    }
    func discardCapture() { capture = nil; elapsed = 0; level = 0 }

    // MARK: Playback

    /// Speaks sentence by sentence: the next sentence is synthesized while the current one plays.
    func speak(_ text: String, voice: String, speed: Double = 1, onReady: (() -> Void)? = nil) async throws {
        let chunks = SpeechText.sentences(from: text)
        guard !chunks.isEmpty else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let worker = speechWorker
        let files = AsyncThrowingStream<URL, Error> { continuation in
            let producer = Task {
                do {
                    for (index, chunk) in chunks.enumerated() {
                        try Task.checkCancellation()
                        let url = folder.appendingPathComponent("\(index).wav")
                        try await NaturalSpeech.synthesize(text: chunk, voice: voice, speed: speed, output: url, worker: worker)
                        continuation.yield(url)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
        if let session, session.engine.isRunning { try await playThroughEngine(files, session: session, onReady: onReady) }
        else { try await playWithFallback(files, onReady: onReady) }
    }
    private func playThroughEngine(_ files: AsyncThrowingStream<URL, Error>, session: MicrophoneSession, onReady: (() -> Void)?) async throws {
        let engine = session.engine
        let player = session.player
        let bridge = self.bridge
        player.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in bridge.meter(buffer) }
        defer { player.removeTap(onBus: 0); player.stop(); gate = nil; level = 0 }
        var connected = false
        var last: PlaybackGate?
        for try await url in files {
            try Task.checkCancellation()
            let file = try AVAudioFile(forReading: url)
            if !connected {
                engine.disconnectNodeOutput(player)
                engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
                connected = true
            }
            let gate = PlaybackGate()
            self.gate = gate
            player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { _ in gate.finish() }
            if !player.isPlaying { player.play(); onReady?() }
            last = gate
        }
        guard let last else { return }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                last.arm(continuation)
                if Task.isCancelled { last.cancel() }
            }
        }, onCancel: { player.stop(); last.cancel() })
        try Task.checkCancellation()
    }
    private func playWithFallback(_ files: AsyncThrowingStream<URL, Error>, onReady: (() -> Void)?) async throws {
        var first = true
        for try await url in files {
            let playback = try AVAudioPlayer(contentsOf: url)
            playback.isMeteringEnabled = true; fallback = playback
            guard playback.play() else { throw JarvisError.message("Audio playback could not start.") }
            if first { onReady?(); first = false }
            defer { playback.stop(); if fallback === playback { fallback = nil; level = 0 } }
            while playback.isPlaying {
                try Task.checkCancellation()
                playback.updateMeters()
                level = Self.meter(playback.averagePower(forChannel: 0))
                try await Task.sleep(nanoseconds: 40_000_000)
            }
        }
    }
    func stopPlayback() {
        gate?.cancel(); gate = nil
        if let session, session.engine.isRunning { session.player.stop() }
        fallback?.stop(); fallback = nil
        level = 0
    }
    /// Stops playback and drops any capture in progress. The engine itself stays as it was.
    func stop() {
        stopPlayback()
        discardCapture()
    }
}

/// Resolves a playback continuation exactly once, whichever side finishes first, even when the
/// file finished before anyone started waiting for it.
private final class PlaybackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var outcome: Error?? = nil
    func arm(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let outcome {
            lock.unlock()
            if let error = outcome { continuation.resume(throwing: error) } else { continuation.resume() }
            return
        }
        self.continuation = continuation
        lock.unlock()
    }
    func finish() { settle(nil) }
    func cancel() { settle(CancellationError()) }
    private func settle(_ error: Error?) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = .some(error)
        let waiting = continuation; continuation = nil
        lock.unlock()
        if let error { waiting?.resume(throwing: error) } else { waiting?.resume() }
    }
}

/// Runs on the audio thread: hands each input buffer to a downsampler matched to its format and
/// passes the 16 kHz chunk to the main actor.
private final class TapBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var downsampler: MicDownsampler?
    private var format: AVAudioFormat?
    var deliver: (@Sendable (AudioController.Chunk) -> Void)?
    var levelSink: (@Sendable (Float) -> Void)?
    func reset() { lock.lock(); downsampler = nil; format = nil; lock.unlock() }
    func handle(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if format != buffer.format { downsampler = MicDownsampler(inputFormat: buffer.format); format = buffer.format }
        let downsampler = self.downsampler
        lock.unlock()
        guard let deliver, let converted = downsampler?.convert(buffer) else { return }
        deliver(AudioController.Chunk(samples: converted.samples, power: converted.power,
                                      duration: Double(converted.samples.count) / MicDownsampler.sampleRate))
    }
    func meter(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += channel[i] * channel[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        levelSink?(20 * log10(max(rms, 1e-7)))
    }
}
