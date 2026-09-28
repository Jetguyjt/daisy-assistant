import Foundation

/// Does a background `delegate_task` ever hand its result back over ACP? Hermes runs top-level
/// delegations in the background and posts each result to a queue that only its CLI, TUI and
/// gateway read, so the expectation is no. This checks it on the real hermes-acp, cheaply:
/// - `/tools`, which Hermes answers itself without the model, shows whether delegate_task is offered;
/// - one short turn asks for a single tiny delegation: spell a random code word backwards;
/// - every message on the session is watched until `wait` seconds after the delegation starts,
///   and at least `afterTurn` seconds after the turn ends.
/// The reversed word turns up only if the subagent's answer reaches Daisy. Approvals are declined.
public enum DelegationProbe {
    public enum Verdict: String, Sendable {
        /// The result was in delegate_task's own output: it ran synchronously.
        case cameBackInTurn = "CAME BACK IN THE TURN"
        /// Hermes delivered it after the turn ended.
        case cameBack = "CAME BACK"
        case neverCameBack = "NEVER CAME BACK"
        /// The reversed word showed up in Hermes's own reply only, so it may have worked it out itself.
        case unclear = "UNCLEAR"
        /// delegate_task was called but failed, for example blocked by the guard.
        case delegationFailed = "DELEGATION FAILED"
        /// Hermes didn't call delegate_task.
        case notCalled = "NOT CALLED"
        /// delegate_task isn't among the session's tools.
        case notOffered = "NOT OFFERED"
        case couldNotRun = "COULD NOT RUN"

        public var exitCode: Int32 {
            switch self {
            case .cameBackInTurn, .cameBack: return 0
            case .neverCameBack: return 1
            case .couldNotRun: return 2
            case .unclear, .delegationFailed, .notCalled, .notOffered: return 3
            }
        }
    }

    public struct Options: Sendable {
        /// nil looks where the app looks.
        public var executable: URL?
        public var workingDirectory: URL
        public var environment: [String: String]
        /// Seconds to watch after the delegation starts.
        public var wait: TimeInterval
        /// Seconds to keep watching after the turn ends, however early that is.
        public var afterTurn: TimeInterval
        public var word: String
        public init(executable: URL? = nil, workingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                    environment: [String: String] = ["DAISY_SESSION": "1"], wait: TimeInterval = 90, afterTurn: TimeInterval = 10,
                    word: String = DelegationProbe.randomWord()) {
            self.executable = executable; self.workingDirectory = workingDirectory; self.environment = environment
            self.wait = wait; self.afterTurn = afterTurn; self.word = word
        }
    }

    public struct Report: Sendable {
        public let verdict: Verdict
        /// One line on why.
        public let reason: String
    }

