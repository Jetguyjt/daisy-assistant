import Foundation

/// Speech to text for the whole app. Apple's on-device recognizer (macOS 26) goes first when its
/// model is installed; the owned whisper-server child is the fallback, and one-shot whisper-cli is
/// the fallback's fallback. whisper-server loads the Whisper model once instead of per utterance.
/// Same shape as LocalRuntime for the child: preflight, coalesced startup, shutdown only of what we
/// started, and a watchdog so it can't outlive the app.
public actor SpeechRuntime {
    public static let endpoint = URL(string: "http://127.0.0.1:11437")!
    private var process: Process?
    private var startup: Task<Void, Error>?
    private let session: URLSession
    private let children: ChildProcesses
    private var settings = SpeechInputSettings()

    // Apple's recognizer and how it has been doing this session.
    private var apple: (any OnDeviceRecognizer)?
    private var appleState: AppleSpeechState = .unknown
    private var appleChecked: Date?
    private var appleCheck: Task<Void, Never>?
    private var install: Task<Void, Never>?
    private var appleBenchedUntil: Date?
    /// Apple has returned text at least once, so its silence can be trusted.
    private var appleProven = false
    private var appleMisses = 0
    private var appleFailures = 0

    public init() { self.init(children: .shared) }
    public init(children: ChildProcesses) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
        self.children = children
    }

    /// New settings. Changing the recognizer or its language starts the Apple checks over.
    public func configure(_ settings: SpeechInputSettings) {
        let changed = settings.usesAppleSpeech != self.settings.usesAppleSpeech || settings.localeIdentifier != self.settings.localeIdentifier
        self.settings = settings
        guard changed else { return }
        apple = nil; appleState = .unknown; appleChecked = nil; appleBenchedUntil = nil
        appleProven = false; appleMisses = 0; appleFailures = 0
    }

    public var status: SpeechRecognitionStatus {
        SpeechRecognitionStatus(active: apple != nil && appleState == .ready ? .apple : .whisper, apple: appleState)
    }

    /// Gets the recognizer that will be used ready ahead of the first utterance: Apple's model
    /// loaded (or installing, if Apple still has to fetch it), otherwise whisper-server started.
    public func prepare(configuration: Configuration) async {
        children.sweepOnce()
        if let apple = await appleRecognizer() {
            await apple.warmUp()
        } else {
            try? await ensureRunning(configuration: configuration)
        }
    }

    // MARK: Transcription

    /// One finished recording. Apple, then whisper-server, then whisper-cli.
    public func transcribe(audio: URL, configuration: Configuration) async throws -> String {
        if let apple = await appleRecognizer() {
            var heard: String?
            do {
                heard = try await withTimeout(30, "Apple's recognizer took too long.") { try await apple.transcribe(file: audio) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                note(.failed(error.localizedDescription))
            }
            if let heard {
                if !heard.isEmpty { note(.heard); return heard }
                // Silence from a recognizer that has never heard anything might be the recognizer.
                guard !appleProven else { throw Self.noSpeech }
                let whisper = (try? await whisperText(audio: audio, configuration: configuration)) ?? ""
                note(.empty(whisperHeard: !whisper.isEmpty))
                guard !whisper.isEmpty else { throw Self.noSpeech }
                return whisper
            }
        }
        let text = try await whisperText(audio: audio, configuration: configuration)
        guard !text.isEmpty else { throw Self.noSpeech }
        return text
    }

    /// One utterance as it's spoken. With Apple, `onUpdate` gets partial transcripts and a copy of
    /// the audio is kept for Whisper in case Apple fails. Without it, Whisper hears it all at the end.
    public func stream(configuration: Configuration, onUpdate: @escaping @Sendable (String) -> Void) async throws -> any SpeechStream {
        let backup = RecordedSpeechStream { [weak self] url in
            guard let self else { throw CancellationError() }
            return try await self.whisperText(audio: url, configuration: configuration)
        }
        guard let apple = await appleRecognizer() else { return backup }
        do {
            let primary = try await withTimeout(5, "Apple's recognizer didn't start.") { try await apple.stream(onUpdate: onUpdate) }
            return FallbackSpeechStream(primary: primary, backup: backup, retryEmpty: !appleProven) { [weak self] outcome in
                await self?.note(outcome)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            note(.failed(error.localizedDescription))
            return backup
        }
    }

    private static var noSpeech: DaisyError {
        .message("No speech was detected. Say a few words, then pause. Check the input meter and microphone in Settings if it stays quiet.")
    }

    /// Whisper's text for a file, empty when it heard nothing. Server first, one-shot CLI second.
    private func whisperText(audio: URL, configuration: Configuration) async throws -> String {
        let text: String
        do {
            try await ensureRunning(configuration: configuration)
            text = try await transcribe(audio: audio)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            do {
                text = try await SpeechDecoder.transcribe(audio: audio, executable: URL(fileURLWithPath: configuration.whisperExecutable),
                                                         model: URL(fileURLWithPath: configuration.whisperModel))
            } catch let error as DaisyError where error.localizedDescription.hasPrefix("No speech was detected") {
                return ""
            }
        }
        return text.contains("[BLANK_AUDIO]") ? "" : text
    }

    // MARK: Apple

    /// Apple's recognizer when it can be used right now; nil means Whisper. Checks at most every
    /// 30 seconds, and starts Apple's model install when the language is supported but not set up.
    private func appleRecognizer() async -> (any OnDeviceRecognizer)? {
        guard settings.usesAppleSpeech else {
            apple = nil; appleState = .unavailable("it's turned off in Settings.")
            return nil
        }
        if let until = appleBenchedUntil, until > Date() { return nil }
        if let apple, appleState == .ready { return apple }
        if install != nil { return nil }
        if let checked = appleChecked, Date().timeIntervalSince(checked) < 30 { return nil }
        if appleCheck == nil {
            appleCheck = Task { await self.checkApple() }
        }
        await appleCheck?.value
        return appleState == .ready ? apple : nil
    }

    private func checkApple() async {
        defer { appleCheck = nil }
        appleChecked = Date()
        let locale = settings.localeIdentifier
        let state = await AppleSpeech.state(locale: locale)
        switch state {
        case .ready:
            do {
                apple = try await AppleSpeech.recognizer(locale: locale)
                appleState = .ready; appleBenchedUntil = nil; appleFailures = 0
            } catch {
                appleState = .unavailable(error.localizedDescription)
            }
        case .needsDownload, .downloading:
            startInstall(locale: locale)
        case .unavailable, .unknown:
            apple = nil; appleState = state
        }
    }

    /// Apple fetches the model itself (from Apple, not Hugging Face). Whisper is used meanwhile.
    private func startInstall(locale: String) {
        guard install == nil else { return }
        appleState = .downloading(nil)
        install = Task {
            do {
                try await AppleSpeech.install(locale: locale) { fraction in Task { await self.installProgress(fraction) } }
                self.installFinished(nil)
            } catch {
                self.installFinished(error)
            }
        }
    }
    private func installProgress(_ fraction: Double) {
        if case .downloading = appleState { appleState = .downloading(fraction) }
    }
    private func installFinished(_ error: Error?) {
        install = nil
        if let error {
            appleState = .unavailable("its model didn't install (\(error.localizedDescription)).")
            appleChecked = Date()
        } else {
            appleState = .unknown; appleChecked = nil
        }
    }

    /// Keeps score. Two failures in a row bench Apple for five minutes; three empty results where
    /// Whisper heard speech, before Apple has ever heard anything, bench it for the session.
    private func note(_ outcome: FallbackSpeechStream.Outcome) {
        switch outcome {
        case .heard:
            appleProven = true; appleMisses = 0; appleFailures = 0
        case .empty(let whisperHeard):
            guard whisperHeard, !appleProven else { return }
            appleMisses += 1
            if appleMisses >= 3 { bench("it returned nothing three times where Whisper heard speech.", for: .infinity) }
        case .failed(let reason):
            appleFailures += 1
            if appleFailures >= 2 { bench("it failed twice in a row (\(reason))", for: 300) }
        }
    }
    private func bench(_ reason: String, for seconds: TimeInterval) {
        apple = nil
        appleState = .unavailable(reason)
        appleBenchedUntil = seconds.isInfinite ? .distantFuture : Date().addingTimeInterval(seconds)
        appleChecked = nil
        appleFailures = 0
    }

    // MARK: whisper-server

    /// Homebrew installs whisper-server beside whisper-cli.
    public static func serverExecutable(near cli: String) -> URL {
        URL(fileURLWithPath: cli).deletingLastPathComponent().appendingPathComponent("whisper-server")
    }
    public func isReachable() async -> Bool {
        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 1
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }
    public func ensureRunning(configuration: Configuration) async throws {
        try Task.checkCancellation()
        // A server left behind by a Daisy that crashed would otherwise answer here and never be stopped.
        children.sweepOnce()
        if await isReachable() { return }
        if let startup { try await startup.value; return }
        let server = Self.serverExecutable(near: configuration.whisperExecutable)
        guard FileManager.default.isExecutableFile(atPath: server.path) else {
            throw DaisyError.message("whisper-server is not installed next to whisper-cli.")
        }
        guard FileManager.default.fileExists(atPath: configuration.whisperModel) else {
            throw DaisyError.message("The Whisper model is missing. Run scripts/download-models.sh.")
        }
        if process?.isRunning != true {
            let child = Process()
            child.executableURL = server
            child.arguments = ["-m", configuration.whisperModel, "--host", "127.0.0.1", "--port", "11437", "-t", "4", "-l", "en"]
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try children.launch(child, label: "whisper-server")
            process = child
        }
        let task = Task {
            for _ in 0..<80 {
                try Task.checkCancellation()
                if await self.isReachable() { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw DaisyError.message("whisper-server did not become ready.")
        }
        startup = task
        defer { startup = nil }
        try await task.value
    }
    /// One multipart POST to whisper-server; it answers `{"text": "..."}`.
    public func transcribe(audio: URL) async throws -> String {
        try Task.checkCancellation()
        let boundary = "daisy-\(UUID().uuidString)"
        var request = URLRequest(url: Self.endpoint.appendingPathComponent("inference"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("response_format", "json")
        field("temperature", "0.0")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"input.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(try Data(contentsOf: audio))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else {
            throw DaisyError.message("whisper-server returned an invalid response.")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func shutdown() async {
        install?.cancel(); install = nil
        apple = nil
        startup?.cancel(); startup = nil
        if let child = process, child.isRunning {
            child.terminate()
            for _ in 0..<20 {
                if !child.isRunning { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        process = nil
    }
}
