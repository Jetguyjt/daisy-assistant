import Foundation

/// Executes an explicit binary with argv, never a shell. Cancellation terminates the child.
public enum LocalProcess {
    public static func run(executable: URL, arguments: [String], timeout: TimeInterval = 90) async throws {
        let state = ProcessState()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                state.launch(executable: executable, arguments: arguments, timeout: timeout, continuation: continuation)
            }
            try Task.checkCancellation()
        }, onCancel: { state.cancel() })
    }
    /// Same discipline as run(), but captures stdout with a byte cap for read-only diagnostic
    /// commands (git status, git log). Stderr and stdin are discarded.
    public static func capture(executable: URL, arguments: [String], workingDirectory: URL? = nil,
                               timeout: TimeInterval = 15, maxBytes: Int = 65_536) async throws -> String {
        try Task.checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw DaisyError.message("The binary is missing or not executable at \(executable.path).")
        }
        let state = CaptureState(maxBytes: maxBytes)
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                state.launch(executable: executable, arguments: arguments, workingDirectory: workingDirectory,
                             timeout: timeout, continuation: continuation)
            }
            try Task.checkCancellation()
        }, onCancel: { state.cancel() })
        return state.output()
    }
}

private final class CaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false, timedOut = false, finished = false
    private var timer: DispatchWorkItem?
    private var stdout = Data()
    private let cap: Int
    init(maxBytes: Int) { cap = max(1024, maxBytes) }
    func output() -> String { lock.lock(); defer { lock.unlock() }; return String(decoding: stdout.prefix(cap), as: UTF8.self) }
    func launch(executable: URL, arguments: [String], workingDirectory: URL?, timeout: TimeInterval,
                continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        let child = Process(), pipe = Pipe()
        child.executableURL = executable; child.arguments = arguments
        if let workingDirectory { child.currentDirectoryURL = workingDirectory }
        child.standardOutput = pipe; child.standardError = FileHandle.nullDevice; child.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            guard let self else { return }
            self.lock.lock()
            self.stdout.append(data)
            let overflow = self.stdout.count > self.cap
            self.lock.unlock()
            if overflow { self.process?.terminate() }
        }
        child.terminationHandler = { [self] child in
            lock.lock(); finished = true; timer?.cancel(); timer = nil; process = nil
            let wasCancelled = cancelled; let wasTimedOut = timedOut; let status = child.terminationStatus; lock.unlock()
            child.terminationHandler = nil
            pipe.fileHandleForReading.readabilityHandler = nil
            // Drain any final bytes buffered after termination.
            if let tail = try? pipe.fileHandleForReading.readToEnd(), !tail.isEmpty {
                lock.lock(); stdout.append(tail); lock.unlock()
            }
            if wasCancelled { continuation.resume(throwing: CancellationError()) }
            else if wasTimedOut { continuation.resume(throwing: DaisyError.message("The local process timed out.")) }
            else if status != 0 && !wasTimedOut {
                // Many git commands (e.g. git status in a clean tree, git log with no matches) exit 0
                // but a nonzero code with captured output is still useful; surface both.
                continuation.resume(throwing: DaisyError.message("Local process exited with code \(status)."))
            } else { continuation.resume() }
        }
        do { try child.run(); process = child }
        catch { finished = true; lock.unlock(); continuation.resume(throwing: error); return }
        let deadline = DispatchWorkItem { [weak self] in self?.expire() }
        timer = deadline; lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
    }
    func cancel() { lock.lock(); cancelled = true; stopLocked(); lock.unlock() }
    private func expire() { lock.lock(); timedOut = true; stopLocked(); lock.unlock() }
    private func stopLocked() {
        guard !finished, let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }; self.lock.lock(); defer { self.lock.unlock() }
            if !self.finished, let child = self.process, child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }
}

private final class ProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false
    private var finished = false
    private var timer: DispatchWorkItem?
    func launch(executable: URL, arguments: [String], timeout: TimeInterval, continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        let child = Process(); child.executableURL = executable; child.arguments = arguments
        // Discard stdout/stderr: transcription goes to a private temporary file; no content logs.
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        child.standardInput = FileHandle.nullDevice
        child.terminationHandler = { [self] child in
            lock.lock(); finished = true; timer?.cancel(); timer = nil; process = nil
            let wasCancelled = cancelled; let wasTimedOut = timedOut; lock.unlock()
            child.terminationHandler = nil
            if wasCancelled { continuation.resume(throwing: CancellationError()) }
            else if wasTimedOut { continuation.resume(throwing: DaisyError.message("Local audio processing timed out.")) }
            else if child.terminationStatus != 0 { continuation.resume(throwing: DaisyError.message("Local audio process exited with code \(child.terminationStatus). Check the speech model and binary paths.")) }
            else { continuation.resume() }
        }
        do { try child.run(); process = child }
        catch { finished = true; lock.unlock(); continuation.resume(throwing: error); return }
        let deadline = DispatchWorkItem { [weak self] in self?.expire() }
        timer = deadline; lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
    }
    func cancel() { lock.lock(); cancelled = true; stopLocked(); lock.unlock() }
    private func expire() { lock.lock(); timedOut = true; stopLocked(); lock.unlock() }
    private func stopLocked() {
        guard !finished, let process, process.isRunning else { return }
        process.terminate()
        // A hung decoder must not survive Stop; only signal the still-running owned Process.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }; self.lock.lock(); defer { self.lock.unlock() }
            if !self.finished, let child = self.process, child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }
}

public enum SpeechDecoder {
    public static func transcribe(audio: URL, executable: URL, model: URL) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw DaisyError.message("whisper-cli is missing. Run scripts/setup.sh.") }
        guard FileManager.default.fileExists(atPath: model.path) else { throw DaisyError.message("The Whisper model is missing. Run scripts/download-models.sh.") }
        let base = audio.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        let output = base.appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: output) }
        try await LocalProcess.run(executable: executable, arguments: ["-m", model.path, "-f", audio.path,
            "-l", "en", "-otxt", "-of", base.path, "-nt", "-np", "-t", "4"])
        try Task.checkCancellation()
        let text = try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != "[BLANK_AUDIO]" else { throw DaisyError.message("No speech was detected. Click Record, speak, then click Finish. Check the input meter and microphone in Settings if it stays quiet.") }
        return text
    }
}
