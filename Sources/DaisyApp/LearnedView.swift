import SwiftUI
import DaisyCore

/// The Learned feed for the Memory tab: what Hermes saved, changed or dropped on its own, newest first,
/// with Undo, Edit and Keep. Shown when Hermes is the brain; the model does the file work.
struct LearnedView: View {
    @ObservedObject var learned: LearnedMemory
    @State private var editing: LearnedItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("LEARNED ON ITS OWN").hudCaption(HUD.accent)
                if learned.working { ProgressView().controlSize(.mini) }
                Spacer()
                Button { learned.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(HUDButtonStyle(kind: .ghost, compact: true)).help("Reload")
            }
            Text("What Hermes saved, changed or dropped without being asked. Undo puts it back how it was, Keep clears it from this list. Changes reach the next chat.")
                .font(.system(size: 11.5)).foregroundStyle(HUD.dim).fixedSize(horizontal: false, vertical: true)
            if learned.items.isEmpty {
                Text("Nothing yet. Every few turns Hermes looks back over the chat and saves what's worth keeping; it shows up here.")
                    .font(.system(size: 12)).foregroundStyle(HUD.dim)
            }
            ForEach(learned.items) { item in
                LearnedRow(item: item, busy: learned.working,
                           undo: { Task { await learned.undo(item) } },
                           edit: { editing = item },
                           keep: { learned.keep(item) })
            }
            if let problem = learned.problem {
                Text(problem).font(.system(size: 11)).foregroundStyle(HUD.amber).textSelection(.enabled)
            }
        }
        .onAppear { learned.refresh() }
        .task {
            // Hermes's review runs after a turn, so check again now and then while this is on screen.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                learned.refresh()
            }
        }
        .sheet(item: $editing) { item in LearnedEditor(learned: learned, item: item) }
    }
}

private struct LearnedRow: View {
    let item: LearnedItem
    let busy: Bool
    let undo: () -> Void
    let edit: () -> Void
    let keep: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label).foregroundStyle(item.kind == .forgot ? HUD.amber : HUD.accent)
                Text("·")
                Text(item.target.title.uppercased())
                Text("·")
                Text(item.date.formatted(.relative(presentation: .named)).uppercased())
                Spacer(minLength: 8)
                Button("Keep", action: keep).buttonStyle(HUDButtonStyle(kind: .ghost, compact: true)).disabled(busy)
                    .help("It's right; take it off this list")
                if item.canEdit {
                    Button("Edit", action: edit).buttonStyle(HUDButtonStyle(kind: .ghost, compact: true)).disabled(busy)
                }
                if item.canUndo {
                    Button(item.kind == .forgot ? "Put back" : "Undo", action: undo)
                        .buttonStyle(HUDButtonStyle(kind: .danger, compact: true)).disabled(busy)
                        .help(undoHelp)
                }
            }
            .font(HUD.label(9)).tracking(1.1).foregroundStyle(HUD.dim)
            Text(rich(item.text)).font(.system(size: 13.5)).foregroundStyle(item.kind == .forgot ? HUD.steel : HUD.ice)
                .strikethrough(item.kind == .forgot && item.exact, color: HUD.dim).textSelection(.enabled)
            if let previous = item.previous {
                Text("Was: " + previous).font(.system(size: 12)).foregroundStyle(HUD.steel).textSelection(.enabled)
            }
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(HUD.dim)
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(HUD.line.opacity(0.09)).frame(height: 1) }
    }

    private var label: String {
        switch item.kind {
        case .learned: return item.origin == nil ? "NEW" : "LEARNED"
        case .changed: return "CHANGED"
        case .forgot: return "FORGOT"
        }
    }

    private var undoHelp: String {
        switch item.kind {
        case .learned: return "Take this out of Hermes's memory"
        case .changed: return "Put back what it replaced"
        case .forgot: return "Put this back in Hermes's memory"
        }
    }

    private var note: String? {
        if item.origin == nil { return "Nothing logged how this got here: maybe added outside a chat, or before Daisy kept a log." }
        if item.kind == .changed && item.previous == nil { return "What it replaced wasn't recorded, so there's nothing to put back. Edit it instead." }
        if item.kind == .forgot && !item.exact { return "Only the words it matched on were logged, so it can't be put back from here." }
        return nil
    }
}

/// Rewrites a learned entry in the user's own words.
private struct LearnedEditor: View {
    @ObservedObject var learned: LearnedMemory
    let item: LearnedItem
    @State private var text: String
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    init(learned: LearnedMemory, item: LearnedItem) {
        self.learned = learned; self.item = item
        _text = State(initialValue: item.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit what Hermes learned").font(.system(size: 17, weight: .semibold)).foregroundStyle(HUD.ice)
            TextEditor(text: $text).font(.system(size: 13)).scrollContentBackground(.hidden).padding(6)
                .frame(height: 150).background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.28)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(HUD.line.opacity(0.2), lineWidth: 1))
            Text("\(HermesMemory.length(HermesMemory.strip(text)).formatted()) characters · \(item.target.fileName) holds \(learned.files.limit(item.target).formatted()) in all. Hermes sees the change in its next chat.")
                .font(.system(size: 11)).foregroundStyle(HUD.dim)
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(HUDButtonStyle(kind: .ghost))
                Spacer()
                Button(saving ? "Saving…" : "Save") {
                    saving = true
                    Task {
                        if await learned.edit(item, to: text) { dismiss() }
                        saving = false
                    }
                }
                .buttonStyle(HUDButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                .disabled(saving || HermesMemory.strip(text).isEmpty)
            }
            if let problem = learned.problem { Text(problem).font(.system(size: 11)).foregroundStyle(HUD.amber) }
        }
        .padding(24).frame(width: 470)
        .background(HUD.deep)
    }
}
