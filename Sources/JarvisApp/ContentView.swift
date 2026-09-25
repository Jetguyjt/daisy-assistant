import SwiftUI
import JarvisCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    @FocusState private var inputFocused: Bool
    @AppStorage("telemetryCollapsed") private var telemetryCollapsed = false
    private let tabs = [("Assistant", "bubble.left"), ("Tasks", "checklist"), ("Memory", "memorychip"),
                        ("Connections", "link"), ("Capabilities", "bolt"), ("Settings", "gearshape")]
    var body: some View {
        HStack(spacing: 0) {
            rail
            Rectangle().fill(hairline).frame(width: 1)
            VStack(spacing: 0) {
                topBar
                Rectangle().fill(hairline).frame(height: 1)
                HStack(spacing: 0) {
                    Group {
                        switch model.tab {
                        case "Memory": MemoryView(model: model)
                        case "Tasks": TasksView(model: model)
                        case "Connections": ConnectionsView(model: model)
                        case "Settings": SettingsView(model: model)
                        case "Capabilities": CapabilitiesView(model: model)
                        default: assistant
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    Rectangle().fill(hairline).frame(width: 1)
                    TelemetryPanel(model: model, audio: model.audio, collapsed: $telemetryCollapsed)
                }
            }
        }
        .background(HUDBackdrop())
        .overlay(Vignette())
        .foregroundStyle(ink)
        .tint(accent)
        .onExitCommand { model.interrupt() }
    }

    private var offline: Bool { !model.connected && !model.connecting }

    private var rail: some View {
        VStack(spacing: 10) {
            Button { model.tab = "Assistant" } label: {
                VStack(spacing: 3) {
                    Text("J").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(accent)
                    Text("JARVIS").microLabel(size: 7)
                }
            }.buttonStyle(.plain).padding(.top, 34).padding(.bottom, 22)
            ForEach(tabs, id: \.0) { item in
                let selected = model.tab == item.0
                Button { model.tab = item.0 } label: {
                    Image(systemName: item.1).font(.system(size: 15))
                        .frame(width: 38, height: 38)
                        .foregroundStyle(selected ? accent : muted)
                        .background(selected ? accent.opacity(0.1) : .clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .leading) { if selected { Rectangle().fill(accent).frame(width: 1, height: 20).offset(x: -18) } }
                .help(item.0)
                .accessibilityLabel(item.0)
            }
            Spacer()
            Text("v0.3").microLabel()
        }
        .frame(width: 76).padding(.bottom, 20)
        .background(surface.opacity(0.9))
    }

    private var topBar: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.tab == "Assistant" ? "Active session" : "Workspace").microLabel()
                Text(sessionTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 7) {
                Rectangle().fill(offline ? warning : accent).frame(width: 6, height: 6)
                Text(model.connected ? "Engine · ready" : model.connecting ? "Engine · connecting" : "Engine · offline")
            }
            .microLabel(offline ? warning : accent)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background((offline ? warning : accent).opacity(0.05))
            .overlay(Rectangle().stroke((offline ? warning : accent).opacity(0.25)))
            Button { model.clearConversation() } label: { Label("New conversation", systemImage: "plus.circle") }
                .buttonStyle(HUDButtonStyle()).help("New conversation (⌘N)")
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(context.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(accent).monospacedDigit()
            }.frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 12)
    }
    private var sessionTitle: String {
        guard model.tab == "Assistant" else { return model.tab }
        guard let first = model.messages.first(where: { $0.role == "user" })?.text else { return "New session" }
        return first.count > 60 ? String(first.prefix(60)) + "…" : first
    }

    private var assistant: some View {
        VStack(spacing: 0) {
            if model.messages.isEmpty {
                Spacer(minLength: 8)
                OrbView(audio: model.audio, phase: model.phase, offline: offline).frame(width: 250, height: 250)
                StatusLine(model: model, audio: model.audio).padding(.top, 18)
                HStack(spacing: 20) { Text("⌘⇧Space · talk"); Text("⌘. · stop") }.microLabel().padding(.top, 26)
                Spacer(minLength: 16)
            } else {
                HStack(spacing: 16) {
                    OrbView(audio: model.audio, phase: model.phase, offline: offline).frame(width: 64, height: 64)
                    StatusLine(model: model, audio: model.audio)
                    Spacer()
                    if model.busy { Button { model.interrupt() } label: { Label("Stop", systemImage: "stop.fill") }.buttonStyle(HUDButtonStyle(tint: warning)) }
                }.padding(.horizontal, 28).padding(.vertical, 8)
                Rectangle().fill(hairline).frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            ForEach(model.messages) { item in message(item).id(item.id) }
                            Color.clear.frame(height: 1).id("bottom")
                        }.frame(maxWidth: 760).padding(.horizontal, 28).padding(.vertical, 20).frame(maxWidth: .infinity)
                    }.onChange(of: model.messages.count) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
            }
            composer
        }
    }

    private func message(_ item: ConversationItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.role == "user" ? "You" : item.role == "status" ? "Status" : "Jarvis")
                .microLabel(item.role == "assistant" ? accent : item.role == "status" ? warning : muted)
            if item.role == "user" {
                Text(item.text).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
                    .padding(.vertical, 8).padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(accent.opacity(0.06))
                    .overlay(alignment: .leading) { Rectangle().fill(accent.opacity(0.4)).frame(width: 1) }
            } else {
                Text(rendered(item.text)).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                    .foregroundStyle(item.role == "status" ? warning.opacity(0.9) : ink)
            }
            ForEach(item.receipts) { receipt in ReceiptRow(receipt: receipt) }
            ForEach(item.receipts.compactMap(\.output.review)) { review in ReviewCard(model: model, review: review) }
            if let report = item.files { files(report) }
            if let detail = item.detail { Text(detail).font(.system(size: 9, design: .monospaced)).foregroundStyle(muted.opacity(0.75)) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    /// Inline markdown (bold, italics, code) renders instead of showing raw asterisks; line breaks are kept.
    private func rendered(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
    private func files(_ report: SearchReport) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                Text("file_search · \(report.files.count) results · \(report.scanned) scanned\(report.limited ? " · partial" : "")\(report.unreadableLocations > 0 ? " · \(report.unreadableLocations) unreadable" : "")")
            }.microLabel(accent, size: 9).padding(.bottom, 8)
            ForEach(report.files.prefix(8)) { file in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(file.name).font(.system(size: 12, weight: .semibold))
                        Text(file.path).font(.system(size: 9, design: .monospaced)).foregroundStyle(muted).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Text(file.modified.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 9, design: .monospaced)).foregroundStyle(muted)
                    }
                    Spacer(minLength: 4)
                    Button("Open") { model.openFile(file, reveal: false) }.buttonStyle(HUDButtonStyle())
                    Button("Reveal") { model.openFile(file, reveal: true) }.buttonStyle(HUDButtonStyle())
                }.padding(.vertical, 8).overlay(alignment: .top) { Rectangle().fill(hairline).frame(height: 1) }
            }
            if report.files.count > 8 { Text("Showing 8 of \(report.files.count). Narrow the search for more.").font(.system(size: 10)).foregroundStyle(muted).padding(.top, 6) }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.025))
        .overlay(Rectangle().stroke(accent.opacity(0.2)))
        .overlay(CornerBrackets().stroke(accent, lineWidth: 2))
    }

    private var composer: some View {
        VStack(spacing: 10) {
            RecordingStatusView(audio: model.audio, phase: model.phase)
            if let notice = model.notice {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(notice).textSelection(.enabled)
                    Spacer(minLength: 2)
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.font(.system(size: 11)).foregroundStyle(warning).padding(10)
                    .background(warning.opacity(0.05)).overlay(Rectangle().stroke(warning.opacity(0.3)))
            }
            HStack(spacing: 18) {
                HStack(alignment: .center, spacing: 10) {
                    TextField("Ask Jarvis…", text: $model.input, axis: .vertical).lineLimit(1...5)
                        .textFieldStyle(.plain).font(.system(size: 13)).focused($inputFocused)
                        .onSubmit { model.submit() }
                    Button { model.toggleListening() } label: {
                        Image(systemName: model.phase == .listening ? "stop.circle.fill" : "mic")
                            .font(.system(size: 14)).frame(width: 32, height: 32)
                            .foregroundStyle(model.phase == .listening ? hudBackground : accent)
                            .background(model.phase == .listening ? accent : accent.opacity(0.06))
                    }.buttonStyle(.plain)
                        .accessibilityLabel(model.phase == .listening ? "Finish recording and send" : "Start recording")
                        .help(model.phase == .listening ? "Finish (⌘⇧Space)" : "Talk (⌘⇧Space)")
                    if model.busy {
                        Button { model.interrupt() } label: {
                            Image(systemName: "stop.fill").font(.system(size: 12)).frame(width: 32, height: 32)
                                .foregroundStyle(hudBackground).background(warning)
                        }.buttonStyle(.plain).help("Stop (⌘.)")
                    } else {
                        Button { model.submit() } label: {
                            Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold)).frame(width: 32, height: 32)
                                .foregroundStyle(hudBackground).background(accent)
                        }.buttonStyle(.plain).disabled(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).help("Send")
                    }
                }
                .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
                .background(hudBackground.opacity(0.7))
                .overlay(Rectangle().stroke(inputFocused ? accent.opacity(0.5) : hairline))
                AlwaysListeningSwitch(model: model, audio: model.audio).frame(width: 205)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(surface.opacity(0.9))
        .overlay(alignment: .top) { Rectangle().fill(hairline).frame(height: 1) }
    }
}

