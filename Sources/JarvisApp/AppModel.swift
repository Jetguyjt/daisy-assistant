import AppKit
import SwiftUI
import JarvisCore

enum AssistantPhase: String { case idle = "Ready", preparing = "Preparing microphone", listening = "Listening", thinking = "Thinking", searching = "Searching files", transcribing = "Transcribing", synthesizing = "Preparing voice", speaking = "Speaking" }
enum ListeningMode: String, CaseIterable, Identifiable {
    case manual, handsFree, wakeWord
    var id: String { rawValue }
    var title: String {
        switch self {
        case .manual: return "Click to talk"
        case .handsFree: return "Hands-free conversation"
        case .wakeWord: return "Wake word: Hey Jarvis"
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
}

@MainActor final class AppModel: ObservableObject {
    @Published var config = Configuration()
    @Published var phase: AssistantPhase = .idle
    @Published var input = ""
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
    private var expiredReviews = Set<UUID>()
    private var taskStore: TaskStore?
    private let chrome = ChromeConnection()
    private var browserWork: Task<Void, Never>?
    private var chromeHealth: Task<Void, Never>?
    let audio = AudioController()
    private var store: MemoryStore?
    private let client = OllamaClient()
    private var work: Task<Void, Never>?
    private var generation = UUID()
    private var holdRequested = false
    private let runtime = LocalRuntime()
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

    init() {
        do {
            config = try Configuration.load()
            store = try MemoryStore(url: Configuration.dataDirectory.appendingPathComponent("memory.sqlite"))
            taskStore = try TaskStore(url: Configuration.dataDirectory.appendingPathComponent("tasks.json"))
            if let data = try? Data(contentsOf: bookmarkURL) {
                var stale = false
                let folder = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
                _ = folder.startAccessingSecurityScopedResource()
                selectedFolder = folder
                if stale { try saveBookmark(folder) }
            }
        } catch { notice = "Setup needs attention: \(error.localizedDescription)" }
        audio.speechWorker = speechWorker
        audio.onChunk = { [weak self] power, duration in self?.observe(power: power, duration: duration) }
        audio.onEngineLost = { [weak self] in self?.engineLost() }
        Task {
            await reloadMemories(); await reloadTasks()
            if config.speakResponses { await speechWorker.warmUp() }
            applyListeningMode()
        }
        startRuntime()
    }

    func startRuntime() {
        guard !connecting else { return }
        connected = false; connecting = true
        startup = Task {
            defer { connecting = false }
            do {
                try await runtime.ensureRunning(configuration: config)
                availableModels = try await client.models()
                try await client.verifyLocal(model: config.model)
                connected = true
            } catch is CancellationError { }
            catch { connected = false; notice = error.localizedDescription }
        }
        if healthMonitor == nil {
            healthMonitor = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
                    guard let self else { return }
                    let reachable = await self.client.isReachable()
                    if !reachable { self.connected = false }
                }
            }
        }
    }

