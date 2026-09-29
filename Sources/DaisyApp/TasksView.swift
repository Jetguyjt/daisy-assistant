import SwiftUI
import DaisyCore

/// The task list: projects, their tasks and subtasks, each with a status chip that changes in one click.
/// Hermes's tasks tools write the same tasks.json, so the list reloads whenever the file changes.
struct TasksView: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var filter: TaskFilter = .open
    @State private var editing: WorkItem?
    @State private var deleting: WorkItem?
    /// Collapsed projects ("p:name") and tasks ("t:id"), kept between launches.
    @AppStorage("tasksCollapsed") private var collapsedKeys = ""

    var body: some View {
        let counts = TaskCounts(model.tasks)
        let groups = TaskTree.groups(model.tasks, filter: filter, query: query)
        // Searching or picking one status opens everything, so nothing that matches hides in a fold.
        let folding = query.trimmingCharacters(in: .whitespaces).isEmpty && filter == .open
        let collapsed = folding ? Set(collapsedKeys.split(separator: ",").map(String.init)) : []
        HUDPage(kicker: "TASK LOG / " + counts.summary.uppercased(), title: "Tasks") {
            HStack(spacing: 10) {
                TextField("Search tasks, projects and notes", text: $query).hudField()
                Button { editing = WorkItem(title: "") } label: { Label("Add task", systemImage: "plus") }
                    .buttonStyle(HUDButtonStyle(kind: .primary, compact: true))
            }
            TaskFilterBar(filter: $filter, counts: counts)
            if groups.isEmpty { emptyState(counts) }
            ForEach(groups) { group in
                let key = "p:" + group.id
                VStack(alignment: .leading, spacing: 0) {
                    TaskGroupHeader(group: group, collapsed: collapsed.contains(key), canFold: folding) { toggle(key) }
                    if !collapsed.contains(key) {
                        ForEach(Self.rows(group, collapsed: collapsed)) { row in
                            TaskRow(row: row, setStatus: setStatus, edit: { editing = $0 },
                                    addSubtask: { editing = WorkItem(title: "", project: $0.project, parent: $0.id) },
                                    delete: { deleting = $0 }, toggle: { toggle("t:" + row.id.uuidString) })
                        }
                    }
                }
                .padding(.top, 4)
            }
            if let notice = model.notice { Text(notice).font(.system(size: 11)).foregroundStyle(HUD.amber).textSelection(.enabled) }
        }
        .task { await watch() }
        .sheet(item: $editing) { item in TaskEditor(model: model, item: item) }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button(deleteButton, role: .destructive) { if let item = deleting { model.deleteTask(item) }; deleting = nil }
        } message: {
            Text(deleteMessage)
        }
    }

    /// Reloads when Daisy (through Hermes) or anything else changes tasks.json, for as long as the tab is open.
    private func watch() async {
        await model.reloadTasks()
        for await _ in TaskFile.changes(of: TaskStore.defaultURL) { await model.reloadTasks() }
    }

    private func setStatus(_ item: WorkItem, _ status: TaskStatus) {
        var changed = item
        changed.status = status
        Task { if !(await model.saveTask(changed)) { await model.reloadTasks() } }
    }

    private func toggle(_ key: String) {
        var keys = Set(collapsedKeys.split(separator: ",").map(String.init))
        if keys.remove(key) == nil { keys.insert(key) }
        collapsedKeys = keys.sorted().joined(separator: ",")
    }

    /// The group's tasks top to bottom, subtasks under their parent, skipping what's folded away.
    static func rows(_ group: TaskGroup, collapsed: Set<String>) -> [TaskRowModel] {
        var rows: [TaskRowModel] = []
        func walk(_ node: TaskNode, _ depth: Int) {
            let folded = collapsed.contains("t:" + node.id.uuidString)
            rows.append(TaskRowModel(node: node, depth: depth, collapsed: folded))
            if !folded { node.children.forEach { walk($0, depth + 1) } }
        }
        group.nodes.forEach { walk($0, 0) }
        return rows
    }

    @ViewBuilder private func emptyState(_ counts: TaskCounts) -> some View {
        if counts.total == 0 {
            Text("No tasks yet. Add one here, or ask Daisy: “add my college essays to my tasks.”")
                .font(.system(size: 12)).foregroundStyle(HUD.dim).padding(.vertical, 6)
        } else {
            HStack(spacing: 10) {
                Text(query.isEmpty ? "Nothing in \(filter.title.lowercased())." : "No matches in \(filter.title.lowercased()).")
                    .font(.system(size: 12)).foregroundStyle(HUD.dim)
                if filter != .all {
                    Button("Show everything") { filter = .all }.buttonStyle(HUDButtonStyle(kind: .ghost, compact: true))
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var deletingSubtasks: Int { deleting.map { TaskTree.descendants(of: $0.id, in: model.tasks).count } ?? 0 }
    private var deleteTitle: String { "Delete “\(deleting?.title ?? "")”?" }
    private var deleteButton: String { deletingSubtasks == 0 ? "Delete task" : "Delete \(deletingSubtasks + 1) tasks" }
    private var deleteMessage: String {
        deletingSubtasks == 0 ? "This can't be undone."
            : "Its \(deletingSubtasks) subtask\(deletingSubtasks == 1 ? "" : "s") go\(deletingSubtasks == 1 ? "es" : "") too. This can't be undone."
    }
}

struct TaskRowModel: Identifiable {
    let node: TaskNode
    let depth: Int
    let collapsed: Bool
    var id: UUID { node.id }
}

extension TaskStatus {
    /// The chip color in the current theme. Reading it in a view's body redraws the view when the accent changes.
    var color: Color { Color(tint(in: ThemeStore.shared.palette)) }
}

extension TaskFilter {
    var color: Color {
        switch self {
        case .open: HUD.accent
        case .status(let status): status.color
        case .finished: TaskStatus.done.color
        case .all: HUD.steel
        }
    }
}

/// All open, each status that has tasks, Finished, Everything; with counts.
private struct TaskFilterBar: View {
    @Binding var filter: TaskFilter
    let counts: TaskCounts
    private struct Option: Identifiable { let filter: TaskFilter; let count: Int; var id: TaskFilter { filter } }
    var body: some View {
        let statuses = TaskStatus.allCases.filter { counts[$0] > 0 || filter == .status($0) }.map { Option(filter: .status($0), count: counts[$0]) }
        let options = [Option(filter: .open, count: counts.open)] + statuses
            + [Option(filter: .finished, count: counts.finished), Option(filter: .all, count: counts.total)]
        TaskFlow(spacing: 6) {
            ForEach(options) { option in
                FilterChip(title: option.filter.title, count: option.count, color: option.filter.color, selected: filter == option.filter) {
                    filter = option.filter
                }
            }
        }
    }
}

private struct FilterChip: View {
    let title: String
    let count: Int
    let color: Color
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title.uppercased()).tracking(1.1)
                Text("\(count)").foregroundStyle(selected ? color : HUD.dim).monospacedDigit()
            }
            .font(HUD.label(9))
            .foregroundStyle(selected ? color : HUD.steel)
            .padding(.horizontal, 9).frame(height: 24)
            .background(Rectangle().fill(color.opacity(selected ? 0.14 : (hovering ? 0.07 : 0.02))))
            .overlay(Rectangle().strokeBorder(color.opacity(selected ? 0.6 : (hovering ? 0.35 : 0.15)), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct TaskGroupHeader: View {
    let group: TaskGroup
    let collapsed: Bool
    let canFold: Bool
    let toggle: () -> Void
    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90)).foregroundStyle(HUD.dim).opacity(canFold ? 1 : 0.3)
                Text((group.project.isEmpty ? "No project" : group.project).uppercased())
                    .font(HUD.label(10)).tracking(1.6).foregroundStyle(HUD.accent)
                Rectangle().fill(HUD.line.opacity(0.12)).frame(height: 1)
                Text("\(group.open) OPEN").font(HUD.label(9)).tracking(1.2).foregroundStyle(HUD.dim).monospacedDigit()
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canFold)
        .animation(.easeOut(duration: 0.15), value: collapsed)
    }
}

