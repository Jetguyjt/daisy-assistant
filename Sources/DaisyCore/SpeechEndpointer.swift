import Foundation

/// Decides when an utterance has ended from a stream of input power readings in dBFS. Energy
/// based with an adaptive noise floor: no model, no dependency, deterministic and testable.
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
        public init() { }
        public static let standard = Settings()
        /// After Daisy answers: a shorter wait for a follow-up before returning to rest.
        public static var followUp: Settings { var s = Settings(); s.noSpeechTimeout = 6; return s }
        /// Wake-word standby: wait indefinitely, close an utterance a little sooner, cap its length.
        public static var standby: Settings {
            var s = Settings(); s.noSpeechTimeout = .infinity; s.trailingSilence = 1.0; s.maximumDuration = 20; return s
        }
        /// While Daisy speaks: only a clear, sustained voice over the echo residue interrupts.
        public static var bargeIn: Settings {
            var s = Settings(); s.speechStart = 0.35; s.margin = 15; s.noSpeechTimeout = .infinity; s.maximumDuration = .infinity
            s.calibration = 0.6; s.floorFall = 0.02
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
    private var done = false

    public init(settings: Settings = .standard) { self.settings = settings }

    public var threshold: Float { max((noiseFloor ?? -80) + settings.margin, settings.minimumThreshold) }
    /// True while the speaker is mid-utterance, including brief pauses.
    public var speaking: Bool { spoke && !done && belowRun < 0.3 }

    public mutating func observe(power: Float, duration: TimeInterval) -> Event {
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
        let loud = power > threshold
        if !loud {
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
            if power < threshold - 4 { aboveRun = 0 }
        }
        if spoke && belowRun >= settings.trailingSilence { done = true; return .finished }
        if spoke && spokenFor >= settings.maximumDuration { done = true; return .finished }
        if !spoke && elapsed >= settings.noSpeechTimeout { done = true; return .timedOut }
        return event
    }
}

/// Wake phrase spotting on recognizer transcripts, and removing the phrase from what Whisper heard.
public enum WakePhrase {
    static let greetings = ["hey", "hi", "okay", "ok", "yo"]
    /// "Daisy" plus the ways Whisper has been seen to spell it.
    static let names = ["daisy", "daisey", "daisie", "daizy", "dazy", "days he", "daisy s"]
    public static let phrases = greetings.flatMap { greeting in names.map { greeting + " " + $0 } }
    static func normalized(_ text: String) -> String {
        text.lowercased().map { $0.isLetter ? String($0) : " " }.joined()
            .split(separator: " ").joined(separator: " ")
    }
    public static func matches(_ transcript: String) -> Bool {
        let text = normalized(transcript)
        return phrases.contains { text.contains($0) }
    }
    /// "Hey Daisy, what time is it?" becomes "what time is it?". Only a leading phrase is removed.
    public static func stripping(_ transcript: String) -> String {
        let pattern = "^[\\s\\p{P}]*(hey|hi|okay|ok|yo)[\\s\\p{P}]+(daisy|daisey|daisie|daizy|dazy|days\\s+he)('s)?[\\s\\p{P}]*"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return transcript }
        let range = NSRange(transcript.startIndex..., in: transcript)
        return regex.stringByReplacingMatches(in: transcript, range: range, withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
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
