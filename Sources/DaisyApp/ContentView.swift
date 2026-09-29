import SwiftUI
import DaisyCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Namespace private var orbSpace
    @AppStorage("telemetryCollapsed") private var telemetryCollapsed = false
    /// Off: the core stays in the middle and replies show as a caption under it. On: the full transcript.
    @AppStorage("chatMode") private var chatMode = false
    @State private var showingChats = false
    @State private var atBottom = true

    private static let tabs: [(id: String, label: String, symbol: String)] = [
        ("Assistant", "DAISY", "circle.hexagongrid"), ("Tasks", "TASKS", "checklist"),
        ("Jobs", "JOBS", "square.stack.3d.forward.dottedline"),
        ("Memory", "MEMORY", "square.stack.3d.up"), ("Connections", "LINKS", "point.3.connected.trianglepath.dotted"),
        ("Capabilities", "TOOLS", "square.grid.2x2"), ("Settings", "SETUP", "slider.horizontal.3")
    ]

    var body: some View {
        ZStack {
            HUDBackground()
            HStack(spacing: 0) {
                rail
                VStack(spacing: 0) {
                    topBar
                    Rectangle().fill(HUD.line.opacity(0.2)).frame(height: 1).padding(.bottom, 14)
                    Group {
                        switch model.tab {
                        case "Memory": MemoryView(model: model)
                        case "Tasks": TasksView(model: model)
                        case "Jobs": JobsView(jobs: model.jobs, approvals: model.approvalQueue,
                                              alwaysOn: model.usesHermes ? model.alwaysOn : nil, budget: model.budget)
                        case "Connections": ConnectionsView(model: model)
                        case "Settings": SettingsView(model: model)
                        case "Capabilities": CapabilitiesView(model: model)
                        default: assistant
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(HUD.ice)
        .tint(HUD.accent)
        .onExitCommand { model.interrupt() }
    }

    // MARK: Frame

    private var rail: some View {
        VStack(spacing: 8) {
            Button { model.tab = "Assistant" } label: {
                VStack(spacing: 3) {
                    Text("D").font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(HUD.accent)
                    Text("DAISY").font(HUD.label(7)).tracking(1.4).foregroundStyle(HUD.dim)
                }
            }
            .buttonStyle(.plain).padding(.top, 34).padding(.bottom, 20)
            .accessibilityLabel("Assistant")
            ForEach(Self.tabs, id: \.id) { tab in
                RailButton(label: tab.label, symbol: tab.symbol, selected: model.tab == tab.id,
                           badge: tab.id == "Memory" && !model.memories.isEmpty ? "\(model.memories.count)" : nil) { model.tab = tab.id }
            }
            Spacer()
            Text("V0.4").font(HUD.label(9)).tracking(1.4).foregroundStyle(HUD.dim).padding(.bottom, 20)
        }
        .frame(width: 76)
        .background(HUD.deep.opacity(0.9))
        .overlay(alignment: .trailing) { Rectangle().fill(HUD.line.opacity(0.2)).frame(width: 1) }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.tab == "Assistant" ? "ACTIVE SESSION" : "WORKSPACE / " + sectionLabel).font(HUD.label(10)).tracking(1.6).foregroundStyle(HUD.dim)
                Text(sessionTitle).font(.system(size: 13, weight: .medium)).foregroundStyle(HUD.ice).lineLimit(1)
            }
            Spacer()
            StatusPill(text: linkText, color: linkColor, lit: model.connected)
            MicPill(audio: model.audio, phase: model.phase, standby: model.standby)
            if model.usesHermes {
                Button { model.refreshChats(); showingChats = true } label: { Label("Chats", systemImage: "clock.arrow.circlepath") }
                    .buttonStyle(HUDButtonStyle(kind: .ghost, compact: true))
                    .help("Earlier conversations")
                    .popover(isPresented: $showingChats, arrowEdge: .bottom) {
                        ChatsList(model: model) { showingChats = false }
                    }
            }
            Button { model.clearConversation() } label: { Label("New conversation", systemImage: "plus.circle") }
                .buttonStyle(HUDButtonStyle(kind: .ghost, compact: true))
                .help("New conversation (⌘N)")
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(context.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
                    .font(HUD.readout(12)).foregroundStyle(HUD.accent).monospacedDigit()
            }
            .frame(width: 70, alignment: .trailing)
        }
        .padding(.leading, 20).padding(.trailing, 18).padding(.top, 22).frame(height: 70)
    }

    private var sessionTitle: String {
        guard model.tab == "Assistant" else { return model.tab }
        guard let first = model.messages.first(where: { $0.role == "user" })?.text else { return "New session" }
        return first.count > 60 ? String(first.prefix(60)) + "…" : first
    }
    private var sectionLabel: String {
        model.tab == "Assistant" ? "ASSISTANT" : Self.tabs.first { $0.id == model.tab }?.label ?? ""
    }
    private var linkText: String {
        switch model.agentLink {
        case .ready(let detail): return (model.usesHermes ? "HERMES" : "LOCAL") + " · " + (detail ?? model.config.model).uppercased()
        case .starting: return "CONNECTING"
        case .needsSetup: return "SETUP NEEDED"
        case .offline: return "OFFLINE"
        }
    }
    private var linkColor: Color {
        switch model.agentLink {
        case .ready: return HUD.accent
        case .starting: return HUD.ember
        case .needsSetup: return HUD.amber
        case .offline: return HUD.crimson
        }
    }

    // MARK: Assistant

    private var conversationEmpty: Bool { model.messages.isEmpty }
    private var setupShowing: Bool {
        switch model.agentLink { case .needsSetup, .offline: return model.phase == .idle; default: return false }
    }

    private var assistant: some View {
        ZStack {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 12) {
                if chatMode { transcript } else { hero }
                composer
            }
            if telemetryCollapsed {
                VStack(spacing: 22) {
                    Button { telemetryCollapsed = false } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.plain).foregroundStyle(HUD.dim).help("Show telemetry")
                    Text("TELEMETRY").font(HUD.label(9)).tracking(1.6).foregroundStyle(HUD.dim)
                        .fixedSize().rotationEffect(.degrees(90)).frame(width: 20, height: 90)
                    Spacer()
                }
                .padding(.top, 14).frame(width: 36).frame(maxHeight: .infinity).hudPanel(brackets: false)
            } else {
                corePanel.frame(width: 264)
            }
        }
        .opacity(model.composerExpanded ? 0 : 1)
            if model.composerExpanded {
                ExpandedComposer(model: model, composer: model.composer)
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 16)
        .animation(.spring(response: 0.55, dampingFraction: 0.86), value: chatMode)
        .animation(.easeOut(duration: 0.18), value: model.composerExpanded)
    }

    private var mood: OrbMood {
        switch model.phase {
        case .idle:
            if case .offline = model.agentLink { return .offline }
            return model.standby ? .standby : .idle
        case .preparing, .listening: return .listening
        case .transcribing, .thinking, .searching, .working, .responding: return .thinking
        case .awaitingApproval: return .approval
        case .synthesizing, .speaking: return .speaking
        }
    }
    private var moodColor: Color { mood == .idle || mood == .standby ? HUD.accent : mood.tint }

    private var phaseTitle: String {
        switch model.phase {
        case .idle:
            if case .needsSetup = model.agentLink { return "SETUP NEEDED" }
            return mood == .offline ? "OFFLINE" : model.standby ? "STANDING BY" : "READY"
        case .preparing: return "OPENING MIC"
        case .searching, .working: return (model.currentStep ?? "Working").uppercased()
        case .awaitingApproval: return "NEEDS YOUR OK"
        default: return model.phase.rawValue.uppercased()
        }
    }
    private var phaseDetail: String? {
        switch model.phase {
        case .idle:
            if case .offline(let reason) = model.agentLink { return reason }
            if case .needsSetup = model.agentLink { return nil }
            return model.standby ? "Say “Hey Daisy”" : "Type below or press Talk"
        case .thinking: return model.currentStep
        case .listening: return "Pause to send"
        default: return nil
        }
    }

    private func orb(_ size: CGFloat) -> some View {
        OrbView(audio: model.audio, mood: mood, visible: model.appVisible)
            .matchedGeometryEffect(id: "core", in: orbSpace)
            .frame(width: size, height: size)
    }

    private func phaseReadout(large: Bool) -> some View {
        VStack(spacing: large ? 8 : 5) {
            Text(phaseTitle).font(HUD.label(large ? 12 : 10)).tracking(large ? 4 : 2.5).foregroundStyle(moodColor)
                .lineLimit(1).contentTransition(.opacity)
            if let detail = phaseDetail {
                Text(detail).font(.system(size: large ? 13 : 11)).foregroundStyle(HUD.steel).lineLimit(2).multilineTextAlignment(.center)
            }
        }
        .animation(.easeOut(duration: 0.2), value: phaseTitle)
    }

    private var hero: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            orb(setupShowing ? 220 : 260)
            phaseReadout(large: true)
            if setupShowing {
                SetupPanel(model: model)
            } else if let caption {
                Text(rich(caption))
                    .font(.system(size: 14)).lineSpacing(4).foregroundStyle(HUD.ice.opacity(0.9))
                    .multilineTextAlignment(.center).lineLimit(4).truncationMode(.head)
                    .frame(maxWidth: 560)
                    .textSelection(.enabled)
                    .onTapGesture(count: 2) { chatMode = true }
                    .help("Double-click for the full conversation")
            } else if conversationEmpty {
                HStack(spacing: 10) {
                    Button { model.composer.set("/find ") } label: { Label("Find a file", systemImage: "doc.text.magnifyingglass") }
                    Button { model.composer.set("Remember that ") } label: { Label("Remember something", systemImage: "brain") }
                }
                .buttonStyle(HUDButtonStyle(kind: .ghost, compact: true))
            }
            // Anything waiting on a yes shows here too, so it's never hidden behind chat mode.
            ApprovalQueueList(queue: model.approvalQueue).frame(maxWidth: 560)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What Daisy is saying right now, or the last thing she said, under the core.
    private var caption: String? {
        if !model.liveText.isEmpty { let shown = model.shownText; return shown.isEmpty ? nil : shown }
        guard let last = model.messages.last, last.role == "assistant", !last.text.isEmpty else { return nil }
        return last.text
    }

    private var chatModeButton: some View {
        Button { chatMode.toggle() } label: {
            Label(chatMode ? "Core" : "Chat", systemImage: chatMode ? "circle.hexagongrid" : "text.bubble")
        }
        .buttonStyle(HUDButtonStyle(kind: chatMode ? .primary : .ghost, compact: true))
        .help(chatMode ? "Back to the core view" : "Show the full conversation")
        .accessibilityLabel(chatMode ? "Show the core" : "Show the conversation")
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(model.messages) { item in
                        MessageView(model: model, item: item, isLast: item.id == model.messages.last?.id).equatable().id(item.id)
                            .transition(.opacity.combined(with: .offset(y: 8)))
                    }
                    if !model.liveText.isEmpty || [.thinking, .searching, .working, .responding, .awaitingApproval].contains(model.phase) {
                        LiveReply(text: model.shownText, step: model.currentStep ?? model.phase.rawValue).id("live")
                    }
                    ApprovalQueueList(queue: model.approvalQueue)
                    if setupShowing { SetupPanel(model: model) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 24).padding(.vertical, 20)
            }
            .scrollIndicators(.never)
            .modifier(BottomTracker(atBottom: $atBottom))
            // Follow new text only while already at the bottom, so reading back isn't yanked away.
            .onChange(of: model.messages.count) { if atBottom { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) } } }
            .onChange(of: model.shownText) { if atBottom { proxy.scrollTo("bottom", anchor: .bottom) } }
            // A new card always comes into view: it's waiting on an answer.
            .onReceive(model.approvalQueue.$items.map(\.count).removeDuplicates()) { _ in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !atBottom {
                    Button { withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("bottom", anchor: .bottom) } } label: {
                        Image(systemName: "arrow.down").font(.system(size: 12, weight: .bold))
                            .frame(width: 32, height: 32).foregroundStyle(HUD.void)
                            .background(Rectangle().fill(HUD.accent))
                    }
                    .buttonStyle(.plain).padding(16).help("Jump to latest").accessibilityLabel("Jump to latest")
                    .transition(.opacity)
                }
            }
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.035),
                                     .init(color: .black, location: 0.965), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .hudPanel(radius: 16)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if let notice = model.notice {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(HUD.amber)
                    Text(notice).foregroundStyle(HUD.ice.opacity(0.85)).textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(HUD.dim)
                        .accessibilityLabel("Dismiss")
                }
                .font(.system(size: 11.5)).padding(.horizontal, 12).padding(.vertical, 9)
                .background(Rectangle().fill(HUD.amber.opacity(0.06)))
                .overlay(Rectangle().strokeBorder(HUD.amber.opacity(0.3), lineWidth: 1))
            }
            HStack(alignment: .bottom, spacing: 14) {
                ComposerBar(model: model, composer: model.composer)
                chatModeButton
                VStack(alignment: .trailing, spacing: 10) {
                    // Same setting as Settings → Voice → Read answers aloud, saved right away.
                    HUDSwitch(title: "DAISY'S VOICE", isOn: model.config.speakResponses,
                              detail: model.config.speakResponses ? "Replies spoken aloud" : "Text only") {
                        model.config.speakResponses.toggle()
                        do { try model.config.save() } catch { model.notice = "Couldn't save the voice setting: \(error.localizedDescription)" }
                    }
                    .help("Turn Daisy's spoken replies on or off")
                    HUDSwitch(title: "ALWAYS LISTENING", isOn: model.alwaysListening,
                              detail: model.alwaysListening ? (model.batteryHold ? BatteryListening.note : model.standby ? "Say “Hey Daisy”" : "Arming mic…")
                                                            : "Mic off between turns") {
                        model.setAlwaysListening(!model.alwaysListening)
                    }
                    .help("Keep the mic open for “Hey Daisy” (⌘⇧L)")
                }
                .frame(width: 200, alignment: .trailing)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .hudPanel(radius: 14, brackets: false)
        }
    }

    // MARK: Core panel

    private var corePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if chatMode {
                VStack(spacing: 10) {
                    orb(150)
                    phaseReadout(large: false)
                }
                .frame(maxWidth: .infinity).padding(.top, 16).padding(.bottom, 14)
                rule
            }
            HStack {
                Text("SYSTEM TELEMETRY").hudCaption(HUD.accent)
                Spacer()
                Button { telemetryCollapsed = true } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain).foregroundStyle(HUD.dim).help("Hide telemetry")
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 4)
            // Scrolls instead of growing, so a short window never pushes the composer off screen.
            ScrollView {
            VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("ACTIVITY").hudCaption()
                if model.activity.isEmpty {
                    Text("Nothing running").font(.system(size: 11)).foregroundStyle(HUD.dim)
                } else {
                    ForEach(model.activity.suffix(6)) { item in ActivityRow(item: item) }
                }
            }
            .padding(16)
            rule
            if let plan = model.plan, !plan.entries.isEmpty {
                PlanView(plan: plan).padding(16)
                rule
            }
            VStack(alignment: .leading, spacing: 12) {
                readout("LINK", model.agentLink.isReady ? (model.agentDetail ?? model.linkLabel) : linkText.capitalized, color: model.agentLink.isReady ? HUD.ice : linkColor)
                readout("REPLY", replyText)
                MicReadout(audio: model.audio)
                readout("FOLDER", model.selectedFolder?.lastPathComponent ?? "None") { model.chooseFolder() }
                readout("MEMORY", "\(model.memories.count) saved") { model.tab = "Memory" }
                readout("TASKS", "\(model.tasks.filter(\.status.isOpen).count) open") { model.tab = "Tasks" }
                JobsReadout(jobs: model.jobs) { model.tab = "Jobs" }
                if model.usesHermes { BudgetReadout(budget: model.budget) }
            }
            .padding(16)
            }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .hudPanel(radius: 16)
    }

    private var rule: some View { Rectangle().fill(HUD.line.opacity(0.1)).frame(height: 1) }

    private var replyText: String {
        guard let reply = model.lastReply else { return "—" }
        if let first = reply.firstText { return String(format: "%.1fs · first word %.1fs", reply.total, first) }
        return String(format: "%.1fs", reply.total)
    }

    private func readout(_ label: String, _ value: String, color: Color = HUD.ice, action: (() -> Void)? = nil) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(HUD.label(10)).tracking(1.6).foregroundStyle(HUD.dim)
                Text(value).font(.system(size: 12)).foregroundStyle(color).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if let action {
                Button(action: action) { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(HUD.dim)
                    .accessibilityLabel("Open \(label.lowercased())")
            }
        }
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(HUD.line.opacity(0.12)).frame(height: 1) }
    }
}

