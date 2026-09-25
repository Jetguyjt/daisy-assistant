import Foundation

public struct WorkItem: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var project: String
    public var due: String
    public var status: String
    public var notes: String
    public var revision: Int
    public var updatedAt: Date
    public init(id: UUID = UUID(), title: String, project: String = "", due: String = "", status: String = "planned", notes: String = "", revision: Int = 0) {
        self.id = id; self.title = title; self.project = project; self.due = due; self.status = status
        self.notes = notes; self.revision = revision; updatedAt = Date()
    }
    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 180,
              project.count <= 100, notes.count <= 8000, ["planned", "in_progress", "done"].contains(status) else {
            throw JarvisError.message("Use a title up to 180 characters, project up to 100, notes up to 8,000, and a valid task status.")
        }
        if !due.isEmpty {
            let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyy-MM-dd"; format.isLenient = false
            guard due.count == 10, let date = format.date(from: due), format.string(from: date) == due else {
                throw JarvisError.message("Use a real due date in YYYY-MM-DD form, or leave it blank.")
            }
        }
    }
    public var preview: String {
        "\(title)\nProject: \(project.isEmpty ? "Unsorted" : project)\nDue: \(due.isEmpty ? "No date" : due)\nStatus: \(status)\n\n\(notes)"
    }
    var json: JSONValue { .object(["id": .string(id.uuidString), "title": .string(title), "project": .string(project), "due": .string(due),
        "status": .string(status), "notes": .string(String(notes.prefix(1200))), "notes_truncated": .bool(notes.count > 1200), "revision": .number(Double(revision))]) }
}

/// Atomic local persistence with optimistic revisions so old review cards cannot overwrite edits.
public actor TaskStore {
    private let url: URL
    private var items: [WorkItem]
    public init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            items = try JSONDecoder().decode([WorkItem].self, from: Data(contentsOf: url))
            for item in items { try item.validate() }
        } else { items = [] }
    }
    public func all() -> [WorkItem] {
        items.sorted {
            if ($0.status == "done") != ($1.status == "done") { return $1.status == "done" }
            if $0.due != $1.due { return ($0.due.isEmpty ? "9999" : $0.due) < ($1.due.isEmpty ? "9999" : $1.due) }
            return $0.updatedAt > $1.updatedAt
        }
    }
    public func item(_ id: UUID) -> WorkItem? { items.first { $0.id == id } }
    @discardableResult public func save(_ item: WorkItem, expectedRevision: Int) throws -> WorkItem {
        try Task.checkCancellation(); try item.validate()
        let index = items.firstIndex { $0.id == item.id }
        guard (index.map { items[$0].revision } ?? 0) == expectedRevision else {
            throw JarvisError.message("This task changed after the draft was prepared. Review its latest version and try again.")
        }
        guard index != nil || expectedRevision == 0, items.count < 10_000 || index != nil else { throw JarvisError.message("Task limit reached or task no longer exists.") }
        var updated = item; updated.revision = expectedRevision + 1; updated.updatedAt = Date()
        var next = items
        if let index { next[index] = updated } else { next.append(updated) }
        try persist(next); items = next
        return updated
    }
    public func delete(_ item: WorkItem) throws {
        try Task.checkCancellation()
        guard let existing = items.first(where: { $0.id == item.id }), existing.revision == item.revision else { throw JarvisError.message("This task changed. Reload it before deleting.") }
        let next = items.filter { $0.id != item.id }; try persist(next); items = next
    }
    private func persist(_ next: [WorkItem]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(next).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public struct TaskCapabilityProvider: CapabilityProvider {
    public let store: TaskStore
    public init(store: TaskStore) { self.store = store }
    public func capabilities() -> [Capability] { [
        Capability(.init(name: "list_tasks", title: "Track tasks and projects", provider: "Local workspace",
            description: "Read saved homework, essay, coding and other tasks. Optional query matches title/project/notes. Returns up to two tasks; offset pages through results. Tasks have due dates, status and editable notes.",
            parameters: .object(properties: ["query": .string(maxLength: 200), "offset": .number], required: []))) { args in
                let query = args["query"]?.stringValue ?? ""
                let all = await store.all().filter { query.isEmpty || ($0.title + " " + $0.project + " " + $0.notes).localizedCaseInsensitiveContains(query) }
                var offset = 0
                if case .number(let value) = args["offset"] {
                    guard value >= 0, value <= 10_000, value.rounded() == value else { throw JarvisError.message("Invalid task offset.") }; offset = Int(value)
                }
                let slice = Array(all.dropFirst(offset).prefix(2))
                return .init(summary: "Found \(all.count) saved tasks matching this request.", data: .object([
                    "tasks": .array(slice.map(\.json)), "next_offset": offset + slice.count < all.count ? .number(Double(offset + slice.count)) : .null]))
            },
        Capability(.init(name: "prepare_task", title: "Prepare task updates", provider: "Local workspace",
            description: "Prepare a local task for user review. Supply title/project/due YYYY-MM-DD/status/notes. For updates, first list_tasks and supply id; omitted fields retain their full current values. Nothing saves until user clicks Apply in the review card. Do not invent deadlines.",
            parameters: .object(properties: ["id": .string(maxLength: 36), "title": .string(maxLength: 180), "project": .string(maxLength: 100), "due": .string(maxLength: 10),
                "status": .choice(["planned", "in_progress", "done"]), "notes": .string(maxLength: 8000)], required: []), effect: .preparesChanges)) { args in
                var item: WorkItem
                if let raw = args["id"]?.stringValue {
                    guard let id = UUID(uuidString: raw), let found = await store.item(id) else { throw JarvisError.message("That task does not exist. Find it with list_tasks first.") }
                    item = found
                } else { item = WorkItem(title: args["title"]?.stringValue ?? "") }
                if let value = args["title"]?.stringValue { item.title = value }
                if let value = args["project"]?.stringValue { item.project = value }
                if let value = args["due"]?.stringValue { item.due = value }
                if let value = args["status"]?.stringValue { item.status = value }
                if let value = args["notes"]?.stringValue { item.notes = value }
                try item.validate()
                let draft = item
                return .init(summary: "Prepared a task review card. Nothing has been saved yet.", data: .object(["title": .string(draft.title), "saved": .bool(false)]),
                    review: ReviewedAction(title: draft.revision == 0 ? "Create task" : "Update task", preview: draft.preview) {
                        let saved = try await store.save(draft, expectedRevision: draft.revision)
                        return "Saved task: \(saved.title) · revision \(saved.revision)"
                    })
            }
    ] }
}
