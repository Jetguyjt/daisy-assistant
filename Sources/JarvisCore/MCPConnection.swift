import Foundation

/// A local stdio MCP connection. No HTTP endpoint, account tokens, or transcript logs.
public actor MCPConnection {
    public enum Stage: String, Sendable { case notStarted, spawning, initializing, ready, closed, failed }
    private var child: Process?
    private var input: FileHandle?
    private var reader: Task<Void, Never>?
    private var stderrReader: Task<Void, Never>?
    // Bounded rolling stderr buffer for host-side diagnosis. Never contains browser content;
    // adapters write only their own protocol/log lines here.
    private var stderrBuffer = Data()
    private static let stderrCap = 4000
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private var connectionID = UUID()
    public private(set) var stage: Stage = .notStarted
    public init() { }

    public func recentStderr() -> String {
        String(decoding: stderrBuffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func start(executable: URL, arguments: [String], environment: [String: String] = [:]) async throws {
        if child?.isRunning == true { return }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            stage = .failed
            throw JarvisError.message("The connection runtime is missing at \(executable.path). Run its setup script first.")
        }
        stage = .spawning
        let process = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = stdinPipe; process.standardOutput = stdoutPipe; process.standardError = stderrPipe
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, replacement in replacement }
        process.currentDirectoryURL = Configuration.dataDirectory
        do { try process.run() }
        catch {
            stage = .failed
            throw JarvisError.message("Could not launch the connection runtime (\(executable.lastPathComponent)). Check that it is installed and executable.")
        }
        child = process; input = stdinPipe.fileHandleForWriting; buffer = Data(); stderrBuffer = Data()
        connectionID = UUID(); let token = connectionID
        let output = stdoutPipe.fileHandleForReading
        reader = Task.detached { [weak self] in
            while !Task.isCancelled {
                let data = output.availableData
                if data.isEmpty { break }
                await self?.receive(data, token: token)
            }
            await self?.closed(token: token)
        }
        let errors = stderrPipe.fileHandleForReading
        stderrReader = Task.detached { [weak self] in
            while !Task.isCancelled {
                let data = errors.availableData
                if data.isEmpty { break }
                await self?.receiveStderr(data, token: token)
            }
        }
        stage = .initializing
        do {
            _ = try await request(method: "initialize", parameters: .object([
                "protocolVersion": "2025-06-18", "capabilities": .object([:]),
                "clientInfo": .object(["name": "Jarvis", "version": "0.3.0"])
            ]), timeout: 20)
            try notify(method: "notifications/initialized", parameters: .object([:]))
            stage = .ready
        } catch {
            stage = .failed
            let tail = recentStderr()
            await stop()
            if error is CancellationError { throw error }
            if tail.isEmpty {
                throw JarvisError.message("The connection adapter did not complete its handshake. The runtime started but no valid protocol reply arrived.")
            }
            throw JarvisError.message("The connection adapter did not complete its handshake. Adapter reported: \(String(tail.suffix(320)))")
        }
    }
    public func request(method: String, parameters: JSONValue, timeout: Double = 45) async throws -> JSONValue {
        try Task.checkCancellation()
        guard child?.isRunning == true else { throw JarvisError.message("The local connection is not running. Reconnect in Connections.") }
        nextID += 1; let id = nextID
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                deadlines[id] = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(max(0.05, timeout) * 1_000_000_000)) } catch { return }
                    await self?.failRequest(id, error: JarvisError.message("The connection timed out. No result was confirmed; the request was not retried."))
                }
                do {
                    try write(.object(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": parameters]))
                } catch { failRequest(id, error: error) }
            }
        }, onCancel: { Task { await self.cancelRequest(id) } })
    }
    private func notify(method: String, parameters: JSONValue) throws {
        try write(.object(["jsonrpc": "2.0", "method": .string(method), "params": parameters]))
    }
    private func write(_ object: JSONValue) throws {
        guard let input else { throw JarvisError.message("The connection is closed.") }
        let bytes = Data((try object.json() + "\n").utf8)
        guard bytes.count < 100_000 else { throw JarvisError.message("Connection request is too large.") }
        try input.write(contentsOf: bytes)
    }
    private func receive(_ data: Data, token: UUID) {
        guard token == connectionID else { return }
        buffer.append(data)
        guard buffer.count <= 4_000_000 else { closed(token: token); buffer = Data(); child?.terminate(); return }
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer[..<end]; buffer.removeSubrange(...end)
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: line), case .object(let object) = value,
                  case .number(let number) = object["id"], number.isFinite, number >= 0, number < Double(Int.max),
                  number.rounded() == number else { continue }
            let id = Int(number)
            guard let continuation = pending.removeValue(forKey: id) else { continue }
            deadlines.removeValue(forKey: id)?.cancel()
            if object["error"] != nil {
                continuation.resume(throwing: JarvisError.message("The connection rejected the request. Check its access and try a supported action."))
            } else if let result = object["result"] { continuation.resume(returning: result) }
            else { continuation.resume(throwing: JarvisError.message("The connection returned an invalid response.")) }
        }
    }
    private func receiveStderr(_ data: Data, token: UUID) {
        guard token == connectionID else { return }
        stderrBuffer.append(data)
        if stderrBuffer.count > Self.stderrCap {
            stderrBuffer.removeSubrange(0..<(stderrBuffer.count - Self.stderrCap))
        }
    }
    private func failRequest(_ id: Int, error: Error) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }
    private func cancelRequest(_ id: Int) {
        guard pending[id] != nil else { return }
        try? notify(method: "notifications/cancelled", parameters: .object(["requestId": .number(Double(id)), "reason": "User stopped this request"]))
        failRequest(id, error: CancellationError())
    }
    private func closed(token: UUID) {
        guard token == connectionID else { return }
        let waiting = pending; pending = [:]
        deadlines.values.forEach { $0.cancel() }; deadlines = [:]
        waiting.values.forEach { $0.resume(throwing: JarvisError.message("The local connection closed. Reconnect in Connections.")) }
    }
    public func stop() async {
        closed(token: connectionID); connectionID = UUID()
        try? input?.close(); input = nil
        reader?.cancel(); reader = nil
        stderrReader?.cancel(); stderrReader = nil
        if let process = child, process.isRunning {
            process.terminate()
            for _ in 0..<20 {
                if !process.isRunning { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        child = nil; buffer = Data()
        if stage != .failed { stage = .closed }
    }
}