// MARK: - Pieces

/// These watch the audio controller directly so levels and timers stay live.
private struct MicPill: View {
    @ObservedObject var audio: AudioController
    let phase: AssistantPhase
    let standby: Bool
    var body: some View {
        let live = phase == .listening
        StatusPill(text: live ? "MIC LIVE" : standby ? "HEY DAISY" : audio.engineRunning ? "MIC OPEN" : "MIC OFF",
                   color: live ? HUD.crimson : audio.engineRunning ? HUD.accent : HUD.dim, lit: audio.engineRunning)
    }
}

private struct MicReadout: View {
    @ObservedObject var audio: AudioController
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MIC INPUT").font(HUD.label(10)).tracking(1.6).foregroundStyle(HUD.dim)
            HStack(spacing: 8) {
                Text(audio.inputDeviceName).font(.system(size: 12)).foregroundStyle(audio.engineRunning ? HUD.ice : HUD.steel).lineLimit(1)
                Spacer(minLength: 0)
                if audio.engineRunning { LevelBars(level: audio.level, bars: 10) }
            }
        }
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(HUD.line.opacity(0.12)).frame(height: 1) }
    }
}

struct ListeningStrip: View {
    @ObservedObject var audio: AudioController
    let preparing: Bool
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(HUD.crimson).frame(width: 8, height: 8).shadow(color: HUD.crimson, radius: 5)
            Text(preparing ? "OPENING MIC" : "LISTENING · \(Int(audio.elapsed))S")
                .font(HUD.label(10)).tracking(1.6).foregroundStyle(HUD.ice)
            LevelBars(level: audio.level, bars: 16)
            Spacer(minLength: 6)
            Text(audio.inputDeviceName).font(.system(size: 11)).foregroundStyle(HUD.dim).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 30)
    }
}

