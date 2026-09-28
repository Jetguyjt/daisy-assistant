import SwiftUI
import DaisyCore

/// A prepared change waiting for a yes. Amber corners mark anything that needs a decision.
struct ReviewCard: View {
    @ObservedObject var model: AppModel
    let review: ReviewedAction
    @State private var expanded = true
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(HUD.amber)
                Text(review.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(HUD.ice)
            }
            DisclosureGroup(isExpanded: $expanded) {
                ScrollView {
                    Text(review.preview).font(.system(size: 12, design: .monospaced)).foregroundStyle(HUD.ice.opacity(0.9))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240).padding(.top, 8)
            } label: {
                Text("EXACT CONTENTS").font(HUD.label(8.5)).tracking(1.4).foregroundStyle(HUD.steel)
            }
            if let status = model.reviewStatus(review) {
                Text(status).font(.system(size: 11.5)).foregroundStyle(HUD.accent).textSelection(.enabled)
            } else {
                HStack(spacing: 10) {
                    Button("Discard") { model.discardReview(review) }
                        .buttonStyle(HUDButtonStyle(kind: .ghost, compact: true))
                        .disabled(model.applyingReviews.contains(review.id))
                    Button(model.applyingReviews.contains(review.id) ? "Applying…" : "Apply") { model.applyReview(review) }
                        .buttonStyle(HUDButtonStyle(kind: .critical, compact: true))
                        .disabled(model.busy || model.applyingReviews.contains(review.id))
                    Text("Nothing changes until you apply it.").font(.system(size: 11)).foregroundStyle(HUD.dim)
                }
            }
        }
        .padding(14)
        .hudPanel(tint: HUD.amber)
    }
}

struct ConnectionsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HUDPage(kicker: "CHROME / THROUGH HERMES", title: "Connections") {
            HStack(spacing: 12) {
                Image(systemName: "globe").font(.system(size: 18)).foregroundStyle(HUD.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Google Chrome").font(.system(size: 15, weight: .semibold)).foregroundStyle(HUD.ice)
                    Text("YOUR OWN CHROME, NOTHING TO CONNECT").font(HUD.label(9)).tracking(1.4).foregroundStyle(HUD.accent)
                }
            }
            Text("Daisy uses your own Chrome through Hermes: it can list your tabs, switch to one and open pages, including your signed-in ones. It can't click, type or run anything inside a page. The first time, macOS asks whether Daisy can control Google Chrome.")
                .font(.system(size: 12)).foregroundStyle(HUD.dim).lineSpacing(3)
            Button("Open Automation settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
            }
            .buttonStyle(HUDButtonStyle(kind: .ghost, compact: true))
        }
    }
}

struct TasksView: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var editing: WorkItem?
    @State private var deleting: WorkItem?
    var filtered: [WorkItem] { model.tasks.filter { query.isEmpty || ($0.title + " " + $0.project + " " + $0.notes).localizedCaseInsensitiveContains(query) } }
    var body: some View {
        HUDPage(kicker: "TASK LOG / \(model.tasks.filter { $0.status != "done" }.count) OPEN", title: "Tasks") {
            HStack(spacing: 10) {
                TextField("Search tasks, projects and notes", text: $query).hudField()
                Button { editing = WorkItem(title: "") } label: { Label("Add task", systemImage: "plus") }
                    .buttonStyle(HUDButtonStyle(kind: .primary, compact: true))
            }
            if filtered.isEmpty {
                Text(model.tasks.isEmpty ? "No tasks yet." : "No matches.").font(.system(size: 12)).foregroundStyle(HUD.dim).padding(.vertical, 6)
            }
            ForEach(filtered) { item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: item.status == "done" ? "checkmark.circle.fill" : item.status == "in_progress" ? "circle.lefthalf.filled" : "circle")
                            .foregroundStyle(item.status == "done" ? HUD.dim : HUD.accent)
                        Text(item.title).font(.system(size: 14, weight: .medium)).foregroundStyle(item.status == "done" ? HUD.steel : HUD.ice)
                        Spacer()
                        Button("Edit") { editing = item }.buttonStyle(HUDButtonStyle(kind: .ghost, compact: true))
                        Button("Delete") { deleting = item }.buttonStyle(HUDButtonStyle(kind: .danger, compact: true))
                    }
                    HStack(spacing: 6) {
                        Text((item.project.isEmpty ? "Unsorted" : item.project).uppercased())
                        Text("·")
                        Text(item.status.replacingOccurrences(of: "_", with: " ").uppercased())
                        if !item.due.isEmpty { Text("· DUE " + item.due) }
                    }
                    .font(HUD.label(9)).tracking(1.1).foregroundStyle(HUD.accent.opacity(0.8))
                    if !item.notes.isEmpty {
                        Text(item.notes).lineLimit(6).font(.system(size: 12.5)).foregroundStyle(HUD.steel).textSelection(.enabled)
                    }
                }
                .padding(.vertical, 12)
                .overlay(alignment: .top) { Rectangle().fill(HUD.line.opacity(0.09)).frame(height: 1) }
            }
            if let notice = model.notice { Text(notice).font(.system(size: 11)).foregroundStyle(HUD.amber) }
        }
        .sheet(item: $editing) { item in TaskEditor(model: model, item: item) }
        .confirmationDialog("Delete this task?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete task", role: .destructive) { if let item = deleting { model.deleteTask(item) }; deleting = nil }
        }
    }
}

