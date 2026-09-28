import AVFoundation
import Foundation
import DaisyCore

/// `daisy-check --voice-ab ["text"] [--voice af_heart] [--speed 1.0] [--blind] [--render-only] [--out folder]`
///
/// Plays one Kokoro render three ways, back to back, each announced first:
///   A  plain AVAudioPlayer, no engine: the WAV as it is
///   B  the app's engine with Apple voice processing (echo cancellation) on: how Daisy speaks today
///   C  the same engine with voice processing off
/// Voice processing lives in the engine's output unit and needs the live microphone and speakers,
/// so it can't be rendered offline, and no tap sees what it does to the sound: B has to be heard
/// live. What can be kept lands in .build/voice-ab/<time>/: source.wav and each chunk as
/// synthesized, engine-offline.wav (the engine path without voice processing, rendered offline),
/// b-mixer.wav and c-mixer.wav (what the mixer handed the output unit during B and C, so before
/// voice processing), and report.txt. --blind shuffles the order and keeps the answer in key.txt.
/// --render-only skips playback.
enum VoiceAB {
    static let sample = "Hi, I'm Daisy. Your draft is due Oct. 15, so let's block out 45 minutes a day, e.g. 3:30 to 4:15 p.m. Sound good? The notes you gave me are about 2,400 words, roughly 12 minutes of reading."

    static func run(_ arguments: [String]) async throws {
        let options = try Options(arguments)
        // Daisy's saved voice and speed, unless both were given.
        let saved = options.voice == nil || options.speed == nil ? try? Configuration.load() : nil
        let voice = options.voice ?? saved?.naturalVoice ?? NaturalSpeech.defaultVoice
        let speed = options.speed ?? saved?.speechRate ?? 1
        _ = try NaturalSpeech.blend(voice)
        guard NaturalSpeech.speeds.contains(speed) else { throw DaisyError.message("--speed has to be between 0.75 and 1.3.") }
        guard NaturalSpeech.isInstalled else { throw DaisyError.message("The Kokoro voice isn't installed. Run scripts/setup-voice.sh first.") }

        let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let folder = options.folder ?? here.appendingPathComponent(".build/voice-ab/" + stamp())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Run from the repo, the repo's synthesize.py is used with the installed model, so a change
        // to it can be heard before it's installed.
        let repoScript = here.appendingPathComponent("scripts/voice/synthesize.py")
        let fromRepo = FileManager.default.fileExists(atPath: repoScript.path)
        let worker = SpeechWorker(script: fromRepo ? repoScript : NaturalSpeech.script,
                                  arguments: fromRepo ? ["--models", NaturalSpeech.runtime.path] : [])
        var report = Report(folder: folder)
        do {
            let text = options.words.isEmpty ? sample : options.words.joined(separator: " ")
            let chunks = SpeechText.sentences(from: SpeechText.spoken(from: text))
            guard !chunks.isEmpty else { throw DaisyError.message("There's nothing to say in that text.") }
            report.add("Voice \(voice) at \(String(format: "%.2f", speed))x, synthesized by \(fromRepo ? repoScript.path : NaturalSpeech.script.path)")
            report.add("Text: \(text)")
            report.add("Folder: \(folder.path)\n")

            var files: [URL] = []
            for (index, chunk) in chunks.enumerated() {
                let url = folder.appendingPathComponent("chunk-\(index + 1).wav")
                let seconds = try await worker.synthesize(text: chunk, voice: voice, speed: speed, output: url)
                files.append(url)
                report.add("chunk \(index + 1): " + String(format: "%.2fs of audio, made in %.2fs: ", Audio.seconds(url), seconds) + chunk)
            }
            let source = folder.appendingPathComponent("source.wav")
            try Audio.join(files, into: source)
            let offline = folder.appendingPathComponent("engine-offline.wav")
            try Audio.renderThroughEngine(source, to: offline)
            report.add("")
            report.add(file: source, "the render, chunks joined; A plays these")
            report.add(file: offline, "through AVAudioEngine's player and mixer at 48 kHz, offline, no voice processing")

            if options.renderOnly {
                report.add("\nPlayback skipped (--render-only). Voice processing needs the live microphone and speakers, so it can only be heard live.")
            } else {
                let order = options.blind ? Version.allCases.shuffled() : Version.allCases
                let names = order.enumerated().map { options.blind ? "Sample \($0.offset + 1)" : "Version \($0.element.rawValue)" }
                // Each version is announced in the same voice, through the same path.
                var labels: [URL] = []
                for (position, name) in names.enumerated() {
                    let label = folder.appendingPathComponent("label-\(position + 1).wav")
                    _ = try await worker.synthesize(text: SpeechText.spoken(from: name), voice: voice, speed: speed, output: label)
                    labels.append(label)
                }
                print("\nQuit Daisy first if it's running: its own voice processing ducks other audio, this included.")
                print("B and C open the microphone, so the terminal may ask for microphone access once. Starting in 3 seconds.")
                try await Task.sleep(nanoseconds: 3_000_000_000)
                // Blind: which sample was which stays in the files until the end.
                report.quiet = options.blind
                var key: [String] = []
                for (position, version) in order.enumerated() {
                    print("\n>> \(options.blind ? names[position] : version.title)")
                    key.append("\(names[position]) = \(version.title)")
                    try await play(version, files: [labels[position]] + files, folder: folder, report: &report)
                    try await Task.sleep(nanoseconds: 1_200_000_000)
                }
                report.quiet = false
                if options.blind {
                    let keyFile = folder.appendingPathComponent("key.txt")
                    try (key.joined(separator: "\n") + "\n").write(to: keyFile, atomically: true, encoding: .utf8)
                    report.add("\nWhich sample was which: \(keyFile.path) (levels for each are in report.txt)")
                }
                report.add("\nThe mixer recordings are what the engine handed its output unit. Voice processing and ducking happen after that, so if B sounds thinner or quieter than A and C live while b-mixer.wav matches c-mixer.wav, voice processing is the cause.")
            }
            await worker.stop()
            try report.save()
            print("\nReport: \(folder.appendingPathComponent("report.txt").path)")
        } catch {
            await worker.stop()
            try? report.save()
            throw error
        }
    }