private struct RailButton: View {
    let label: String
    let symbol: String
    let selected: Bool
    var badge: String?
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? HUD.accent : hovering ? HUD.ice : HUD.dim)
                .frame(width: 40, height: 40)
                .background(Rectangle().fill(selected ? HUD.accent.opacity(0.1) : hovering ? Color.white.opacity(0.04) : .clear))
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Text(badge).font(HUD.label(8)).foregroundStyle(HUD.void)
                            .padding(.horizontal, 3).frame(minWidth: 14, minHeight: 14)
                            .background(Rectangle().fill(HUD.accent)).offset(x: 3, y: -3)
                    }
                }
                .overlay(alignment: .leading) { if selected { Rectangle().fill(HUD.accent).frame(width: 1, height: 20).offset(x: -18) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label.capitalized)
        .accessibilityLabel(label.capitalized)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ActivityRow: View {
    let item: ActivityItem
    var body: some View {
        HStack(spacing: 8) {
            Group {
                switch item.state {
                case .running: ProgressView().controlSize(.mini).tint(HUD.accent)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(HUD.accent)
                case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(HUD.crimson)
                }
            }
            .font(.system(size: 11)).frame(width: 14)
            (Text(item.title).foregroundStyle(item.state == .running ? HUD.ice : HUD.steel)
             + Text(item.detail.map { "  " + $0 } ?? "").foregroundStyle(HUD.dim))
                .font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if let finished = item.finished {
                Text(String(format: "%.1fs", finished.timeIntervalSince(item.started))).font(HUD.readout(9.5)).foregroundStyle(HUD.dim)
            }
        }
    }
}

/// The answer while it is still being written, or a working line before any words arrive.
private struct LiveReply: View {
    let text: String
    let step: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            speaker("DAISY", color: HUD.accent)
            if text.isEmpty {
                TimelineView(.periodic(from: .now, by: 0.35)) { timeline in
                    let dots = Int(timeline.date.timeIntervalSinceReferenceDate / 0.35) % 4
                    Text(step + String(repeating: ".", count: dots)).font(.system(size: 13)).foregroundStyle(HUD.steel)
                }
            } else {
                MarkdownView(text: text)
                TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
                    Rectangle().fill(HUD.accent).frame(width: 8, height: 14)
                        .opacity(Int(timeline.date.timeIntervalSinceReferenceDate * 2) % 2 == 0 ? 1 : 0.2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var caret: AttributedString {
        var caret = AttributedString(" ▍")
        caret.foregroundColor = HUD.accent
        return caret
    }
}

private func speaker(_ name: String, color: Color, detail: String? = nil) -> some View {
    HStack(spacing: 7) {
        Rectangle().fill(color).frame(width: 5, height: 5)
        Text(name).font(HUD.label(10)).tracking(1.6).foregroundStyle(color)
        if let detail { Text(detail).font(HUD.readout(9)).foregroundStyle(HUD.dim).lineLimit(1) }
    }
}

/// Inline Markdown (bold, italics, code, links) with line breaks kept, instead of raw asterisks.
func rich(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
}

// MARK: - Memory

private struct MemoryView: View {
    @ObservedObject var model: AppModel
    @State private var editing: Memory?
    @State private var adding = false
    @State private var key = ""
    @State private var value = ""
    @State private var profile: [String] = []
    @State private var notes: [String] = []
    var body: some View {
        HUDPage(kicker: "KNOWLEDGE STORE / \(model.memories.count) SAVED", title: "Memory") {
            if model.usesHermes { hermes; LearnedView(learned: model.learned).padding(.top, 10) }
            HStack {
                Text(model.usesHermes ? "ON-DEVICE MEMORY · OLD ENGINE" : "\(model.memories.count) SAVED").hudCaption(model.usesHermes ? HUD.dim : HUD.accent)
                Spacer()
                if !model.usesHermes {
                    Button { key = ""; value = ""; editing = nil; adding = true } label: { Label("Add memory", systemImage: "plus") }
                        .buttonStyle(HUDButtonStyle(kind: .primary, compact: true))
                }
            }
            .padding(.top, model.usesHermes ? 10 : 0)
            if model.memories.isEmpty {
                Text("Nothing saved. Say “Remember that …” or use /remember key = value.").font(.system(size: 12)).foregroundStyle(HUD.dim)
            }
            ForEach(model.memories) { memory in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(memory.key).font(HUD.readout(11)).foregroundStyle(HUD.accent).textSelection(.enabled)
                        Spacer()
                        if model.usesHermes {
                            Button("Tell Hermes") { model.tab = "Assistant"; model.run("Remember this about me: \(memory.key) — \(memory.value)") }
                                .buttonStyle(HUDButtonStyle(kind: .ghost, compact: true)).disabled(!model.agentLink.isReady)
                                .help("Hermes decides how to store it in its own memory")
                        } else {
                            Button("Edit") { editing = memory; key = memory.key; value = memory.value; adding = true }
                                .buttonStyle(HUDButtonStyle(kind: .ghost, compact: true))
                        }
                        Button("Delete") { model.deleteMemory(memory) }
                            .buttonStyle(HUDButtonStyle(kind: .danger, compact: true))
                    }
                    Text(memory.value).font(.system(size: 14)).foregroundStyle(HUD.ice).textSelection(.enabled)
                    Text("Revision \(memory.revision) · \(memory.updatedAt.formatted(date: .abbreviated, time: .shortened)) · \(memory.source)")
                        .font(.system(size: 10.5)).foregroundStyle(HUD.dim).lineLimit(2).textSelection(.enabled)
                }
                .padding(.vertical, 12)
                .overlay(alignment: .top) { Rectangle().fill(HUD.line.opacity(0.09)).frame(height: 1) }
            }
            if let notice = model.notice { Text(notice).font(.system(size: 11)).foregroundStyle(HUD.amber) }
        }
        .onAppear(perform: reload)
        .sheet(isPresented: $adding, onDismiss: { editing = nil }) {
            VStack(alignment: .leading, spacing: 14) {
                Text(editing == nil ? "New memory" : "Correct memory").font(.system(size: 17, weight: .semibold))
                TextField("Key, e.g. response_style", text: $key).hudField().disabled(editing != nil)
                TextEditor(text: $value).font(.system(size: 13)).scrollContentBackground(.hidden).padding(6)
                    .frame(height: 140).background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.28)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(HUD.line.opacity(0.2), lineWidth: 1))
                Text("Saving an existing key replaces its value.").font(.system(size: 11)).foregroundStyle(HUD.dim)
                HStack {
                    Button("Cancel") { adding = false }.buttonStyle(HUDButtonStyle(kind: .ghost))
                    Spacer()
                    Button("Save") { Task { if await model.saveMemory(key: key, value: value) { adding = false } } }
                        .buttonStyle(HUDButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                }
                if let notice = model.notice { Text(notice).font(.system(size: 11)).foregroundStyle(HUD.amber) }
            }
            .padding(24).frame(width: 470)
            .background(HUD.deep)
        }
    }
    /// Hermes's own memory, read straight from its files. Hermes curates it; ask Daisy to change it.
    private var hermes: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("HERMES MEMORY").hudCaption(HUD.accent)
                Spacer()
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(HUDButtonStyle(kind: .ghost, compact: true)).help("Reload")
                Button("Show files") { NSWorkspace.shared.open(HermesMemory.directory) }
                    .buttonStyle(HUDButtonStyle(kind: .ghost, compact: true))
            }
            if profile.isEmpty && notes.isEmpty {
                Text("Nothing yet. Say “Remember that …” and Hermes keeps it across sessions and models.")
                    .font(.system(size: 12)).foregroundStyle(HUD.dim)
            }
            group("ABOUT YOU", profile)
            group("NOTES", notes)
        }
    }
    @ViewBuilder private func group(_ title: String, _ entries: [String]) -> some View {
        if !entries.isEmpty {
            Text(title).font(HUD.label(8.5)).tracking(1.4).foregroundStyle(HUD.dim).padding(.top, 4)
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                Text(rich(entry)).font(.system(size: 13.5)).foregroundStyle(HUD.ice).textSelection(.enabled)
                    .padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Rectangle().fill(HUD.line.opacity(0.09)).frame(height: 1) }
            }
        }
    }
    private func reload() { profile = HermesMemory.profile(); notes = HermesMemory.notes() }
}

