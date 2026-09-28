import Foundation
import DaisyCore

/// A recognizer stream that says scripted partials as audio arrives and a fixed final at the end.
final class ScriptedStream: SpeechStream, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [(after: Int, text: String)]
    private let final: String
    private let failure: Error?
    private let onUpdate: @Sendable (String) -> Void
    private(set) var received: [Int16] = []
    private(set) var finished = false
    private(set) var cancelled = false

    init(partials: [(after: TimeInterval, text: String)] = [], final: String, failure: Error? = nil, onUpdate: @escaping @Sendable (String) -> Void) {
        script = partials.map { (Int($0.after * 16000), $0.text) }
        self.final = final; self.failure = failure; self.onUpdate = onUpdate
    }
    var receivedCount: Int { lock.withLock { received.count } }
    func append(_ samples: [Int16]) {
        var due: [String] = []
        lock.withLock {
            received += samples
            while let next = script.first, received.count >= next.after { due.append(next.text); script.removeFirst() }
        }
        due.forEach(onUpdate)
    }
    func finish() async throws -> String {
        lock.withLock { finished = true }
        if let failure { throw failure }
        return final
    }
    func cancel() async { lock.withLock { cancelled = true } }
}

/// A wake word model that fires when told to.
final class ManualDetector: WakeWordDetector, @unchecked Sendable {
    private let lock = NSLock()
    private var detection: Int?
    private var up = true
    private(set) var fed = 0
    var available: Bool {
        get { lock.withLock { up } }
        set { lock.withLock { up = newValue } }
    }
    func feed(_ samples: [Int16]) { lock.withLock { fed += samples.count } }
    func fire(samplesAgo: Int) { lock.withLock { detection = samplesAgo } }
    func takeDetection() -> Int? { lock.withLock { defer { detection = nil }; return detection } }
    func stop() async { }
}

@MainActor final class ListenerProbe {
    var events: [WakeListener.Event] = []
    var streams: [ScriptedStream] = []
    var planned: [(partials: [(after: TimeInterval, text: String)], final: String)] = []
    lazy var listener = WakeListener { [unowned self] onUpdate in
        let plan = self.planned.isEmpty ? (partials: [], final: "") : self.planned.removeFirst()
        let stream = ScriptedStream(partials: plan.partials, final: plan.final, onUpdate: onUpdate)
        self.streams.append(stream)
        return stream
    }
    init() { listener.onEvent = { [unowned self] event in self.events.append(event) } }

    /// 50 ms chunks of quiet room (-60 dB) or voice (-25 dB), letting the listener's tasks run between them.
    func feed(seconds: TimeInterval, loud: Bool, each: (() -> Void)? = nil) async {
        for _ in 0..<Int((seconds / 0.05).rounded()) {
            listener.feed(AudioChunk(samples: [Int16](repeating: loud ? 1800 : 30, count: 800), power: loud ? -25 : -60, duration: 0.05))
            await Task.yield(); await Task.yield()
            each?()
        }
    }
    func settle() async {
        for _ in 0..<20 { try? await Task.sleep(nanoseconds: 5_000_000) }
    }
}

/// Wake listening, recognizer fallback and Apple's recognizer. The listener tests use scripted
/// streams; the Apple tests run only where Apple's recognizer is ready (macOS 26 with its model).
final class SpeechInTests {
    @MainActor
    func testWakeListenerWakesOnAPartialBeforeTheUtteranceEnds() async {
        let probe = ListenerProbe()
        // The stream gets 1 s of pre-roll first, so partials are timed from the start of that.
        probe.planned = [(partials: [(1.2, "Hey"), (1.6, "Hey, Daisy"), (2.4, "Hey, Daisy, what time")], final: "Hey, Daisy, what time is it?")]
        await probe.feed(seconds: 1, loud: false)
        var wokeAfter: TimeInterval?
        var spoken = 0.0
        await probe.feed(seconds: 2, loud: true) {
            spoken += 0.05
            if wokeAfter == nil, probe.events.contains(.wake(request: "")) { wokeAfter = spoken }
        }
        // Woke about 0.6 s into speech, long before the pause that ends it.
        expectTrue(wokeAfter != nil && wokeAfter! < 1.0)
        expectTrue(probe.listener.awake)
        // After waking, a 1.1 s pause (enough to end a standby utterance) doesn't cut the request.
        await probe.feed(seconds: 1.1, loud: false)
        await probe.feed(seconds: 0.5, loud: true)
        await probe.feed(seconds: 1.5, loud: false)
        await probe.settle()
        expectEqual(probe.events, [.wake(request: ""), .request("what time is it?")])
        expectEqual(probe.streams.count, 1)
        expectTrue(probe.streams.first?.finished == true)
        expectFalse(probe.listener.busy)
    }