private struct TaskRow: View {
    let row: TaskRowModel
    let setStatus: (WorkItem, TaskStatus) -> Void
    let edit: (WorkItem) -> Void
    let addSubtask: (WorkItem) -> Void
    let delete: (WorkItem) -> Void
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        let item = row.node.item
        HStack(alignment: .center, spacing: 10) {
            fold.frame(width: 12)
            StatusMenu(status: item.status) { setStatus(item, $0) }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: row.depth == 0 ? 14 : 13, weight: row.depth == 0 ? .medium : .regular))
                    .foregroundStyle(item.status.isFinished ? HUD.steel : HUD.ice)
                    .strikethrough(item.status == .dropped, color: HUD.dim)
                    .lineLimit(2)
                if !item.notes.isEmpty {
                    Text(item.notes).font(.system(size: 11.5)).foregroundStyle(HUD.dim).lineLimit(2).textSelection(.enabled)
                }
            }
            .opacity(row.node.matches ? 1 : 0.5)
            Spacer(minLength: 8)
            if row.node.subtasks > 0 {
                Text("\(row.node.finished)/\(row.node.subtasks)")
                    .font(HUD.readout(10)).foregroundStyle(row.node.finished == row.node.subtasks ? TaskStatus.done.color : HUD.dim)
                    .monospacedDigit().help("\(row.node.finished) of \(row.node.subtasks) subtasks finished")
            }
            if let due = DueLabel(item.due, finished: item.status.isFinished) {
                Text(due.text).font(HUD.label(9)).tracking(1.1).foregroundStyle(due.color).monospacedDigit()
            }
            HStack(spacing: 2) {
                icon("plus", "Add a subtask") { addSubtask(item) }
                icon("pencil", "Edit") { edit(item) }
                icon("trash", "Delete", tint: HUD.crimson) { delete(item) }
            }
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
        }
        .padding(.vertical, 7)
        .padding(.leading, CGFloat(row.depth) * 22)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { edit(item) }
        .overlay(alignment: .top) { Rectangle().fill(HUD.line.opacity(0.07)).frame(height: 1).padding(.leading, CGFloat(row.depth) * 22) }
        .contextMenu {
            Menu("Status") {
                ForEach(TaskStatus.allCases) { status in Button(status.title) { setStatus(item, status) }.disabled(status == item.status) }
            }
            Button("Edit…") { edit(item) }
            Button("Add a subtask…") { addSubtask(item) }
            Divider()
            Button("Delete…", role: .destructive) { delete(item) }
        }
    }

    @ViewBuilder private var fold: some View {
        if row.node.subtasks > 0 {
            Button(action: toggle) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(HUD.dim)
                    .rotationEffect(.degrees(row.collapsed ? 0 : 90)).frame(width: 12, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(row.collapsed ? "Show subtasks" : "Hide subtasks")
        } else {
            Color.clear
        }
    }

    private func icon(_ symbol: String, _ label: String, tint: Color = HUD.steel, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(tint)
                .frame(width: 24, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// "DUE OCT 15", "DUE TOMORROW", "OVERDUE · OCT 1".
private struct DueLabel {
    let text: String
    let color: Color
    init?(_ due: String, finished: Bool) {
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyy-MM-dd"
        guard !due.isEmpty, let date = format.date(from: due) else { return nil }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: date)).day ?? 0
        let shown = date.formatted(.dateTime.month(.abbreviated).day()).uppercased()
        switch days {
        case _ where finished: text = "DUE \(shown)"; color = HUD.dim
        case ..<0: text = "OVERDUE · \(shown)"; color = TaskStatus.blocked.color
        case 0: text = "DUE TODAY"; color = HUD.ice
        case 1: text = "DUE TOMORROW"; color = HUD.ice
        case 2...6: text = "DUE \(date.formatted(.dateTime.weekday(.abbreviated)).uppercased())"; color = HUD.steel
        default: text = "DUE \(shown)"; color = HUD.dim
        }
    }
}

/// The chip, and one click on it opens every status with what it means.
private struct StatusMenu: View {
    let status: TaskStatus
    let choose: (TaskStatus) -> Void
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: { StatusChip(status: status) }
            .buttonStyle(.plain)
            .help("Change the status")
            .accessibilityLabel("Status: \(status.title)")
            .accessibilityHint("Opens the status list")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(TaskStatus.allCases) { option in
                        StatusOption(status: option, current: option == status) {
                            open = false
                            if option != status { choose(option) }
                        }
                        if option == .blocked {
                            Rectangle().fill(HUD.line.opacity(0.12)).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 8)
                        }
                    }
                }
                .padding(6)
                .frame(width: 280)
                .background(HUD.deep)
            }
    }
}

