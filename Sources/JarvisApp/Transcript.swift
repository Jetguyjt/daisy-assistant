import AppKit
import SwiftUI
import JarvisCore

/// One message in the transcript. Equatable on the message itself, so a streaming reply
/// elsewhere doesn't make every earlier row lay out its text again.
struct MessageView: View, Equatable {
    let model: AppModel
    let item: ConversationItem
    let isLast: Bool
    @State private var hovering = false

    static func == (a: MessageView, b: MessageView) -> Bool { a.item.id == b.item.id && a.isLast == b.isLast }

    var body: some View {
        Group {
            switch item.role {
            case "user": user
            case "status": status
            default: assistant
            }
        }
        .onHover { hovering = $0 }
    }

    private var user: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("YOU").font(HUD.label(10)).tracking(1.6).foregroundStyle(HUD.dim)
                Spacer()
                actions(copy: true, edit: true)
            }
            if !item.attachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(item.attachments, id: \.self) { name in
                        Label(name, systemImage: "paperclip").font(.system(size: 11)).foregroundStyle(HUD.steel).lineLimit(1)
                            .padding(.horizontal, 8).frame(height: 22)
                            .overlay(Rectangle().strokeBorder(HUD.line.opacity(0.25), lineWidth: 1))
                    }
                }
            }
            if !item.text.isEmpty {
                CollapsibleText(text: item.text, markdown: false)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Rectangle().fill(HUD.accent.opacity(0.06)))
                    .overlay(alignment: .leading) { Rectangle().fill(HUD.accent.opacity(0.4)).frame(width: 1) }
            }
        }
    }

    private var status: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(HUD.amber)
            Text(item.text).foregroundStyle(HUD.amber.opacity(0.92)).textSelection(.enabled)
        }
        .font(.system(size: 12))
    }

    private var assistant: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                speakerLabel("JARVIS", color: HUD.accent, detail: item.detail)
                Spacer()
                actions(copy: true, speak: true, retry: isLast)
            }
            ForEach(item.decisions, id: \.self) { decision in
                HStack(spacing: 6) {
                    Image(systemName: decision.hasPrefix("Approved") ? "checkmark.shield.fill" : "xmark.shield.fill")
                        .foregroundStyle(decision.hasPrefix("Approved") ? HUD.accent : HUD.amber)
                    Text(decision).foregroundStyle(HUD.steel)
                }
                .font(.system(size: 11))
            }
            CollapsibleText(text: item.text, markdown: true)
            if !item.receipts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(item.receipts) { receipt in
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: receipt.status == .succeeded ? "checkmark.circle" : "exclamationmark.circle")
                                .foregroundStyle(receipt.status == .succeeded ? HUD.accent : HUD.amber)
                            Text(receipt.title).foregroundStyle(HUD.steel) + Text("  " + receipt.output.summary).foregroundStyle(HUD.dim)
                        }
                        .font(.system(size: 11)).textSelection(.enabled)
                    }
                }
            }
            ForEach(item.receipts.compactMap(\.output.review)) { review in ReviewCard(model: model, review: review) }
            if let report = item.files { FileResults(model: model, report: report) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Copy, edit, read aloud, retry: on hover, and always on the latest answer.
    @ViewBuilder private func actions(copy: Bool = false, edit: Bool = false, speak: Bool = false, retry: Bool = false) -> some View {
        HStack(spacing: 2) {
            if copy { CopyButton(text: item.text) }
            if edit {
                ActionButton(symbol: "pencil", help: "Edit and resend") { model.composer.set(item.text) }
            }
            if speak {
                ActionButton(symbol: "speaker.wave.2", help: "Read aloud") { model.readAloud(item.text) }
            }
            if retry {
                ActionButton(symbol: "arrow.clockwise", help: "Try again") { model.retryLast() }
            }
        }
        .opacity(hovering || isLast ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

func speakerLabel(_ name: String, color: Color, detail: String? = nil) -> some View {
    HStack(spacing: 7) {
        Rectangle().fill(color).frame(width: 5, height: 5)
        Text(name).font(HUD.label(10)).tracking(1.6).foregroundStyle(color)
        if let detail { Text(detail).font(HUD.readout(9)).foregroundStyle(HUD.dim).lineLimit(1) }
    }
}

struct ActionButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 22)
                .foregroundStyle(hovering ? HUD.accent : HUD.dim)
                .background(Rectangle().fill(hovering ? HUD.accent.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
        .help(help).accessibilityLabel(help)
    }
}

struct CopyButton: View {
    let text: String
    @State private var copied = false
    var body: some View {
        ActionButton(symbol: copied ? "checkmark" : "doc.on.doc", help: copied ? "Copied" : "Copy") {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        }
    }
}

/// Short text renders inline. Very long text (a big paste) shows a preview, and "Show all" opens it
/// in a native scrolling box: laying out 50,000 characters as a SwiftUI Text is what froze the app.
struct CollapsibleText: View {
    let text: String
    let markdown: Bool
    @State private var expanded = false
    static let previewLimit = 2_500

    var body: some View {
        if text.count <= Self.previewLimit {
            if markdown { MarkdownView(text: text) }
            else { Text(text).font(.system(size: 14)).lineSpacing(4).foregroundStyle(HUD.ice).textSelection(.enabled) }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if expanded {
                    LongTextBox(text: text).frame(height: 420)
                } else {
                    Text(String(text.prefix(1_200)) + "…").font(.system(size: 14)).lineSpacing(4).foregroundStyle(HUD.ice)
                }
                Button(expanded ? "SHOW LESS" : "SHOW ALL · \(text.count.formatted()) CHARACTERS") { expanded.toggle() }
                    .buttonStyle(.plain).font(HUD.label(9)).tracking(1.4).foregroundStyle(HUD.accent)
            }
        }
    }
}

/// Read-only native text view for very long messages.
struct LongTextBox: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false; view.isSelectable = true; view.drawsBackground = false
            view.font = .systemFont(ofSize: 13); view.textColor = NSColor(HUD.ice)
            view.layoutManager?.allowsNonContiguousLayout = true
            view.string = text
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let view = scroll.documentView as? NSTextView, view.string != text { view.string = text }
    }
}

