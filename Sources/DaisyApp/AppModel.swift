import AppKit
import SwiftUI
import DaisyCore

enum AssistantPhase: String { case idle = "Ready", preparing = "Preparing microphone", listening = "Listening", thinking = "Thinking", searching = "Searching files", working = "Working", awaitingApproval = "Waiting for approval", responding = "Responding", transcribing = "Transcribing", synthesizing = "Preparing voice", speaking = "Speaking" }
/// One step the assistant took during a turn, for the activity readout.
struct ActivityItem: Identifiable, Equatable {
    enum State: Equatable { case running, done, failed }
    let id: String
    var title: String
    var detail: String? = nil
    var state: State = .running
    let started = Date()
    var finished: Date?
}
/// How long the last answer took: to the first streamed words, and in total.
struct ReplyTiming: Equatable {
    let firstText: TimeInterval?
    let total: TimeInterval
}
enum ListeningMode: String, CaseIterable, Identifiable {
    case manual, handsFree, wakeWord
    var id: String { rawValue }
    var title: String {
        switch self {
        case .manual: return "Click to talk"
        case .handsFree: return "Hands-free conversation"
        case .wakeWord: return "Wake word: Hey Daisy"
        }
    }
}
struct ConversationItem: Identifiable {
    let id = UUID()
    let role: String
    let text: String
    var files: SearchReport? = nil
    var detail: String? = nil
    var receipts: [CapabilityReceipt] = []
    /// Approvals given or refused during this answer, e.g. "Approved: Send an iMessage to Dad".
    var decisions: [String] = []
    /// Files sent with a user message, by name.
    var attachments: [String] = []
}

@MainActor final class AppModel: ObservableObject {
    @Published var config = Configuration()
    @Published var phase: AssistantPhase = .idle
    /// The message being written. Its own object, so typing doesn't redraw the whole window.
    let composer = ComposerState()
    @Published var composerExpanded = false
    @Published var messages: [ConversationItem] = []
    @Published var memories: [Memory] = []
    @Published var selectedFolder: URL?
    @Published var availableModels: [String] = []
    @Published var connected = false
    @Published var connecting = false
    @Published var notice: String?
    @Published var tab = "Assistant"
    @Published var recentSearch: SearchReport?
    @Published var currentStep: String?
    @Published var chromeConnected = false
    @Published var chromeConnecting = false
    @Published var connectionNotice: String?
    @Published var tasks: [WorkItem] = []
    @Published var reviewResults: [UUID: String] = [:]
    @Published var applyingReviews = Set<UUID>()
    /// Wake-word mode is armed: the mic is open and an utterance starting with the phrase opens a turn.
    @Published var standby = false
    /// The answer as it streams in, before it becomes a message.
    @Published var liveText = ""
    /// Steps taken during the current (or last) turn.
    @Published var activity: [ActivityItem] = []
    @Published var lastReply: ReplyTiming?
    /// False while every window is hidden or covered, so animation can pause.
    @Published var appVisible = true
    /// Where the agent stands: starting, ready, waiting on setup, or offline.
    @Published var agentLink: AgentLink = .starting
    /// Decisions the agent is waiting on during this turn.
    @Published var approvals: [AgentApproval] = []
    /// The listening mode to return to when always-listening is switched off.
    private var quietMode: ListeningMode = .handsFree
    private lazy var backend: AgentBackend = makeBackend()
    private var backendSignature = ""
    private var turnHistory: [ChatMessage] = []
    private var decisions: [String] = []
    private var feed = SpeechFeed()
    private var voiceChunks: AsyncStream<String>.Continuation?
    private var voicePlayback: Task<Void, Error>?
    private var expiredReviews = Set<UUID>()
    private var taskStore: TaskStore?
    private let chrome = ChromeConnection()
    private var browserWork: Task<Void, Never>?
    private var chromeHealth: Task<Void, Never>?
    let audio = AudioController()
    private var store: MemoryStore?
    private var work: Task<Void, Never>?
    private var generation = UUID()
    private var holdRequested = false
    private let speech = SpeechRuntime()
    private let speechWorker = SpeechWorker()
    private var healthMonitor: Task<Void, Never>?
    private var startup: Task<Void, Never>?
    private enum ListeningPurpose { case command, followUp }
    private var purpose: ListeningPurpose = .command
    private var voiceTurn = false
    private var endpointer = SpeechEndpointer()
    private var bargeEndpointer = SpeechEndpointer(settings: .bargeIn)
    private var standbyWork: Task<Void, Never>?
    var busy: Bool { phase != .idle }
    var listeningMode: ListeningMode { ListeningMode(rawValue: config.listeningMode ?? "") ?? .wakeWord }
    var alwaysListening: Bool { listeningMode == .wakeWord }
    /// Hermes is the default brain; the on-device engine is an opt-in fallback.
    var usesHermes: Bool { (config.agentBackend ?? "hermes") != "local" }
    var bookmarkURL: URL { Configuration.dataDirectory.appendingPathComponent("folder.bookmark") }
    func capabilityRegistry() throws -> CapabilityRegistry {
        var entries = try BuiltInCapabilities.registry(root: selectedFolder, allowFiles: config.allowFileSearch,
            memories: memories, memoryStore: store, permissions: config.capabilityPermissions ?? [:]).entries
        var additional = BrowserCapabilityProvider(connection: chrome, available: chromeConnected).capabilities()
        if let taskStore { additional += TaskCapabilityProvider(store: taskStore).capabilities() }
        additional += DraftCapabilityProvider(root: selectedFolder).capabilities()
        additional += MacCapabilityProvider().capabilities()
        additional += ProjectSnapshotCapabilityProvider(memories: memories).capabilities()
        entries += additional.map { entry in
            Capability(entry.definition, unavailableReason: capabilityEnabled(entry.definition.name) ? entry.unavailableReason : "Disabled in Capabilities.", execute: entry.execute)
        }
        return try CapabilityRegistry(capabilities: entries)
    }
    var capabilityEntries: [Capability] { (try? capabilityRegistry().entries) ?? [] }
    func capabilityEnabled(_ name: String) -> Bool {
        config.capabilityPermissions?[name] ?? (name != "read_text_file")
    }
    func setCapability(_ name: String, enabled: Bool) {
        stop(clearNotice: true)
        var permissions = config.capabilityPermissions ?? [:]; permissions[name] = enabled
        config.capabilityPermissions = permissions
        do { try config.save() } catch { notice = error.localizedDescription }
    }