    private enum Version: String, CaseIterable {
        case plain = "A", processed = "B", engine = "C"
        var title: String {
            switch self {
            case .plain: return "A: plain AVAudioPlayer, no engine, no voice processing"
            case .processed: return "B: the app's engine with voice processing on (how Daisy sounds now)"
            case .engine: return "C: the app's engine with voice processing off"
            }
        }
    }

    private static func play(_ version: Version, files: [URL], folder: URL, report: inout Report) async throws {
        switch version {
        case .plain:
            // The app's fallback path: one AVAudioPlayer per chunk.
            for url in files {
                let player = try AVAudioPlayer(contentsOf: url)
                guard player.play() else { throw DaisyError.message("AVAudioPlayer could not start.") }
                while player.isPlaying { try await Task.sleep(nanoseconds: 20_000_000) }
            }
        case .processed, .engine:
            let recording = folder.appendingPathComponent(version == .processed ? "b-mixer.wav" : "c-mixer.wav")
            let run = try await playThroughEngine(voiceProcessing: version == .processed, files: files, recording: recording)
            let state = run.voiceProcessing ? "on" : version == .processed ? "REFUSED, so this was the plain engine" : "off"
            report.add("\(version.rawValue): voice processing \(state) · mixer \(run.mixer) · output \(run.output) · played \(run.finished ? "to the end" : "until the timeout")")
            if let details = run.details { report.add("   " + details) }
            report.add(file: recording, "the mixer's output during \(version.rawValue)")
        }
    }

    private struct EngineRun {
        let voiceProcessing: Bool
        let mixer: String
        let output: String
        let finished: Bool
        let details: String?
    }

    /// The app's engine path: MicrophoneEngine, the chunks scheduled back to back on its player
    /// node, and a tap on the mixer written to `recording`. The file is complete once this returns.
    private static func playThroughEngine(voiceProcessing: Bool, files: [URL], recording: URL) async throws -> EngineRun {
        let session = try MicrophoneEngine.start(preferVoiceProcessing: voiceProcessing) { _ in }
        defer { session.stop() }
        let engine = session.engine
        let mixer = engine.mainMixerNode.outputFormat(forBus: 0)
        let recorder = try Recorder(url: recording, format: mixer)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: mixer) { buffer, _ in recorder.write(buffer) }
        defer { engine.mainMixerNode.removeTap(onBus: 0) }
        let finished = Flag()
        try schedule(files, on: session) { finished.set() }
        let deadline = Date().addingTimeInterval(files.reduce(10) { $0 + Audio.seconds($1) })
        while !finished.isSet, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try await Task.sleep(nanoseconds: 300_000_000)
        session.player.stop()
        var details: String?
        if session.voiceProcessing {
            let input = engine.inputNode
            let ducking = input.voiceProcessingOtherAudioDuckingConfiguration
            let level: String
            switch ducking.duckingLevel {
            case .min: level = "min"
            case .mid: level = "mid"
            case .max: level = "max"
            default: level = "default"
            }
            details = "AGC \(input.isVoiceProcessingAGCEnabled ? "on" : "off"), bypassed \(input.isVoiceProcessingBypassed ? "yes" : "no"), "
                + "other audio ducked at level \(level)\(ducking.enableAdvancedDucking.boolValue ? " (advanced)" : "")"
        }
        let output = engine.outputNode.outputFormat(forBus: 0)
        return EngineRun(voiceProcessing: session.voiceProcessing, mixer: describe(mixer), output: describe(output),
                         finished: finished.isSet, details: details)
    }

    private static func schedule(_ files: [URL], on session: MicrophoneSession, then done: @escaping @Sendable () -> Void) throws {
        let audio = try files.map { try AVAudioFile(forReading: $0) }
        guard let first = audio.first else { return done() }
        session.engine.connect(session.player, to: session.engine.mainMixerNode, format: first.processingFormat)
        for (index, file) in audio.enumerated() {
            let last = index == audio.count - 1
            session.player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { _ in if last { done() } }
        }
        session.player.play()
    }

    private static func describe(_ format: AVAudioFormat) -> String {
        "\(format.channelCount) ch at \(Int(format.sampleRate)) Hz"
    }

    private static func stamp() -> String {
        let format = DateFormatter()
        format.dateFormat = "yyyyMMdd-HHmmss"
        return format.string(from: Date())
    }

    private struct Options {
        var words: [String] = []
        var voice: String?
        var speed: Double?
        var blind = false
        var renderOnly = false
        var folder: URL?
        init(_ arguments: [String]) throws {
            let usage = DaisyError.message("Usage: daisy-check --voice-ab [\"text\"] [--voice af_heart] [--speed 1.0] [--blind] [--render-only] [--out folder]")
            var rest = arguments[...]
            while let argument = rest.popFirst() {
                switch argument {
                case "--voice": guard let value = rest.popFirst() else { throw usage }; voice = value
                case "--speed": guard let value = rest.popFirst().flatMap({ Double($0) }) else { throw usage }; speed = value
                case "--blind": blind = true
                case "--render-only": renderOnly = true
                case "--out": guard let value = rest.popFirst() else { throw usage }; folder = URL(fileURLWithPath: value)
                default:
                    if argument.hasPrefix("--") { throw usage }
                    words.append(argument)
                }
            }
        }
    }

    /// Printed as it goes, unless quiet, and saved as report.txt.
    private struct Report {
        let folder: URL
        var lines: [String] = []
        var quiet = false
        mutating func add(_ line: String) {
            if !quiet { print(line) }
            lines.append(line)
        }
        mutating func add(file: URL, _ what: String) {
            let level = Audio.levels(file)
            add(file.lastPathComponent + String(format: "  %.2fs, peak %.1f dBFS, RMS %.1f dBFS: ", Audio.seconds(file), level.peak, level.rms) + what)
        }
        func save() throws {
            try (lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        }
    }
}