/// "LISTENING · 3.2s" style readout under the orb.
private struct StatusLine: View {
    @ObservedObject var model: AppModel
    @ObservedObject var audio: AudioController
    var body: some View {
        Text(text).microLabel(tone)
    }
    private var tone: Color { !model.connected && !model.connecting && model.phase == .idle ? warning : accent }
    private var text: String {
        switch model.phase {
        case .idle:
            if model.connecting { return "Booting · connecting engine" }
            if !model.connected { return "Offline · engine unreachable" }
            return model.standby ? "Standby · say “Hey Jarvis”" : "Standby · ready"
        case .listening: return "Listening · " + String(format: "%.1fs", audio.elapsed)
        default:
            let step = model.currentStep.map { " · " + $0 } ?? ""
            return model.phase.rawValue + step
        }
    }
}

private struct AlwaysListeningSwitch: View {
    @ObservedObject var model: AppModel
    @ObservedObject var audio: AudioController
    private let shape: [Double] = [0.3, 0.55, 0.8, 0.4, 0.65, 1, 0.45, 0.75, 0.3, 0.55, 0.4, 0.8]
    var body: some View {
        let on = model.listeningMode == .wakeWord
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Always listening").microLabel(on ? accent : muted)
                    Text(on ? (model.standby ? "Say “Hey Jarvis”" : "Arming microphone…") : "Microphone off between turns")
                        .font(.system(size: 10)).foregroundStyle(muted)
                }
                Spacer()
                Toggle("Always listening", isOn: Binding(get: { on }, set: { model.setAlwaysListening($0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small).tint(accent)
            }
            if on {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(shape.indices, id: \.self) { i in
                        Rectangle().fill(accent.opacity(0.7)).frame(width: 3, height: 2 + 10 * shape[i] * min(1, audio.level * 3))
                    }
                }.frame(height: 12, alignment: .bottom)
            }
        }
    }
}