    @MainActor
    func testWakeListenerIgnoresSpeechWithoutTheWakePhrase() async {
        let probe = ListenerProbe()
        probe.planned = [(partials: [(1.3, "Turn left")], final: "Turn left at the light."),
                         (partials: [], final: "Okay, see you.")]
        await probe.feed(seconds: 1, loud: false)
        await probe.feed(seconds: 1.5, loud: true)
        await probe.feed(seconds: 1.2, loud: false)
        await probe.feed(seconds: 1, loud: true)
        await probe.feed(seconds: 1.2, loud: false)
        await probe.settle()
        expectEqual(probe.events, [.ignored, .ignored])
        expectEqual(probe.streams.count, 2)
        expectFalse(probe.listener.awake)
    }

    @MainActor
    func testWakeListenerWaitsForTheRequestAfterABareWakePhrase() async {
        let probe = ListenerProbe()
        // Whisper-like: no partials, so the wake comes when the utterance ends.
        probe.planned = [(partials: [], final: "Hey, Daisy."), (partials: [], final: "What's the weather?")]
        await probe.feed(seconds: 1, loud: false)
        await probe.feed(seconds: 0.8, loud: true)
        expectEqual(probe.events, [])
        await probe.feed(seconds: 1.2, loud: false)
        await probe.settle()
        expectEqual(probe.events, [.wake(request: "")])
        expectTrue(probe.listener.awake)
        await probe.feed(seconds: 1.5, loud: false)
        await probe.feed(seconds: 1, loud: true)
        await probe.feed(seconds: 1.5, loud: false)
        await probe.settle()
        expectEqual(probe.events, [.wake(request: ""), .request("What's the weather?")])
        expectEqual(probe.streams.count, 2)
    }

    @MainActor
    func testWakeListenerGivesUpWhenNothingFollowsTheWakePhrase() async {
        let probe = ListenerProbe()
        probe.planned = [(partials: [], final: "Hey Daisy"), (partials: [], final: "never used")]
        await probe.feed(seconds: 1, loud: false)
        await probe.feed(seconds: 0.8, loud: true)
        await probe.feed(seconds: 1.2, loud: false)
        await probe.settle()
        await probe.feed(seconds: 8.5, loud: false)
        await probe.settle()
        expectEqual(probe.events, [.wake(request: ""), .request("")])
        expectTrue(probe.streams.last?.cancelled == true)
        expectFalse(probe.listener.busy)
    }

    @MainActor
    func testWakeListenerWithWhisperWakesWhenTheUtteranceEnds() async {
        let probe = ListenerProbe()
        probe.planned = [(partials: [], final: "Hey Daisy, set a timer for ten minutes.")]
        await probe.feed(seconds: 1, loud: false)
        await probe.feed(seconds: 2, loud: true)
        expectEqual(probe.events, [])
        await probe.feed(seconds: 1.2, loud: false)
        await probe.settle()
        expectEqual(probe.events, [.wake(request: "set a timer for ten minutes."), .request("set a timer for ten minutes.")])
    }

    @MainActor
    func testWakeWordModelStartsTheRecognizerOnlyAfterTheWakeWord() async {
        let probe = ListenerProbe()
        let detector = ManualDetector()
        probe.listener.detector = detector
        probe.planned = [(partials: [], final: "What time is it?")]
        await probe.feed(seconds: 1, loud: false)
        // Someone talking without the wake word: no recognizer at all.
        await probe.feed(seconds: 3, loud: true)
        await probe.feed(seconds: 1.5, loud: false)
        expectEqual(probe.streams.count, 0)
        expectEqual(probe.events, [])
        expectEqual(detector.fed, 110 * 800)
        // The model hears "hey daisy"; the request starts 400 samples (25 ms) back.
        await probe.feed(seconds: 0.5, loud: true)
        detector.fire(samplesAgo: 400)
        await probe.feed(seconds: 0.05, loud: true)
        await probe.settle()
        expectEqual(probe.events, [.wake(request: "")])
        expectEqual(probe.streams.count, 1)
        expectEqual(probe.streams.first?.receivedCount, 400)
        await probe.feed(seconds: 1, loud: true)
        await probe.feed(seconds: 1.5, loud: false)
        await probe.settle()
        expectEqual(probe.events, [.wake(request: ""), .request("What time is it?")])
    }