    func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.utf8.count <= 4000 else { notice = "Please keep each request under 4,000 UTF-8 bytes so it fits the local context window."; return }
        input = ""; run(text)
    }
    func run(_ text: String, spoken: Bool = false) {
        stop(clearNotice: true)
        standby = false; voiceTurn = spoken
        let token = generation
        let history = messages.filter { $0.role == "user" || $0.role == "assistant" }.suffix(8).map { ChatMessage(role: $0.role, content: $0.text) }
        messages.append(ConversationItem(role: "user", text: text))
        if messages.count > 100 { messages.removeFirst(messages.count - 100) }
        phase = .thinking
        work = Task {
            do {
                let answer: String
                var report: SearchReport?; var detail: String?
                var receipts: [CapabilityReceipt] = []
                if let command = try MemoryCommand.parse(text) {
                    guard let store else { throw JarvisError.message("Memory storage is unavailable. Restart after fixing the setup error.") }
                    let memory = try await store.put(key: command.key, value: command.value, source: "Explicit user request: \(text)")
                    answer = "Remembered: \(memory.value)"
                    detail = "Saved locally · \(memory.key) · revision \(memory.revision)"
                    await reloadMemories()
                } else if text.hasPrefix("/find ") {
                    phase = .searching
                    let session = CapabilitySession(registry: try capabilityRegistry())
                    let receipt = try await session.execute(.init(name: "search_files", arguments: ["query": .string(String(text.dropFirst(6)))]))
                    receipts = [receipt]; report = receipt.output.files
                    answer = receipt.output.summary
                    detail = "Direct capability request"
                } else {
                    // Always preflight, even if the badge was previously green. Do not replay an action after dispatch.
                    connecting = true
                    do {
                        try await runtime.ensureRunning(configuration: config)
                        try await client.verifyLocal(model: config.model)
                        try Task.checkCancellation()
                        guard generation == token else { throw CancellationError() }
                        connected = true; connecting = false
                    } catch {
                        connected = false; connecting = false; throw error
                    }
                    var contextMemories = capabilityEnabled("search_memories") ? Array(memories.prefix(12)) : []
                    if capabilityEnabled("search_memories"), let store {
                        let hits = try await store.relevant(to: text)
                        contextMemories = hits + contextMemories.filter { candidate in !hits.contains { $0.key == candidate.key } }
                    }
                    let result = try await AssistantEngine(client: client).respond(text: text, history: Array(history), memories: contextMemories,
                        model: config.model, registry: try capabilityRegistry(), spoken: config.speakResponses, onProgress: { [weak self] step in
                            await self?.updateProgress(step, token: token)
                        })
                    answer = result.text; report = result.search
                    receipts = result.receipts
                    detail = String(format: "Local · %@ · %.1fs", config.model, result.elapsed)
                }
                try Task.checkCancellation()
                guard generation == token else { return }
                if let report { recentSearch = report }
                currentStep = nil
                messages.append(ConversationItem(role: "assistant", text: answer, files: report, detail: detail, receipts: receipts))
                let speech = config.speakResponses ? SpeechText.spoken(from: answer) : ""
                if !speech.isEmpty {
                    phase = .synthesizing
                    bargeEndpointer = SpeechEndpointer(settings: .bargeIn)
                    do {
                        try await audio.speak(speech, voice: config.naturalVoice ?? "bm_george", speed: config.speechRate ?? 1) {
                            if self.generation == token { self.phase = .speaking }
                        }
                    }
                    catch is CancellationError { throw CancellationError() }
                    catch { notice = "The answer is ready, but speech failed: \(error.localizedDescription)" }
                }
                if generation == token { finishTurn() }
            } catch is CancellationError { if generation == token { phase = .idle } }
            catch {
                guard generation == token else { return }
                if (error as? URLError)?.code == .cancelled { phase = .idle; return }
                if error is URLError { connected = false }
                currentStep = nil
                notice = error.localizedDescription; phase = .idle
                messages.append(ConversationItem(role: "status", text: error.localizedDescription))
                rest()
            }
        }
    }
    private func updateProgress(_ step: String, token: UUID) {
        if generation == token { currentStep = step }
    }

    // MARK: Listening

    /// Called after settings change and at launch. Wake-word mode keeps the mic open; the others
    /// open it only while a conversation is going.
    func applyListeningMode() {
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
                self.notice = "Allow Jarvis in System Settings → Privacy & Security → Microphone to use the wake word."; return
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
    /// One reading per audio chunk. Which endpointer it feeds depends on what Jarvis is doing.
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
                if generation == token { notice = "Allow Jarvis in System Settings → Privacy & Security → Microphone."; phase = .idle; holdRequested = false }
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
                try await audio.speak("Good evening. I'm Jarvis. I can help you think through an idea, find what you need, and work through a task with you.",
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
        audio.stop(); holdRequested = false; phase = .idle; currentStep = nil
        if clearNotice { notice = nil }
        else if wasBusy { notice = "Stopped. Completed memory saves remain saved; pending responses were discarded." }
    }
    /// The user's Stop: cancel everything and return to rest.
    func interrupt() {
        stop()
        rest()
    }
    func clearConversation() { stop(clearNotice: true); messages = []; recentSearch = nil; reviewResults = [:]; expiredReviews = []; rest() }
    func reviewStatus(_ review: ReviewedAction) -> String? {
        reviewResults[review.id] ?? (expiredReviews.contains(review.id) ? "Expired. Ask Jarvis to prepare this again." : nil)
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
                chromeConnected = true; connectionNotice = "Connected. Jarvis can find tabs, read accessible page text and open research pages when requested."
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
        panel.allowsMultipleSelection = false; panel.message = "Jarvis will search filenames only inside this folder."
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
            guard let store else { throw JarvisError.message("Memory database unavailable.") }
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
            try config.save(); connected = false; startRuntime()
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
        await runtime.shutdown()
    }
}