    public static func randomWord() -> String {
        let letters = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<8).map { _ in letters.randomElement()! })
    }

    /// The one request the check makes of the model.
    public static func prompt(word: String) -> String {
        """
        Daisy diagnostic, run from Terminal by the developer: we're checking whether background delegate_task \
        results come back over ACP. For this one message the rule against delegate_task is lifted. Call \
        delegate_task exactly once, with a single task whose goal is: "Reply with only this code word spelled \
        backwards, letter by letter, and nothing else: \(word). Don't use any tools." Don't reverse the word \
        yourself, don't wait or poll for the result, and don't call any other tool. Once it's dispatched, \
        reply with one short sentence.
        """
    }

    /// Runs the check, printing what happens through `say`, and returns the verdict.
    public static func run(_ options: Options, say: @escaping @Sendable (String) -> Void) async -> Report {
        guard let executable = HermesBackend.locate(options.executable) else {
            return verdict(.couldNotRun, "hermes-acp isn't installed. Install Hermes first: \(HermesBackend.installCommand)", say)
        }
        let peer = JSONRPCPeer()
        let log = Recorder()
        let messages: AsyncStream<JSONRPCPeer.Inbound>
        do {
            messages = try await peer.start(executable: executable, arguments: [], environment: options.environment,
                                            directory: options.workingDirectory)
        } catch {
            return verdict(.couldNotRun, "hermes-acp didn't start: \(error.localizedDescription)", say)
        }
        let reader = Task {
            for await message in messages {
                switch message {
                case .notification(let method, let params):
                    if method == "session/update" { await log.add(params) }
                case .request(let id, let method, let params):
                    if method == "session/request_permission" {
                        // A check never approves anything.
                        try? await peer.respond(to: id, result: ["outcome": ["outcome": "cancelled"]])
                        await log.declined(HermesBackend.approval(from: params, id: "").title)
                    } else {
                        try? await peer.respond(to: id, errorCode: -32601, message: "Daisy doesn't provide \(method).")
                    }
                }
                await log.tick()
            }
        }
        let report = await probe(peer, log, options, say)
        await peer.stop()
        reader.cancel()
        return report
    }

    private static func probe(_ peer: JSONRPCPeer, _ log: Recorder, _ options: Options, _ say: @escaping @Sendable (String) -> Void) async -> Report {
        let session: String
        do {
            let hello = try await peer.request("initialize", [
                "protocolVersion": .number(1),
                "clientCapabilities": ["fs": ["readTextFile": .bool(false), "writeTextFile": .bool(false)], "terminal": .bool(false)],
                "clientInfo": ["name": "daisy-check", "title": "Daisy delegation check", "version": "0.4.0"]
            ], timeout: 45)
            guard HermesBackend.signedIn(hello) else {
                return verdict(.couldNotRun, "Hermes isn't signed in. Run: \(HermesBackend.signInCommand)", say)
            }
            let opened = try await peer.request("session/new", ["cwd": .string(options.workingDirectory.path), "mcpServers": .array([])], timeout: 90)
            guard let id = opened["sessionId"]?.stringValue, !id.isEmpty else { return verdict(.couldNotRun, "Hermes didn't open a session.", say) }
            session = id
        } catch {
            let tail = await peer.recentStderr()
            return verdict(.couldNotRun, (HermesBackend.describe(error).errorDescription ?? "Hermes didn't answer.")
                                         + (tail.isEmpty ? "" : " stderr: " + String(tail.suffix(200))), say)
        }
        say("session \(session)")

        // The tool list costs nothing: Hermes answers /tools without the model.
        let toolsMark = await peer.delivered
        do {
            _ = try await peer.request("session/prompt", ["sessionId": .string(session), "prompt": [["type": "text", "text": "/tools"]]], timeout: 60)
        } catch {
            return verdict(.couldNotRun, "/tools failed: " + (HermesBackend.describe(error).errorDescription ?? ""), say)
        }
        await catchUp(peer, log)
        let tools = await log.text(in: session, from: toolsMark)
        guard tools.contains("delegate_task") else {
            return verdict(.notOffered, "delegate_task isn't in this session's tools" + (tools.isEmpty ? "." : ": " + clip(tools, 200)), say)
        }
        say("delegate_task is offered. Asking for one tiny background delegation (code word \(options.word)).")

        let started = Date()
        let mark = await peer.delivered
        let params: JSONValue = ["sessionId": .string(session), "prompt": [["type": "text", "text": .string(prompt(word: options.word))]]]
        let turn = Task {
            let reason = (try? await peer.request("session/prompt", params, timeout: options.wait + 120))?["stopReason"]?.stringValue
            if Task.isCancelled { return }
            // Everything Hermes sent before its reply is already counted in `delivered`.
            await log.turnEnded(reason ?? "no reply", boundary: await peer.delivered)
        }
        let answer = String(options.word.reversed())
        var announced = false
        while true {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let end = await log.end
            let delegated = await log.firstDelegation(in: session, from: mark)
            if await log.toolHit(answer, in: session, from: mark) != nil { break }
            if let end {
                if !announced {
                    announced = true
                    await catchUp(peer, log)
                    say(String(format: "turn ended after %.1fs (%@). Watching for the subagent's answer…", end.at.timeIntervalSince(started), end.reason))
                }
                if delegated == nil { break }
                if await log.delegationFailure(in: session, from: mark) != nil { break }
                if await log.textHit(answer, in: session, from: end.boundary) != nil { break }
                if let later = await log.activity(in: session, from: end.boundary), Date().timeIntervalSince(later.at) > 3 { break }
            }
            let deadline = max((delegated ?? started).addingTimeInterval(options.wait),
                               end.map { $0.at.addingTimeInterval(options.afterTurn) } ?? .distantFuture)
            if Date() >= deadline { break }
            if end == nil, Date().timeIntervalSince(started) > options.wait + 120 {
                try? await peer.notify("session/cancel", ["sessionId": .string(session)])
                break
            }
        }
        await catchUp(peer, log)
        let end = await log.end
        turn.cancel()
        let watched = Date().timeIntervalSince(started)
        for line in await log.timeline(in: session, from: mark, since: started) { say(line) }

        guard let delegated = await log.firstDelegation(in: session, from: mark) else {
            let reply = await log.text(in: session, from: mark)
            return verdict(.notCalled, "Hermes didn't call delegate_task" + (reply.isEmpty ? "." : ". It said: " + clip(reply, 240)), say)
        }
        if let hit = await log.toolHit(answer, in: session, from: mark) {
            return verdict(.cameBackInTurn, String(format: "the subagent's answer (%@) was in delegate_task's own output at %.1fs, so it ran synchronously.",
                                                   answer, hit.timeIntervalSince(started)), say)
        }
        if let end {
            if let hit = await log.textHit(answer, in: session, from: end.boundary) {
                return verdict(.cameBack, String(format: "the subagent's answer (%@) arrived at %.1fs, after the turn ended, as %@.",
                                                 answer, hit.at.timeIntervalSince(started), hit.kind), say)
            }
            if let later = await log.activity(in: session, from: end.boundary) {
                return verdict(.cameBack, String(format: "Hermes started talking again at %.1fs, after the turn ended (%@), but without %@: ",
                                                 later.at.timeIntervalSince(started), later.kind, answer) + clip(later.text, 160), say)
            }
        }
        if let hit = await log.textHit(answer, in: session, from: mark) {
            return verdict(.unclear, String(format: "%@ appeared at %.1fs in Hermes's own reply during the turn, so it may have reversed the word itself.",
                                            answer, hit.at.timeIntervalSince(started)), say)
        }
        if let failure = await log.delegationFailure(in: session, from: mark) {
            return verdict(.delegationFailed, "delegate_task was called but failed, so nothing ran in the background"
                           + (failure.isEmpty ? "." : ": " + clip(failure, 240)), say)
        }
        let others = await log.otherSessions(besides: session, from: mark)
        return verdict(.neverCameBack, String(format: "delegate_task ran at %.1fs, and nothing carrying %@ arrived in %.0fs of watching.",
                                              delegated.timeIntervalSince(started), answer, watched)
                       + (end == nil ? " The turn never ended." : "")
                       + (others.isEmpty ? "" : " Updates for other sessions: " + others.joined(separator: ", ") + "."), say)
    }

    /// Waits (briefly) until every message received so far is recorded.
    private static func catchUp(_ peer: JSONRPCPeer, _ log: Recorder) async {
        let target = await peer.delivered
        for _ in 0..<400 {
            if await log.handled >= target { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private static func verdict(_ verdict: Verdict, _ reason: String, _ say: (String) -> Void) -> Report {
        say("VERDICT: \(verdict.rawValue) — \(reason)")
        return Report(verdict: verdict, reason: reason)
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    /// Every string in a JSON value, in order.
    static func strings(in value: JSONValue) -> [String] {
        switch value {
        case .string(let text): return [text]
        case .array(let items): return items.flatMap(strings(in:))
        case .object(let fields): return fields.keys.sorted().flatMap { strings(in: fields[$0] ?? .null) }
        default: return []
        }
    }

    /// Every session update in the order it arrived. `seq` is its place among all inbound messages,
    /// the same count as the peer's `delivered`, which is how "after the turn" is told apart without
    /// racing the clock.
    private actor Recorder {
        struct Entry {
            let seq: Int
            let at: Date
            let session: String
            let kind: String
            /// Everything it carried, for searching.
            let text: String
            /// What's worth printing: message text, or a tool's title, output and raw result.
            let shown: String
            /// A tool call from delegate_task.
            let delegation: Bool
            let status: String?
        }
        private var entries: [Entry] = []
        private var delegations: Set<String> = []
        private var refusals: [(at: Date, title: String)] = []
        private(set) var handled = 0
        private(set) var end: (at: Date, reason: String, boundary: Int)?

        func tick() { handled += 1 }
        func declined(_ title: String) { refusals.append((Date(), title)) }
        func turnEnded(_ reason: String, boundary: Int) { end = (Date(), reason, boundary) }

        func add(_ params: JSONValue) {
            let update = params["update"] ?? .null
            let kind = update["sessionUpdate"]?.stringValue ?? "?"
            let call = update["toolCallId"]?.stringValue ?? ""
            if kind == "tool_call" || kind == "tool_call_update", let title = update["title"]?.stringValue {
                if title.lowercased().hasPrefix("delegate") { delegations.insert(call) } else { delegations.remove(call) }
            }
            let text: String, shown: String
            switch kind {
            case "agent_message_chunk", "user_message_chunk", "agent_thought_chunk":
                text = update["content"]?["text"]?.stringValue ?? ""
                shown = text
            default:
                text = DelegationProbe.strings(in: update).joined(separator: " ")
                let output = (update["content"]?.arrayValue ?? []).compactMap { $0["content"]?["text"]?.stringValue ?? $0["text"]?.stringValue }
                shown = ([update["title"]?.stringValue] + output.map { Optional($0) } + [update["rawOutput"]?.stringValue])
                    .compactMap { $0 }.joined(separator: " · ")
            }
            entries.append(Entry(seq: handled, at: Date(), session: params["sessionId"]?.stringValue ?? "", kind: kind, text: text, shown: shown,
                                 delegation: kind.hasPrefix("tool_call") && delegations.contains(call),
                                 status: update["status"]?.stringValue))
        }

        private func since(_ mark: Int, in session: String) -> [Entry] {
            entries.filter { $0.seq >= mark && $0.session == session }
        }

        /// The reply's text since `mark`.
        func text(in session: String, from mark: Int) -> String {
            since(mark, in: session).filter { $0.kind == "agent_message_chunk" }.map(\.text).joined()
        }

        func firstDelegation(in session: String, from mark: Int) -> Date? {
            since(mark, in: session).first { $0.delegation }?.at
        }

        /// What a failed delegate_task call said, if it failed.
        func delegationFailure(in session: String, from mark: Int) -> String? {
            since(mark, in: session).first { $0.delegation && $0.status == "failed" }?.shown
        }

        /// When `word` first shows up in delegate_task's own output.
        func toolHit(_ word: String, in session: String, from mark: Int) -> Date? {
            since(mark, in: session).first { $0.delegation && $0.text.contains(word) }?.at
        }

        /// Where `word` first shows up in anything else Hermes sent from `mark` on. Each kind of
        /// message is searched as one text, since the word can be split across chunks.
        func textHit(_ word: String, in session: String, from mark: Int) -> (at: Date, kind: String)? {
            var joined: [String: String] = [:]
            for entry in since(mark, in: session) where entry.kind != "agent_thought_chunk" && !entry.delegation {
                joined[entry.kind, default: ""] += entry.text
                if joined[entry.kind]?.contains(word) == true { return (entry.at, entry.kind) }
            }
            return nil
        }

        /// The first sign of Hermes working on the session from `mark` on: text, a tool, a plan.
        func activity(in session: String, from mark: Int) -> (at: Date, kind: String, text: String)? {
            let talk: Set<String> = ["agent_message_chunk", "user_message_chunk", "tool_call", "tool_call_update", "plan"]
            let later = since(mark, in: session)
            guard let first = later.first(where: { talk.contains($0.kind) }) else { return nil }
            return (first.at, first.kind, later.filter { $0.kind == first.kind }.map(\.shown).joined())
        }

        func otherSessions(besides session: String, from mark: Int) -> [String] {
            var seen: [String] = []
            for entry in entries where entry.seq >= mark && entry.session != session && !seen.contains(entry.session) { seen.append(entry.session) }
            return seen
        }

        /// Readable lines: runs of message chunks joined, tool calls with their state, anything else
        /// counted by kind.
        func timeline(in session: String, from mark: Int, since start: Date) -> [String] {
            var lines: [(at: Date, line: String)] = []
            var run: (kind: String, at: Date, text: String)?
            func flush() {
                guard let current = run else { return }
                lines.append((current.at, "\(current.kind) “\(DelegationProbe.clip(current.text, 160))”"))
                run = nil
            }
            var quiet: [String: (count: Int, first: Date)] = [:]
            for entry in since(mark, in: session) {
                switch entry.kind {
                case "agent_message_chunk", "user_message_chunk":
                    if run?.kind == entry.kind { run?.text += entry.text } else { flush(); run = (entry.kind, entry.at, entry.text) }
                case "tool_call", "tool_call_update":
                    flush()
                    lines.append((entry.at, "\(entry.kind) \(entry.delegation ? "delegate_task" : "tool")"
                                  + (entry.status.map { " [\($0)]" } ?? "") + (entry.shown.isEmpty ? "" : ": " + DelegationProbe.clip(entry.shown, 200))))
                case "agent_thought_chunk":
                    continue
                default:
                    flush()
                    let key = entry.kind + ((end.map { entry.seq >= $0.boundary } ?? false) ? " (after the turn)" : "")
                    quiet[key] = quiet[key].map { ($0.count + 1, $0.first) } ?? (1, entry.at)
                }
            }
            flush()
            for (key, value) in quiet { lines.append((value.first, "\(key) ×\(value.count)")) }
            for refusal in refusals { lines.append((refusal.at, "approval declined by the check: \(refusal.title)")) }
            if let end { lines.append((end.at, "turn ended (\(end.reason))")) }
            return lines.sorted { $0.at < $1.at }.map { String(format: "%6.1fs  ", $0.at.timeIntervalSince(start)) + $0.line }
        }
    }
}