private struct ReceiptRow: View {
    let receipt: CapabilityReceipt
    @State private var expanded = false
    var body: some View {
        let ok = receipt.status == .succeeded
        let tint = ok ? accent : warning
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: ok ? "checkmark" : "exclamationmark.triangle").font(.system(size: 9, weight: .bold))
                    Text("\(receipt.tool) · \(receipt.status.rawValue)").microLabel(tint, size: 9)
                    Text(receipt.title).font(.system(size: 11)).foregroundStyle(muted).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 9)).rotationEffect(.degrees(expanded ? 180 : 0))
                }.foregroundStyle(tint).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if expanded {
                Text(receipt.output.summary).font(.system(size: 11)).foregroundStyle(ink.opacity(0.85)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(tint.opacity(0.025))
        .overlay(Rectangle().stroke(tint.opacity(0.2)))
        .overlay(CornerBrackets(size: 8).stroke(tint, lineWidth: 1.5))
    }
}

private struct TelemetryPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var audio: AudioController
    @Binding var collapsed: Bool
    var body: some View {
        if collapsed {
            VStack(spacing: 24) {
                Button { collapsed = false } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).foregroundStyle(muted).help("Show telemetry")
                Text("Telemetry").microLabel().fixedSize().rotationEffect(.degrees(90)).frame(width: 20, height: 90)
                Spacer()
            }.padding(.top, 16).frame(width: 36).background(surface.opacity(0.9))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("System telemetry").microLabel(accent)
                        Spacer()
                        Button { collapsed = true } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain).foregroundStyle(muted).help("Hide telemetry")
                    }.padding(.bottom, 6)
                    row("Agent link", model.connected ? "Local engine · connected" : model.connecting ? "Connecting…" : "Offline", tint: model.connected ? accent : warning, dot: true)
                    row("Model", model.config.model)
                    row("Voice", NaturalSpeech.voices.first { $0.id == (model.config.naturalVoice ?? "bm_george") }?.name ?? "George · British")
                    row("Listening", model.listeningMode.title)
                    row("Mic input", audio.inputDeviceName)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Folder in reach").microLabel()
                        HStack {
                            Text(model.selectedFolder.map { "~/" + $0.lastPathComponent } ?? "None").font(.system(size: 12)).lineLimit(1)
                            Spacer()
                            Button(model.selectedFolder == nil ? "Choose" : "Change") { model.chooseFolder() }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(accent)
                        }
                    }.padding(.bottom, 8).overlay(alignment: .bottom) { Rectangle().fill(hairline).frame(height: 1) }
                    row("Chrome", model.chromeConnected ? "Connected" : model.chromeConnecting ? "Connecting…" : "Not connected")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Memories").microLabel()
                        Text("\(model.memories.count) entries").font(.system(size: 12))
                        if let latest = model.memories.first { Text("latest: " + latest.value).font(.system(size: 9, design: .monospaced)).foregroundStyle(muted).lineLimit(1) }
                    }.padding(.bottom, 8).overlay(alignment: .bottom) { Rectangle().fill(hairline).frame(height: 1) }
                    Text("Capabilities").microLabel().padding(.top, 8)
                    ForEach(Array(model.capabilityEntries.prefix(10)), id: \.definition.id) { entry in
                        let live = entry.unavailableReason == nil && model.capabilityEnabled(entry.definition.name)
                        HStack {
                            Text(entry.definition.title).font(.system(size: 10, design: .monospaced)).lineLimit(1)
                            Spacer()
                            Rectangle().fill(live ? accent : muted.opacity(0.5)).frame(width: 6, height: 6)
                        }.foregroundStyle(live ? ink : muted)
                    }
                }.padding(16)
            }.frame(width: 260).background(surface.opacity(0.9))
        }
    }
    private func row(_ label: String, _ value: String, tint: Color = ink, dot: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).microLabel()
            HStack(spacing: 8) {
                if dot { Rectangle().fill(tint).frame(width: 6, height: 6) }
                Text(value).font(.system(size: 12)).foregroundStyle(tint).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8).overlay(alignment: .bottom) { Rectangle().fill(hairline).frame(height: 1) }
    }
}

