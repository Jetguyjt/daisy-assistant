import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import DaisyCore

/// What's being typed. Kept apart from AppModel so a keystroke redraws the composer only, not the
/// whole window (a 50,000-character paste used to re-lay out everything on every change).
@MainActor final class ComposerState: ObservableObject {
    @Published var text = ""
    @Published var attachments: [URL] = []
    @Published var focused = false
    private(set) var focusRequest = 0

    func focus() { focusRequest += 1; objectWillChange.send() }
    /// Replaces the text (quick actions, editing an earlier message) and puts the cursor in.
    func set(_ newText: String) { text = newText; focus() }
    func add(_ urls: [URL]) {
        for url in urls where !attachments.contains(url) && attachments.count < 10 { attachments.append(url) }
    }
}

/// Plain-text editor with chat keys: Return sends, Shift- or Option-Return adds a line. In the
/// expanded editor Return adds a line and ⌘Return sends. Esc leaves; ↑ in an empty box edits
/// the last message. Pasted or dropped files become attachments instead of text.
final class ComposerTextView: NSTextView {
    var expanded = false
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onFiles: (([URL]) -> Void)?
    /// Drawn by the view itself at the text origin, so it sits exactly where the cursor and the first
    /// typed letter go. A SwiftUI overlay can't know the container inset and line padding.
    var placeholder = "" { didSet { if placeholder != oldValue { needsDisplay = true } } }
    var placeholderColor = NSColor.secondaryLabelColor

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty, let font else { return }
        let origin = NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y)
        (placeholder as NSString).draw(at: origin, withAttributes: [.font: font, .foregroundColor: placeholderColor])
    }

    override func didChangeText() {
        super.didChangeText()
        // The placeholder shows only while empty, so redraw when that flips.
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 36 where !hasMarkedText(), 76 where !hasMarkedText():
            if expanded {
                if flags.contains(.command) { onSubmit?(); return }
            } else if !flags.contains(.shift), !flags.contains(.option) {
                onSubmit?(); return
            }
        case 126 where string.isEmpty && flags.isDisjoint(with: [.shift, .command, .option, .control]):
            if let onArrowUp { onArrowUp(); return }
        default:
            break
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        if let onFiles, let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onFiles(urls); return
        }
        if let onFiles, !(board.types ?? []).contains(.string), let image = NSImage(pasteboard: board), let url = Self.save(image) {
            onFiles([url]); return
        }
        pasteAsPlainText(sender)
    }

    /// File drops go to the composer as attachments, not into the text as paths.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes.filter { $0 != .fileURL && $0 != .URL && $0.rawValue != "NSFilenamesPboardType" }
    }

    static func save(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("daisy-paste", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Pasted image \(Date().formatted(.dateTime.hour().minute().second())).png")
        return (try? png.write(to: url)) == nil ? nil : url
    }
}