    @MainActor
    func testWakeListenerUsesTheRecognizerWhileTheModelIsDown() async {
        // A worker still loading, or one that died, must not leave Daisy deaf.
        let probe = ListenerProbe()
        let detector = ManualDetector()
        detector.available = false
        probe.listener.detector = detector
        probe.planned = [(partials: [], final: "Hey Daisy, what's next?")]
        await probe.feed(seconds: 1, loud: false)
        await probe.feed(seconds: 1.5, loud: true)
        await probe.feed(seconds: 1.2, loud: false)
        await probe.settle()
        expectEqual(probe.events, [.wake(request: "what's next?"), .request("what's next?")])
        expectEqual(detector.fed, 74 * 800)
    }

    @MainActor
    func testWakeListenerResetDropsTheUtteranceInProgress() async {
        let probe = ListenerProbe()
        probe.planned = [(partials: [(1.6, "Hey, Daisy")], final: "Hey, Daisy, stop.")]
        await probe.feed(seconds: 1, loud: false)
        await probe.feed(seconds: 0.8, loud: true)
        await probe.settle()
        expectTrue(probe.listener.awake)
        probe.listener.reset()
        await probe.settle()
        expectFalse(probe.listener.busy)
        expectTrue(probe.streams.first?.cancelled == true)
        await probe.feed(seconds: 1.5, loud: false)
        await probe.settle()
        expectEqual(probe.events, [.wake(request: "")])
    }

    // MARK: Fallback

    private final class Outcomes: @unchecked Sendable {
        let lock = NSLock()
        var items: [FallbackSpeechStream.Outcome] = []
        func add(_ outcome: FallbackSpeechStream.Outcome) { lock.withLock { items.append(outcome) } }
        var all: [FallbackSpeechStream.Outcome] { lock.withLock { items } }
    }
    private final class Transcripts: @unchecked Sendable {
        let lock = NSLock()
        var items: [String] = []
        func add(_ text: String) { lock.withLock { items.append(text) } }
        var all: [String] { lock.withLock { items } }
    }
    private final class Calls: @unchecked Sendable {
        let lock = NSLock()
        var sampleCounts: [Int] = []
        func add(_ count: Int) { lock.withLock { sampleCounts.append(count) } }
        var all: [Int] { lock.withLock { sampleCounts } }
    }

    func testFallbackStreamHandsTheAudioToWhisperWhenAppleFails() async throws {
        let outcomes = Outcomes(), calls = Calls()
        func whisper() -> RecordedSpeechStream {
            RecordedSpeechStream { url in
                // The WAV holds exactly what was streamed: 44 header bytes plus two per sample.
                let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
                calls.add((size - 44) / 2)
                return "from whisper"
            }
        }
        let second = [Int16](repeating: 500, count: 16000)
        let failing = FallbackSpeechStream(primary: ScriptedStream(final: "", failure: DaisyError.message("model went away"), onUpdate: { _ in }),
                                           backup: whisper(), retryEmpty: false) { outcomes.add($0) }
        failing.append(second); failing.append(second)
        let failed = try await failing.finish()
        expectEqual(failed, "from whisper")
        expectEqual(calls.all, [32000])
        expectEqual(outcomes.all, [.failed("model went away")])

        // Empty before Apple has ever heard anything: Whisper gets a say.
        let doubted = FallbackSpeechStream(primary: ScriptedStream(final: "", onUpdate: { _ in }), backup: whisper(), retryEmpty: true) { outcomes.add($0) }
        doubted.append(second)
        let retried = try await doubted.finish()
        expectEqual(retried, "from whisper")
        expectEqual(outcomes.all.last, .empty(whisperHeard: true))

        // Empty from a recognizer that has proven itself is taken as silence; Whisper isn't asked.
        let trusted = FallbackSpeechStream(primary: ScriptedStream(final: "", onUpdate: { _ in }), backup: whisper(), retryEmpty: false) { outcomes.add($0) }
        trusted.append([Int16](repeating: 500, count: 16000))
        let silence = try await trusted.finish()
        expectEqual(silence, "")
        expectEqual(calls.all.count, 2)

        let heard = FallbackSpeechStream(primary: ScriptedStream(final: "Hey Daisy.", onUpdate: { _ in }), backup: whisper(), retryEmpty: true) { outcomes.add($0) }
        heard.append([Int16](repeating: 500, count: 16000))
        let text = try await heard.finish()
        expectEqual(text, "Hey Daisy.")
        expectEqual(outcomes.all.last, .heard)
        expectEqual(calls.all.count, 2)

        // Too short to be speech: no Whisper run at all.
        let blip = whisper()
        blip.append([Int16](repeating: 500, count: 3000))
        let nothing = try await blip.finish()
        expectEqual(nothing, "")
        expectEqual(calls.all.count, 2)
    }

