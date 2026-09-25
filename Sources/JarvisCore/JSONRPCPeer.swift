import Foundation

/// JSON-RPC 2.0 with a child process over stdin/stdout, one JSON object per line. Two-way,
/// unlike the MCP client: the child can send notifications and requests of its own, which
/// arrive on `inbound`. Stdout is protocol only; stderr is kept in a small ring for diagnosis.
public actor JSONRPCPeer {
    public enum Inbound: Sendable {
        case notification(method: String, params: JSONValue)
        case request(id: JSONValue, method: String, params: JSONValue)
    }
    /// An error object the other side returned. `message` is theirs; show it only after vetting.
    public struct RemoteError: Error, Sendable {
        public let code: Int
        public let message: String
        public let data: JSONValue?
    }
    public struct Closed: Error, Sendable {}

    private var child: Process?
    private var input: FileHandle?
    private var reader: Task<Void, Never>?
    private var errorReader: Task<Void, Never>?
    private var buffer = Data()
    private var stderrRing = Data()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var generation = UUID()
    private var inboundContinuation: AsyncStream<Inbound>.Continuation?
    public var isRunning: Bool { child?.isRunning == true }
    static let lineLimit = 8_000_000
    static let stderrCap = 8000

    public init() { }

    /// Starts the child and returns the stream of its notifications and requests. The stream
    /// finishes when the child exits or `stop` is called.
    public func start(executable: URL, arguments: [String], environment: [String: String] = [:], directory: URL? = nil) throws -> AsyncStream<Inbound> {
        guard child?.isRunning != true else { throw JarvisError.message("Already running.") }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw JarvisError.message("\(executable.lastPathComponent) is not installed at \(executable.path).")
        }
        let process = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = stdinPipe; process.standardOutput = stdoutPipe; process.standardError = stderrPipe
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, replacement in replacement }
        if let directory { process.currentDirectoryURL = directory }
        let (stream, continuation) = AsyncStream<Inbound>.makeStream(bufferingPolicy: .unbounded)
        generation = UUID(); let token = generation
        process.terminationHandler = { [weak self] _ in Task { await self?.closed(token: token) } }
        do { try process.run() } catch { throw JarvisError.message("Could not start \(executable.lastPathComponent).") }
        child = process; input = stdinPipe.fileHandleForWriting
        buffer = Data(); stderrRing = Data(); inboundContinuation = continuation
        let output = stdoutPipe.fileHandleForReading, errors = stderrPipe.fileHandleForReading
        reader = Task.detached { [weak self] in
            while !Task.isCancelled {
                let data = output.availableData
                if data.isEmpty { break }
                await self?.receive(data, token: token)
            }
            await self?.closed(token: token)
        }
        errorReader = Task.detached { [weak self] in
            while !Task.isCancelled {
                let data = errors.availableData
                if data.isEmpty { break }
                await self?.receiveStderr(data, token: token)
            }
        }
        return stream
    }

    /// Sends a request and waits for its result. With no timeout it waits until the reply, the
    /// child exits, or the calling task is cancelled (the caller decides how to tell the agent).
    public func request(_ method: String, _ params: JSONValue, timeout: TimeInterval? = nil) async throws -> JSONValue {
        try Task.checkCancellation()
        guard child?.isRunning == true else { throw Closed() }
        nextID += 1; let id = nextID
        let token = generation
        let deadline: Task<Void, Never>? = timeout.map { seconds in
            Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(max(0.05, seconds) * 1_000_000_000)) } catch { return }
                await self?.fail(id, JarvisError.message("\(method) timed out."), token: token)
            }
        }
        defer { deadline?.cancel() }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do { try write(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]) }
                catch { fail(id, error, token: token) }
            }
        }, onCancel: { Task { await self.fail(id, CancellationError(), token: token) } })
    }

    public func notify(_ method: String, _ params: JSONValue) throws {
        try write(["jsonrpc": "2.0", "method": .string(method), "params": params])
    }
    public func respond(to id: JSONValue, result: JSONValue) throws {
        try write(["jsonrpc": "2.0", "id": id, "result": result])
    }
    public func respond(to id: JSONValue, errorCode code: Int, message: String) throws {
        try write(["jsonrpc": "2.0", "id": id, "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }

    public func recentStderr() -> String {
        String(decoding: stderrRing, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Closes stdin, then terminates the child if it has not left within `grace` seconds.
    public func stop(grace: TimeInterval = 1.5) async {
        let process = child
        try? input?.close(); input = nil
        if let process, process.isRunning {
            let steps = Int(max(1, grace / 0.05))
            for _ in 0..<steps where process.isRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
            if process.isRunning { process.terminate() }
            for _ in 0..<20 where process.isRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        closed(token: generation)
        reader?.cancel(); reader = nil
        errorReader?.cancel(); errorReader = nil
        child = nil
    }

    // MARK: Plumbing

    private func write(_ object: [String: JSONValue]) throws {
        guard let input, child?.isRunning == true else { throw Closed() }
        let line = try JSONValue.object(object).json() + "\n"
        try input.write(contentsOf: Data(line.utf8))
    }

    private func receive(_ data: Data, token: UUID) {
        guard token == generation else { return }
        buffer.append(data)
        if buffer.count > Self.lineLimit, buffer.firstIndex(of: 10) == nil {
            buffer = Data(); child?.terminate(); return
        }
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer[buffer.startIndex..<end]
            buffer.removeSubrange(buffer.startIndex...end)
            guard !line.isEmpty, let value = try? JSONDecoder().decode(JSONValue.self, from: line),
                  case .object(let object) = value else { continue }
            dispatch(object)
        }
    }

    private func dispatch(_ object: [String: JSONValue]) {
        let method = object["method"]?.stringValue
        let id = object["id"]
        if let method {
            let params = object["params"] ?? .object([:])
            if let id, id != .null { inboundContinuation?.yield(.request(id: id, method: method, params: params)) }
            else { inboundContinuation?.yield(.notification(method: method, params: params)) }
            return
        }
        guard case .number(let number) = id, number.rounded() == number, abs(number) < 1e15 else { return }
        guard let continuation = pending.removeValue(forKey: Int(number)) else { return }
        if case .object(let error) = object["error"] {
            let code: Int = { if case .number(let value) = error["code"] { return Int(value) }; return 0 }()
            continuation.resume(throwing: RemoteError(code: code, message: error["message"]?.stringValue ?? "", data: error["data"]))
        } else {
            continuation.resume(returning: object["result"] ?? .null)
        }
    }

    private func receiveStderr(_ data: Data, token: UUID) {
        guard token == generation else { return }
        stderrRing.append(data)
        if stderrRing.count > Self.stderrCap { stderrRing.removeSubrange(0..<(stderrRing.count - Self.stderrCap)) }
    }

    private func fail(_ id: Int, _ error: Error, token: UUID) {
        guard token == generation else { return }
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func closed(token: UUID) {
        guard token == generation else { return }
        let waiting = pending; pending = [:]
        waiting.values.forEach { $0.resume(throwing: Closed()) }
        inboundContinuation?.finish(); inboundContinuation = nil
    }
}

extension JSONValue: ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

public extension JSONValue {
    subscript(key: String) -> JSONValue? { if case .object(let object) = self { return object[key] }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let values) = self { return values }; return nil }
    var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
    var numberValue: Double? { if case .number(let value) = self { return value }; return nil }
}
