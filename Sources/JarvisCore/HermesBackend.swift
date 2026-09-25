import Foundation

/// Hermes Agent over ACP: JSON-RPC on the stdio of `hermes-acp`. Hermes owns the model, the tool
/// loop, sessions, memory, skills and approvals; this actor only turns its protocol into
/// `AgentEvent`s. Provider sign-in stays inside Hermes; nothing here reads or stores credentials.
public actor HermesBackend: AgentBackend {
    public struct Settings: Sendable {
        /// nil looks in the usual install locations.
        public var executable: URL?
        /// Where Hermes runs tools from. A code repo here would switch Hermes into coding mode.
        public var workingDirectory: URL
        /// Remembers the session id between launches.
        public var sessionFile: URL
        public var environment: [String: String]
        public init(executable: URL? = nil, workingDirectory: URL, sessionFile: URL, environment: [String: String] = [:]) {
            self.executable = executable; self.workingDirectory = workingDirectory
            self.sessionFile = sessionFile; self.environment = environment
        }
    }

    public static let installCommand = "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash"
    public static let signInCommand = "hermes auth add openai-codex"

    private let settings: Settings
    private let peer = JSONRPCPeer()
    private var inbound: Task<Void, Never>?
    private var link: AgentLink = .starting
    private var connecting: Task<AgentLink, Never>?
    private var sessionID: String?
    private var modelDetail: String?
    private var replay: [AgentMessage] = []
    private var collectingReplay = false
    // The prompt in flight. `turnID` keeps a cancelled turn that ends late from clearing the next one.
    private var turnID: UUID?
    private var turn: AsyncThrowingStream<AgentEvent, Error>.Continuation?
    private var turnSession: String?
    private var prompt: Task<JSONValue, Error>?
    private var produced = false
    private var toolTitles: [String: (title: String, detail: String?)] = [:]
    private var approvals: [String: (request: JSONValue, options: [AgentApproval.Option])] = [:]

    public init(settings: Settings) { self.settings = settings }
    public nonisolated var name: String { "Hermes" }

    // MARK: Connection

    public func connect() async -> AgentLink {
        if case .ready = link, sessionID != nil, await peer.isRunning { return link }
        if let connecting { return await connecting.value }
        let task = Task { await self.establish() }
        connecting = task
        let result = await task.value
        connecting = nil
        return result
    }

    private func establish() async -> AgentLink {
        link = .starting
        guard let executable = locate() else {
            link = .needsSetup(AgentSetupIssue(title: "Hermes isn't installed",
                detail: "Jarvis runs on Hermes Agent. Install it, sign in, then reopen Jarvis.", command: Self.installCommand))
            return link
        }
        if !(await peer.isRunning) {
            do {
                let messages = try await peer.start(executable: executable, arguments: [], environment: settings.environment,
                                                    directory: settings.workingDirectory)
                inbound?.cancel()
                inbound = Task { [weak self] in
                    for await message in messages { await self?.handle(message) }
                    await self?.peerClosed()
                }
                let hello = try await peer.request("initialize", [
                    "protocolVersion": .number(1),
                    "clientCapabilities": ["fs": ["readTextFile": .bool(false), "writeTextFile": .bool(false)], "terminal": .bool(false)],
                    "clientInfo": ["name": "jarvis", "title": "Jarvis", "version": "0.4.0"]
                ], timeout: 45)
                // Hermes lists its provider as an auth method only when that provider's credentials resolve.
                let methods = hello["authMethods"]?.arrayValue ?? []
                if !methods.contains(where: { ($0["id"]?.stringValue ?? "hermes-setup") != "hermes-setup" }) {
                    await stopPeer()
                    link = .needsSetup(AgentSetupIssue(title: "Sign in to ChatGPT in Hermes",
                        detail: "Hermes has no working model provider yet. Run this in Terminal, finish the device login, then press Retry.",
                        command: Self.signInCommand))
                    return link
                }
            } catch {
                let tail = await peer.recentStderr()
                await stopPeer()
                link = .offline("Hermes didn't start" + (tail.isEmpty ? "." : ": " + String(tail.suffix(200))))
                return link
            }
        }
        do {
            if sessionID == nil, let saved = savedSession() { try await load(saved) }
            if sessionID == nil { try await openSession() }
            link = .ready(detail: modelDetail)
        } catch let error as JSONRPCPeer.RemoteError {
            link = Self.classify(error)
        } catch {
            link = .offline(Self.describe(error).errorDescription ?? "Hermes is not responding.")
        }
        return link
    }

    /// An explicit path is used as given. Otherwise the venv entry point comes first: the
    /// ~/.local/bin shim runs through the full CLI, which is slower and can print to stdout.
    private func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = settings.executable.map { [$0] } ?? [home.appendingPathComponent(".hermes/hermes-agent/venv/bin/hermes-acp"),
                                                             home.appendingPathComponent(".local/bin/hermes-acp")]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Replayed history arrives as updates just before the reply; collection stays open until the
    /// first turn so late chunks aren't lost.
    private func load(_ id: String) async throws {
        replay = []; collectingReplay = true
        let result = try await peer.request("session/load", ["sessionId": .string(id), "cwd": .string(settings.workingDirectory.path),
                                                            "mcpServers": .array([])], timeout: 90)
        // An unknown id comes back as an empty success, so only models or modes prove it loaded.
        guard result["models"] != nil || result["modes"] != nil else { replay = []; collectingReplay = false; return }
        sessionID = id
        modelDetail = Self.model(from: result)
        try? await Task.sleep(nanoseconds: 60_000_000)
    }

    private func openSession() async throws {
        let result = try await peer.request("session/new", ["cwd": .string(settings.workingDirectory.path), "mcpServers": .array([])], timeout: 90)
        guard let id = result["sessionId"]?.stringValue, !id.isEmpty else { throw AgentFailure.failed("Hermes didn't open a session.") }
        sessionID = id; replay = []; collectingReplay = false
        modelDetail = Self.model(from: result)
        try? FileManager.default.createDirectory(at: settings.sessionFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(id.utf8).write(to: settings.sessionFile, options: .atomic)
    }

    private func savedSession() -> String? {
        guard let data = try? Data(contentsOf: settings.sessionFile) else { return nil }
        let id = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty || id.count > 200 ? nil : id
    }

    // MARK: Turns

    public nonisolated func send(_ text: String) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.run(text, continuation) }
            continuation.onTermination = { termination in
                guard case .cancelled = termination else { return }
                task.cancel()
                Task { await self.cancel() }
            }
        }
    }

    private func run(_ text: String, _ continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation) async {
        await settle()
        let state = await connect()
        guard case .ready = state, let session = sessionID else {
            continuation.finish(throwing: Self.failure(for: state)); return
        }
        if Task.isCancelled { continuation.finish(throwing: CancellationError()); return }
        collectingReplay = false
        let id = UUID()
        turnID = id; turn = continuation; turnSession = session; produced = false; toolTitles = [:]
        let params: JSONValue = ["sessionId": .string(session), "prompt": .array([["type": "text", "text": .string(text)]])]
        let peer = self.peer
        let request = Task { try await peer.request("session/prompt", params) }
        prompt = request
        do {
            let result = try await request.value
            let reason = result["stopReason"]?.stringValue ?? "end_turn"
            // "refusal" with nothing said means Hermes no longer knows this session.
            if reason == "refusal", !produced, turnID == id { sessionID = nil }
            finishTurn(id, request)
            continuation.yield(.finished(stopReason: reason))
            continuation.finish()
        } catch {
            finishTurn(id, request)
            continuation.finish(throwing: Self.describe(error))
        }
    }

    private func finishTurn(_ id: UUID, _ request: Task<JSONValue, Error>) {
        if prompt == request { prompt = nil }
        guard turnID == id else { return }
        turnID = nil; turn = nil; turnSession = nil
        for pending in approvals.values { Task { [peer] in try? await peer.respond(to: pending.request, result: ["outcome": ["outcome": "cancelled"]]) } }
        approvals = [:]
    }

    /// Waits for a cancelled prompt to wind down so the next one isn't folded into it.
    private func settle() async {
        guard let previous = prompt else { return }
        let deadline = Task { try? await Task.sleep(nanoseconds: 6_000_000_000); previous.cancel() }
        _ = try? await previous.value
        deadline.cancel()
    }

    public func cancel() async {
        guard let session = turnSession, let request = prompt else { return }
        try? await peer.notify("session/cancel", ["sessionId": .string(session)])
        for pending in approvals.values { try? await peer.respond(to: pending.request, result: ["outcome": ["outcome": "cancelled"]]) }
        approvals = [:]
        // A stop can leave a Hermes session stuck; if the prompt hasn't ended in a few seconds,
        // give up on it and open a fresh session next time.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            await self?.abandon(request)
        }
    }

    private func abandon(_ request: Task<JSONValue, Error>) {
        guard prompt == request else { return }
        request.cancel()
        sessionID = nil
    }

    public func resolve(approval id: String, optionID: String?) async {
        guard let pending = approvals.removeValue(forKey: id) else { return }
        let outcome: JSONValue = optionID.map { ["outcome": "selected", "optionId": .string($0)] } ?? ["outcome": "cancelled"]
        try? await peer.respond(to: pending.request, result: ["outcome": outcome])
        let allowed = optionID.flatMap { choice in pending.options.first { $0.id == choice } }?.allows ?? false
        turn?.yield(.approvalResolved(id: id, allowed: allowed))
    }

    public func newSession() async {
        if prompt != nil { await cancel(); await settle() }
        guard case .ready = await connect() else { return }
        do { try await openSession(); link = .ready(detail: modelDetail) }
        catch { sessionID = nil }
    }

    public func history() async -> [AgentMessage] { replay }

    public func shutdown() async {
        if prompt != nil { await cancel() }
        await stopPeer()
    }

    private func stopPeer() async {
        inbound?.cancel(); inbound = nil
        await peer.stop()
    }

    private func peerClosed() {
        link = .offline("Hermes stopped.")
        turn?.finish(throwing: AgentFailure.offline("Hermes stopped unexpectedly. Try again."))
        turnID = nil; turn = nil; turnSession = nil; approvals = [:]
    }

    // MARK: Inbound

    private func handle(_ message: JSONRPCPeer.Inbound) async {
        switch message {
        case .notification(let method, let params):
            guard method == "session/update" else { return }
            let update = params["update"] ?? .null
            let kind = update["sessionUpdate"]?.stringValue ?? ""
            if collectingReplay { collect(kind, update); return }
            guard let turn, params["sessionId"]?.stringValue == turnSession else { return }
            switch kind {
            case "agent_message_chunk":
                if let text = update["content"]?["text"]?.stringValue, !text.isEmpty { produced = true; turn.yield(.text(text)) }
            case "tool_call", "tool_call_update":
                let id = update["toolCallId"]?.stringValue ?? UUID().uuidString
                let toolKind = update["kind"]?.stringValue
                var label = toolTitles[id] ?? (title: "Working", detail: nil)
                if let raw = update["title"]?.stringValue { label = Self.describeTool(title: raw, kind: toolKind) }
                toolTitles[id] = label
                let state = Self.state(update["status"]?.stringValue) ?? (kind == "tool_call" ? .running : nil)
                if let state { turn.yield(.tool(AgentToolActivity(id: id, title: label.title, detail: label.detail, kind: toolKind, state: state))) }
            default:
                break   // thoughts stay hidden; plans, usage and command lists aren't shown
            }
        case .request(let id, let method, let params):
            if method == "session/request_permission" { await permission(id, params) }
            else { try? await peer.respond(to: id, errorCode: -32601, message: "Jarvis doesn't provide \(method).") }
        }
    }

    private func collect(_ kind: String, _ update: JSONValue) {
        let role = kind == "user_message_chunk" ? "user" : kind == "agent_message_chunk" ? "assistant" : nil
        guard let role, let text = update["content"]?["text"]?.stringValue, !text.isEmpty else { return }
        if replay.last?.role == role { replay[replay.count - 1].text += text }
        else { replay.append(AgentMessage(role: role, text: text)) }
    }

    private func permission(_ id: JSONValue, _ params: JSONValue) async {
        guard let turn, params["sessionId"]?.stringValue == turnSession else {
            try? await peer.respond(to: id, result: ["outcome": ["outcome": "cancelled"]]); return
        }
        let approval = Self.approval(from: params, id: UUID().uuidString)
        approvals[approval.id] = (id, approval.options)
        turn.yield(.approval(approval))
    }

    // MARK: Translation

    static func model(from result: JSONValue) -> String? {
        guard let current = result["models"]?["currentModelId"]?.stringValue, !current.isEmpty else { return nil }
        let parts = current.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return current }
        let provider = parts[0] == "openai-codex" ? "ChatGPT" : parts[0]
        return "\(parts[1]) · \(provider)"
    }

    static func state(_ status: String?) -> AgentToolActivity.State? {
        switch status {
        case "pending": return .pending
        case "in_progress": return .running
        case "completed": return .completed
        case "failed": return .failed
        default: return nil
        }
    }

    static func classify(_ error: JSONRPCPeer.RemoteError) -> AgentLink {
        let details = error.data?["details"]?.stringValue ?? error.message
        let lower = details.lowercased()
        if lower.contains("no llm provider") || lower.contains("hermes model") {
            return .needsSetup(AgentSetupIssue(title: "Pick a model provider in Hermes",
                detail: "Choose “ChatGPT or Codex Subscription”, finish the sign-in, then press Retry.", command: "hermes model"))
        }
        if lower.contains("auth") || lower.contains("login") || lower.contains("credential") || lower.contains("token") {
            return .needsSetup(AgentSetupIssue(title: "Sign in to ChatGPT in Hermes",
                detail: "Hermes couldn't use its saved sign-in. Run this in Terminal, then press Retry.", command: signInCommand))
        }
        return .offline(String(details.prefix(240)))
    }

    static func failure(for link: AgentLink) -> AgentFailure {
        switch link {
        case .needsSetup(let issue): return .setup(issue)
        case .offline(let reason): return .offline(reason)
        default: return .offline("Hermes isn't ready yet.")
        }
    }

    static func describe(_ error: Error) -> AgentFailure {
        if let failure = error as? AgentFailure { return failure }
        if let remote = error as? JSONRPCPeer.RemoteError {
            if case .needsSetup(let issue) = classify(remote) { return .setup(issue) }
            let details = remote.data?["details"]?.stringValue ?? remote.message
            return .failed(details.isEmpty ? "Hermes couldn't finish that." : String(details.prefix(240)))
        }
        if error is JSONRPCPeer.Closed { return .offline("Hermes stopped unexpectedly. Try again.") }
        if error is CancellationError { return .failed("Stopped.") }
        return .failed(error.localizedDescription)
    }

    /// Plain words for the HUD: "Searching the web", "Reading resume.pdf". Commands stay hidden.
    static func describeTool(title: String, kind: String?) -> (title: String, detail: String?) {
        let parts = title.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let head = parts.first?.lowercased() ?? ""
        let rest = parts.count > 1 ? parts[1] : ""
        let file: String? = rest.isEmpty ? nil : URL(fileURLWithPath: rest).lastPathComponent
        switch head {
        case "terminal", "process", "process_manage": return (describeCommand(rest), nil)
        case "read", "read_file": return ("Reading a file", file)
        case "write", "write_file": return ("Writing a file", file)
        case "search", "search_files", "search files", "find": return ("Searching your files", rest.isEmpty ? nil : rest)
        case "web search", "web_search": return ("Searching the web", rest.isEmpty ? nil : rest)
        case "web extract", "web_extract", "fetch": return ("Reading a web page", nil)
        case "memory": return ("Updating memory", nil)
        case "session_search", "session search": return ("Searching past conversations", nil)
        case "skill_view", "skills_list", "skill view", "skills list": return ("Checking skills", nil)
        case "skill_manage": return ("Updating a skill", nil)
        case "delegate_task": return ("Handing off a subtask", nil)
        case "execute_code": return ("Running code", nil)
        case "todo", "todo_list": return ("Planning", nil)
        case "vision_analyze": return ("Looking at an image", nil)
        default:
            if head.hasPrefix("patch") { return ("Editing a file", file) }
            if head.hasPrefix("memory") { return ("Updating memory", nil) }
            if head.hasPrefix("browser") { return ("Using the browser", nil) }
            switch kind {
            case "read": return ("Reading", nil)
            case "search": return ("Searching", nil)
            case "fetch": return ("Fetching from the web", nil)
            case "edit": return ("Editing a file", nil)
            case "execute": return ("Working", nil)
            default:
                let words = title.replacingOccurrences(of: "_", with: " ")
                return (words.isEmpty ? "Working" : words.prefix(1).uppercased() + words.dropFirst(), nil)
            }
        }
    }

    static func describeCommand(_ command: String) -> String {
        let text = command.trimmingCharacters(in: .whitespaces)
        let words = text.split(separator: " ").map(String.init)
        let tool = URL(fileURLWithPath: words.first ?? "").lastPathComponent
        switch tool {
        case "imsg": return words.contains("send") ? "Sending a message" : "Looking through Messages"
        case "open":
            if let index = words.firstIndex(of: "-a"), index + 1 < words.count {
                return "Opening " + words[(index + 1)...].joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            return "Opening"
        case "mdfind", "find", "fd", "locate": return "Searching your files"
        case "du", "df": return "Checking storage"
        case "ls", "tree": return "Looking in a folder"
        case "gws":
            if text.contains("calendar") { return ["insert", "update", "delete", "patch", "move"].contains(where: text.contains) ? "Updating your calendar" : "Checking your calendar" }
            if text.contains("gmail") { return text.contains("send") ? "Sending email" : "Checking email" }
            return "Checking Google"
        case "remindctl": return "Checking reminders"
        case "memo": return "Checking notes"
        case "osascript": return "Talking to a Mac app"
        case "curl", "wget": return "Fetching from the web"
        case "git": return "Checking a repo"
        case "python", "python3": return "Running a script"
        default: return "Running a command"
        }
    }

    static func approval(from params: JSONValue, id: String) -> AgentApproval {
        let call = params["toolCall"] ?? .null
        let command = call["rawInput"]?["command"]?.stringValue
        let description = call["rawInput"]?["description"]?.stringValue ?? ""
        var title = call["title"]?.stringValue ?? "Approve this step"
        var detail: String?
        if let command, command.hasSuffix("(plugin approval rule)"), !description.isEmpty {
            // Written by the Jarvis guard plugin as "What happens — exact content".
            let parts = description.components(separatedBy: " — ")
            title = parts[0]
            detail = parts.count > 1 ? parts.dropFirst().joined(separator: " — ") : nil
        } else if let command {
            title = description.isEmpty ? "Run a command" : description
            detail = command
        } else if let diff = call["content"]?.arrayValue?.first(where: { $0["type"]?.stringValue == "diff" }) {
            let path = diff["path"]?.stringValue ?? ""
            title = "Change " + URL(fileURLWithPath: path).lastPathComponent
            detail = path + "\n\n" + String((diff["newText"]?.stringValue ?? "").prefix(1500))
        }
        let options: [AgentApproval.Option] = (params["options"]?.arrayValue ?? []).compactMap { option in
            guard let optionID = option["optionId"]?.stringValue,
                  let kind = AgentApproval.Option.Kind(rawValue: option["kind"]?.stringValue ?? "") else { return nil }
            return AgentApproval.Option(id: optionID, name: option["name"]?.stringValue ?? optionID, kind: kind)
        }
        return AgentApproval(id: id, title: title, detail: detail, options: options)
    }
}