// MARK: - Settings

private struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HUDPage(kicker: "SYSTEM CONFIGURATION", title: "Settings", width: 760) {
            AppearanceSection()
            section("AGENT") {
                field("Brain") {
                    Picker("", selection: Binding(get: { model.usesHermes ? "hermes" : "local" }, set: { model.config.agentBackend = $0 })) {
                        Text("Hermes Agent · ChatGPT").tag("hermes")
                        Text("On-device model (fallback)").tag("local")
                    }
                    .labelsHidden().fixedSize()
                }
                note(status)
                if model.usesHermes {
                    field("hermes-acp") {
                        TextField("~/.hermes/hermes-agent/venv/bin/hermes-acp", text: Binding(get: { model.config.hermesExecutable ?? "" },
                                                                                             set: { model.config.hermesExecutable = $0.isEmpty ? nil : $0 })).hudField()
                    }
                    HStack {
                        Button(model.connecting ? "Connecting…" : "Reconnect") { model.startAgent() }
                            .buttonStyle(HUDButtonStyle(kind: .ghost, compact: true)).disabled(model.connecting)
                        Button("Copy sign-in command") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(HermesBackend.signInCommand, forType: .string)
                        }
                        .buttonStyle(HUDButtonStyle(kind: .ghost, compact: true))
                        Button("Open Hermes folder") {
                            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes"))
                        }
                        .buttonStyle(HUDButtonStyle(kind: .ghost, compact: true))
                    }
                    note("Reasoning runs on OpenAI through Hermes, so what you ask and what tools return for that request leave this Mac. Voice, the wake word, tools, sessions and memory files stay here.")
                }
            }
            if !model.usesHermes {
                section("LOCAL MODEL") {
                    field("Model tag") { TextField("qwen3.5:4b", text: $model.config.model).hudField() }
                    note("Downloaded: \(model.availableModels.isEmpty ? "none found" : model.availableModels.joined(separator: ", "))")
                }
            }
            section("VOICE") {
                Toggle("Read answers aloud", isOn: $model.config.speakResponses).toggleStyle(.switch)
                field("Listening") {
                    Picker("", selection: Binding(get: { model.listeningMode }, set: { model.config.listeningMode = $0.rawValue })) {
                        ForEach(ListeningMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .labelsHidden().fixedSize()
                }
                // Voice and speed save as soon as they change, so a pick survives a relaunch without
                // pressing Save (which also restarts the agent).
                VoiceSettingsView(voice: Binding(get: { model.config.naturalVoice ?? NaturalSpeech.defaultVoice }, set: { model.config.naturalVoice = $0; persist() }),
                                  speed: Binding(get: { model.config.speechRate ?? 1 }, set: { model.config.speechRate = $0; persist() }),
                                  busy: model.busy, preview: { model.previewVoice() }, stop: { model.interrupt() })
                note("\(model.audio.microphoneStatus) · Input: \(model.audio.inputDeviceName)")
                if !model.speechInStatus.isEmpty { note(model.speechInStatus) }
                note(model.audio.voiceActivityStatus)
                note(OpenWakeWordDetector.installed ? "Wake word: the trained model (hey_daisy.onnx)."
                                                    : "Wake word: listening for the words \"Hey Daisy\". A trained model can take over; see docs/wake-word.md.")
                Button("Sound input settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.sound?input")!)
                }
                .buttonStyle(HUDButtonStyle(kind: .ghost, compact: true))
                field("whisper-cli") { TextField("whisper-cli executable", text: $model.config.whisperExecutable).hudField() }
                field("Whisper model") { TextField("ggml .bin model", text: $model.config.whisperModel).hudField() }
            }
            AlwaysOnSettingsSection(loginItem: model.loginItem, power: model.power, budget: model.budget,
                                    clickToTalkOnBattery: Binding(get: { model.config.alwaysOn?.clickToTalkOnBatteryEnabled ?? true },
                                                                  set: { model.setClickToTalkOnBattery($0) }),
                                    holdJobsNearLimit: Binding(get: { model.config.alwaysOn?.holdJobsEnabled ?? true },
                                                               set: { model.setHoldJobsNearLimit($0) }),
                                    usesHermes: model.usesHermes)
            if model.usesHermes { GrantsSection(store: model.grants) }
            section("FILES") {
                Toggle("Filename search in the chosen folder", isOn: $model.config.allowFileSearch).toggleStyle(.switch)
                note(model.selectedFolder?.path ?? "No folder selected")
                HStack {
                    Button("Choose folder…") { model.chooseFolder() }.buttonStyle(HUDButtonStyle(kind: .ghost, compact: true))
                    if model.selectedFolder != nil {
                        Button("Remove access") { model.revokeFolder() }.buttonStyle(HUDButtonStyle(kind: .danger, compact: true))
                    }
                }
            }
            HStack {
                Button("Save settings") { model.saveSettings() }.buttonStyle(HUDButtonStyle(kind: .primary))
                Spacer()
                Button("Show local data") { NSWorkspace.shared.open(Configuration.dataDirectory) }.buttonStyle(HUDButtonStyle(kind: .ghost, compact: true))
            }
            if let notice = model.notice { Text(notice).font(.system(size: 11)).foregroundStyle(HUD.amber).textSelection(.enabled) }
        }
    }
    private func persist() {
        do { try model.config.save() } catch { model.notice = "Couldn't save the voice setting: \(error.localizedDescription)" }
    }
    private var status: String {
        switch model.agentLink {
        case .ready: return "Connected · " + model.linkLabel
        case .starting: return "Connecting…"
        case .needsSetup(let issue): return issue.title
        case .offline(let reason): return "Offline · " + reason
        }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).hudCaption(HUD.accent)
            content()
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Rectangle().fill(HUD.line.opacity(0.09)).frame(height: 1) }
    }
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 12)).foregroundStyle(HUD.steel).frame(width: 110, alignment: .leading)
            content()
        }
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(HUD.dim).textSelection(.enabled)
    }
}

