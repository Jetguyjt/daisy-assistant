import SwiftUI
import JarvisCore

let accent = Color(red: 0.35, green: 0.88, blue: 0.91)
let surface = Color(red: 0.052, green: 0.064, blue: 0.083)
let muted = Color(red: 0.49, green: 0.55, blue: 0.61)

struct ContentView: View {
    @ObservedObject var model: AppModel
    @FocusState private var inputFocused: Bool
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.3)
            VStack(spacing: 0) {
                header
                Divider().opacity(0.3)
                if model.tab == "Memory" { MemoryView(model: model) }
                else if model.tab == "Tasks" { TasksView(model: model) }
                else if model.tab == "Connections" { ConnectionsView(model: model) }
                else if model.tab == "Settings" { SettingsView(model: model) }
                else if model.tab == "Capabilities" { CapabilitiesView(model: model) }
                else { assistant }
            }
        }
        .background(Color(red: 0.025, green: 0.034, blue: 0.049))
        .tint(accent)
        .onExitCommand { model.stop() }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "waveform.circle").font(.system(size: 28, weight: .ultraLight)).foregroundStyle(accent)
                Text("JARVIS").font(.system(size: 17, weight: .semibold, design: .rounded)).tracking(3)
            }.padding(.top, 43).padding(.bottom, 48)
            Text("WORKSPACE").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(muted).padding(.bottom, 18)
            ForEach([("Assistant", "sparkle"), ("Tasks", "checklist"), ("Memory", "square.stack.3d.up"), ("Connections", "point.3.connected.trianglepath.dotted"), ("Capabilities", "square.grid.2x2"), ("Settings", "slider.horizontal.3")], id: \.0) { item in
                Button { model.tab = item.0 } label: {
                    HStack(spacing: 11) {
                        Image(systemName: item.1).frame(width: 17)
                        Text(item.0).font(.system(size: 13, weight: .medium))
                        Spacer()
                        if item.0 == "Memory", !model.memories.isEmpty { Text("\(model.memories.count)").font(.system(size: 10, design: .monospaced)) }
                    }.foregroundStyle(model.tab == item.0 ? accent : muted)
                        .padding(.horizontal, 12).padding(.vertical, 12)
                        .background(model.tab == item.0 ? accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).padding(.horizontal, -12).padding(.bottom, 5)
            }
            Spacer()
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.bottom, 18)
            Label("ON YOUR MAC", systemImage: "lock.shield").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1).foregroundStyle(accent)
            Text("Local inference\nPrivate by design").font(.system(size: 11)).lineSpacing(5).foregroundStyle(muted).padding(.top, 10)
            Text("LOCAL ASSISTANT  /  0.3").font(.system(size: 8, design: .monospaced)).tracking(1.2).foregroundStyle(muted.opacity(0.6)).padding(.top, 22)
        }.padding(.horizontal, 27).padding(.bottom, 26).frame(width: 184)
            .background(Color(red: 0.036, green: 0.045, blue: 0.060))
    }
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.tab).font(.system(size: 16, weight: .medium))
                Text(model.tab == "Assistant" ? "A clear mind. A little more room for yours." : model.tab == "Memory" ? "What you choose to remember." : "Your assistant, on your terms.")
                    .font(.system(size: 11)).foregroundStyle(muted)
            }
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(model.connected ? accent : Color.orange).frame(width: 5, height: 5)
                Text(model.connected ? "LOCAL ENGINE READY" : model.connecting ? "CONNECTING" : "ENGINE OFFLINE")
                    .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(0.8)
            }.foregroundStyle(muted).padding(.horizontal, 12).padding(.vertical, 8)
                .overlay(Capsule().stroke(.white.opacity(0.08)))
            Button { model.clearConversation() } label: { Image(systemName: "square.and.pencil") }.buttonStyle(.plain).padding(.leading, 12).help("New conversation (⌘N)")
        }.padding(.horizontal, 28).padding(.top, 27).padding(.bottom, 20)
    }
    private var assistant: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if model.messages.isEmpty {
                    Spacer(minLength: 8)
                    OrbView(audio: model.audio, phase: model.phase).frame(height: 262)
                    phaseLabel
                    Text("What’s on your mind?").font(.system(size: 27, weight: .light)).padding(.top, 16)
                    Text("Speak freely. Start somewhere.").font(.system(size: 12)).foregroundStyle(muted).padding(.top, 9)
                    HStack(spacing: 8) {
                        suggestion("Find a file", symbol: "doc.text.magnifyingglass", prompt: "/find resume")
                        suggestion("Remember something", symbol: "brain", prompt: "Remember that ")
                    }.padding(.top, 28)
                    Spacer(minLength: 16)
                } else {
                    HStack(spacing: 0) {
                        OrbView(audio: model.audio, phase: model.phase).frame(width: 78, height: 78)
                        phaseLabel
                        Spacer()
                        if model.busy { Button("Stop", systemImage: "stop.fill") { model.stop() }.buttonStyle(.bordered).controlSize(.small) }
                    }.padding(.horizontal, 20)
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 23) {
                                ForEach(model.messages) { item in message(item).id(item.id) }
                                Color.clear.frame(height: 1).id("bottom")
                            }.padding(.horizontal, 28).padding(.vertical, 8)
                        }.onChange(of: model.messages.count) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                    }
                }
                composer
            }
            Divider().opacity(0.3)
            contextPanel
        }
    }
    private var phaseLabel: some View {
        HStack(spacing: 7) {
            Circle().fill(accent).frame(width: 4, height: 4)
            Text((model.currentStep ?? model.phase.rawValue).uppercased()).font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(2)
        }.foregroundStyle(accent)
    }
    private func suggestion(_ text: String, symbol: String, prompt: String) -> some View {
        Button { model.input = prompt; inputFocused = true } label: {
            Label(text, systemImage: symbol).font(.system(size: 11)).foregroundStyle(muted)
                .padding(.horizontal, 12).padding(.vertical, 10).background(surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.05)))
        }.buttonStyle(.plain)
    }
    private func message(_ item: ConversationItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.role == "user" ? "YOU" : item.role == "status" ? "STATUS" : "JARVIS")
                .font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.6)
                .foregroundStyle(item.role == "assistant" ? accent : muted)
            Text(item.text).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                .foregroundStyle(item.role == "status" ? Color.orange.opacity(0.8) : Color.white.opacity(0.86))
            ForEach(item.receipts) { receipt in
                VStack(alignment: .leading, spacing: 5) {
                    Label(receipt.title + " · " + receipt.status.rawValue,
                          systemImage: receipt.status == .succeeded ? "checkmark.circle" : "exclamationmark.circle")
                        .font(.system(size: 11, weight: .medium))
                    Text(receipt.output.summary).font(.system(size: 11)).textSelection(.enabled)
                }.foregroundStyle(receipt.status == .succeeded ? accent : .orange)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(surface, in: RoundedRectangle(cornerRadius: 8))
            }
            ForEach(item.receipts.compactMap(\.output.review)) { review in
                ReviewCard(model: model, review: review)
            }
            if let report = item.files {
                Text("Verified search · \(report.scanned) entries · \(report.files.count) results\(report.limited ? " · partial results" : "")\(report.unreadableLocations > 0 ? " · \(report.unreadableLocations) unreadable locations" : "")")
                    .font(.system(size: 10)).foregroundStyle(accent)
                ForEach(report.files.prefix(8)) { file in
                    HStack {
                        Image(systemName: "doc.text").foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.name).font(.system(size: 12, weight: .medium))
                            Text(file.path).font(.system(size: 9)).foregroundStyle(muted).lineLimit(2).textSelection(.enabled)
                            Text(file.modified.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 9)).foregroundStyle(muted)
                        }
                        Spacer(minLength: 4)
                        Button { model.openFile(file, reveal: true) } label: { Image(systemName: "folder") }.help("Reveal in Finder")
                        Button { model.openFile(file, reveal: false) } label: { Image(systemName: "arrow.up.right") }.help("Open file")
                    }.buttonStyle(.borderless).padding(10).background(surface, in: RoundedRectangle(cornerRadius: 8))
                }
                if report.files.count > 8 { Text("Showing the first 8 of \(report.files.count) matches. Narrow your search for more specific results.").font(.caption).foregroundStyle(muted) }
            }
            if let detail = item.detail { Text(detail).font(.system(size: 9, design: .monospaced)).foregroundStyle(muted.opacity(0.75)) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var composer: some View {
        VStack(spacing: 10) {
            RecordingStatusView(audio: model.audio, phase: model.phase)
            if let notice = model.notice {
                HStack(alignment: .top) {
                    Image(systemName: "info.circle")
                    Text(notice).textSelection(.enabled)
                    Spacer(minLength: 2)
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.font(.system(size: 11)).foregroundStyle(Color.orange.opacity(0.85)).padding(10)
                    .background(Color.orange.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(alignment: .center, spacing: 10) {
                TextField("Ask Jarvis anything…", text: $model.input, axis: .vertical).lineLimit(1...5)
                    .textFieldStyle(.plain).font(.system(size: 13)).focused($inputFocused)
                    .onSubmit { model.submit() }
                if model.busy {
                    Button { model.stop() } label: { Image(systemName: "stop.fill").frame(width: 30, height: 30) }.help("Stop (⌘.)")
                }
                Button { model.toggleListening() } label: {
                    Label(model.phase == .listening ? "Finish" : model.phase == .preparing ? "Cancel" : "Record",
                          systemImage: model.phase == .listening ? "stop.circle.fill" : "mic")
                        .font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).frame(height: 34)
                        .foregroundStyle(model.phase == .listening ? .black : accent)
                        .background(model.phase == .listening ? accent : accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain)
                    .accessibilityLabel(model.phase == .listening ? "Finish recording and send" : "Start recording")
                    .help("Click to start. Speak, then click Finish. Keyboard: ⌘⇧Space.")
                Button { model.submit() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold)).frame(width: 32, height: 34)
                        .foregroundStyle(.black).background(accent, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).disabled(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).help("Send")
            }.buttonStyle(.plain).padding(12).background(surface, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.09)))
            HStack {
                Text("CLICK RECORD · SPEAK · CLICK FINISH").tracking(1)
                Spacer()
                Text("LOCAL VOICE  ·  ⌘. TO STOP").tracking(0.7)
            }.font(.system(size: 8, design: .monospaced)).foregroundStyle(muted.opacity(0.7))
        }.padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 23)
    }
    private var contextPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("IN REACH").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(2).foregroundStyle(muted)
            VStack(alignment: .leading, spacing: 13) {
                Label("Your files", systemImage: "folder").font(.system(size: 12, weight: .medium))
                Text(model.selectedFolder?.lastPathComponent ?? "Choose a starting point")
                    .font(.system(size: 12)).foregroundStyle(accent).lineLimit(2)
                Text(model.selectedFolder == nil ? "Give Jarvis a folder to search. You decide what’s in reach." : "Search this folder. Content reading is a separate permission in Capabilities.")
                    .font(.system(size: 11)).lineSpacing(4).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                Button(model.selectedFolder == nil ? "Choose folder  +" : "Change folder") { model.chooseFolder() }
                    .font(.system(size: 11, weight: .medium)).buttonStyle(.plain).foregroundStyle(accent)
            }.padding(15).frame(maxWidth: .infinity, alignment: .leading).background(surface, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("EXPLICIT MEMORY").font(.system(size: 9, design: .monospaced)).tracking(1); Spacer(); Text("\(model.memories.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(accent) }
                Text(model.memories.isEmpty ? "A fresh start. Tell me what matters, and I’ll keep it here." : model.memories[0].value)
                    .font(.system(size: 11)).lineSpacing(4).lineLimit(5)
                Button("View memory →") { model.tab = "Memory" }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(accent)
            }.foregroundStyle(muted)
            Divider().opacity(0.3)
            Text("CAPABILITIES").font(.system(size: 9, design: .monospaced)).tracking(2).foregroundStyle(muted)
            ForEach(Array(model.capabilityEntries.prefix(7)), id: \.definition.id) { entry in
                HStack(spacing: 8) {
                    Circle().fill(entry.unavailableReason == nil ? accent : muted).frame(width: 5, height: 5)
                    Text(entry.definition.title).font(.system(size: 11))
                    Spacer()
                }.foregroundStyle(entry.unavailableReason == nil ? accent : muted)
            }
            Button("Manage capabilities →") { model.tab = "Capabilities" }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(accent)
            Spacer()
            Text("One conversation.\nYour own corner of the world.").font(.system(size: 11, weight: .light)).lineSpacing(5).foregroundStyle(muted.opacity(0.6))
        }.padding(.horizontal, 21).padding(.vertical, 28).frame(width: 236).frame(maxHeight: .infinity)
    }
}