struct ComposerEditor: NSViewRepresentable {
    @ObservedObject var state: ComposerState
    var expanded = false
    var fontSize: CGFloat = 14
    var maxLines = 8
    var placeholder = ""
    @Binding var height: CGFloat
    var onSubmit: () -> Void
    var onEscape: () -> Void
    var onArrowUp: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let text = ComposerTextView(usingTextLayoutManager: false)
        text.isRichText = false
        text.importsGraphics = false
        text.allowsUndo = true
        text.usesFindBar = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.drawsBackground = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 0, height: 7)
        text.layoutManager?.allowsNonContiguousLayout = true
        text.insertionPointColor = NSColor(HUD.accent)
        text.selectedTextAttributes = [.backgroundColor: NSColor(HUD.accent).withAlphaComponent(0.3), .foregroundColor: NSColor.white]
        text.delegate = context.coordinator
        scroll.documentView = text
        context.coordinator.textView = text
        context.coordinator.apply(self)
        text.string = state.text
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.frameChanged),
                                               name: NSView.frameDidChangeNotification, object: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.apply(self)
        guard let text = coordinator.textView else { return }
        if text.string != state.text {
            text.string = state.text
            text.needsDisplay = true
            text.setSelectedRange(NSRange(location: (state.text as NSString).length, length: 0))
            text.scrollToEndOfDocument(nil)
            coordinator.measure()
        }
        if coordinator.focusSeen != state.focusRequest {
            coordinator.focusSeen = state.focusRequest
            DispatchQueue.main.async { text.window?.makeFirstResponder(text) }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerEditor
        weak var textView: ComposerTextView?
        var focusSeen = 0
        private var fontSize: CGFloat = 0

        init(_ parent: ComposerEditor) { self.parent = parent; focusSeen = parent.state.focusRequest }

        func apply(_ parent: ComposerEditor) {
            guard let text = textView else { return }
            text.expanded = parent.expanded
            text.onSubmit = parent.onSubmit
            text.onEscape = parent.onEscape
            text.onArrowUp = parent.onArrowUp
            let state = parent.state
            text.onFiles = { urls in state.add(urls) }
            text.placeholder = parent.placeholder
            text.placeholderColor = NSColor(HUD.dim)
            if fontSize != parent.fontSize {
                fontSize = parent.fontSize
                let font = NSFont.systemFont(ofSize: parent.fontSize)
                text.font = font
                text.textColor = NSColor(HUD.ice)
                text.typingAttributes = [.font: font, .foregroundColor: NSColor(HUD.ice)]
                measure()
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let text = textView else { return }
            parent.state.text = text.string
            // Spell-checking a huge paste costs more than it helps.
            let long = (text.string as NSString).length > 20_000
            if text.isContinuousSpellCheckingEnabled == long { text.isContinuousSpellCheckingEnabled = !long }
            measure()
        }
        func textDidBeginEditing(_ notification: Notification) { parent.state.focused = true }
        func textDidEndEditing(_ notification: Notification) { parent.state.focused = false }
        @objc func frameChanged() { measure() }

        /// Grows with the text up to `maxLines`, then scrolls. Long text skips the full layout: past a
        /// few thousand characters it's taller than the cap whatever the width, and laying out a big
        /// paste just to learn that is what used to freeze the app.
        func measure() {
            guard let text = textView, !parent.expanded, let layout = text.layoutManager, let container = text.textContainer,
                  let font = text.font else { return }
            let line = layout.defaultLineHeight(for: font)
            let inset = text.textContainerInset.height * 2
            let cap = line * CGFloat(parent.maxLines) + inset
            var height = cap
            if (text.string as NSString).length < 2_000 {
                layout.ensureLayout(for: container)
                height = layout.usedRect(for: container).height + inset
            }
            height = min(max(height, line + inset), cap)
            if abs(height - parent.height) > 0.5 {
                DispatchQueue.main.async { self.parent.height = height }
            }
        }
    }
}

/// Byte count against the limit, shown once it starts to matter.
struct SizeCounter: View {
    let bytes: Int
    let limit: Int
    var always = false
    var body: some View {
        if always || bytes > limit / 10 {
            Text("\(Self.format(bytes)) / \(Self.format(limit))")
                .font(HUD.readout(10)).monospacedDigit()
                .foregroundStyle(bytes > limit ? HUD.crimson : bytes > limit * 9 / 10 ? HUD.amber : HUD.dim)
                .help(bytes > limit ? "Too long to send" : "Message size")
        }
    }
    static func format(_ bytes: Int) -> String {
        bytes < 1_000 ? "\(bytes) B" : String(format: bytes < 10_000 ? "%.1f KB" : "%.0f KB", Double(bytes) / 1_000)
    }
}

/// Files waiting to be sent with the next message.
struct AttachmentChips: View {
    @ObservedObject var composer: ComposerState
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(composer.attachments, id: \.self) { url in
                    HStack(spacing: 6) {
                        Image(systemName: Attachments.symbol(for: url)).foregroundStyle(HUD.accent)
                        Text(url.lastPathComponent).font(.system(size: 11.5)).foregroundStyle(HUD.ice).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: 180, alignment: .leading)
                        Button { composer.attachments.removeAll { $0 == url } } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                            .buttonStyle(.plain).foregroundStyle(HUD.dim).accessibilityLabel("Remove \(url.lastPathComponent)")
                    }
                    .padding(.horizontal, 9).frame(height: 26)
                    .background(Rectangle().fill(HUD.accent.opacity(0.06)))
                    .overlay(Rectangle().strokeBorder(HUD.accent.opacity(0.3), lineWidth: 1))
                }
            }
        }
        .scrollIndicators(.never)
    }
}