// MARK: - Capabilities

private struct CapabilitiesView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HUDPage(kicker: "CAPABILITY REGISTRY / \(model.capabilityEntries.count) INSTALLED", title: "Capabilities") {
            ForEach(model.capabilityEntries, id: \.definition.id) { entry in
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(entry.definition.title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(HUD.ice)
                            Text(entry.definition.effect == .readOnly ? "READ" : "REVIEW")
                                .font(HUD.label(8)).tracking(1.2)
                                .foregroundStyle(entry.definition.effect == .readOnly ? HUD.accent : HUD.amber)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .overlay(Capsule().strokeBorder((entry.definition.effect == .readOnly ? HUD.accent : HUD.amber).opacity(0.45), lineWidth: 1))
                        }
                        Text(entry.definition.description).font(.system(size: 11.5)).foregroundStyle(HUD.steel).fixedSize(horizontal: false, vertical: true)
                        Text(entry.definition.provider + (entry.unavailableReason.map { " · " + $0 } ?? ""))
                            .font(.system(size: 10.5)).foregroundStyle(entry.unavailableReason == nil ? HUD.dim : HUD.amber)
                    }
                    Spacer(minLength: 10)
                    Toggle("", isOn: Binding(get: { model.capabilityEnabled(entry.definition.name) },
                                             set: { model.setCapability(entry.definition.name, enabled: $0) }))
                        .toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel(entry.definition.title)
                }
                .padding(.vertical, 12)
                .overlay(alignment: .top) { Rectangle().fill(HUD.line.opacity(0.09)).frame(height: 1) }
            }
            if model.usesHermes { PermissionsSection(grants: model.grants) }
            if let notice = model.notice { Text(notice).font(.system(size: 11)).foregroundStyle(HUD.amber) }
        }
    }
}