private struct MemoryView: View {
    @ObservedObject var model: AppModel
    @State private var editing: Memory?
    @State private var adding = false
    @State private var key = ""
    @State private var value = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack { Text("Remember deliberately.").font(.system(size: 27, weight: .light)); Spacer(); Button("Add memory", systemImage: "plus") { key = ""; value = ""; adding = true } }
                Text("Only information you explicitly save lives here. Edit the same key to correct a fact. Nothing is inferred from computer activity. Deleting a memory also clears the current conversation so it cannot be reused there.")
                    .font(.system(size: 13)).foregroundStyle(muted).lineSpacing(5)
                Text("Try: /remember response_style = Keep spoken answers short")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(accent).textSelection(.enabled)
                if model.memories.isEmpty { ContentUnavailableView("A clean slate", systemImage: "brain", description: Text("Save a preference or a project’s next step.")) }
                ForEach(model.memories) { memory in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(memory.key).font(.system(size: 11, design: .monospaced)).foregroundStyle(accent)
                            Spacer()
                            Button("Edit") { editing = memory; key = memory.key; value = memory.value; adding = true }
                            Button("Delete", role: .destructive) { model.deleteMemory(memory) }
                        }
                        Text(memory.value).font(.system(size: 14)).textSelection(.enabled)
                        Text("Explicit · revision \(memory.revision) · \(memory.updatedAt.formatted())").font(.system(size: 10)).foregroundStyle(muted)
                        Text("Source: \(memory.source)").font(.system(size: 10)).foregroundStyle(muted).textSelection(.enabled)
                    }.padding(18).background(surface, in: RoundedRectangle(cornerRadius: 10))
                }
                if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
            }.padding(32)
        }.sheet(isPresented: $adding, onDismiss: { editing = nil }) {
            VStack(alignment: .leading, spacing: 17) {
                Text(editing == nil ? "New explicit memory" : "Correct memory").font(.title2)
                TextField("Key, e.g. response_style", text: $key).disabled(editing != nil)
                TextEditor(text: $value).frame(height: 140).font(.body)
                Text("Saving an existing key replaces its value. Freeform ‘Remember that’ notes can be corrected here.").font(.caption).foregroundStyle(.secondary)
                HStack { Button("Cancel") { adding = false }; Spacer(); Button("Save") { Task { if await model.saveMemory(key: key, value: value) { adding = false } } }.keyboardShortcut(.defaultAction) }
                if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
            }.padding(25).frame(width: 470)
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Built to stay close.").font(.system(size: 27, weight: .light))
                GroupBox("Local model") {
                    VStack(alignment: .leading, spacing: 14) {
                        TextField("Model tag", text: $model.config.model)
                        Text("Downloaded: \(model.availableModels.isEmpty ? "none found" : model.availableModels.joined(separator: ", "))")
                        Text("127.0.0.1:11435 · redirects blocked · cloud models rejected").font(.system(size: 10, design: .monospaced)).foregroundStyle(accent)
                        Button(model.connecting ? "Connecting…" : "Save & reconnect") { model.saveSettings() }.disabled(model.connecting)
                    }.padding(10)
                }
                GroupBox("Voice") {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Read responses aloud", isOn: $model.config.speakResponses)
                        Text(model.audio.microphoneStatus).font(.system(size: 11)).foregroundStyle(accent)
                        Text("Input: " + model.audio.inputDeviceName).font(.system(size: 11)).foregroundStyle(muted)
                        Button("Open macOS sound input settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.sound?input")!)
                        }
                        Picker("Natural voice", selection: Binding(get: { model.config.naturalVoice ?? "bm_george" }, set: { model.config.naturalVoice = $0 })) {
                            ForEach(NaturalSpeech.voices) { voice in Text(voice.name).tag(voice.id) }
                        }
                        HStack {
                            Text("Speed")
                            Slider(value: Binding(get: { model.config.speechRate ?? 1 }, set: { model.config.speechRate = $0 }), in: 0.75...1.3, step: 0.05)
                            Text(String(format: "%.2f×", model.config.speechRate ?? 1)).monospacedDigit().frame(width: 50)
                        }
                        HStack {
                            Button("Preview voice") { model.previewVoice() }.disabled(model.busy)
                            if model.busy { Text(model.phase.rawValue).font(.caption); Button("Stop") { model.stop() } }
                        }
                        Text("Kokoro neural speech runs entirely on your Mac. Choose a voice, preview it, then save settings.").font(.system(size: 11)).foregroundStyle(muted)
                        TextField("whisper-cli executable", text: $model.config.whisperExecutable)
                        TextField("Whisper .bin model", text: $model.config.whisperModel)
                        Text("English local recording · click Record, speak, click Finish · up to 60 seconds · whisper.cpp on your Mac. Audio is temporary and deleted after transcription. Press ⌘⇧Space to start / finish; ⌘. stops speech and work.")
                            .font(.system(size: 11)).foregroundStyle(muted)
                    }.padding(10)
                }
                GroupBox("Permissions") {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Allow filename search in my chosen folder", isOn: $model.config.allowFileSearch)
                        Text(model.selectedFolder?.path ?? "No folder selected").font(.system(size: 11)).textSelection(.enabled)
                        HStack { Button("Choose folder…") { model.chooseFolder() }; if model.selectedFolder != nil { Button("Remove access") { model.revokeFolder() } } }
                        Text("Choose the folder for searching, reading text and saving reviewed drafts. Connect Chrome separately for websites. Browser form editing, sending messages, arbitrary app control and wake-word listening are not enabled. No Full Disk Access or Accessibility permission is needed.")
                            .font(.system(size: 11)).foregroundStyle(muted)
                    }.padding(10)
                }
                HStack { Button("Save settings") { model.saveSettings() }.buttonStyle(.borderedProminent); Spacer(); Button("Show local data") { NSWorkspace.shared.open(Configuration.dataDirectory) } }
                Text("Memories are stored in SQLite on this Mac. Conversations stay in memory until cleared or the app quits. Settings and the folder bookmark are stored alongside the database. No telemetry or hosted inference is configured.")
                    .font(.system(size: 11)).foregroundStyle(muted).lineSpacing(4)
                if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            }.textFieldStyle(.roundedBorder).padding(32).frame(maxWidth: 760, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RecordingStatusView: View {
    @ObservedObject var audio: AudioController
    let phase: AssistantPhase
    var body: some View {
        if phase == .listening {
            HStack(spacing: 10) {
                Circle().fill(.red).frame(width: 7, height: 7)
                Text("Recording · \(Int(audio.elapsed))s").font(.system(size: 11, weight: .medium))
                ProgressView(value: audio.level).frame(width: 80).tint(accent)
                Text(audio.inputDeviceName).font(.system(size: 10)).foregroundStyle(muted).lineLimit(1)
                Spacer()
                Text("Click Finish to send").font(.system(size: 10)).foregroundStyle(accent)
            }.padding(9).background(surface, in: RoundedRectangle(cornerRadius: 8))
        } else if phase == .preparing {
            Text("Waiting for microphone permission…").font(.caption).foregroundStyle(accent)
        }
    }
}

private struct CapabilitiesView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Choose what Jarvis can use.").font(.system(size: 27, weight: .light))
                Text("Jarvis combines enabled capabilities to work through a request. Each connection provides its own tools; the same assistant chooses and combines them. Only installed capabilities appear here.")
                    .font(.system(size: 13)).foregroundStyle(muted).lineSpacing(4)
                ForEach(model.capabilityEntries, id: \.definition.id) { entry in
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: Binding(get: { model.capabilityEnabled(entry.definition.name) },
                                             set: { model.setCapability(entry.definition.name, enabled: $0) })) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.definition.title).font(.system(size: 14, weight: .medium))
                                Text(entry.definition.provider + " · " + (entry.definition.effect == .readOnly ? "Read only" : "Review required"))
                                    .font(.system(size: 10)).foregroundStyle(muted)
                            }
                        }
                        Text(entry.definition.description).font(.system(size: 11)).foregroundStyle(muted)
                        Text(entry.unavailableReason ?? "Available").font(.system(size: 11)).foregroundStyle(entry.unavailableReason == nil ? accent : .orange)
                    }.padding(18).background(surface, in: RoundedRectangle(cornerRadius: 10))
                }
                Text("Connections to other apps and accounts require installed adapters and your permission. Jarvis cannot invent access. Local task and new-file changes appear as review cards. Apply a card to commit its exact contents. Browser sending, form editing and arbitrary code execution are not enabled. Wake-word listening is also not enabled.")
                    .font(.system(size: 12)).foregroundStyle(muted).lineSpacing(4)
                if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
            }.padding(32).frame(maxWidth: 760, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