/// The message box: attachments, the editor, and the talk / send / stop buttons.
struct ComposerBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var composer: ComposerState
    @State private var height: CGFloat = 32
    @State private var dropTargeted = false

    var body: some View {
        let limit = model.usesHermes ? HermesBackend.maxRequestBytes : 4000
        let bytes = composer.text.utf8.count
        VStack(alignment: .leading, spacing: 8) {
            if !composer.attachments.isEmpty { AttachmentChips(composer: composer) }
            HStack(alignment: .bottom, spacing: 10) {
                if model.usesHermes {
                    Button { pickFiles() } label: {
                        Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 34)
                    }
                    .buttonStyle(.plain).foregroundStyle(HUD.accent)
                    .help("Attach files or images (their contents go to the model)")
                    .accessibilityLabel("Attach files")
                }
                if model.phase == .listening || model.phase == .preparing {
                    ListeningStrip(audio: model.audio, preparing: model.phase == .preparing).frame(height: 34)
                } else {
                    ComposerEditor(state: composer,
                                   placeholder: model.alwaysListening ? "Message Daisy, or say “Hey Daisy”" : "Message Daisy",
                                   height: $height, onSubmit: model.submit, onEscape: model.interrupt,
                                   onArrowUp: model.editLastMessage)
                        .frame(height: height)
                        .frame(maxWidth: .infinity)
                }
                VStack(alignment: .trailing, spacing: 4) {
                    if height > 60 || bytes > 600 {
                        Button { model.composerExpanded = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .semibold)) }
                            .buttonStyle(.plain).foregroundStyle(HUD.dim).help("Expand editor (⌘⇧E)").accessibilityLabel("Expand editor")
                    }
                    SizeCounter(bytes: bytes, limit: limit)
                }
                talkButton
                if model.busy && model.phase != .listening && model.phase != .preparing { stopButton }
                else { sendButton(disabled: (composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && composer.attachments.isEmpty) || bytes > limit) }
            }
        }
        .padding(.leading, model.usesHermes ? 4 : 12).padding(.trailing, 6).padding(.vertical, 6)
        .background(Rectangle().fill(HUD.void.opacity(0.7)))
        .overlay(Rectangle().strokeBorder(dropTargeted ? HUD.accent : composer.focused ? HUD.accent.opacity(0.5) : HUD.line.opacity(0.2), lineWidth: 1))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard model.usesHermes else { return false }
            Attachments.urls(from: providers) { urls in composer.add(urls) }
            return true
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.message = "Attach files. Their contents are sent to the model with your message."
        guard panel.runModal() == .OK else { return }
        composer.add(panel.urls)
        composer.focus()
    }

    private var talkButton: some View {
        let live = model.phase == .listening
        let preparing = model.phase == .preparing
        return Button { model.toggleListening() } label: {
            Image(systemName: live ? "stop.fill" : preparing ? "xmark" : "mic.fill")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 34, height: 34)
                .foregroundStyle(live ? HUD.void : HUD.accent)
                .background(Rectangle().fill(live ? HUD.crimson : HUD.accent.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(live ? "Finish and send (⌘⇧Space)" : "Talk (⌘⇧Space)")
        .accessibilityLabel(live ? "Finish recording and send" : preparing ? "Cancel" : "Start talking")
    }

    private func sendButton(disabled: Bool) -> some View {
        Button { model.submit() } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .frame(width: 34, height: 34)
                .foregroundStyle(HUD.void)
                .background(Rectangle().fill(HUD.accent.opacity(disabled ? 0.35 : 1)))
        }
        .buttonStyle(.plain).disabled(disabled)
        .help("Send (Return)")
        .accessibilityLabel("Send")
    }

    private var stopButton: some View {
        Button { model.interrupt() } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 12, weight: .bold))
                .frame(width: 34, height: 34)
                .foregroundStyle(HUD.void)
                .background(Rectangle().fill(HUD.crimson))
        }
        .buttonStyle(.plain)
        .help("Stop (⌘.)")
        .accessibilityLabel("Stop")
    }
}