    /// The app was Jarvis (com.local.jarvis.desktop) until 2026-09-27. Its saved preferences come
    /// across once; the data folder moves in `Configuration.dataDirectory`.
    private static func adoptLegacyDefaults() -> Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "adoptedLegacyDefaults") else { return false }
        if let old = defaults.persistentDomain(forName: "com.local.jarvis.desktop") {
            for (key, value) in old where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: "adoptedLegacyDefaults")
        return true
    }

    init() {
        let firstDaisyLaunch = Self.adoptLegacyDefaults()
        do {
            config = try Configuration.load()
            store = try MemoryStore(url: Configuration.dataDirectory.appendingPathComponent("memory.sqlite"))
            taskStore = try TaskStore(url: Configuration.dataDirectory.appendingPathComponent("tasks.json"))
        } catch { notice = "Setup needs attention: \(error.localizedDescription)" }
        // Folder access is tied to the app that granted it, so a bookmark made by the old Jarvis app
        // (or one that has gone bad) can't be resolved. Drop it and ask for the folder again.
        var folderLost = false
        if let data = try? Data(contentsOf: bookmarkURL) {
            do {
                var stale = false
                let folder = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
                _ = folder.startAccessingSecurityScopedResource()
                selectedFolder = folder
                if stale { try saveBookmark(folder) }
            } catch {
                try? FileManager.default.removeItem(at: bookmarkURL)
                folderLost = true
            }
        }
        if firstDaisyLaunch, notice == nil {
            notice = "Jarvis is now Daisy. macOS treats it as a new app, so allow the microphone again when asked (and Automation for Chrome later)."
                + (folderLost ? " Choose your search folder again in Setup." : "")
        } else if folderLost, notice == nil {
            notice = "Choose your search folder again in Setup; macOS no longer recognizes the old one."
        }
        if listeningMode != .wakeWord { quietMode = listeningMode }
        audio.speechWorker = speechWorker
        audio.onChunk = { [weak self] power, duration in self?.observe(power: power, duration: duration) }
        audio.onEngineLost = { [weak self] in self?.engineLost() }
        Task {
            await reloadMemories(); await reloadTasks()
            if config.speakResponses { await speechWorker.warmUp() }
            applyListeningMode()
        }
        backendSignature = signature
        connectWhenAllowed()
    }

    /// Connects, except on the first Hermes run: then it waits for Connect, so Daisy never
    /// starts Hermes (and a provider token refresh) without a click.
    private func connectWhenAllowed() {
        if usesHermes && config.hermesConnected != true {
            agentLink = .needsSetup(AgentSetupIssue(title: "Connect Daisy to Hermes",
                detail: "Daisy thinks with Hermes Agent and your ChatGPT sign-in. Sign in to Hermes first if you haven't recently, then press Connect.",
                command: HermesBackend.signInCommand))
            connected = false
        } else {
            startAgent()
        }
    }

    private var signature: String { "\(usesHermes)|\(config.hermesExecutable ?? "")" }

    private func makeBackend() -> AgentBackend {
        if usesHermes {
            let path = config.hermesExecutable?.trimmingCharacters(in: .whitespaces) ?? ""
            return HermesBackend(settings: .init(
                executable: path.isEmpty ? nil : URL(fileURLWithPath: path),
                // A home-folder cwd keeps Hermes in assistant mode; a repo would switch it to coding mode.
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
                sessionFile: Configuration.dataDirectory.appendingPathComponent("hermes-session"),
                environment: ["DAISY_SESSION": "1"]))
        }
        return LocalBackend { [weak self] text in
            guard let self else { throw CancellationError() }
            return try await self.localContext(for: text)
        }
    }

    /// What the on-device engine needs for one turn.
    func localContext(for text: String) async throws -> LocalBackend.Context {
        var context = capabilityEnabled("search_memories") ? Array(memories.prefix(12)) : []
        if capabilityEnabled("search_memories"), let store, !text.isEmpty {
            let hits = try await store.relevant(to: text)
            context = hits + context.filter { candidate in !hits.contains { $0.key == candidate.key } }
        }
        return LocalBackend.Context(configuration: config, registry: try capabilityRegistry(), history: turnHistory,
                                    memories: context, store: store)
    }

    /// Starts the agent or reconnects to it, then keeps an eye on it.
    func startAgent() {
        guard !connecting else { return }
        connected = false; connecting = true; agentLink = .starting
        let backend = self.backend
        startup = Task {
            defer { connecting = false }
            let link = await backend.connect()
            guard !Task.isCancelled else { return }
            agentLink = link; connected = link.isReady
            if link.isReady, usesHermes, config.hermesConnected != true {
                config.hermesConnected = true
                try? config.save()
            }
            if let local = backend as? LocalBackend { availableModels = await local.models() }
            if link.isReady, messages.isEmpty {
                let earlier = await backend.history().suffix(40)
                if messages.isEmpty, !earlier.isEmpty {
                    messages = earlier.map { ConversationItem(role: $0.role == "user" ? "user" : "assistant", text: $0.text) }
                }
            }
        }
        if healthMonitor == nil {
            // Brings a crashed agent back between turns. Setup problems wait for the user.
            healthMonitor = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
                    guard let self else { return }
                    if self.busy || self.connecting { continue }
                    if case .needsSetup = self.agentLink { continue }
                    let link = await self.backend.connect()
                    if !self.connecting { self.agentLink = link; self.connected = link.isReady }
                }
            }
        }
    }

    /// Answers a pending approval from its card. Sends and deletes only ever get "once".
    func answer(_ request: AgentApproval, allow: Bool) {
        let option = allow ? (request.options.first { $0.kind == .allowOnce } ?? request.options.first { $0.allows })
                           : request.options.first { $0.kind == .rejectOnce }
        let backend = self.backend
        Task { await backend.resolve(approval: request.id, optionID: option?.id) }
    }

    var linkLabel: String {
        usesHermes ? "Hermes" + (agentDetail.map { " · " + $0 } ?? "") : "Local · " + config.model
    }
    var agentDetail: String? { if case .ready(let detail) = agentLink { return detail }; return nil }

    func submit() {
        let text = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = composer.attachments
        guard !text.isEmpty || !files.isEmpty else { return }
        // Hermes gets up to 100 KB; the on-device model's small context keeps it at 4,000 bytes.
        if usesHermes {
            guard text.utf8.count <= HermesBackend.maxRequestBytes else { notice = "Please keep each message under 100 KB."; return }
        } else {
            guard text.utf8.count <= 4000 else { notice = "Please keep each request under 4,000 UTF-8 bytes so it fits the local context window."; return }
            guard files.isEmpty else { notice = "Attachments need Hermes. Switch the brain in Setup."; return }
        }
        let attachments: [AgentAttachment]
        do { attachments = try files.map(Attachments.load) } catch { notice = error.localizedDescription; return }
        composer.text = ""; composer.attachments = []; composerExpanded = false
        run(text, attachments: attachments)
    }
    /// ↑ in an empty composer: bring back the last thing you sent to edit it.
    func editLastMessage() {
        guard let last = messages.last(where: { $0.role == "user" }) else { return }
        composer.set(last.text)
    }
    /// Sends the last question again in place of its answer.
    func retryLast() {
        guard let index = messages.lastIndex(where: { $0.role == "user" }) else { return }
        let text = messages[index].text
        stop(clearNotice: true)
        messages.removeSubrange(index...)
        run(text)
    }
    /// Earlier Hermes conversations, newest first, for the Chats list.
    @Published var chats: [AgentSession] = []
    func refreshChats() {
        let backend = self.backend
        Task { chats = await backend.sessions() }
    }
    /// Reopens an earlier conversation; Hermes replays it and the transcript shows the last part.
    func openChat(_ id: String) {
        stop(clearNotice: true)
        let backend = self.backend
        Task {
            guard let history = await backend.open(session: id) else { notice = "That chat couldn't be opened."; return }
            messages = history.suffix(60).map { ConversationItem(role: $0.role == "user" ? "user" : "assistant", text: $0.text) }
            activity = []; recentSearch = nil; liveText = ""
            rest()
        }
    }
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    /// Reads one message aloud with the current voice.
    func readAloud(_ text: String) {
        stop(clearNotice: true)
        let token = generation
        let speech = SpeechText.spoken(from: text)
        guard !speech.isEmpty else { return }
        phase = .synthesizing
        bargeEndpointer = SpeechEndpointer(settings: .bargeIn)
        work = Task {
            do {
                try await audio.speak(speech, voice: config.naturalVoice ?? "bm_george", speed: config.speechRate ?? 1) {
                    if self.generation == token { self.phase = .speaking }
                }
            } catch { }
            if generation == token { phase = .idle; rest() }
        }
    }
    func run(_ text: String, spoken: Bool = false, attachments: [AgentAttachment] = []) {
        stop(clearNotice: true)
        standby = false; voiceTurn = spoken
        let token = generation
        turnHistory = messages.filter { $0.role == "user" || $0.role == "assistant" }.suffix(8).map { ChatMessage(role: $0.role, content: $0.text) }
        messages.append(ConversationItem(role: "user", text: text, attachments: attachments.map(\.name)))
        if messages.count > 100 { messages.removeFirst(messages.count - 100) }
        phase = .thinking
        activity = []; liveText = ""; approvals = []; decisions = []; feed = SpeechFeed()
        let started = Date()
        let backend = self.backend
        let direct = text.hasPrefix("/find ")
        work = Task {
            var firstText: TimeInterval?
            var receipts: [CapabilityReceipt] = []
            do {
                if direct {
                    // A plain filename search runs here without the agent, so it works offline too.
                    phase = .searching
                    updateProgress("Search your files", token: token)
                    let session = CapabilitySession(registry: try capabilityRegistry())
                    let receipt = try await session.execute(.init(name: "search_files", arguments: ["query": .string(String(text.dropFirst(6)))]))
                    receipts = [receipt]; liveText = receipt.output.summary
                } else {
                    for try await event in backend.send(AgentPrompt(text: text, attachments: attachments)) {
                        try Task.checkCancellation()
                        guard generation == token else { return }
                        switch event {
                        case .text(let delta):
                            if firstText == nil { firstText = Date().timeIntervalSince(started) }
                            liveText += delta
                            if [.thinking, .working, .searching].contains(phase) { phase = .responding }
                            if config.speakResponses { say(feed.update(liveText), token: token) }
                        case .tool(let tool):
                            track(tool)
                        case .approval(let request):
                            approvals.append(request); phase = .awaitingApproval
                        case .approvalResolved(let id, let allowed):
                            if let request = approvals.first(where: { $0.id == id }) {
                                decisions.append((allowed ? "Approved: " : "Declined: ") + request.title)
                            }
                            approvals.removeAll { $0.id == id }
                            if phase == .awaitingApproval { phase = approvals.isEmpty ? .working : .awaitingApproval }
                        case .receipts(let more):
                            receipts += more
                        case .finished:
                            break
                        }
                    }
                }
                try Task.checkCancellation()
                guard generation == token else { return }
                let report = receipts.compactMap(\.output.files).last
                if let report { recentSearch = report }
                currentStep = nil; settleActivity(.done); approvals = []
                let answer = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
                let total = Date().timeIntervalSince(started)
                lastReply = ReplyTiming(firstText: firstText, total: total)
                let detail = direct ? "Direct search" : String(format: "%@ · %.1fs", linkLabel, total)
                messages.append(ConversationItem(role: "assistant", text: answer.isEmpty ? "Done." : answer, files: report,
                                                 detail: detail, receipts: receipts, decisions: decisions))
                liveText = ""
                if !usesHermes { await reloadMemories(); await reloadTasks() }
                if config.speakResponses { say(feed.finish(answer), token: token) }
                try await finishVoice(token: token)
                if generation == token { finishTurn() }
            } catch is CancellationError {
                if generation == token { phase = .idle }
            } catch {
                guard generation == token else { return }
                endVoice()
                if (error as? URLError)?.code == .cancelled { phase = .idle; return }
                switch error as? AgentFailure {
                case .setup(let issue): agentLink = .needsSetup(issue); connected = false
                case .offline(let reason): agentLink = .offline(reason); connected = false
                default: if error is URLError { connected = false }
                }
                currentStep = nil; settleActivity(.failed); approvals = []
                if !liveText.isEmpty {
                    messages.append(ConversationItem(role: "assistant", text: liveText, detail: "Cut off", decisions: decisions))
                    liveText = ""
                }
                notice = error.localizedDescription; phase = .idle
                messages.append(ConversationItem(role: "status", text: error.localizedDescription))
                rest()
            }
        }
    }

    /// Keeps the activity readout in step with the agent's tools.
    private func track(_ tool: AgentToolActivity) {
        let state: ActivityItem.State = tool.state == .failed ? .failed : tool.state == .completed ? .done : .running
        if let index = activity.firstIndex(where: { $0.id == tool.id }) {
            activity[index].title = tool.title
            activity[index].detail = tool.detail ?? activity[index].detail
            if state != .running, activity[index].state == .running { activity[index].state = state; activity[index].finished = Date() }
        } else {
            // The on-device engine reports only starts: a new step means the last one is done.
            if !usesHermes { settleActivity(.done) }
            activity.append(ActivityItem(id: tool.id, title: tool.title, detail: tool.detail, state: state,
                                         finished: state == .running ? nil : Date()))
        }
        if state == .running {
            currentStep = tool.title
            if [.thinking, .responding, .searching].contains(phase) { phase = .working }
        }
    }

    // MARK: Streamed voice

    /// Hands finished sentences to the voice; playback starts with the first one.
    private func say(_ pieces: [String], token: UUID) {
        guard !pieces.isEmpty, generation == token else { return }
        if voiceChunks == nil {
            let (stream, continuation) = AsyncStream<String>.makeStream()
            voiceChunks = continuation
            bargeEndpointer = SpeechEndpointer(settings: .bargeIn)
            let voice = config.naturalVoice ?? "bm_george", speed = config.speechRate ?? 1
            voicePlayback = Task { [weak self] in
                guard let self else { return }
                try await self.audio.speak(stream, voice: voice, speed: speed) {
                    if self.generation == token { self.phase = .speaking }
                }
            }
        }
        for piece in pieces { voiceChunks?.yield(piece) }
    }

    /// Closes the voice stream and waits for the last sentence to play.
    private func finishVoice(token: UUID) async throws {
        voiceChunks?.finish(); voiceChunks = nil
        guard let playback = voicePlayback else { return }
        if phase != .speaking { phase = .synthesizing }
        do { try await playback.value }
        catch is CancellationError { throw CancellationError() }
        catch { notice = "The answer is ready, but speech failed: \(error.localizedDescription)" }
        voicePlayback = nil
    }

    private func endVoice() {
        voiceChunks?.finish(); voiceChunks = nil
        voicePlayback?.cancel(); voicePlayback = nil
    }

    private func updateProgress(_ step: String, token: UUID) {
        guard generation == token else { return }
        currentStep = step
        settleActivity(.done)
        activity.append(ActivityItem(id: UUID().uuidString, title: step))
    }
    /// Closes whatever step is still running.
    private func settleActivity(_ state: ActivityItem.State) {
        for index in activity.indices where activity[index].state == .running {
            activity[index].state = state; activity[index].finished = Date()
        }
    }

    // MARK: Listening

    /// The main-screen switch. On is wake-word standby; off goes back to the last non-wake mode.
    /// Saved right away, without the engine restart that saving settings does.
    func setAlwaysListening(_ on: Bool) {
        guard on != alwaysListening else { return }
        if on { quietMode = listeningMode }
        config.listeningMode = (on ? ListeningMode.wakeWord : quietMode).rawValue
        do { try config.save() } catch { notice = error.localizedDescription }
        applyListeningMode()
    }
    /// Called after settings change and at launch. Wake-word mode keeps the mic open; the others
    /// open it only while a conversation is going.
    func applyListeningMode() {
        if listeningMode != .wakeWord { quietMode = listeningMode }
        switch listeningMode {
        case .wakeWord: armStandby()
        case .manual, .handsFree:
            disarmStandby()
            if !busy { audio.stopEngine() }
        }
    }
    private func armStandby() {
        guard listeningMode == .wakeWord, !busy, !standby else { return }
        standbyWork?.cancel()
        standbyWork = Task { [weak self] in
            guard let self else { return }
            guard await self.audio.requestMicrophone() else {
                self.notice = "Allow Daisy in System Settings → Privacy & Security → Microphone to use the wake word."; return
            }
            guard !Task.isCancelled, self.listeningMode == .wakeWord, !self.busy else { return }
            do { try self.audio.startEngine() } catch { self.notice = error.localizedDescription; return }
            self.endpointer = SpeechEndpointer(settings: .standby)
            self.standby = true
            self.warmTranscriber()
        }
    }
    /// Start whisper-server ahead of the first utterance so the wake gate answers at once.
    private func warmTranscriber() {
        let speech = self.speech, configuration = self.config
        Task.detached { try? await speech.ensureRunning(configuration: configuration) }
    }
    private func disarmStandby() {
        standbyWork?.cancel(); standbyWork = nil
        standby = false
        if audio.capturing && phase == .idle { audio.discardCapture() }
    }
    /// One reading per audio chunk. Which endpointer it feeds depends on what Daisy is doing.
    private func observe(power: Float, duration: TimeInterval) {
        switch phase {
        case .listening:
            switch endpointer.observe(power: power, duration: duration) {
            case .finished: endListening()
            case .timedOut: abandonListening()
            default: break
            }
        case .speaking:
            guard listeningMode != .manual, audio.echoCancellation else { return }
            if bargeEndpointer.observe(power: power, duration: duration) == .speechStarted { bargeIn() }
        case .idle:
            guard standby else { return }
            switch endpointer.observe(power: power, duration: duration) {
            case .speechStarted: audio.beginCapture(preRoll: 1.0)
            case .finished: gateStandbyUtterance()
            default: break
            }
        default: break
        }
    }
    /// Standby heard something. Transcribe it; only an utterance that starts with the wake phrase
    /// becomes a turn, everything else is dropped without a trace.
    private func gateStandbyUtterance() {
        endpointer = SpeechEndpointer(settings: .standby)
        guard let url = try? audio.endCapture() else { return }
        let token = generation
        standbyWork = Task { [weak self] in
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            guard let self else { return }
            do {
                let text = try await self.speech.transcribe(audio: url, configuration: self.config)
                guard !Task.isCancelled, self.generation == token, self.standby, WakePhrase.matches(text) else { return }
                let request = WakePhrase.stripping(text)
                self.standby = false
                if request.isEmpty { self.beginListening(purpose: .command) } else { self.run(request, spoken: true) }
            } catch { }
        }
    }
    func beginListening() { beginListening(purpose: .command) }
    private func beginListening(purpose: ListeningPurpose) {
        guard !holdRequested else { return }
        stop(clearNotice: true); standby = false; holdRequested = true; phase = .preparing
        self.purpose = purpose
        let token = generation
        work = Task {
            guard await audio.requestMicrophone() else {
                if generation == token { notice = "Allow Daisy in System Settings → Privacy & Security → Microphone."; phase = .idle; holdRequested = false }
                return
            }
            guard holdRequested, generation == token, !Task.isCancelled else { return }
            do {
                try audio.startEngine()
                warmTranscriber()
                endpointer = SpeechEndpointer(settings: purpose == .followUp ? .followUp : .standard)
                for reading in audio.beginCapture(preRoll: purpose == .command ? 0.5 : 0) {
                    _ = endpointer.observe(power: reading.power, duration: reading.duration)
                }
                phase = .listening
            } catch { notice = error.localizedDescription; phase = .idle; holdRequested = false; rest() }
        }
    }
    func endListening() {
        holdRequested = false
        if phase == .preparing { stop(); rest(); return }
        guard phase == .listening else { return }
        let token = generation
        let quietly = purpose == .followUp
        do {
            let url = try audio.endCapture()
            phase = .transcribing
            work = Task {
                defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                do {
                    let text = WakePhrase.stripping(try await speech.transcribe(audio: url, configuration: config))
                    try Task.checkCancellation(); guard generation == token else { return }
                    guard !text.isEmpty else { abandonListening(); return }
                    // Recognized requests may prepare changes, but cannot click their review cards.
                    run(text, spoken: true)
                } catch is CancellationError { }
                catch {
                    guard generation == token else { return }
                    if !quietly { notice = error.localizedDescription }
                    phase = .idle; rest()
                }
            }
        } catch {
            if !quietly { notice = error.localizedDescription }
            phase = .idle; rest()
        }
    }
    private func abandonListening() {
        audio.discardCapture(); holdRequested = false
        if purpose == .command, listeningMode == .manual { notice = "No speech was detected. Click Record, speak, then pause." }
        phase = .idle; rest()
    }
    private func bargeIn() {
        stop(clearNotice: true)
        beginListening(purpose: .command)
    }
    private func finishTurn() {
        phase = .idle; currentStep = nil
        let again = voiceTurn && listeningMode != .manual
        voiceTurn = false
        if again { beginListening(purpose: .followUp) } else { rest() }
    }
    /// Back to whatever idle means for the current mode: standby with the mic open, or mic off.
    private func rest() {
        phase = .idle
        switch listeningMode {
        case .wakeWord: armStandby()
        case .manual, .handsFree: if !audio.capturing { audio.stopEngine() }
        }
    }
    private func engineLost() {
        standby = false
        if phase == .listening || phase == .preparing { holdRequested = false; phase = .idle; notice = "The audio device changed. Try again." }
        guard listeningMode == .wakeWord, !busy else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.armStandby()
        }
    }
    func toggleListening() {
        if phase == .listening || phase == .preparing { endListening() }
        else if busy { stop(clearNotice: true); beginListening(purpose: .command) }
        else { beginListening(purpose: .command) }
    }
    func previewVoice() {
        stop(clearNotice: true)
        let token = generation
        phase = .synthesizing
        work = Task {
            do {
                try await audio.speak("Good evening. I'm Daisy. I can help you think through an idea, find what you need, and work through a task with you.",
                                      voice: config.naturalVoice ?? "bm_george", speed: config.speechRate ?? 1) {
                    if self.generation == token { self.phase = .speaking }
                }
                if generation == token { phase = .idle; rest() }
            } catch is CancellationError { }
            catch { if generation == token { phase = .idle; notice = error.localizedDescription; rest() } }
        }
    }
    /// Internal cancel: drops pending work, playback and capture. The engine and standby flag are
    /// left to the caller, which knows whether it is starting something new or going to rest.
    func stop(clearNotice: Bool = false) {
        let wasBusy = busy
        for review in messages.flatMap({ $0.receipts.compactMap(\.output.review) }) where reviewResults[review.id] == nil && !applyingReviews.contains(review.id) {
            expiredReviews.insert(review.id)
        }
        generation = UUID(); work?.cancel(); work = nil
        standbyWork?.cancel(); standbyWork = nil
        endVoice(); approvals = []
        // Whatever was already written stays in the transcript, marked as cut off.
        if !liveText.isEmpty {
            messages.append(ConversationItem(role: "assistant", text: liveText, detail: "Stopped", decisions: decisions))
            liveText = ""
        }
        for index in activity.indices where activity[index].state == .running { activity[index].state = .failed; activity[index].finished = Date() }
        audio.stop(); holdRequested = false; phase = .idle; currentStep = nil
        if clearNotice { notice = nil }
        else if wasBusy { notice = "Stopped." }
    }
    /// The user's Stop: cancel everything and return to rest.
    func interrupt() {
        stop()
        rest()
    }
    func clearConversation() {
        stop(clearNotice: true); messages = []; recentSearch = nil; reviewResults = [:]; expiredReviews = []; activity = []
        let backend = self.backend
        Task { await backend.newSession() }
        rest()
    }
    func reviewStatus(_ review: ReviewedAction) -> String? {
        reviewResults[review.id] ?? (expiredReviews.contains(review.id) ? "Expired. Ask Daisy to prepare this again." : nil)
    }
    func applyReview(_ review: ReviewedAction) {
        guard reviewStatus(review) == nil, !applyingReviews.contains(review.id), !busy else { return }
        applyingReviews.insert(review.id)
        Task {
            defer { applyingReviews.remove(review.id) }
            do {
                let result = try await review.commit()
                reviewResults[review.id] = result
                messages.append(ConversationItem(role: "status", text: result))
                await reloadTasks()
            } catch { reviewResults[review.id] = "Not applied: " + error.localizedDescription }
        }
    }
    func discardReview(_ review: ReviewedAction) { reviewResults[review.id] = "Discarded. No change applied." }

    // MARK: Chrome

    func connectChrome() {
        guard !chromeConnecting else { return }
        stop(clearNotice: true); chromeConnecting = true; connectionNotice = "Waiting for Chrome to allow the local connection…"
        browserWork = Task {
            defer { chromeConnecting = false }
            do {
                try await chrome.connect(node: config.browserNode ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/node").path)
                chromeConnected = true; connectionNotice = "Connected. Daisy can find tabs, read accessible page text and open research pages when requested."
                startChromeHealth()
            } catch is CancellationError { chromeConnected = false; connectionNotice = "Connection cancelled." }
            catch { chromeConnected = false; connectionNotice = error.localizedDescription }
            rest()
        }
    }
    func disconnectChrome() {
        stop(clearNotice: true); browserWork?.cancel(); chromeHealth?.cancel(); chromeHealth = nil; chromeConnected = false
        Task { await chrome.disconnect(); connectionNotice = "Disconnected from Chrome."; rest() }
    }
    /// Periodically probe the adapter so the badge stops lying when Chrome or the child dies.
    /// A slow reply is left alone: the model may be generating and starving the adapter.
    private func startChromeHealth() {
        chromeHealth?.cancel()
        chromeHealth = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                guard let self else { return }
                if self.busy || self.chromeConnecting { continue }
                guard await self.chrome.health() == .lost else { continue }
                self.chromeConnected = false
                if self.connectionNotice?.hasPrefix("Connected.") == true {
                    self.connectionNotice = "The Chrome adapter stopped. Reconnect in Connections."
                }
                return
            }
        }
    }
    func openChromeSetup() {
        let application = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        NSWorkspace.shared.open([URL(string: "chrome://inspect/#remote-debugging")!], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Tasks, folder, memory, settings

    func reloadTasks() async { tasks = await taskStore?.all() ?? [] }
    func saveTask(_ item: WorkItem) async -> Bool {
        guard let taskStore else { notice = "Task storage is unavailable."; return false }
        do { try await taskStore.save(item, expectedRevision: item.revision); await reloadTasks(); return true }
        catch { notice = error.localizedDescription; return false }
    }
    func deleteTask(_ item: WorkItem) {
        Task {
            do { try await taskStore?.delete(item); await reloadTasks() }
            catch { notice = error.localizedDescription }
        }
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.message = "Daisy will search filenames only inside this folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            stop(clearNotice: true); try saveBookmark(url)
            selectedFolder?.stopAccessingSecurityScopedResource()
            _ = url.startAccessingSecurityScopedResource(); selectedFolder = url; recentSearch = nil
            rest()
        } catch { notice = error.localizedDescription }
    }
    private func saveBookmark(_ url: URL) throws {
        let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        try data.write(to: bookmarkURL, options: .atomic)
    }
    func revokeFolder() {
        do {
            stop(clearNotice: true)
            if FileManager.default.fileExists(atPath: bookmarkURL.path) { try FileManager.default.removeItem(at: bookmarkURL) }
            selectedFolder?.stopAccessingSecurityScopedResource(); selectedFolder = nil; recentSearch = nil
            rest()
        } catch { notice = error.localizedDescription }
    }
    func openFile(_ file: FileMatch, reveal: Bool) {
        guard config.allowFileSearch, let root = selectedFolder, FileSearch.isInside(URL(fileURLWithPath: file.path), root: root),
              FileManager.default.fileExists(atPath: file.path) else { notice = "This result is no longer accessible in your selected folder."; return }
        let url = URL(fileURLWithPath: file.path)
        if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else if !NSWorkspace.shared.open(url) { notice = "macOS could not open this file." }
    }
    func reloadMemories() async {
        do { memories = try await store?.all() ?? [] }
        catch { notice = error.localizedDescription }
    }
    func saveMemory(key: String, value: String) async -> Bool {
        do {
            guard let store else { throw DaisyError.message("Memory database unavailable.") }
            stop(clearNotice: true)
            try await store.put(key: key, value: value, source: "Explicit edit in Memory tab")
            await reloadMemories(); rest(); return true
        } catch { notice = error.localizedDescription; return false }
    }
    func deleteMemory(_ memory: Memory) {
        stop(clearNotice: true)
        Task {
            do { try await store?.delete(key: memory.key); await reloadMemories(); clearConversation() }
            catch { notice = error.localizedDescription }
        }
    }
    func saveSettings() {
        stop(clearNotice: true)
        do {
            try config.save()
            // Switching brains (or where Hermes lives) replaces the backend; other changes just reconnect.
            if signature != backendSignature {
                let old = backend
                Task { await old.shutdown() }
                backend = makeBackend(); backendSignature = signature
                messages = []; activity = []
            }
            connected = false; connectWhenAllowed()
            if config.speakResponses { Task { await speechWorker.warmUp() } }
            applyListeningMode()
        } catch { notice = error.localizedDescription }
    }
    func shutdown() async {
        startup?.cancel(); healthMonitor?.cancel(); chromeHealth?.cancel(); stop()
        audio.stopEngine()
        selectedFolder?.stopAccessingSecurityScopedResource()
        browserWork?.cancel(); await chrome.disconnect()
        await speechWorker.stop()
        await speech.shutdown()
        await backend.shutdown()
    }
}
