import Foundation

/// A first-stage wake word detector that hears the same audio as the listener. openWakeWord's
/// "hey daisy" model is the planned one (docs/wake-word.md); anything with this shape can stand in.
public protocol WakeWordDetector: AnyObject, Sendable {
    /// False while it loads, or after it has died; the listener then uses the recognizer gate.
    var available: Bool { get }
    /// 16 kHz mono samples, in order. Must not block.
    func feed(_ samples: [Int16])
    /// The latest detection since the last call, as how many of the samples fed so far came after
    /// the wake word ended. Nil when there's nothing new.
    func takeDetection() -> Int?
    func stop() async
}

/// Standby listening in one place. Feed it every audio chunk while Daisy waits for "Hey Daisy".
///
/// Without a detector, each utterance the endpointer finds goes to a streaming recognizer, and the
/// wake phrase is looked for in its partial results, so with Apple's recognizer Daisy wakes while
/// the sentence is still being said. Whisper has no partials, so there the wake comes when the
/// utterance ends. With a detector (openWakeWord), the recognizer only starts once the wake word
/// has been heard, on the audio after it. Either way the listener keeps going until the request
/// is complete, and waits a few seconds for one after a bare "Hey Daisy".
@MainActor public final class WakeListener {
    public enum Event: Equatable, Sendable {
        /// The wake phrase was heard. `request` is what followed it so far (often empty).
        case wake(request: String)
        /// The request is complete, without the wake phrase. Empty when nothing followed in time.
        case request(String)
        /// Speech ended without the wake phrase. Nothing was kept.
        case ignored
    }
    public struct Settings: Sendable {
        /// Audio from before speech started, handed to the recognizer so the first word isn't clipped.
        public var preRoll: TimeInterval = 1.0
        /// The same when listening for the request after a bare "Hey Daisy".
        public var requestPreRoll: TimeInterval = 0.5
        public var standby = SpeechEndpointer.Settings.standby
        public var request = SpeechEndpointer.Settings.afterWake
        public init() {}
    }
    /// Opens a recognizer stream; partial transcripts go to `onUpdate`.
    public typealias Recognize = @MainActor (_ onUpdate: @escaping @Sendable (String) -> Void) async throws -> any SpeechStream

    public var onEvent: ((Event) -> Void)?
    /// Replaceable at any time; nil means the recognizer gate does all the work.
    public var detector: (any WakeWordDetector)?
    /// True from the moment the wake phrase is heard until the request is handed over.
    public var awake: Bool { current?.awake ?? false }
    /// True while an utterance is being heard or transcribed.
    public var busy: Bool { current != nil }

    private let recognize: Recognize
    private let settings: Settings
    private var endpointer: SpeechEndpointer
    /// The last few seconds of chunks, with where each started in samples fed.
    private var recent: [(chunk: AudioChunk, start: Int, at: TimeInterval)] = []
    private var position = 0
    private var current: Utterance?
    private var nextID = 0

    private final class Utterance {
        let id: Int
        /// The wake phrase (or word) is established; no more `.wake` events.
        var awake: Bool
        /// This utterance is the request itself; no wake phrase is expected in it.
        let requestOnly: Bool
        /// An empty result means listening once more for the request.
        let mayWait: Bool
        var stream: (any SpeechStream)?
        var pending: [Int16] = []
        var failed = false
        var ending = false
        /// Where the endpointer closed it, in samples fed.
        var endedAt = 0
        init(id: Int, awake: Bool, requestOnly: Bool, mayWait: Bool) {
            self.id = id; self.awake = awake; self.requestOnly = requestOnly; self.mayWait = mayWait
        }
    }

    public init(settings: Settings = Settings(), detector: (any WakeWordDetector)? = nil, recognize: @escaping Recognize) {
        self.settings = settings
        self.detector = detector
        self.recognize = recognize
        endpointer = SpeechEndpointer(settings: settings.standby)
    }

    /// Drops whatever is in progress, for when standby is left or re-armed.
    public func reset() {
        if let stream = current?.stream { Task { await stream.cancel() } }
        current = nil
        recent = []
        endpointer = SpeechEndpointer(settings: settings.standby)
        _ = detector?.takeDetection()
    }

    /// One audio chunk: 16 kHz samples, their power in dBFS, and the voice activity probability.
    public func feed(_ chunk: AudioChunk) {
        remember(chunk)
        detector?.feed(chunk.samples)
        let detection = detector?.takeDetection()
        if let utterance = current, !utterance.ending {
            add(chunk.samples, to: utterance)
            switch endpointer.observe(power: chunk.power, duration: chunk.duration, speech: chunk.speech) {
            case .finished: end(utterance)
            case .timedOut: timedOut(utterance)
            default: break
            }
            return
        }
        let event = endpointer.observe(power: chunk.power, duration: chunk.duration, speech: chunk.speech)
        if event == .finished || event == .timedOut { endpointer = SpeechEndpointer(settings: settings.standby, continuing: endpointer) }
        // While the last utterance is still being transcribed, new speech waits in `recent`.
        guard current == nil else { return }
        if let detector, detector.available {
            guard let ago = detection else { return }
            // The model heard the wake word: the request starts right after it.
            onEvent?(.wake(request: ""))
            endpointer = SpeechEndpointer(settings: settings.request, continuing: endpointer)
            begin(awake: true, requestOnly: true, mayWait: true, seed: last(ago))
        } else if event == .speechStarted {
            begin(awake: false, requestOnly: false, mayWait: true, seed: last(samples(settings.preRoll)))
        }
    }

