import Foundation

/// Decides when an utterance has ended from a stream of input power readings in dBFS, plus a
/// speech probability per reading when a voice activity detector (Silero) runs. Without one it is
/// energy based with an adaptive noise floor. Deterministic and testable either way.
/// Feed it one reading per audio chunk; it answers with at most one event per chunk.
public struct SpeechEndpointer: Sendable {
    public struct Settings: Sendable {
        /// Speech must rise this far above the measured floor.
        public var margin: Float = 12
        /// The threshold never drops below this, so a silent room does not trigger on breathing.
        public var minimumThreshold: Float = -52
        /// Sustained level above the threshold before speech counts as started.
        public var speechStart: TimeInterval = 0.15
        /// Silence after speech before the utterance counts as finished.
        public var trailingSilence: TimeInterval = 1.3
        /// No speech at all within this window ends listening.
        public var noSpeechTimeout: TimeInterval = 10
        /// Hard cap on utterance length.
        public var maximumDuration: TimeInterval = 60
        /// Readings at the start used only to learn the floor; no events fire meanwhile.
        public var calibration: TimeInterval = 0
        /// How fast the floor follows a quieter room. Barge-in keeps it slow so the gaps between
        /// Daisy's sentences do not drag the floor under its own echo.
        public var floorFall: Float = 0.3
        /// With a voice activity detector: the probability that counts as speech, and the lower one
        /// that keeps an utterance going through short dips between words (Silero's own defaults).
        public var voiceStart: Float = 0.5
        public var voiceEnd: Float = 0.35
        /// With a voice activity detector, also require the energy threshold. Barge-in sets this:
        /// Daisy's own echo is speech to the detector, so only a voice louder than the echo counts.
        public var voiceNeedsEnergy = false
        public init() { }
        public static let standard = Settings()
        /// After Daisy answers: a shorter wait for a follow-up before returning to rest.
        public static var followUp: Settings { var s = Settings(); s.noSpeechTimeout = 6; return s }
        /// Wake-word standby: wait indefinitely, close an utterance a little sooner, cap its length.
        public static var standby: Settings {
            var s = Settings(); s.noSpeechTimeout = .infinity; s.trailingSilence = 1.0; s.maximumDuration = 20; return s
        }
        /// After "Hey Daisy": the request gets the normal pause and length, and a few seconds to start.
        public static var afterWake: Settings { var s = Settings(); s.noSpeechTimeout = 8; return s }
        /// While Daisy speaks: only a clear, sustained voice over the echo residue interrupts.
        public static var bargeIn: Settings {
            var s = Settings(); s.speechStart = 0.35; s.margin = 15; s.noSpeechTimeout = .infinity; s.maximumDuration = .infinity
            s.calibration = 0.6; s.floorFall = 0.02; s.voiceNeedsEnergy = true
            return s
        }
    }
    public enum Event: Equatable, Sendable { case none, speechStarted, finished, timedOut }

    public let settings: Settings
    public private(set) var noiseFloor: Float?
    public private(set) var spoke = false
    public private(set) var elapsed: TimeInterval = 0
    /// Time since speech began; the length cap applies to the utterance, not to a long quiet wait.
    public private(set) var spokenFor: TimeInterval = 0
    private var aboveRun: TimeInterval = 0
    private var calibrationSum: Float = 0
    private var calibrationCount = 0
    private var belowRun: TimeInterval = 0
    private var voiced = false
    private var done = false

    public init(settings: Settings = .standard) { self.settings = settings }
    /// Carries an utterance in progress over to new settings: the learned floor, and whether the
    /// speaker has started and is still talking. Used when "Hey Daisy" turns standby into a request.
    public init(settings: Settings, continuing previous: SpeechEndpointer) {
        self.settings = settings
        noiseFloor = previous.noiseFloor
        spoke = previous.spoke && !previous.done
        spokenFor = spoke ? previous.spokenFor : 0
        aboveRun = spoke ? previous.aboveRun : 0
        belowRun = spoke ? previous.belowRun : 0
        voiced = spoke && previous.voiced
    }

    public var threshold: Float { max((noiseFloor ?? -80) + settings.margin, settings.minimumThreshold) }
    /// True while the speaker is mid-utterance, including brief pauses.
    public var speaking: Bool { spoke && !done && belowRun < 0.3 }