    func testSpeechSettingsDefaultsAndStatusWording() throws {
        let old = try JSONDecoder().decode(SpeechInputSettings.self, from: Data("{}".utf8))
        expectTrue(old.usesAppleSpeech); expectTrue(old.usesVoiceActivity); expectTrue(old.usesWakeWordModel)
        expectEqual(old.localeIdentifier, "en-US"); expectEqual(old.wakeThreshold, 0.5)
        var tuned = SpeechInputSettings(); tuned.wakeWordThreshold = 3; tuned.appleSpeech = false
        expectEqual(tuned.wakeThreshold, 0.99)
        let decoded = try JSONDecoder().decode(SpeechInputSettings.self, from: JSONEncoder().encode(tuned))
        expectEqual(decoded, tuned)
        expectTrue(SpeechRecognitionStatus(active: .apple, apple: .ready).summary.hasPrefix("Apple on-device"))
        expectTrue(SpeechRecognitionStatus(active: .whisper, apple: .downloading(0.4)).summary.contains("(40%)"))
        expectTrue(SpeechRecognitionStatus(active: .whisper, apple: .unavailable("it needs macOS 26.")).summary.hasSuffix("it needs macOS 26."))
    }

    // MARK: Apple

    /// A `say` clip at 16 kHz, the format the microphone path produces.
    private func sayClip(_ text: String, in folder: URL) async throws -> URL {
        let aiff = folder.appendingPathComponent("clip.aiff"), wav = folder.appendingPathComponent("clip.wav")
        try await LocalProcess.run(executable: URL(fileURLWithPath: "/usr/bin/say"), arguments: ["-o", aiff.path, text])
        try await LocalProcess.run(executable: URL(fileURLWithPath: "/usr/bin/afconvert"), arguments: [aiff.path, wav.path, "-f", "WAVE", "-d", "LEI16@16000", "-c", "1"])
        return wav
    }

    /// Apple's recognizer when it's ready here. If the model is on disk but not yet reserved for this
    /// program, reserve it; that asks Apple for nothing over the network.
    private func appleReady() async throws -> Bool {
        var state = await AppleSpeech.state(locale: "en-US")
        if state == .needsDownload, await AppleSpeech.onDisk(locale: "en-US") {
            try await AppleSpeech.install(locale: "en-US") { _ in }
            state = await AppleSpeech.state(locale: "en-US")
        }
        if state != .ready { print("  skipped: Apple's recognizer isn't ready on this Mac (\(state))") }
        return state == .ready
    }