    // MARK: Utterances

    private func begin(awake: Bool, requestOnly: Bool, mayWait: Bool, seed: [Int16]) {
        nextID += 1
        let utterance = Utterance(id: nextID, awake: awake, requestOnly: requestOnly, mayWait: mayWait)
        utterance.pending = seed
        current = utterance
        let id = utterance.id
        let onUpdate: @Sendable (String) -> Void = { [weak self] text in
            Task { @MainActor in self?.heard(text, id: id) }
        }
        Task { [weak self, recognize] in
            do {
                let stream = try await recognize(onUpdate)
                guard let self, self.current === utterance else { await stream.cancel(); return }
                utterance.stream = stream
                stream.append(utterance.pending)
                utterance.pending = []
            } catch {
                guard let self, self.current === utterance else { return }
                utterance.failed = true
                utterance.pending = []
            }
            if utterance.ending { self?.complete(utterance) }
        }
    }

    private func add(_ samples: [Int16], to utterance: Utterance) {
        if let stream = utterance.stream { stream.append(samples) } else if !utterance.failed { utterance.pending += samples }
    }

    /// A partial transcript. The first one with the wake phrase in it wakes Daisy.
    private func heard(_ text: String, id: Int) {
        guard let utterance = current, utterance.id == id, !utterance.awake, !utterance.requestOnly,
              let request = WakePhrase.request(after: text) else { return }
        utterance.awake = true
        // From here on it's a request: the normal pause and length limits, not standby's.
        if !utterance.ending { endpointer = SpeechEndpointer(settings: settings.request, continuing: endpointer) }
        onEvent?(.wake(request: request))
    }

    private func end(_ utterance: Utterance) {
        utterance.ending = true
        utterance.endedAt = position
        endpointer = SpeechEndpointer(settings: settings.standby, continuing: endpointer)
        if utterance.stream != nil || utterance.failed { complete(utterance) }
    }

    private func timedOut(_ utterance: Utterance) {
        // Nobody spoke after the wake word.
        if let stream = utterance.stream { Task { await stream.cancel() } }
        current = nil
        endpointer = SpeechEndpointer(settings: settings.standby, continuing: endpointer)
        onEvent?(.request(""))
    }

    private func complete(_ utterance: Utterance) {
        let stream = utterance.stream
        Task { [weak self] in
            let text = (try? await stream?.finish()) ?? ""
            self?.resolve(utterance, text: text)
        }
    }

    private func resolve(_ utterance: Utterance, text: String) {
        guard current === utterance else { return }
        current = nil
        let request = WakePhrase.request(after: text)
        if !utterance.awake && !utterance.requestOnly {
            guard let request else {
                onEvent?(.ignored)
                // Someone started talking again while this was being transcribed.
                if endpointer.speaking {
                    begin(awake: false, requestOnly: false, mayWait: true,
                          seed: last(position - utterance.endedAt + samples(settings.preRoll)))
                }
                return
            }
            onEvent?(.wake(request: request))
            utterance.awake = true
        }
        // Apple can revise the phrase away between partial and final; then there's nothing to strip.
        let words = request ?? text
        guard words.isEmpty && utterance.mayWait else { onEvent?(.request(words)); return }
        // "Hey Daisy" on its own: listen for the request, which may have started meanwhile. The
        // audio since the phrase ended is replayed so the endpointer knows about it.
        endpointer = SpeechEndpointer(settings: settings.request)
        var finished = false
        for item in recent where item.start >= utterance.endedAt {
            if endpointer.observe(power: item.chunk.power, duration: item.chunk.duration, speech: item.chunk.speech) == .finished { finished = true }
        }
        begin(awake: true, requestOnly: true, mayWait: false, seed: last(position - utterance.endedAt + samples(settings.requestPreRoll)))
        if finished, let waiting = current { end(waiting) }
    }

    // MARK: Recent audio

    private func remember(_ chunk: AudioChunk) {
        let now = ProcessInfo.processInfo.systemUptime
        recent.append((chunk, position, now))
        position += chunk.samples.count
        // Enough for the pre-roll plus a slow transcription, and nothing from before a pause in feeding.
        let keep = max(settings.preRoll, settings.requestPreRoll) + 2
        var total = recent.reduce(0) { $0 + $1.chunk.samples.count }
        while let first = recent.first, recent.count > 1,
              now - first.at > keep + 0.5 || Double(total - first.chunk.samples.count) / MicDownsampler.sampleRate >= keep {
            total -= first.chunk.samples.count
            recent.removeFirst()
        }
    }
    private func samples(_ seconds: TimeInterval) -> Int { Int(seconds * MicDownsampler.sampleRate) }
    /// The last `count` samples fed, as far back as `recent` goes.
    private func last(_ count: Int) -> [Int16] {
        guard count > 0 else { return [] }
        var collected: [Int16] = []
        for item in recent.reversed() {
            collected.insert(contentsOf: item.chunk.samples, at: 0)
            if collected.count >= count { break }
        }
        return Array(collected.suffix(count))
    }
}

