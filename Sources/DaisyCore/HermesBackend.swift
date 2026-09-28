import Foundation

/// Hermes Agent over ACP: JSON-RPC on the stdio of `hermes-acp`. Hermes owns the model, the tool
/// loop, sessions, memory, skills and approvals; this actor only turns its protocol into
/// `AgentEvent`s. Provider sign-in stays inside Hermes; nothing here reads or stores credentials.
///
/// One `hermes-acp` runs the conversation and up to `maxWorkers` background jobs, each job in a
/// session of its own. Every update and approval request names its session and goes to that
/// session's turn. Anything for a session with no turn running is dropped, and its approval
/// requests are declined.
public actor HermesBackend: AgentBackend, JobBackend {
    public struct Settings: Sendable {
        /// nil looks in the usual install locations.
        public var executable: URL?
        /// Where Hermes runs tools from. A code repo here would switch Hermes into coding mode.
        public var workingDirectory: URL
        /// Remembers the session id between launches.
        public var sessionFile: URL
        public var environment: [String: String]
        /// Where job sessions are listed for the guard plugin. nil means
        /// `${HERMES_HOME:-~/.hermes}/daisy/roles.json`, with HERMES_HOME taken from `environment` first.
        public var rolesFile: URL?
        /// How long an approval waits for an answer before it counts as no. Hermes itself gives up
        /// at 60 seconds; answering first means nothing is left waiting on a card that can't work.
        /// The app's `ApprovalQueue` takes its cards down a little earlier; this is the backstop.
        public var approvalWindow: TimeInterval
        public init(executable: URL? = nil, workingDirectory: URL, sessionFile: URL, environment: [String: String] = [:],
                    rolesFile: URL? = nil, approvalWindow: TimeInterval = 57) {
            self.executable = executable; self.workingDirectory = workingDirectory
            self.sessionFile = sessionFile; self.environment = environment
            self.rolesFile = rolesFile; self.approvalWindow = approvalWindow
        }
    }

    public static let installCommand = "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash"
    /// Largest message Daisy sends Hermes in one turn. Hermes's own pipe takes far more; this keeps
    /// a stray paste from filling the model's context.
    public static let maxRequestBytes = 100_000
    public static let signInCommand = "hermes auth add openai-codex"
    /// Background jobs at once. hermes-acp runs four turns at a time, so two jobs always leave
    /// room for the conversation.
    public static let maxWorkers = 2

    private let settings: Settings
    private let peer = JSONRPCPeer()
    private let roles: WorkerRoles
    private var inbound: Task<Void, Never>?
    private var link: AgentLink = .starting
    private var connecting: Task<AgentLink, Never>?
    private var sessionID: String?
    private var modelDetail: String?
    private var replay: [AgentMessage] = []
    /// The session whose history is being replayed. Collection stays open until the first turn so
    /// late chunks aren't lost.
    private var replaySession: String?
    /// Turns in flight, by session: the conversation's and each job's.
    private var turns: [String: Turn] = [:]
    /// The conversation's prompt in flight, and the session it runs in (which can differ from
    /// `sessionID` while a stopped turn winds down).
    private var prompt: Task<JSONValue, Error>?
    private var turnSession: String?
    /// Job sessions open now, how many are being opened, and every one since launch (kept out of
    /// the chat list).
    private var workers: Set<String> = []
    private var opening = 0
    private var workerHistory: Set<String> = []
    /// Job sessions this backend listed in roles.json and hasn't taken off yet.
    private var listed: Set<String> = []
    /// Inbound messages handled so far; compared with the peer's `delivered` count.
    private var handled = 0
    private var approvals: [String: Pending] = [:]

    private struct Turn {
        let id: UUID
        let sink: Sink
        var request: Task<JSONValue, Error>?
        var produced = false
        var tools: [String: (title: String, detail: String?)] = [:]
    }
    private struct Pending {
        let request: JSONValue
        let options: [AgentApproval.Option]
        let session: String
        let expiry: Task<Void, Never>
    }
    /// Where a turn's updates go: the caller's stream, filtered to what it asked for.
    private struct Sink: Sendable {
        let yield: @Sendable (AgentUpdate) -> Void
        let finish: @Sendable (Error?) -> Void
    }
    private static let declined: JSONValue = ["outcome": ["outcome": "cancelled"]]

    public init(settings: Settings) {
        self.settings = settings
        roles = WorkerRoles(url: settings.rolesFile ?? WorkerRoles.defaultURL(environment: settings.environment))
    }
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
        guard let executable = Self.locate(settings.executable) else {
            link = .needsSetup(AgentSetupIssue(title: "Hermes isn't installed",
                detail: "Daisy runs on Hermes Agent. Install it, sign in, then reopen Daisy.", command: Self.installCommand))
            return link
        }
        if !(await peer.isRunning) {
            do {
                let messages = try await peer.start(executable: executable, arguments: [], environment: settings.environment,
                                                    directory: settings.workingDirectory)
                inbound?.cancel()
                handled = 0
                inbound = Task { [weak self] in
                    for await message in messages { await self?.handle(message) }
                    await self?.peerClosed()
                }
                let hello = try await peer.request("initialize", [
                    "protocolVersion": .number(1),
                    "clientCapabilities": ["fs": ["readTextFile": .bool(false), "writeTextFile": .bool(false)], "terminal": .bool(false)],
                    "clientInfo": ["name": "daisy", "title": "Daisy", "version": "0.4.0"]
                ], timeout: 45)
                if !Self.signedIn(hello) {
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
    public static func locate(_ explicit: URL? = nil) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = explicit.map { [$0] } ?? [home.appendingPathComponent(".hermes/hermes-agent/venv/bin/hermes-acp"),
                                                   home.appendingPathComponent(".local/bin/hermes-acp")]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Hermes lists its provider as an auth method only when that provider's credentials resolve.
    static func signedIn(_ hello: JSONValue) -> Bool {
        (hello["authMethods"]?.arrayValue ?? []).contains { ($0["id"]?.stringValue ?? "hermes-setup") != "hermes-setup" }
    }

    /// Replayed history arrives as updates just before the reply; collection stays open until the
    /// first turn so late chunks aren't lost.
    private func load(_ id: String) async throws {
        replay = []; replaySession = id
        let result = try await peer.request("session/load", ["sessionId": .string(id), "cwd": .string(settings.workingDirectory.path),
                                                            "mcpServers": .array([])], timeout: 90)
        // An unknown id comes back as an empty success, so only models or modes prove it loaded.
        guard result["models"] != nil || result["modes"] != nil else { replay = []; replaySession = nil; return }
        sessionID = id
        modelDetail = Self.model(from: result)
        try? await Task.sleep(nanoseconds: 60_000_000)
    }

    private func openSession() async throws {
        let (id, result) = try await newHermesSession()
        sessionID = id; replay = []; replaySession = nil
        modelDetail = Self.model(from: result)
        try? FileManager.default.createDirectory(at: settings.sessionFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(id.utf8).write(to: settings.sessionFile, options: .atomic)
    }

    private func newHermesSession() async throws -> (id: String, result: JSONValue) {
        let result = try await peer.request("session/new", ["cwd": .string(settings.workingDirectory.path), "mcpServers": .array([])], timeout: 90)
        guard let id = result["sessionId"]?.stringValue, !id.isEmpty else { throw AgentFailure.failed("Hermes didn't open a session.") }
        return (id, result)
    }

    private func savedSession() -> String? {
        guard let data = try? Data(contentsOf: settings.sessionFile) else { return nil }
        let id = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty || id.count > 200 ? nil : id
    }

    // MARK: Turns

    public nonisolated func send(_ prompt: AgentPrompt) -> AsyncThrowingStream<AgentEvent, Error> {
        stream(of: { update in if case .event(let event) = update { return event }; return nil },
               run: { await self.run(prompt, $0) }, stop: { await self.cancel() })
    }

    public nonisolated func stream(_ prompt: AgentPrompt) -> AsyncThrowingStream<AgentUpdate, Error> {
        stream(of: { $0 }, run: { await self.run(prompt, $0) }, stop: { await self.cancel() })
    }

    /// A turn as a stream of what the caller wants from it. When the caller stops listening, the
    /// turn is stopped too.
    private nonisolated func stream<T: Sendable>(of pick: @escaping @Sendable (AgentUpdate) -> T?,
                                                 run: @escaping @Sendable (Sink) async -> Void,
                                                 stop: @escaping @Sendable () async -> Void) -> AsyncThrowingStream<T, Error> {
        AsyncThrowingStream { continuation in
            let sink = Sink(yield: { update in if let value = pick(update) { continuation.yield(value) } },
                            finish: { error in continuation.finish(throwing: error) })
            let task = Task { await run(sink) }
            continuation.onTermination = { termination in
                guard case .cancelled = termination else { return }
                task.cancel()
                Task { await stop() }
            }
        }
    }

    private func run(_ message: AgentPrompt, _ sink: Sink) async {
        guard message.text.utf8.count <= Self.maxRequestBytes else {
            sink.finish(AgentFailure.failed("Please keep each message under 100 KB.")); return
        }
        await settle()
        let state = await connect()
        guard case .ready = state, let session = sessionID else {
            sink.finish(Self.failure(for: state)); return
        }
        if Task.isCancelled { sink.finish(CancellationError()); return }
        replaySession = nil
        let id = UUID()
        turns[session] = Turn(id: id, sink: sink)
        turnSession = session
        let request = startPrompt(message, in: session)
        prompt = request
        do {
            let result = try await request.value
            await catchUp()
            let reason = result["stopReason"]?.stringValue ?? "end_turn"
            // "refusal" with nothing said means Hermes no longer knows this session.
            if reason == "refusal", let turn = turns[session], turn.id == id, !turn.produced { sessionID = nil }
            if prompt == request { prompt = nil }
            endTurn(session, id)
            sink.yield(.event(.finished(stopReason: reason)))
            sink.finish(nil)
        } catch {
            if prompt == request { prompt = nil }
            endTurn(session, id)
            sink.finish(Self.describe(error))
        }
    }

    private func startPrompt(_ message: AgentPrompt, in session: String) -> Task<JSONValue, Error> {
        let params: JSONValue = ["sessionId": .string(session), "prompt": .array(Self.blocks(for: message))]
        let peer = self.peer
        let request = Task { try await peer.request("session/prompt", params) }
        turns[session]?.request = request
        return request
    }

    /// Hermes writes the last text chunk just before the prompt's reply, and the two can be handled
    /// in either order. Waits (briefly) until every message that came before the reply is handled,
    /// so the end of an answer is never dropped.
    private func catchUp() async {
        let target = await peer.delivered
        for _ in 0..<400 where handled < target {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Clears a finished turn. Whatever it left waiting for approval is declined.
    private func endTurn(_ session: String, _ id: UUID) {
        guard turns[session]?.id == id else { return }
        turns[session] = nil
        if turnSession == session { turnSession = nil }
        for (key, pending) in approvals where pending.session == session {
            approvals[key] = nil
            pending.expiry.cancel()
            Task { [peer] in try? await peer.respond(to: pending.request, result: Self.declined) }
        }
    }

    /// Declines every approval still waiting in a session.
    private func decline(in session: String) async {
        for (key, pending) in approvals where pending.session == session {
            approvals[key] = nil
            pending.expiry.cancel()
            try? await peer.respond(to: pending.request, result: Self.declined)
        }
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
        await decline(in: session)
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
        pending.expiry.cancel()
        // "Once" is the only yes Daisy gives: a request to always allow goes back as allow once.
        var choice = optionID.flatMap { choice in pending.options.first { $0.id == choice } }
        if choice?.kind == .allowAlways { choice = pending.options.first { $0.kind == .allowOnce } }
        let outcome: JSONValue = choice.map { ["outcome": "selected", "optionId": .string($0.id)] } ?? ["outcome": "cancelled"]
        try? await peer.respond(to: pending.request, result: ["outcome": outcome])
        turns[pending.session]?.sink.yield(.event(.approvalResolved(id: id, allowed: choice?.allows ?? false)))
    }

    public func newSession() async {
        if prompt != nil { await cancel(); await settle() }
        guard case .ready = await connect() else { return }
        do { try await openSession(); link = .ready(detail: modelDetail) }
        catch { sessionID = nil }
    }

    public func history() async -> [AgentMessage] { replay }

    public func sessions() async -> [AgentSession] {
        guard case .ready = await connect(),
              let result = try? await peer.request("session/list", ["cwd": .string(settings.workingDirectory.path)], timeout: 20) else { return [] }
        let stamps = ISO8601DateFormatter(), precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let jobs = workerHistory
        let list: [AgentSession] = (result["sessions"]?.arrayValue ?? []).compactMap { item in
            // Background jobs are sessions too, but they aren't chats.
            guard let id = item["sessionId"]?.stringValue, !jobs.contains(id) else { return nil }
            let title = item["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled chat"
            let date = item["updatedAt"]?.stringValue.flatMap { precise.date(from: $0) ?? stamps.date(from: $0) }
                ?? item["updatedAt"]?.numberValue.map { Date(timeIntervalSince1970: $0 > 1e11 ? $0 / 1000 : $0) }
            return AgentSession(id: id, title: title, updated: date)
        }
        return list.sorted { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }
    }

    public func open(session id: String) async -> [AgentMessage]? {
        if prompt != nil { await cancel(); await settle() }
        guard case .ready = await connect() else { return nil }
        if id == sessionID { return replay }
        do { try await load(id) } catch { return nil }
        guard sessionID == id else { return nil }
        try? Data(id.utf8).write(to: settings.sessionFile, options: .atomic)
        return replay
    }

    /// The prompt as ACP content: attachments first, then the words.
    static func blocks(for prompt: AgentPrompt) -> [JSONValue] {
        var blocks: [JSONValue] = prompt.attachments.map { attachment in
            switch attachment {
            case .image(_, let mimeType, let data):
                return ["type": "image", "mimeType": .string(mimeType), "data": .string(data.base64EncodedString())]
            case .document(_, let uri, let text):
                return ["type": "resource", "resource": ["uri": .string(uri), "mimeType": "text/plain", "text": .string(text)]]
            case .file(let url):
                return ["type": "resource_link", "uri": .string(url.absoluteString), "name": .string(url.lastPathComponent)]
            }
        }
        if !prompt.text.isEmpty || blocks.isEmpty { blocks.append(["type": "text", "text": .string(prompt.text)]) }
        return blocks
    }

    public func shutdown() async {
        if prompt != nil { await cancel() }
        for session in workers { await cancel(worker: session) }
        await stopPeer()
        unlist(listed)
    }

    private func stopPeer() async {
        inbound?.cancel(); inbound = nil
        await peer.stop()
    }

    private func peerClosed() {
        link = .offline("Hermes stopped.")
        let closing = turns
        turns = [:]; turnSession = nil
        for turn in closing.values { turn.sink.finish(AgentFailure.offline("Hermes stopped unexpectedly. Try again.")) }
        for pending in approvals.values { pending.expiry.cancel() }
        approvals = [:]
        workers = []
        // The job sessions ended with the process, so none of them can run as anything now.
        unlist(listed)
    }

    // MARK: Jobs

    public func openWorker() async throws -> String {
        guard case .ready = await connect() else { throw Self.failure(for: link) }
        guard workers.count + opening < Self.maxWorkers else {
            throw AgentFailure.failed("Daisy already runs \(Self.maxWorkers) jobs at once.")
        }
        opening += 1
        defer { opening -= 1 }
        let id: String
        do { id = try await newHermesSession().id } catch { throw Self.describe(error) }
        workerHistory.insert(id)
        // The guard has to see this session as a job before anything runs in it. If the mark
        // can't be written, the job doesn't run.
        do { try roles.mark(id) } catch {
            throw AgentFailure.failed("Daisy couldn't mark the job for the guard: \(error.localizedDescription)")
        }
        listed.insert(id); workers.insert(id)
        return id
    }

    public nonisolated func run(worker session: String, prompt: AgentPrompt) -> AsyncThrowingStream<AgentUpdate, Error> {
        stream(of: { $0 }, run: { await self.runWorker(session, prompt, $0) }, stop: { await self.cancel(worker: session) })
    }

    private func runWorker(_ session: String, _ message: AgentPrompt, _ sink: Sink) async {
        guard message.text.utf8.count <= Self.maxRequestBytes else {
            sink.finish(AgentFailure.failed("Please keep each job under 100 KB.")); return
        }
        guard workers.contains(session), turns[session] == nil else {
            sink.finish(AgentFailure.failed("That job isn't open.")); return
        }
        if Task.isCancelled { sink.finish(CancellationError()); return }
        let id = UUID()
        turns[session] = Turn(id: id, sink: sink)
        let request = startPrompt(message, in: session)
        do {
            let result = try await request.value
            await catchUp()
            let reason = result["stopReason"]?.stringValue ?? "end_turn"
            endTurn(session, id)
            sink.yield(.event(.finished(stopReason: reason)))
            sink.finish(nil)
        } catch {
            endTurn(session, id)
            sink.finish(Self.describe(error))
        }
    }

    public func cancel(worker session: String) async {
        guard workers.contains(session), turns[session] != nil else { return }
        try? await peer.notify("session/cancel", ["sessionId": .string(session)])
        await decline(in: session)
    }

    public func closeWorker(_ session: String) async {
        guard workers.contains(session) else { return }
        if turns[session] != nil {
            await cancel(worker: session)
            // The guard keeps treating the session as a job until Hermes has really stopped it.
            for _ in 0..<120 where turns[session] != nil { await Self.pause(50_000_000) }
        }
        workers.remove(session)
        if let stuck = turns[session] {
            // Hermes didn't stop in time. Stop waiting for it, but leave the job mark: the turn may
            // still be running in there. It comes off when Hermes stops or Daisy quits.
            stuck.request?.cancel()
            return
        }
        unlist([session])
    }

    private func unlist(_ sessions: Set<String>) {
        let mine = sessions.intersection(listed)
        guard !mine.isEmpty else { return }
        // A failed write keeps them in `listed`, to try again at the next chance.
        if (try? roles.clear(Array(mine))) != nil { listed.subtract(mine) }
    }

    /// Sleeps even when the calling task is cancelled: cleanup still has to wait for Hermes.
    private static func pause(_ nanoseconds: UInt64) async {
        await Task { try? await Task.sleep(nanoseconds: nanoseconds) }.value
    }

    // MARK: Inbound

    private func handle(_ message: JSONRPCPeer.Inbound) async {
        defer { handled += 1 }
        switch message {
        case .notification(let method, let params):
            guard method == "session/update", let session = params["sessionId"]?.stringValue else { return }
            let update = params["update"] ?? .null
            let kind = update["sessionUpdate"]?.stringValue ?? ""
            if session == replaySession, turns[session] == nil { collect(kind, update); return }
            guard let turn = turns[session] else { return }
            switch kind {
            case "agent_message_chunk":
                if let text = update["content"]?["text"]?.stringValue, !text.isEmpty {
                    turns[session]?.produced = true
                    turn.sink.yield(.event(.text(text)))
                }
            case "tool_call", "tool_call_update":
                let id = update["toolCallId"]?.stringValue ?? UUID().uuidString
                let toolKind = update["kind"]?.stringValue
                var label = turn.tools[id] ?? (title: "Working", detail: nil)
                if let raw = update["title"]?.stringValue { label = ToolPhrases.describe(title: raw, kind: toolKind, input: update["rawInput"]) }
                turns[session]?.tools[id] = label
                let state = Self.state(update["status"]?.stringValue) ?? (kind == "tool_call" ? .running : nil)
                if let state { turn.sink.yield(.event(.tool(AgentToolActivity(id: id, title: label.title, detail: label.detail, kind: toolKind, state: state)))) }
            case "plan":
                turn.sink.yield(.plan(Self.plan(from: update)))
            default:
                break   // thoughts stay hidden; usage and command lists aren't shown
            }
        case .request(let id, let method, let params):
            if method == "session/request_permission" { await permission(id, params) }
            else { try? await peer.respond(to: id, errorCode: -32601, message: "Daisy doesn't provide \(method).") }
        }
    }

    private func collect(_ kind: String, _ update: JSONValue) {
        let role = kind == "user_message_chunk" ? "user" : kind == "agent_message_chunk" ? "assistant" : nil
        guard let role, let text = update["content"]?["text"]?.stringValue, !text.isEmpty else { return }
        if replay.last?.role == role { replay[replay.count - 1].text += text }
        else { replay.append(AgentMessage(role: role, text: text)) }
    }

    /// Hermes blocks the tool until this is answered, and gives up after 60 seconds. It's answered
    /// no when `approvalWindow` runs out first.
    private func permission(_ request: JSONValue, _ params: JSONValue) async {
        guard let session = params["sessionId"]?.stringValue, let turn = turns[session] else {
            try? await peer.respond(to: request, result: Self.declined); return
        }
        let approval = Self.approval(from: params, id: UUID().uuidString)
        let window = settings.approvalWindow
        let expiry = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0.05, window) * 1_000_000_000)) } catch { return }
            await self?.resolve(approval: approval.id, optionID: nil)
        }
        approvals[approval.id] = Pending(request: request, options: approval.options, session: session, expiry: expiry)
        turn.sink.yield(.event(.approval(approval)))
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

    /// Hermes sends its `todo` list as `{"sessionUpdate": "plan", "entries": [{"content", "priority",
    /// "status"}]}`. Dropped items come as completed with "[cancelled] " in front.
    static func plan(from update: JSONValue) -> AgentPlan {
        let marker = "[cancelled]"
        let entries = (update["entries"]?.arrayValue ?? []).enumerated().compactMap { index, entry -> AgentPlan.Entry? in
            guard var content = entry["content"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else { return nil }
            let cancelled = content.hasPrefix(marker)
            if cancelled { content = content.dropFirst(marker.count).trimmingCharacters(in: .whitespaces) }
            let status = AgentPlan.Entry.Status(rawValue: entry["status"]?.stringValue ?? "") ?? .pending
            return AgentPlan.Entry(id: index, content: content, status: status, cancelled: cancelled)
        }
        return AgentPlan(entries: entries)
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

    static func approval(from params: JSONValue, id: String) -> AgentApproval {
        let call = params["toolCall"] ?? .null
        let command = call["rawInput"]?["command"]?.stringValue
        let description = call["rawInput"]?["description"]?.stringValue ?? ""
        var title = call["title"]?.stringValue ?? "Approve this step"
        var detail: String?
        if let command, command.hasSuffix("(plugin approval rule)"), !description.isEmpty {
            // Written by the Daisy guard plugin as "What happens — exact content".
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