    func testAppleRecognizerTranscribesASayClip() async throws {
        guard try await appleReady() else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("daisy-apple-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = try await sayClip("Hey Daisy, what time is it?", in: folder)
        // Its own child registry, so nothing here can touch processes outside the test.
        let runtime = SpeechRuntime(children: ChildProcesses(records: folder.appendingPathComponent("children.json"), signatures: []))
        let text = try await runtime.transcribe(audio: clip, configuration: Configuration())
        expectTrue(text.lowercased().contains("what time is it"))
        expectEqual(WakePhrase.request(after: text)?.lowercased(), "what time is it?")
        let status = await runtime.status
        expectEqual(status.active, .apple)
        await runtime.shutdown()
    }

    func testAppleStreamingHearsTheWakePhraseBeforeTheEnd() async throws {
        guard try await appleReady() else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("daisy-apple-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let samples = try samplesOf(try await sayClip("Hey Daisy, what time is it in Tokyo right now?", in: folder))
        let runtime = SpeechRuntime(children: ChildProcesses(records: folder.appendingPathComponent("children.json"), signatures: []))
        let partials = Transcripts()
        let stream = try await runtime.stream(configuration: Configuration()) { text in partials.add(text) }
        // Real time, as the microphone would deliver it: 85 ms chunks.
        for start in stride(from: 0, to: samples.count, by: 1360) {
            stream.append(Array(samples[start..<min(samples.count, start + 1360)]))
            try await Task.sleep(nanoseconds: 85_000_000)
        }
        let early = partials.all
        let final = try await stream.finish()
        expectTrue(early.contains { WakePhrase.matches($0) })
        expectTrue(final.lowercased().contains("tokyo"))
        let status = await runtime.status
        expectEqual(status.active, .apple)
        await runtime.shutdown()
    }

    /// The whole standby path on a real clip, short of the microphone: chunks at real time with their
    /// power (and Silero's probability when DAISY_SILERO_MODEL is set), the endpointer, Apple's
    /// streaming partials, and the request at the end.
    @MainActor
    func testWakeListenerWithAppleWakesMidSentence() async throws {
        guard try await appleReady() else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("daisy-apple-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let speech = try samplesOf(try await sayClip("Hey Daisy, what time is it in Tokyo right now?", in: folder))
        let audio = [Int16](repeating: 0, count: 16000) + speech + [Int16](repeating: 0, count: 40000)
        let runtime = SpeechRuntime(children: ChildProcesses(records: folder.appendingPathComponent("children.json"), signatures: []))
        let vad = ProcessInfo.processInfo.environment["DAISY_SILERO_MODEL"].flatMap { try? SileroVAD(model: URL(fileURLWithPath: $0)) }
        let probe = ListenerProbe()
        let listener = WakeListener { onUpdate in try await runtime.stream(configuration: Configuration(), onUpdate: onUpdate) }
        listener.onEvent = { probe.events.append($0) }
        var wokeAt: Int?
        for start in stride(from: 0, to: audio.count, by: 1360) {
            let chunk = Array(audio[start..<min(audio.count, start + 1360)])
            var sum = 0.0
            for sample in chunk { let value = Double(sample) / 32768; sum += value * value }
            let power = Float(10 * log10(max(sum / Double(chunk.count), 1e-14)))
            listener.feed(AudioChunk(samples: chunk, power: power, duration: Double(chunk.count) / 16000, speech: vad?.probability(for: chunk)))
            try await Task.sleep(nanoseconds: 85_000_000)
            if wokeAt == nil, probe.events.contains(where: { if case .wake = $0 { return true } else { return false } }) { wokeAt = start + chunk.count }
        }
        for _ in 0..<100 where !probe.events.contains(where: { if case .request = $0 { return true } else { return false } }) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        // Awake before the sentence was over, not after the pause and a full transcription.
        let spokenUntil = 16000 + speech.count
        expectTrue(wokeAt != nil && wokeAt! < spokenUntil)
        print("  woke \(String(format: "%.2f", Double((wokeAt ?? 0) - 16000) / 16000)) s into a \(String(format: "%.2f", Double(speech.count) / 16000)) s sentence\(vad == nil ? "" : " (Silero on)")")
        guard case .request(let request)? = probe.events.last else { fail("no request: \(probe.events)"); return }
        expectTrue(request.lowercased().hasPrefix("what time is it in tokyo"))
        expectEqual(probe.events.filter { if case .wake = $0 { return true } else { return false } }.count, 1)
        await runtime.shutdown()
    }

    /// The openWakeWord first stage for real: the worker script from this repo, the feature models
    /// and a wake word model. Runs when DAISY_WAKEWORD_MODEL (a model file), DAISY_WAKEWORD_FEATURES
    /// (the folder setup-speech.sh fills) and DAISY_VOICE_PYTHON (a Python with onnxruntime) are set.
    /// Until hey_daisy.onnx exists, openWakeWord's own hey_jarvis model stands in for it.
    @MainActor
    func testWakeWordModelFirstStageEndToEnd() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let model = environment["DAISY_WAKEWORD_MODEL"], let features = environment["DAISY_WAKEWORD_FEATURES"],
              let python = environment["DAISY_VOICE_PYTHON"] else {
            print("  skipped: set DAISY_WAKEWORD_MODEL, DAISY_WAKEWORD_FEATURES and DAISY_VOICE_PYTHON to run the wake word worker")
            return
        }
        let phrase = environment["DAISY_WAKEWORD_PHRASE"] ?? "Hey Jarvis"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("daisy-wakeword-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let registry = ChildProcesses(records: folder.appendingPathComponent("children.json"), signatures: [])
        let featureFolder = URL(fileURLWithPath: features)
        let detector = OpenWakeWordDetector(python: URL(fileURLWithPath: python), script: repo.appendingPathComponent("scripts/speech/wakeword.py"),
                                            models: [URL(fileURLWithPath: model)],
                                            melSpectrogram: featureFolder.appendingPathComponent("melspectrogram.onnx"),
                                            embedding: featureFolder.appendingPathComponent("embedding_model.onnx"), children: registry)
        try detector.start()
        for _ in 0..<100 where !detector.isReady { try await Task.sleep(nanoseconds: 50_000_000) }
        expectTrue(detector.isReady)
        expectEqual(registry.recorded.map(\.label), ["wake word worker"])

        // Somebody else's name first: nothing.
        let other = try samplesOf(try await sayClip("Hey Daisy, what time is it?", in: folder))
        for start in stride(from: 0, to: other.count, by: 1360) { detector.feed(Array(other[start..<min(other.count, start + 1360)])) }
        detector.feed([Int16](repeating: 0, count: 16000))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        expectEqual(detector.takeDetection(), nil)

        // Then the wake phrase, through the listener, at real time.
        let speech = try samplesOf(try await sayClip("\(phrase), what time is it?", in: folder))
        let audio = [Int16](repeating: 0, count: 16000) + speech + [Int16](repeating: 0, count: 40000)
        let probe = ListenerProbe()
        let listener = WakeListener(detector: detector) { onUpdate in
            let stream = ScriptedStream(final: "What time is it?", onUpdate: onUpdate)
            probe.streams.append(stream)
            return stream
        }
        listener.onEvent = { probe.events.append($0) }
        var wokeAt: Int?
        for start in stride(from: 0, to: audio.count, by: 1360) {
            let chunk = Array(audio[start..<min(audio.count, start + 1360)])
            var sum = 0.0
            for sample in chunk { let value = Double(sample) / 32768; sum += value * value }
            let power = Float(10 * log10(max(sum / Double(chunk.count), 1e-14)))
            listener.feed(AudioChunk(samples: chunk, power: power, duration: Double(chunk.count) / 16000))
            try await Task.sleep(nanoseconds: 85_000_000)
            if wokeAt == nil, !probe.events.isEmpty { wokeAt = start + chunk.count }
        }
        for _ in 0..<60 where probe.events.count < 2 { try await Task.sleep(nanoseconds: 50_000_000) }
        let spokenUntil = 16000 + speech.count
        print("  woke \(String(format: "%.2f", Double((wokeAt ?? 0) - 16000) / 16000)) s into a \(String(format: "%.2f", Double(speech.count) / 16000)) s sentence")
        expectTrue(wokeAt != nil && wokeAt! < spokenUntil)
        expectEqual(probe.events, [.wake(request: ""), .request("What time is it?")])
        // The recognizer heard only what came after the wake word (plus the detector's delay, well
        // under half a second), never the wake phrase itself.
        expectEqual(probe.streams.count, 1)
        expectTrue((probe.streams.first?.receivedCount ?? .max) < audio.count - (wokeAt ?? 0) + 8000)
        await detector.stop()
        expectFalse(detector.isRunning)
        for _ in 0..<40 where !registry.recorded.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
        expectTrue(registry.recorded.isEmpty)
    }

    /// 16-bit samples from a WAV; afconvert writes a longer header than 44 bytes.
    private func samplesOf(_ url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url)
        guard let marker = data.range(of: Data("data".utf8)) else { throw DaisyError.message("no data chunk") }
        let body = data[(marker.upperBound + 4)...]
        return stride(from: body.startIndex, to: body.endIndex - 1, by: 2).map { Int16(bitPattern: UInt16(body[$0]) | UInt16(body[$0 + 1]) << 8) }
    }
}