private struct TaskEditor: View {
    @ObservedObject var model: AppModel
    @State var item: WorkItem
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(item.revision == 0 ? "New task" : "Edit task").font(.system(size: 17, weight: .semibold)).foregroundStyle(HUD.ice)
            TextField("Title", text: $item.title).hudField()
            TextField("Project, e.g. College essays", text: $item.project).hudField()
            TextField("Due date, YYYY-MM-DD (optional)", text: $item.due).hudField()
            Picker("Status", selection: $item.status) {
                Text("Planned").tag("planned"); Text("In progress").tag("in_progress"); Text("Done").tag("done")
            }
            .pickerStyle(.segmented)
            Text("NOTES").font(HUD.label(9)).tracking(1.4).foregroundStyle(HUD.dim)
            TextEditor(text: $item.notes).font(.system(size: 13)).scrollContentBackground(.hidden).padding(6)
                .frame(height: 170).background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.28)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(HUD.line.opacity(0.2), lineWidth: 1))
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(HUDButtonStyle(kind: .ghost))
                Spacer()
                Button("Save task") { Task { if await model.saveTask(item) { dismiss() } } }
                    .buttonStyle(HUDButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
            }
            if let notice = model.notice { Text(notice).font(.system(size: 11)).foregroundStyle(HUD.amber) }
        }
        .padding(24).frame(width: 510)
        .background(HUD.deep)
    }
}

/// Shown while the agent can't answer: what's wrong, the one command that fixes it, and a retry.
struct SetupPanel: View {
    @ObservedObject var model: AppModel
    @State private var copied = false
    var body: some View {
        let offline: String? = { if case .offline(let reason) = model.agentLink { return reason }; return nil }()
        let issue: AgentSetupIssue? = { if case .needsSetup(let issue) = model.agentLink { return issue }; return nil }()
        let tint = offline == nil ? HUD.amber : HUD.crimson
        let firstRun = model.usesHermes && model.config.hermesConnected != true
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: offline == nil ? "key.horizontal.fill" : "bolt.horizontal.circle.fill").foregroundStyle(tint)
                Text(issue?.title ?? "Daisy can't reach its agent").font(.system(size: 15, weight: .semibold)).foregroundStyle(HUD.ice)
            }
            Text(issue?.detail ?? offline ?? "").font(.system(size: 12.5)).foregroundStyle(HUD.steel).fixedSize(horizontal: false, vertical: true)
            if let command = issue?.command {
                HStack(spacing: 10) {
                    Text(command).font(HUD.readout(12)).foregroundStyle(HUD.ice).textSelection(.enabled).lineLimit(2)
                    Spacer(minLength: 6)
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string); copied = true
                    }
                    .buttonStyle(HUDButtonStyle(kind: .ghost, compact: true))
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.35)))
            }
            HStack(spacing: 10) {
                if issue?.command != nil {
                    Button("Open Terminal") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")) }
                        .buttonStyle(HUDButtonStyle(kind: .ghost, compact: true))
                }
                Button(firstRun ? "Connect" : "Retry") { model.startAgent() }
                    .buttonStyle(HUDButtonStyle(kind: .primary, compact: true)).disabled(model.connecting)
                if model.connecting { ProgressView().controlSize(.small) }
            }
        }
        .padding(18)
        .frame(maxWidth: 540, alignment: .leading)
        .hudPanel(radius: 14, tint: tint)
    }
}