/// Small WAV jobs: length, levels, joining chunks and an offline pass through AVAudioEngine.
private enum Audio {
    static func seconds(_ url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }
    static func levels(_ url: URL) -> (peak: Double, rms: Double) {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let channels = buffer.floatChannelData else { return (-140, -140) }
        var peak: Float = 0, sum: Double = 0
        let frames = Int(buffer.frameLength), count = Int(buffer.format.channelCount), stride = buffer.stride
        for channel in 0..<count {
            for frame in 0..<frames {
                let value = buffer.format.isInterleaved ? channels[0][frame * stride + channel] : channels[channel][frame]
                peak = max(peak, abs(value)); sum += Double(value * value)
            }
        }
        let rms = (sum / Double(max(1, frames * count))).squareRoot()
        return (20 * log10(max(Double(peak), 1e-7)), 20 * log10(max(rms, 1e-7)))
    }
    /// A WAV file is interleaved whatever the buffers are; saying so keeps AVAudioFile from logging it.
    static func wav(_ format: AVAudioFormat) -> [String: Any] {
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        return settings
    }
    static func join(_ files: [URL], into output: URL) throws {
        let first = try AVAudioFile(forReading: files[0])
        let joined = try AVAudioFile(forWriting: output, settings: first.fileFormat.settings,
                                     commonFormat: first.processingFormat.commonFormat, interleaved: first.processingFormat.isInterleaved)
        for url in files {
            let file = try AVAudioFile(forReading: url)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { continue }
            try file.read(into: buffer)
            try joined.write(from: buffer)
        }
    }
    /// Player, then mixer, then output, rendered offline at 48 kHz stereo: the engine path with
    /// nothing live, so no microphone and no voice processing.
    static func renderThroughEngine(_ source: URL, to output: URL) throws {
        let file = try AVAudioFile(forReading: source)
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2) else { return }
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
        try engine.start()
        defer { player.stop(); engine.stop() }
        player.scheduleFile(file, at: nil)
        player.play()
        let rendered = try AVAudioFile(forWriting: output, settings: wav(format), commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount) else { return }
        let total = AVAudioFramePosition(Double(file.length) * format.sampleRate / file.processingFormat.sampleRate)
        while engine.manualRenderingSampleTime < total {
            let frames = min(AVAudioFrameCount(total - engine.manualRenderingSampleTime), buffer.frameCapacity)
            guard try engine.renderOffline(frames, to: buffer) == .success else { break }
            try rendered.write(from: buffer)
        }
    }
}

/// Writes tap buffers to a file from the audio thread.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private let file: AVAudioFile
    init(url: URL, format: AVAudioFormat) throws {
        file = try AVAudioFile(forWriting: url, settings: Audio.wav(format), commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }
    func write(_ buffer: AVAudioPCMBuffer) { lock.lock(); try? file.write(from: buffer); lock.unlock() }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