private struct MemoryView: View {
    @ObservedObject var model: AppModel
    @State private var editing: Memory?
    @State private var adding = false
    @State private var key = ""
    @State private var value = ""
    @State private var query = ""
    private var filtered: [Memory] { model.memories.filter { query.isEmpty || ($0.key + " " + $0.value).localizedCaseInsensitiveContains(query) } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(kicker: "Knowledge store / \(model.memories.count) entries", title: "Memory") {
                    Button { key = ""; value = ""; adding = true } label: { Label("Add memory", systemImage: "plus") }.buttonStyle(HUDButtonStyle(filled: true))
                }
                Text("Explicit only · /remember key = value · deleting a memory also clears the current conversation")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(muted).textSelection(.enabled)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(muted)
                    TextField("Search memories", text: $query).textFieldStyle(.plain)
                }.padding(.horizontal, 12).frame(height: 38).background(surface).overlay(Rectangle().stroke(hairline))
                if filtered.isEmpty {
                    Text(model.memories.isEmpty ? "No memories saved." : "No matches.").microLabel().padding(.vertical, 30).frame(maxWidth: .infinity)
                } else {
                    VStack(spacing: 0) {
                        ForEach(filtered) { memory in
                            HStack(alignment: .top, spacing: 20) {
                                Text(memory.key).microLabel().frame(width: 170, alignment: .leading).textSelection(.enabled)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(memory.value).font(.system(size: 13)).textSelection(.enabled)
                                    Text("rev \(memory.revision) · \(memory.updatedAt.formatted(date: .abbreviated, time: .shortened)) · \(memory.source)")
                                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(muted).lineLimit(1)
                                }
                                Spacer()
                                Button { editing = memory; key = memory.key; value = memory.value; adding = true } label: { Image(systemName: "pencil") }
                                    .buttonStyle(.plain).foregroundStyle(muted).help("Edit")
                                Button { model.deleteMemory(memory) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.plain).foregroundStyle(muted).help("Delete")
                            }.padding(.vertical, 14)
                                .overlay(alignment: .bottom) { if memory.id != filtered.last?.id { Rectangle().fill(hairline).frame(height: 1) } }
                        }
                    }.hudPanel(padding: 18)
                }
                if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(warning) }
            }.padding(28).frame(maxWidth: 900)
        }.frame(maxWidth: .infinity)
        .sheet(isPresented: $adding, onDismiss: { editing = nil }) {
            VStack(alignment: .leading, spacing: 17) {
                Text(editing == nil ? "New memory" : "Correct memory").font(.title2)
                TextField("Key, e.g. response_style", text: $key).disabled(editing != nil)
                TextEditor(text: $value).frame(height: 140).font(.body)
                Text("Saving an existing key replaces its value.").font(.caption).foregroundStyle(.secondary)
                HStack { Button("Cancel") { adding = false }; Spacer(); Button("Save") { Task { if await model.saveMemory(key: key, value: value) { adding = false } } }.keyboardShortcut(.defaultAction) }
                if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(warning) }
            }.padding(25).frame(width: 470)
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(kicker: "System configuration", title: "Settings") {
                    Button("Save settings") { model.saveSettings() }.buttonStyle(HUDButtonStyle(filled: true))
                }
                section("Voice", icon: "waveform") {
                    Picker("Voice", selection: Binding(get: { model.config.naturalVoice ?? "bm_george" }, set: { model.config.naturalVoice = $0 })) {
                        ForEach(NaturalSpeech.voices) { voice in Text(voice.name).tag(voice.id) }
                    }
                    HStack {
                        Text("Speed")
                        Slider(value: Binding(get: { model.config.speechRate ?? 1 }, set: { model.config.speechRate = $0 }), in: 0.75...1.3, step: 0.05)
                        Text(String(format: "%.2f×", model.config.speechRate ?? 1)).monospacedDigit().frame(width: 50)
                    }
                    Toggle("Read responses aloud", isOn: $model.config.speakResponses)
                    HStack {
                        Button("Preview voice") { model.previewVoice() }.disabled(model.busy)
                        if model.busy { Button("Stop") { model.interrupt() } }
                    }
                }
                section("Listening", icon: "mic") {
                    Picker("Mode", selection: Binding(get: { model.listeningMode }, set: { model.config.listeningMode = $0.rawValue })) {
                        ForEach(ListeningMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    Text(model.listeningMode == .wakeWord
                         ? "Mic stays open. Each pause is transcribed locally and dropped unless it starts with “Hey Jarvis”. After an answer Jarvis listens for a follow-up."
                         : model.listeningMode == .handsFree
                         ? "Click once. Recording ends when you pause; Jarvis listens again after each answer until you stay quiet."
                         : "Click, speak, then pause or click again. Mic is off otherwise.")
                        .font(.system(size: 11)).foregroundStyle(muted)
                    HStack {
                        Text(model.audio.inputDeviceName).font(.system(size: 11, design: .monospaced)).foregroundStyle(accent)
                        Spacer()
                        Button("Sound input settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.sound?input")!) }
                    }
                    Text(model.audio.microphoneStatus).font(.system(size: 11)).foregroundStyle(muted)
                    TextField("whisper-cli executable", text: $model.config.whisperExecutable)
                    TextField("Whisper .bin model", text: $model.config.whisperModel)
                    Text("⌘⇧Space talk / finish · ⌘. stop · talking over Jarvis interrupts it").font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
                }
                section("Agent backend", icon: "cpu") {
                    TextField("Model tag", text: $model.config.model)
                    Text("Available: \(model.availableModels.isEmpty ? "none found" : model.availableModels.joined(separator: ", "))").font(.system(size: 11)).foregroundStyle(muted)
                    Text("127.0.0.1:11435 · redirects blocked · cloud models rejected").font(.system(size: 10, design: .monospaced)).foregroundStyle(accent)
                    Button(model.connecting ? "Connecting…" : "Save & reconnect") { model.saveSettings() }.disabled(model.connecting)
                }
                section("Permissions", icon: "folder") {
                    Toggle("Allow filename search in my chosen folder", isOn: $model.config.allowFileSearch)
                    Text(model.selectedFolder?.path ?? "No folder selected").font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    HStack { Button("Choose folder…") { model.chooseFolder() }; if model.selectedFolder != nil { Button("Remove access") { model.revokeFolder() } } }
                    Text("The folder is used for search, reading text and saving reviewed drafts. Chrome is connected separately. Form editing, sending and app control are not enabled.")
                        .font(.system(size: 11)).foregroundStyle(muted)
                }
                HStack {
                    Text("Memories in SQLite on this Mac · conversations in memory until cleared").font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
                    Spacer()
                    Button("Show local data") { NSWorkspace.shared.open(Configuration.dataDirectory) }
                }
                if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(warning).textSelection(.enabled) }
            }.textFieldStyle(.roundedBorder).padding(28).frame(maxWidth: 780, alignment: .leading)
        }.frame(maxWidth: .infinity)
    }
    private func section<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 12) {
                Text(title).microLabel(accent)
                content()
            }
        }.hudPanel(padding: 20)
    }
}