/// Scrolling page body for the non-assistant tabs: one glass panel, rows inside.
struct HUDPage<Content: View>: View {
    var kicker: String?
    var title: String?
    var width: CGFloat = .infinity
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let title {
                    VStack(alignment: .leading, spacing: 8) {
                        if let kicker { Text(kicker).font(HUD.label(10)).tracking(1.6).foregroundStyle(HUD.accent) }
                        Text(title).font(HUD.title).foregroundStyle(HUD.ice)
                    }
                    .padding(.bottom, 8)
                }
                content
            }
                .padding(24)
                .frame(maxWidth: width, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .hudPanel(radius: 16)
        .padding(.horizontal, 16).padding(.bottom, 16)
    }
}

/// Tracks whether the transcript is scrolled to the bottom (macOS 15+; earlier versions always follow).
private struct BottomTracker: ViewModifier {
    @Binding var atBottom: Bool
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 60
            } action: { _, bottom in
                if bottom != atBottom { atBottom = bottom }
            }
        } else {
            content
        }
    }
}

/// Earlier conversations, newest first. Picking one reopens it where it left off.
private struct ChatsList: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("RECENT CHATS").hudCaption(HUD.accent)
                Spacer()
                Button { model.clearConversation(); close() } label: { Label("New", systemImage: "plus") }
                    .buttonStyle(HUDButtonStyle(kind: .ghost, compact: true))
            }
            .padding(12)
            Rectangle().fill(HUD.line.opacity(0.15)).frame(height: 1)
            if model.chats.isEmpty {
                Text("No earlier chats yet.").font(.system(size: 12)).foregroundStyle(HUD.dim).padding(12)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.chats) { chat in
                        Button { model.openChat(chat.id); close() } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(chat.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(HUD.ice).lineLimit(2)
                                if let updated = chat.updated {
                                    Text(updated.formatted(.relative(presentation: .named))).font(HUD.readout(9.5)).foregroundStyle(HUD.dim)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .bottom) { Rectangle().fill(HUD.line.opacity(0.08)).frame(height: 1) }
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 320)
        .background(HUD.deep)
    }
}