/// Answers as blocks: paragraphs, headings, lists, quotes, tables, and code with a copy button.
struct MarkdownView: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlocks.parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(rich(text)).font(.system(size: 14)).lineSpacing(5).foregroundStyle(HUD.ice.opacity(0.94))
        case .heading(let level, let text):
            Text(rich(text)).font(.system(size: level == 1 ? 18 : level == 2 ? 16 : 14.5, weight: .semibold)).foregroundStyle(HUD.ice)
                .padding(.top, 4)
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(index + 1)." : "▪").font(ordered ? HUD.readout(12) : .system(size: 8)).foregroundStyle(HUD.accent)
                            .frame(minWidth: 16, alignment: .trailing)
                        Text(rich(item)).font(.system(size: 14)).lineSpacing(4).foregroundStyle(HUD.ice.opacity(0.94))
                    }
                }
            }
        case .code(let language, let code):
            CodeBlock(language: language, code: code)
        case .quote(let text):
            Text(rich(text)).font(.system(size: 13.5)).italic().foregroundStyle(HUD.steel)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(HUD.accent.opacity(0.5)).frame(width: 1) }
        case .table(let rows):
            TableBlock(rows: rows)
        case .rule:
            Rectangle().fill(HUD.line.opacity(0.2)).frame(height: 1).padding(.vertical, 4)
        }
    }
}

struct CodeBlock: View {
    let language: String?
    let code: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text((language ?? "code").uppercased()).font(HUD.label(9)).tracking(1.4).foregroundStyle(HUD.dim)
                Spacer()
                CopyButton(text: code)
            }
            .padding(.leading, 12).padding(.trailing, 4).frame(height: 28)
            .overlay(alignment: .bottom) { Rectangle().fill(HUD.line.opacity(0.15)).frame(height: 1) }
            ScrollView(.horizontal) {
                Text(code).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(HUD.ice)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(12)
            }
            .scrollIndicators(.automatic)
        }
        .background(Rectangle().fill(Color.black.opacity(0.35)))
        .overlay(Rectangle().strokeBorder(HUD.line.opacity(0.2), lineWidth: 1))
    }
}

struct TableBlock: View {
    let rows: [[String]]
    var body: some View {
        let width = rows.map(\.count).max() ?? 0
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(0..<width, id: \.self) { column in
                            let cell = column < row.count ? row[column] : ""
                            if index == 0 {
                                Text(cell.uppercased()).font(HUD.label(9.5)).tracking(1.2).foregroundStyle(HUD.accent)
                            } else {
                                Text(rich(cell)).font(.system(size: 13)).foregroundStyle(HUD.ice.opacity(0.92))
                            }
                        }
                    }
                    if index == 0 { Rectangle().fill(HUD.line.opacity(0.2)).frame(height: 1).gridCellUnsizedAxes(.horizontal) }
                }
            }
            .padding(12)
        }
        .overlay(Rectangle().strokeBorder(HUD.line.opacity(0.18), lineWidth: 1))
    }
}

/// File search results with open and reveal buttons.
struct FileResults: View {
    let model: AppModel
    let report: SearchReport
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(report.files.count) RESULTS · \(report.scanned) SCANNED\(report.limited ? " · PARTIAL" : "")\(report.unreadableLocations > 0 ? " · \(report.unreadableLocations) UNREADABLE" : "")")
                .font(HUD.label(8.5)).tracking(1.3).foregroundStyle(HUD.dim).padding(.bottom, 8)
            ForEach(report.files.prefix(8)) { file in
                HStack(spacing: 10) {
                    Image(systemName: "doc.text").foregroundStyle(HUD.accent).frame(width: 16)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(file.name).font(.system(size: 12, weight: .medium)).foregroundStyle(HUD.ice)
                        Text(file.path).font(.system(size: 10)).foregroundStyle(HUD.dim).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    Spacer(minLength: 6)
                    Text(file.modified.formatted(date: .abbreviated, time: .omitted)).font(HUD.readout(9.5)).foregroundStyle(HUD.dim)
                    Button { model.openFile(file, reveal: true) } label: { Image(systemName: "folder") }.help("Show in Finder")
                        .accessibilityLabel("Show \(file.name) in Finder")
                    Button { model.openFile(file, reveal: false) } label: { Image(systemName: "arrow.up.forward.square") }.help("Open")
                        .accessibilityLabel("Open \(file.name)")
                }
                .buttonStyle(.plain).foregroundStyle(HUD.steel)
                .padding(.vertical, 8)
                .overlay(alignment: .top) { Rectangle().fill(HUD.line.opacity(0.08)).frame(height: 1) }
            }
            if report.files.count > 8 {
                Text("Showing 8 of \(report.files.count). Narrow the search for the rest.").font(.system(size: 11)).foregroundStyle(HUD.dim).padding(.top, 6)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Rectangle().fill(HUD.accent.opacity(0.025)))
        .overlay(Rectangle().strokeBorder(HUD.accent.opacity(0.2), lineWidth: 1))
        .overlay(CornerBrackets(length: 10).stroke(HUD.accent, lineWidth: 1.5))
    }
}
