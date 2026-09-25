import SwiftUI
import JarvisCore

struct ReviewCard: View {
    @ObservedObject var model: AppModel
    let review: ReviewedAction
    @State private var expanded = true
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(review.title, systemImage: "doc.text.magnifyingglass").font(.headline)
            DisclosureGroup("Review exact contents", isExpanded: $expanded) {
                ScrollView { Text(review.preview).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 240).padding(.top, 8)
            }
            if let status = model.reviewStatus(review) { Text(status).font(.caption).foregroundStyle(accent).textSelection(.enabled) }
            else {
                Text("Prepared only. Apply saves this exact change on your Mac.").font(.caption).foregroundStyle(muted)
                HStack {
                    Button(model.applyingReviews.contains(review.id) ? "Applying…" : "Apply") { model.applyReview(review) }
                        .disabled(model.busy || model.applyingReviews.contains(review.id)).buttonStyle(.borderedProminent)
                    Button("Discard") { model.discardReview(review) }.disabled(model.applyingReviews.contains(review.id))
                }
            }
        }.padding(16).background(surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(0.3)))
    }
}
struct ConnectionsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("One browser. Many possibilities.").font(.system(size: 27, weight: .light))
                Text("Use your Chrome session for research and supported signed-in pages, including Gmail and Google Drive. The assistant runs locally; browsing and searches still contact the websites you use.")
                    .foregroundStyle(muted).lineSpacing(5)
                VStack(alignment: .leading, spacing: 16) {
                    Label("Google Chrome", systemImage: "globe").font(.title3)
                    Text(model.chromeConnected ? "Connected for this app session" : "Not connected").foregroundStyle(model.chromeConnected ? accent : .orange)
                    Text("1. Open Chrome connection settings below.\n2. Enable remote debugging in Chrome.\n3. Click Connect here, then allow Chrome’s connection prompt.").lineSpacing(7)
                    HStack {
                        Button("Open Chrome connection settings") { model.openChromeSetup() }
                        if model.chromeConnected || model.chromeConnecting {
                            Button(model.chromeConnecting ? "Cancel connection" : "Disconnect") { model.disconnectChrome() }
                        } else { Button("Connect Chrome") { model.connectChrome() }.buttonStyle(.borderedProminent) }
                    }
                    Text("This grants the local Chrome DevTools connection access to your browser session. Jarvis exposes finding tabs, reading page text and opening new tabs. It does not expose JavaScript execution, form input, network inspection or sending. Disconnect here when finished.")
                        .font(.caption).foregroundStyle(muted).lineSpacing(4)
                    Text("Some sites and Google Docs canvases do not expose their full text. Jarvis must report that limitation instead of guessing. Full Drive/Gmail APIs and document editing are not connected.")
                        .font(.caption).foregroundStyle(muted)
                    if let status = model.connectionNotice { Text(status).font(.callout).foregroundStyle(accent).textSelection(.enabled) }
                }.padding(22).background(surface, in: RoundedRectangle(cornerRadius: 12))
                Text("Try after connecting: “Research this topic and cite sources”, “Summarize my open Gmail tab”, or “Find my Drive tab and tell me what files are visible.”")
                    .font(.callout).foregroundStyle(muted)
                Text("Connections do not reconnect automatically after quitting Jarvis.").font(.caption).foregroundStyle(muted)
            }.padding(32).frame(maxWidth: 800, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct TasksView: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var editing: WorkItem?
    @State private var deleting: WorkItem?
    var filtered: [WorkItem] { model.tasks.filter { query.isEmpty || ($0.title + " " + $0.project + " " + $0.notes).localizedCaseInsensitiveContains(query) } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Keep your work in view.").font(.system(size: 27, weight: .light))
                    Spacer(); Button("Add task", systemImage: "plus") { editing = WorkItem(title: "") }
                }
                Text("Track homework, college essays, coding and anything else. Group work by project, keep links and next steps in notes, and set your own dates. These are local tasks; reminders are not scheduled.")
                    .foregroundStyle(muted).font(.callout).lineSpacing(4)
                TextField("Search tasks, projects and notes", text: $query).textFieldStyle(.roundedBorder)
                if filtered.isEmpty { ContentUnavailableView("Nothing here yet", systemImage: "checklist", description: Text("Add a task, or ask Jarvis to prepare one in the conversation.")) }
                ForEach(filtered) { item in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: item.status == "done" ? "checkmark.circle.fill" : item.status == "in_progress" ? "circle.lefthalf.filled" : "circle").foregroundStyle(accent)
                            Text(item.title).font(.headline); Spacer()
                            Button("Edit") { editing = item }
                            Button("Delete", role: .destructive) { deleting = item }
                        }
                        HStack { Text(item.project.isEmpty ? "Unsorted" : item.project); Text("·"); Text(item.status.replacingOccurrences(of: "_", with: " ")); if !item.due.isEmpty { Text("· Due " + item.due) } }.font(.caption).foregroundStyle(accent)
                        if !item.notes.isEmpty { Text(item.notes).lineLimit(6).font(.callout).textSelection(.enabled) }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(surface, in: RoundedRectangle(cornerRadius: 10))
                }
                if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
            }.padding(32)
        }.sheet(item: $editing) { item in TaskEditor(model: model, item: item) }
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
        VStack(alignment: .leading, spacing: 15) {
            Text(item.revision == 0 ? "New task" : "Edit task").font(.title2)
            TextField("Title", text: $item.title)
            TextField("Project, e.g. College essays", text: $item.project)
            TextField("Due date · YYYY-MM-DD · optional", text: $item.due)
            Picker("Status", selection: $item.status) { Text("Planned").tag("planned"); Text("In progress").tag("in_progress"); Text("Done").tag("done") }
            Text("Notes, links and next steps").font(.caption).foregroundStyle(muted)
            TextEditor(text: $item.notes).frame(height: 180)
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Save task") { Task { if await model.saveTask(item) { dismiss() } } }.keyboardShortcut(.defaultAction) }
            if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
        }.textFieldStyle(.roundedBorder).padding(25).frame(width: 510)
    }
}