    /// `speech` is the voice activity detector's probability for this chunk, nil when none runs.
    public mutating func observe(power: Float, duration: TimeInterval, speech: Float? = nil) -> Event {
        guard !done, duration > 0 else { return .none }
        elapsed += duration
        if elapsed <= settings.calibration {
            calibrationSum += power; calibrationCount += 1
            noiseFloor = calibrationSum / Float(calibrationCount)
            return .none
        }
        if spoke { spokenFor += duration }
        // The first reading may already be speech (wake-word pre-roll), so never start the floor
        // above a level a quiet room would produce.
        let floor = noiseFloor ?? min(power, -45)
        if noiseFloor == nil { noiseFloor = floor }
        let energetic = power > threshold
        let loud: Bool
        if let speech {
            // Hysteresis: a word that has started keeps going until the probability drops well down.
            voiced = speech >= (voiced ? settings.voiceEnd : settings.voiceStart)
            loud = voiced && (energetic || !settings.voiceNeedsEnergy)
        } else {
            loud = energetic
        }
        // The floor learns only from what is neither loud nor voice, so quiet speech isn't taken for the room.
        if !energetic && !voiced {
            // Fall fast, rise slowly: a fan that starts up moves the floor over a couple of seconds.
            let alpha: Float = power < floor ? settings.floorFall : 0.05
            noiseFloor = floor + (power - floor) * alpha
        }
        var event = Event.none
        if loud {
            aboveRun += duration; belowRun = 0
            if !spoke && aboveRun >= settings.speechStart { spoke = true; event = .speechStarted }
        } else {
            belowRun += duration
            // The detector has its own hysteresis; energy keeps a 4 dB band so a hovering level doesn't reset the start.
            if speech != nil || power < threshold - 4 { aboveRun = 0 }
        }
        if spoke && belowRun >= settings.trailingSilence { done = true; return .finished }
        if spoke && spokenFor >= settings.maximumDuration { done = true; return .finished }
        if !spoke && elapsed >= settings.noSpeechTimeout { done = true; return .timedOut }
        return event
    }
}

/// Wake phrase spotting on recognizer transcripts, and removing the phrase from what was heard.
public enum WakePhrase {
    static let greetings = ["hey", "hi", "okay", "ok", "yo"]
    /// "Daisy" plus the ways Whisper has been seen to spell it. "Daisy's" is covered by the pattern.
    static let names = ["daisy", "daisey", "daisie", "daizy", "dazy", "days he"]
    public static let phrases = greetings.flatMap { greeting in names.map { greeting + " " + $0 } }
    /// Greeting, any punctuation or spacing, name. Whole words only, so "they, Daisy" and
    /// "hey days here" don't wake her.
    private static let core = "(" + greetings.joined(separator: "|") + ")[\\s\\p{P}]+("
        + names.map { $0.replacingOccurrences(of: " ", with: "\\s+") }.joined(separator: "|") + ")(['’]s)?\\b[\\s\\p{P}]*"
    private static let anywhere = try? NSRegularExpression(pattern: "\\b" + core, options: [.caseInsensitive])
    private static let leading = try? NSRegularExpression(pattern: "^[\\s\\p{P}]*" + core, options: [.caseInsensitive])
    public static func matches(_ transcript: String) -> Bool { request(after: transcript) != nil }
    /// What was said after the first wake phrase, or nil when there is none. Works on a partial
    /// transcript too: "so, hey Daisy, what's the" gives "what's the".
    public static func request(after transcript: String) -> String? {
        guard let anywhere, let match = anywhere.firstMatch(in: transcript, range: NSRange(transcript.startIndex..., in: transcript)),
              let range = Range(match.range, in: transcript) else { return nil }
        return String(transcript[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// "Hey Daisy, what time is it?" becomes "what time is it?". Only a leading phrase is removed.
    public static func stripping(_ transcript: String) -> String {
        guard let leading else { return transcript }
        let range = NSRange(transcript.startIndex..., in: transcript)
        return leading.stringByReplacingMatches(in: transcript, range: range, withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Minimal 16-bit PCM WAV writer for whisper-cli input.
public enum WAVFile {
    public static func write(samples: [Int16], sampleRate: Int, to url: URL) throws {
        var data = Data(capacity: 44 + samples.count * 2)
        func append(_ value: UInt32) { var v = value.littleEndian; data.append(Data(bytes: &v, count: 4)) }
        func append(_ value: UInt16) { var v = value.littleEndian; data.append(Data(bytes: &v, count: 2)) }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + byteCount); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(byteCount)
        samples.withUnsafeBufferPointer { buffer in
            for sample in buffer { var v = sample.littleEndian; data.append(Data(bytes: &v, count: 2)) }
        }
        try data.write(to: url, options: .atomic)
    }
}