/// The editor at full size for long messages. Return adds a line here; ⌘Return sends.
struct ExpandedComposer: View {
    @ObservedObject var model: AppModel
    @ObservedObject var composer: ComposerState
    @State private var unused: CGFloat = 0
    var body: some View {
        let limit = model.usesHermes ? HermesBackend.maxRequestBytes : 4000
        let bytes = composer.text.utf8.count
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("COMPOSE").hudCaption(HUD.accent)
                SizeCounter(bytes: bytes, limit: limit, always: true)
                Spacer()
                Button { model.composerExpanded = false } label: { Label("Collapse", systemImage: "arrow.down.right.and.arrow.up.left") }
                    .buttonStyle(HUDButtonStyle(kind: .ghost, compact: true)).help("Collapse (Esc or ⌘⇧E)")
            }
            ComposerEditor(state: composer, expanded: true, fontSize: 15, height: $unused,
                           onSubmit: model.submit, onEscape: { model.composerExpanded = false })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Rectangle().fill(HUD.void.opacity(0.6)))
                .overlay(Rectangle().strokeBorder(HUD.accent.opacity(0.35), lineWidth: 1))
            if !composer.attachments.isEmpty { AttachmentChips(composer: composer) }
            HStack {
                Text("RETURN ADDS A LINE · ⌘RETURN SENDS").font(HUD.label(9)).tracking(1.4).foregroundStyle(HUD.dim)
                Spacer()
                Button { model.submit() } label: { Label("Send", systemImage: "arrow.up") }
                    .buttonStyle(HUDButtonStyle(kind: .primary))
                    .disabled((composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && composer.attachments.isEmpty) || bytes > limit)
            }
        }
        .padding(18)
        .hudPanel(radius: 16)
        .onAppear { composer.focus() }
    }
}

/// Turns picked files into what the agent can read: images inline, PDF and Word text pulled out
/// here, everything else handed over by path for Hermes to read.
enum Attachments {
    static let imageLimit = 10_000_000
    static let textLimit = 400_000

    static func symbol(for url: URL) -> String {
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true { return "photo" }
        if type?.conforms(to: .pdf) == true { return "doc.richtext" }
        return "doc.text"
    }

    static func load(_ url: URL) throws -> AgentAttachment {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        let name = url.lastPathComponent
        if let type, type.conforms(to: .image) {
            let data = try Data(contentsOf: url)
            if [UTType.png, .jpeg, .gif, .webP].contains(type), data.count <= imageLimit {
                return .image(name: name, mimeType: type.preferredMIMEType ?? "image/png", data: data)
            }
            // HEIC, TIFF and oversized images go over as a JPEG that fits.
            guard let image = NSImage(data: data), let jpeg = jpeg(image, maxSide: 2048), jpeg.count <= imageLimit else {
                throw DaisyError.message("\(name) couldn't be read as an image.")
            }
            return .image(name: name, mimeType: "image/jpeg", data: jpeg)
        }
        if let type, type.conforms(to: .pdf) {
            guard let text = PDFDocument(url: url)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                throw DaisyError.message("\(name) has no readable text (it may be scanned).")
            }
            return .document(name: name, uri: url.absoluteString, text: String(text.prefix(textLimit)))
        }
        if ["docx", "doc", "rtf", "rtfd", "odt"].contains(url.pathExtension.lowercased()) {
            let text = try NSAttributedString(url: url, options: [:], documentAttributes: nil).string
            return .document(name: name, uri: url.absoluteString, text: String(text.prefix(textLimit)))
        }
        return .file(url)
    }

    static func jpeg(_ image: NSImage, maxSide: CGFloat) -> Data? {
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height, 1))
        let target = NSSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    static func urls(from providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in completion([url]) }
            }
        }
    }
}
