import AppKit
import DaisyCore
import SwiftUI

extension TaskLink.Kind {
    var symbol: String {
        switch self {
        case .file: "doc"
        case .url: "globe"
        case .googleDoc: "doc.text"
        case .googleDrive: "cloud"
        case .calendarEvent: "calendar"
        case .gmail: "envelope"
        case .note: "note.text"
        case .reminder: "checklist"
        }
    }
}

extension ProjectColor {
    /// The color in the current theme. Reading it in a view's body redraws the view when the accent changes.
    var color: Color { Color(tint(in: ThemeStore.shared.palette)) }
}

/// Small link buttons for a task row or a project header: up to three, then a count.
struct LinkIcons: View {
    let links: [TaskLink]
    let open: (TaskLink) -> Void
    var body: some View {
        HStack(spacing: 1) {
            ForEach(links.prefix(3)) { link in
                Button { open(link) } label: {
                    Image(systemName: link.kind.symbol).font(.system(size: 10.5, weight: .medium)).foregroundStyle(HUD.steel)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(link.title) · \(link.detail)")
                .accessibilityLabel("Open \(link.kind.title.lowercased()): \(link.title)")
            }
            if links.count > 3 {
                Menu {
                    ForEach(links.dropFirst(3)) { link in Button(link.title) { open(link) } }
                } label: {
                    Text("+\(links.count - 3)").font(HUD.label(9)).foregroundStyle(HUD.dim)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("More links")
            }
        }
    }
}

/// The links part of the task and project editors: what's linked, and a field to paste a URL or a path
/// into, or pick files.
struct LinksEditor: View {
    @Binding var links: [TaskLink]
    @State private var draft = ""
    @State private var problem: String?

    var body: some View {
        let detected = TaskLink.detect(draft)
        VStack(alignment: .leading, spacing: 6) {
            Text("LINKS").font(HUD.label(9)).tracking(1.4).foregroundStyle(HUD.dim)
            // A long list scrolls, so the sheet stays on screen.
            if links.count > 4 {
                ScrollView { rows }.frame(height: 200)
            } else {
                rows
            }
            HStack(spacing: 8) {
                TextField("Paste a link or a file's path", text: $draft).hudField().onSubmit(add)
                Button("Add", action: add).buttonStyle(HUDButtonStyle(kind: .ghost, compact: true))
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Choose files…", action: choose).buttonStyle(HUDButtonStyle(kind: .ghost, compact: true))
            }
            if let detected {
                Label("\(detected.kind.title) · \(detected.detail)", systemImage: detected.kind.symbol)
                    .font(.system(size: 11)).foregroundStyle(HUD.dim).lineLimit(1)
            }
            if let problem { Text(problem).font(.system(size: 11)).foregroundStyle(HUD.amber).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($links) { $link in
                LinkRow(link: $link, open: { problem = LinkOpener.open(link) { problem = $0 } },
                        remove: { links.removeAll { $0.id == link.id } })
            }
        }
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard var link = TaskLink.detect(text) else {
            problem = "That isn't a web link or a file path. Paste a full link (https://…) or a path like ~/Documents/essay.pdf."
            return
        }
        if link.kind == .file { link = link.refreshed() }
        if insert(link) { draft = "" }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = "Link"
        panel.message = "Pick files or folders to link. Daisy keeps track of them if they move."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { _ = insert(TaskLink.file(path: url.path).refreshed()) }
    }

    /// Adds it unless it's already there or can't be kept. True when it was added.
    private func insert(_ link: TaskLink) -> Bool {
        if links.contains(where: { $0.reference == link.reference }) { problem = "“\(link.title)” is already linked."; return false }
        guard links.count < TaskLink.perItem else { problem = "Up to \(TaskLink.perItem) links."; return false }
        do { try link.validate() } catch { problem = error.localizedDescription; return false }
        links.append(link)
        problem = nil
        return true
    }
}

/// One link in an editor: its kind, a title you can change, where it points, open and remove.
private struct LinkRow: View {
    @Binding var link: TaskLink
    let open: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        let missing = link.kind == .file && link.resolvedFile() == nil
        HStack(spacing: 10) {
            Image(systemName: link.kind.symbol).font(.system(size: 12, weight: .medium))
                .foregroundStyle(missing ? HUD.crimson : HUD.accent).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Title", text: $link.title).textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(HUD.ice)
                Text(missing ? "Not found · \(link.detail)" : "\(link.kind.title) · \(link.detail)")
                    .font(.system(size: 10.5)).foregroundStyle(missing ? HUD.crimson : HUD.dim).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Button(action: open) { Image(systemName: "arrow.up.right.square") }
                .buttonStyle(.plain).foregroundStyle(HUD.steel).help(link.kind == .file ? "Open the file" : "Open")
            Button(action: remove) { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(HUD.crimson).help("Remove the link")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Rectangle().fill(HUD.void.opacity(hovering ? 0.8 : 0.55)))
        .overlay(Rectangle().strokeBorder(HUD.line.opacity(0.14), lineWidth: 1))
        .onHover { hovering = $0 }
    }
}