private struct RecordingStatusView: View {
    @ObservedObject var audio: AudioController
    let phase: AssistantPhase
    var body: some View {
        if phase == .listening {
            HStack(spacing: 10) {
                Rectangle().fill(danger).frame(width: 7, height: 7)
                Text("Rec · \(Int(audio.elapsed))s").microLabel(ink)
                ProgressView(value: min(1, audio.level)).frame(width: 90).tint(accent)
                Text(audio.inputDeviceName).font(.system(size: 10)).foregroundStyle(muted).lineLimit(1)
                Spacer()
                Text("Pause to send").microLabel(accent, size: 9)
            }.padding(9).background(accent.opacity(0.04)).overlay(Rectangle().stroke(hairline))
        } else if phase == .preparing {
            Text("Waiting for microphone permission…").microLabel(accent)
        }
    }
}

private struct CapabilitiesView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(kicker: "Capability registry / \(model.capabilityEntries.count) installed", title: "Capabilities")
                Text("Each capability is a tool Jarvis can combine to answer a request. Changes to files and tasks show up as review cards first; nothing is applied until you approve it.")
                    .font(.system(size: 12)).foregroundStyle(muted).lineSpacing(4)
                ForEach(model.capabilityEntries, id: \.definition.id) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(get: { model.capabilityEnabled(entry.definition.name) },
                                             set: { model.setCapability(entry.definition.name, enabled: $0) })) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.definition.title).font(.system(size: 14, weight: .medium))
                                Text(entry.definition.provider + " · " + (entry.definition.effect == .readOnly ? "Read only" : "Review required")).microLabel(size: 9)
                            }
                        }.toggleStyle(.switch)
                        Text(entry.definition.description).font(.system(size: 11)).foregroundStyle(muted)
                        Text(entry.unavailableReason ?? "Available").font(.system(size: 11)).foregroundStyle(entry.unavailableReason == nil ? accent : warning)
                    }.hudPanel(entry.definition.effect == .readOnly ? accent : warning, padding: 18)
                }
                if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(warning) }
            }.padding(28).frame(maxWidth: 780, alignment: .leading)
        }.frame(maxWidth: .infinity)
    }
}