/// openWakeWord in a small Python worker, using the onnxruntime and numpy already in the voice
/// venv. Raw 16 kHz Int16 audio goes in on stdin; one score per 80 ms frame comes back on stdout.
public final class OpenWakeWordDetector: WakeWordDetector, @unchecked Sendable {
    public static let frame = 1280
    /// Whether everything the worker needs is on disk.
    public static var installed: Bool {
        [NaturalSpeech.python.path].allSatisfy { FileManager.default.isExecutableFile(atPath: $0) }
            && [SpeechAssets.wakeWord, SpeechAssets.melSpectrogram, SpeechAssets.speechEmbedding, SpeechAssets.wakeWordWorker]
                .allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    private let lock = NSLock()
    private let writes = DispatchQueue(label: "daisy.wakeword.input")
    private let python: URL, script: URL, models: [URL], melSpectrogram: URL, embedding: URL
    private let threshold: Float
    private let refractory: Int
    private let children: ChildProcesses
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var ready = false
    private var queued = 0
    private var fed = 0
    private var scored = 0
    private var lastHit = Int.min / 2
    private var detection: Int?
    public private(set) var failure: String?

    public init(python: URL = NaturalSpeech.python, script: URL = SpeechAssets.wakeWordWorker,
                models: [URL] = [SpeechAssets.wakeWord], melSpectrogram: URL = SpeechAssets.melSpectrogram,
                embedding: URL = SpeechAssets.speechEmbedding, threshold: Float = 0.5,
                refractory: TimeInterval = 2, children: ChildProcesses = .shared) {
        self.python = python; self.script = script; self.models = models
        self.melSpectrogram = melSpectrogram; self.embedding = embedding
        self.threshold = threshold; self.refractory = Int(refractory * 16000); self.children = children
    }

    public var isRunning: Bool { lock.withLock { process?.isRunning == true } }
    public var isReady: Bool { lock.withLock { ready } }
    /// Loaded, running, and keeping up with the audio.
    public var available: Bool { lock.withLock { ready && process?.isRunning == true && failure == nil } }

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard process?.isRunning != true else { return }
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = python
        child.arguments = [script.path, "--melspec", melSpectrogram.path, "--embedding", embedding.path] + models.flatMap { ["--model", $0.path] }
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
        child.environment = ["PYTHONDONTWRITEBYTECODE": "1", "PATH": "/usr/bin:/bin"]
        // A worker that dies must not take Daisy with it: writing to its closed pipe would raise SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try children.launch(child, label: "wake word worker")
        process = child; input = stdin.fileHandleForWriting
        buffer = Data(); ready = false; queued = 0; fed = 0; scored = 0; detection = nil; failure = nil
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; self?.closed(child); return }
            self?.receive(data)
        }
    }

    public func feed(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        guard let input, process?.isRunning == true else { lock.unlock(); return }
        // More than about three seconds unwritten means the worker is stuck; drop audio rather than block.
        guard queued < 40 else { lock.unlock(); return }
        queued += 1; fed += samples.count
        lock.unlock()
        let bytes = samples.map(\.littleEndian).withUnsafeBufferPointer { Data(buffer: $0) }
        writes.async { [weak self] in
            let failed: Bool
            do { try input.write(contentsOf: bytes); failed = false } catch { failed = true }
            guard let self else { return }
            self.lock.withLock {
                self.queued -= 1
                if failed && self.failure == nil { self.failure = "The wake word worker stopped taking audio." }
            }
        }
    }

    public func takeDetection() -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard let position = detection else { return nil }
        detection = nil
        return max(0, fed - position)
    }

    public func stop() async {
        let child = lock.withLock { () -> Process? in
            let child = process
            try? input?.close(); input = nil; process = nil; ready = false
            return child
        }
        guard let child, child.isRunning else { return }
        child.terminate()
        for _ in 0..<20 where child.isRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
    }

    private func receive(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...end)
            if !ready {
                ready = line.contains("\"ready\"")
                if !ready { failure = line }
                continue
            }
            guard let score = Float(line.trimmingCharacters(in: .whitespaces)) else { continue }
            scored += Self.frame
            if score >= threshold && scored - lastHit > refractory {
                lastHit = scored
                detection = scored
            }
        }
    }

    private func closed(_ child: Process) {
        lock.withLock {
            guard process === child else { return }
            if failure == nil { failure = ready ? "The wake word worker stopped." : "The wake word worker couldn't start." }
            process = nil; input = nil; ready = false
        }
    }
}