private struct StatusChip: View {
    let status: TaskStatus
    var body: some View {
        let color = status.color
        HStack(spacing: 6) {
            Rectangle().fill(color).frame(width: 6, height: 6)
            Text(status.title.uppercased()).font(HUD.label(8.5)).tracking(1.0).foregroundStyle(color).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(width: 112, height: 22, alignment: .leading)
        .background(Rectangle().fill(color.opacity(0.08)))
        .overlay(Rectangle().strokeBorder(color.opacity(0.32), lineWidth: 1))
        .contentShape(Rectangle())
    }
}

private struct StatusOption: View {
    let status: TaskStatus
    let current: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Rectangle().fill(status.color).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(status.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(HUD.ice)
                    Text(status.hint).font(.system(size: 10.5)).foregroundStyle(HUD.dim)
                }
                Spacer(minLength: 8)
                if current { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(HUD.accent) }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Rectangle().fill(status.color.opacity(hovering ? 0.12 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Lays chips out left to right and wraps them onto new lines.
private struct TaskFlow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }
    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }
    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if let last = rows.last, !last.indices.isEmpty, last.width + spacing + size.width > width {
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows.removeLast()
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows.append(row)
        }
        return rows
    }
}

/// Add or edit one task: title, project, status, what it sits under, due date and notes.
private struct TaskEditor: View {
    @ObservedObject var model: AppModel
    @State var item: WorkItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let projects = Array(Set(model.tasks.map { $0.project.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        VStack(alignment: .leading, spacing: 13) {
            Text(item.revision == 0 ? (item.parent == nil ? "New task" : "New subtask") : "Edit task")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(HUD.ice)
            TextField("Title", text: $item.title).hudField()
            HStack(spacing: 8) {
                TextField("Project, e.g. College Applications", text: $item.project).hudField()
                if !projects.isEmpty {
                    Menu {
                        ForEach(projects, id: \.self) { name in Button(name) { item.project = name } }
                    } label: { Image(systemName: "chevron.down") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Pick a project")
                }
            }
            HStack(alignment: .top, spacing: 14) {
                field("STATUS") {
                    Picker("Status", selection: $item.status) {
                        ForEach(TaskStatus.allCases) { status in Text(status.title).tag(status) }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 150)
                }
                field("UNDER") {
                    Picker("Under", selection: $item.parent) {
                        Text("Nothing (top level)").tag(UUID?.none)
                        ForEach(parentChoices, id: \.item.id) { choice in
                            Text(String(repeating: "    ", count: choice.depth) + choice.item.title).tag(Optional(choice.item.id))
                        }
                    }
                    .labelsHidden().pickerStyle(.menu)
                }
            }
            Text(item.status.hint).font(.system(size: 11)).foregroundStyle(HUD.dim)
            TextField("Due date, YYYY-MM-DD (optional)", text: $item.due).hudField()
            Text("NOTES").font(HUD.label(9)).tracking(1.4).foregroundStyle(HUD.dim)
            TextEditor(text: $item.notes).font(.system(size: 13)).scrollContentBackground(.hidden).padding(6)
                .frame(height: 150).background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.28)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(HUD.line.opacity(0.2), lineWidth: 1))
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(HUDButtonStyle(kind: .ghost))
                Spacer()
                Button("Save task") { save() }
                    .buttonStyle(HUDButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
            }
            if let notice = model.notice { Text(notice).font(.system(size: 11)).foregroundStyle(HUD.amber) }
        }
        .padding(24).frame(width: 540)
        .background(HUD.deep)
    }

    /// Anything but the task itself and what's under it.
    private var parentChoices: [(depth: Int, item: WorkItem)] {
        let own = Set([item.id] + TaskTree.descendants(of: item.id, in: model.tasks).map(\.id))
        return TaskTree.outline(model.tasks).filter { !own.contains($0.item.id) }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(HUD.label(9)).tracking(1.4).foregroundStyle(HUD.dim)
            content()
        }
    }

    private func save() {
        var draft = item
        draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.project = draft.project.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.due = draft.due.trimmingCharacters(in: .whitespaces)
        // A subtask with no project of its own goes in its parent's.
        if draft.project.isEmpty, let parent = draft.parent, let above = model.tasks.first(where: { $0.id == parent }) {
            draft.project = above.project
        }
        Task {
            if await model.saveTask(draft) { dismiss() } else { await model.reloadTasks() }
        }
    }
}
