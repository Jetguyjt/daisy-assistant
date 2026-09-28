import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Apple's on-device recognizer: SpeechAnalyzer with SpeechTranscriber, new in macOS 26. Its model
/// comes from Apple through AssetInventory, not from Hugging Face. Everything is behind availability
/// checks so the macOS 14 build still works; there the state says why and Whisper does the work.
///
/// Unlike the old SFSpeechRecognizer (which returned nothing on test audio here, see VALIDATION.md),
/// this one was checked on this Mac: a `say` clip of "Hey Daisy, what time is it?" came back exact,
/// and streamed at real time, "Hey, Daisy" showed up as a partial 1.1 s into the clip.
public enum AppleSpeech {
    /// Words the recognizer should lean toward.
    static let vocabulary = ["Daisy", "Hey Daisy"]

    /// Where Apple's recognizer stands for a language. Never downloads anything.
    public static func state(locale identifier: String) async -> AppleSpeechState {
        guard #available(macOS 26.0, *) else { return .unavailable("it needs macOS 26.") }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied, .restricted:
            return .unavailable("Speech Recognition is turned off for Daisy in System Settings → Privacy & Security.")
        default: break
        }
        guard SpeechTranscriber.isAvailable else { return .unavailable("this Mac doesn't offer it.") }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
            return .unavailable("it doesn't support \(identifier).")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: return .ready
        case .downloading: return .downloading(nil)
        case .supported: return .needsDownload
        case .unsupported: return .unavailable("its model for \(identifier) isn't offered on this Mac.")
        @unknown default: return .unavailable("Apple reported a model state Daisy doesn't know.")
        }
    }

    /// Whether the model for a language is already on this Mac (installed for some app), so that
    /// `install` only has to reserve it for Daisy.
    public static func onDisk(locale identifier: String) async -> Bool {
        guard #available(macOS 26.0, *),
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else { return false }
        return await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    /// Asks Apple to install the model for a language, or just to reserve it for Daisy when it's
    /// already on disk (on this Mac that took half a second and downloaded nothing).
    public static func install(locale identifier: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard #available(macOS 26.0, *) else { throw DaisyError.message("Apple's recognizer needs macOS 26.") }
        let transcriber = SpeechTranscriber(locale: try await supported(identifier), preset: .transcription)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
        let observation = request.progress.observe(\.fractionCompleted) { reported, _ in progress(reported.fractionCompleted) }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
    }

    static func recognizer(locale identifier: String) async throws -> any OnDeviceRecognizer {
        guard #available(macOS 26.0, *) else { throw DaisyError.message("Apple's recognizer needs macOS 26.") }
        return AppleSpeechRecognizer(locale: try await supported(identifier))
    }

    @available(macOS 26.0, *)
    private static func supported(_ identifier: String) async throws -> Locale {
        // Locale equality is picky ("en_US" is not "en-US"), so ask for Apple's own equivalent.
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
            throw DaisyError.message("Apple's recognizer doesn't support \(identifier).")
        }
        return locale
    }

    @available(macOS 26.0, *)
    static func analyzer(for transcriber: SpeechTranscriber) async throws -> SpeechAnalyzer {
        // Lingering keeps the model loaded for a while between utterances, so the next one starts fast.
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
        let context = AnalysisContext()
        context.contextualStrings[.general] = vocabulary
        try await analyzer.setContext(context)
        return analyzer
    }
}

@available(macOS 26.0, *)
final class AppleSpeechRecognizer: OnDeviceRecognizer {
    let locale: Locale
    init(locale: Locale) { self.locale = locale }

    func transcribe(file: URL) async throws -> String {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        let analyzer = try await AppleSpeech.analyzer(for: transcriber)
        let audio = try AVAudioFile(forReading: file)
        let collector = Task { () throws -> String in
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text = joinTranscript(text, String(result.text.characters))
            }
            return text
        }
        do {
            try await withTaskCancellationHandler {
                if let last = try await analyzer.analyzeSequence(from: audio) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
            return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    func stream(onUpdate: @escaping @Sendable (String) -> Void) async throws -> any SpeechStream {
        try await AppleSpeechStream.start(locale: locale, onUpdate: onUpdate)
    }

    func warmUp() async {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        guard let analyzer = try? await AppleSpeech.analyzer(for: transcriber),
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return }
        try? await analyzer.prepareToAnalyze(in: format)
        await analyzer.cancelAndFinishNow()
    }
}

/// One utterance fed to SpeechAnalyzer as it's spoken. Partial results come back through
/// `onUpdate` as the whole text so far: the finalized part plus Apple's current guess.
@available(macOS 26.0, *)
final class AppleSpeechStream: SpeechStream, @unchecked Sendable {
    private static let source = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let format: AVAudioFormat
    private let converter: AVAudioConverter?
    private let collector: Task<String, Error>
    private let lock = NSLock()
    private var position: Int64 = 0
    private var closed = false

    private init(analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat,
                 converter: AVAudioConverter?, collector: Task<String, Error>) {
        self.analyzer = analyzer; self.input = input; self.format = format; self.converter = converter; self.collector = collector
    }

    static func start(locale: Locale, onUpdate: @escaping @Sendable (String) -> Void) async throws -> AppleSpeechStream {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        let analyzer = try await AppleSpeech.analyzer(for: transcriber)
        // Nil means the model isn't installed. On this Mac it asks for exactly what the mic path
        // makes, 16 kHz mono Int16, so there's usually nothing to convert.
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw DaisyError.message("Apple's speech model isn't installed yet.")
        }
        let direct = format.commonFormat == .pcmFormatInt16 && format.sampleRate == 16000 && format.channelCount == 1
        let converter = direct ? nil : AVAudioConverter(from: source, to: format)
        guard direct || converter != nil else { throw DaisyError.message("Apple's recognizer wants audio Daisy can't convert.") }
        try await analyzer.prepareToAnalyze(in: format)
        let (sequence, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let collector = Task { () throws -> String in
            var finalized = ""
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    finalized = joinTranscript(finalized, text)
                    onUpdate(finalized)
                } else {
                    onUpdate(joinTranscript(finalized, text))
                }
            }
            return finalized
        }
        do { try await analyzer.start(inputSequence: sequence) }
        catch { collector.cancel(); input.finish(); await analyzer.cancelAndFinishNow(); throw error }
        return AppleSpeechStream(analyzer: analyzer, input: input, format: format, converter: converter, collector: collector)
    }

    func append(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        guard !closed, let buffer = buffer(for: samples) else { return }
        input.yield(AnalyzerInput(buffer: buffer, bufferStartTime: CMTime(value: position, timescale: 16000)))
        position += Int64(samples.count)
    }

    func finish() async throws -> String {
        lock.withLock { closed = true }
        input.finish()
        let analyzer = self.analyzer, collector = self.collector
        do {
            return try await withTimeout(10, "Apple's recognizer took too long to finish.") {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    func cancel() async {
        lock.withLock { closed = true }
        input.finish()
        collector.cancel()
        await analyzer.cancelAndFinishNow()
    }

    /// Each input gets its own buffer: the analyzer may still hold the previous one.
    private func buffer(for samples: [Int16]) -> AVAudioPCMBuffer? {
        guard let pcm = AVAudioPCMBuffer(pcmFormat: Self.source, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = pcm.int16ChannelData?[0] else { return nil }
        pcm.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        guard let converter else { return pcm }
        let capacity = AVAudioFrameCount(Double(samples.count) * format.sampleRate / 16000) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true; outStatus.pointee = .haveData; return pcm
        }
        return status == .error || converted.frameLength == 0 ? nil : converted
    }
}
