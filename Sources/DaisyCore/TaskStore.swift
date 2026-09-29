import Foundation

/// One task. `parent` nests it under another task (Harvard → its essays); `order` is when it was
/// added, so a list keeps the order it was given in. `project` is its project's name; `links` are the
/// docs, events, emails and files it points at.
public struct WorkItem: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var project: String
    public var parent: UUID?
    public var due: String
    public var status: TaskStatus
    public var notes: String
    public var links: [TaskLink]
    public var revision: Int
    public var order: Int
    public var updatedAt: Date
    public init(id: UUID = UUID(), title: String, project: String = "", parent: UUID? = nil, due: String = "",
                status: TaskStatus = .todo, notes: String = "", links: [TaskLink] = [], revision: Int = 0, order: Int = 0) {
        self.id = id; self.title = title; self.project = project; self.parent = parent; self.due = due; self.status = status
        self.notes = notes; self.links = links; self.revision = revision; self.order = order; updatedAt = Date()
    }
    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 180,
              project.count <= 100, notes.count <= 8000 else {
            throw DaisyError.message("Use a title up to 180 characters, project up to 100, and notes up to 8,000.")
        }
        guard parent != id else { throw DaisyError.message("A task can't go under itself.") }
        if !due.isEmpty {
            guard Self.isDate(due) else { throw DaisyError.message("Use a real due date in YYYY-MM-DD form, or leave it blank.") }
        }
        guard links.count <= TaskLink.perItem else { throw DaisyError.message("A task can have up to \(TaskLink.perItem) links.") }
        try links.forEach { try $0.validate() }
    }
    /// A real day in YYYY-MM-DD form.
    public static func isDate(_ text: String) -> Bool {
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyy-MM-dd"; format.isLenient = false
        guard text.count == 10, let date = format.date(from: text) else { return false }
        return format.string(from: date) == text
    }
    public var preview: String { preview(under: nil) }
    public func preview(under parentTitle: String?) -> String {
        "\(title)\nProject: \(project.isEmpty ? "None" : project)" + (parentTitle.map { "\nUnder: \($0)" } ?? "")
            + "\nDue: \(due.isEmpty ? "No date" : due)\nStatus: \(status.title)"
            + links.map { "\nLink: \($0.title) (\($0.kind == .file ? $0.path : $0.webLink))" }.joined() + "\n\n\(notes)"
    }
    var json: JSONValue { .object(["id": .string(id.uuidString), "title": .string(title), "project": .string(project),
        "parent": parent.map { .string($0.uuidString) } ?? .null, "due": .string(due), "status": .string(status.rawValue),
        "status_name": .string(status.title), "notes": .string(String(notes.prefix(1200))),
        "notes_truncated": .bool(notes.count > 1200), "revision": .number(Double(revision)),
        "links": .array(links.map { .object(["kind": .string($0.kind.rawValue), "title": .string($0.title),
                                             "target": .string($0.kind == .file ? $0.path : $0.webLink)]) })]) }

    // Reading never loses a task: missing fields get defaults, old statuses ("planned") and odd ones map to
    // a real status (text with no known words is kept in the notes), and ids that aren't UUIDs get a stable
    // one, the same the plugin makes. Dates come as ISO 8601 text, or seconds since 2001 from older files.
    private enum Keys: String, CodingKey { case id, title, project, parent, due, status, notes, links, revision, order, updatedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func text(_ key: Keys) -> String { (try? c.decode(String.self, forKey: key)) ?? "" }
        func identifier(_ key: Keys) -> String {
            if let value = try? c.decode(String.self, forKey: key) { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let value = try? c.decode(Int.self, forKey: key) { return String(value) }
            return ""
        }
        title = text(.title); project = text(.project); due = text(.due)
        let key = identifier(.id), parentKey = identifier(.parent)
        id = TaskFile.stableID(key.isEmpty ? "untitled:\(title)\n\(project)" : key)
        parent = parentKey.isEmpty ? nil : TaskFile.stableID(parentKey)
        let reading = TaskStatus.read(text(.status))
        status = reading.status
        notes = text(.notes)
        if let leftover = reading.leftover { notes = notes.isEmpty ? "Status: \(leftover)" : "\(notes)\n\nStatus: \(leftover)" }
        links = TaskLink.list(c, Keys.links)
        revision = (try? c.decode(Int.self, forKey: .revision)) ?? 0
        order = (try? c.decode(Int.self, forKey: .order)) ?? 0
        updatedAt = Self.readDate(c, .updatedAt) ?? .distantPast
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id.uuidString, forKey: .id); try c.encode(title, forKey: .title); try c.encode(project, forKey: .project)
        try c.encodeIfPresent(parent?.uuidString, forKey: .parent)
        try c.encode(due, forKey: .due); try c.encode(status.rawValue, forKey: .status); try c.encode(notes, forKey: .notes)
        if !links.isEmpty { try c.encode(links, forKey: .links) }
        try c.encode(revision, forKey: .revision); try c.encode(order, forKey: .order)
        try c.encode(Self.stamp(updatedAt), forKey: .updatedAt)
    }
    /// "2026-09-28T19:04:05.123Z", rounded to the millisecond the same way every time, so saving a task
    /// again never nudges its time.
    static func stamp(_ date: Date) -> String {
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        let seconds = (milliseconds / 1000).rounded(.down)
        let whole = Date(timeIntervalSince1970: seconds).formatted(Date.ISO8601FormatStyle())
        return String(whole.dropLast()) + String(format: ".%03dZ", Int(milliseconds - seconds * 1000))
    }
    /// ISO 8601 text, or seconds since 2001 from older files.
    static func readDate<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Date? {
        if let seconds = try? c.decode(Double.self, forKey: key) { return Date(timeIntervalSinceReferenceDate: seconds) }
        guard let text = try? c.decode(String.self, forKey: key) else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text))
    }
}

/// Daisy's task list, in tasks.json. Hermes's tasks tools write the same file (hermes/daisy/tools/tasks.py),
/// so every change takes the shared lock, reads the file again, changes what it means to and writes it
/// back: nothing the plugin did in the meantime is lost. Revisions stop a stale edit (an old review card,
/// an editor opened before Daisy changed the task) from saving over a newer one.
public actor TaskStore {
    public nonisolated let url: URL
    private var document: TaskDocument
    private var stamp: TaskFile.Stamp?

    /// Where the app keeps it. The app hands this path to hermes-acp as $DAISY_TASKS_FILE.
    public static var defaultURL: URL { Configuration.dataDirectory.appendingPathComponent("tasks.json") }

    public init(url: URL) throws {
        self.url = url
        stamp = TaskFile.stamp(url)
        document = try TaskFile.readDocument(url)
    }

    /// Picks up changes another writer made. True when there were any.
    @discardableResult public func refresh() throws -> Bool {
        let now = TaskFile.stamp(url)
        guard now != stamp else { return false }
        document = try TaskFile.readDocument(url)
        stamp = now
        return true
    }

    /// Open tasks first, then by due date, then in the order they were added.
    public func all() -> [WorkItem] {
        _ = try? refresh()
        return document.tasks.sorted {
            if $0.status.isFinished != $1.status.isFinished { return $1.status.isFinished }
            if $0.due != $1.due { return ($0.due.isEmpty ? "9999" : $0.due) < ($1.due.isEmpty ? "9999" : $1.due) }
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.updatedAt > $1.updatedAt
        }
    }
    public func item(_ id: UUID) -> WorkItem? { _ = try? refresh(); return document.tasks.first { $0.id == id } }

    /// Every project: the saved ones, then any only named on a task.
    public func projects() -> [Project] { _ = try? refresh(); return document.projects }
    public func project(_ id: UUID) -> Project? { _ = try? refresh(); return document.projects.first { $0.id == id } }

    /// Saves a task. A project name that matches a project in any case takes its spelling; a new name
    /// makes a new project.
    @discardableResult public func save(_ item: WorkItem, expectedRevision: Int) throws -> WorkItem {
        try Task.checkCancellation(); try item.validate()
        let saved = try change { document in
            let index = document.tasks.firstIndex { $0.id == item.id }
            guard (index.map { document.tasks[$0].revision } ?? 0) == expectedRevision else {
                throw DaisyError.message("This task changed after the draft was prepared (Daisy may have just updated it). It's been reloaded; review it and try again.")
            }
            guard index != nil || expectedRevision == 0, document.tasks.count < 10_000 || index != nil else { throw DaisyError.message("Task limit reached or task no longer exists.") }
            if let parent = item.parent {
                guard document.tasks.contains(where: { $0.id == parent }) else { throw DaisyError.message("The task this goes under no longer exists.") }
                guard !TaskTree.descendants(of: item.id, in: document.tasks).contains(where: { $0.id == parent }) else {
                    throw DaisyError.message("A task can't go under one of its own subtasks.")
                }
            }
            var updated = item; updated.revision = expectedRevision + 1; updated.updatedAt = Date()
            updated.project = document.project(named: updated.project)?.name ?? Project.squashed(updated.project)
            if let index { document.tasks[index] = updated } else {
                if updated.order == 0 { updated.order = (document.tasks.map(\.order).max() ?? 0) + 1 }
                document.tasks.append(updated)
            }
            return updated
        }
        return document.tasks.first { $0.id == saved.id } ?? saved
    }

    /// Deletes the task and everything under it.
    public func delete(_ item: WorkItem) throws {
        try Task.checkCancellation()
        try change { document in
            guard let existing = document.tasks.first(where: { $0.id == item.id }), existing.revision == item.revision else {
                throw DaisyError.message("This task changed. Reload it before deleting.")
            }
            let gone = Set([item.id] + TaskTree.descendants(of: item.id, in: document.tasks).map(\.id))
            document.tasks.removeAll { gone.contains($0.id) }
        }
    }

    /// Adds or changes a project. A new name renames it on every task in it, in the same write.
    @discardableResult public func saveProject(_ project: Project, expectedRevision: Int) throws -> Project {
        try Task.checkCancellation()
        var project = project
        project.name = Project.squashed(project.name)
        try project.validate()
        let saved = try change { document in
            let index = document.projects.firstIndex { $0.id == project.id }
            guard (index.map { document.projects[$0].revision } ?? 0) == expectedRevision, index != nil || expectedRevision == 0 else {
                throw DaisyError.message("This project changed after you opened it (Daisy may have just updated it). It's been reloaded; try again.")
            }
            if let other = document.projects.first(where: { $0.key == project.key && $0.id != project.id }) {
                throw DaisyError.message("There's already a project called “\(other.name)”.")
            }
            if let index, document.projects[index].name != project.name {
                document.renameTasks(from: document.projects[index].key, to: project.name)
            }
            var updated = project; updated.revision = expectedRevision + 1; updated.updatedAt = Date()
            document.put(updated)
            return updated
        }
        return document.projects.first { $0.id == saved.id } ?? saved
    }

    /// Deletes a project. Its tasks stay with no project, or go too, with everything under them.
    public func deleteProject(_ project: Project, tasks: ProjectDeletion) throws {
        try Task.checkCancellation()
        try change { document in
            guard let existing = document.projects.first(where: { $0.id == project.id }), existing.revision == project.revision else {
                throw DaisyError.message("This project changed. Reload it before deleting.")
            }
            switch tasks {
            case .keepTasks:
                document.renameTasks(from: existing.key, to: "")
            case .deleteTasks:
                let members = document.tasks(in: existing)
                var gone = Set(members.map(\.id))
                for member in members { gone.formUnion(TaskTree.descendants(of: member.id, in: document.tasks).map(\.id)) }
                document.tasks.removeAll { gone.contains($0.id) }
            }
            document.projects.removeAll { $0.id == existing.id }
        }
    }

    /// Fires when the file changes, whoever changed it.
    public nonisolated func changes(poll: TimeInterval = 2) -> AsyncStream<Void> { TaskFile.changes(of: url, poll: poll) }

    /// Reads the file again under the lock, applies `edit`, and writes it back. If `edit` throws, nothing
    /// is written, but what was read is kept so the app shows the latest list. Afterwards the store holds
    /// exactly what's on disk.
    private func change<T>(_ edit: (inout TaskDocument) throws -> T) throws -> T {
        try TaskFile.withLock(url) {
            let before = TaskFile.stamp(url)
            var current = try TaskFile.readDocument(url)
            document = current; stamp = before
            let result = try edit(&current)
            try TaskFile.write(current, to: url)
            stamp = TaskFile.stamp(url)
            document = try TaskFile.readDocument(url)
            return result
        }
    }
}

public struct TaskCapabilityProvider: CapabilityProvider {
    public let store: TaskStore
    public init(store: TaskStore) { self.store = store }
    public func capabilities() -> [Capability] { [
        Capability(.init(name: "list_tasks", title: "Track tasks and projects", provider: "Local workspace",
            description: "Read saved homework, essay, coding and other tasks. Optional query matches title/project/notes. Returns up to two tasks; offset pages through results. Tasks have a status, due date, notes, and a parent id when they sit under another task.",
            parameters: .object(properties: ["query": .string(maxLength: 200), "offset": .number], required: []))) { args in
                let query = args["query"]?.stringValue ?? ""
                let all = await store.all().filter { query.isEmpty || ($0.title + " " + $0.project + " " + $0.notes).localizedCaseInsensitiveContains(query) }
                var offset = 0
                if case .number(let value) = args["offset"] {
                    guard value >= 0, value <= 10_000, value.rounded() == value else { throw DaisyError.message("Invalid task offset.") }; offset = Int(value)
                }
                let slice = Array(all.dropFirst(offset).prefix(2))
                return .init(summary: "Found \(all.count) saved tasks matching this request.", data: .object([
                    "tasks": .array(slice.map(\.json)), "next_offset": offset + slice.count < all.count ? .number(Double(offset + slice.count)) : .null]))
            },
        Capability(.init(name: "prepare_task", title: "Prepare task updates", provider: "Local workspace",
            description: "Prepare a local task for user review. Supply title/project/due YYYY-MM-DD/status/notes, and parent (another task's id) to put it under that task. For updates, first list_tasks and supply id; omitted fields retain their full current values. Nothing saves until user clicks Apply in the review card. Do not invent deadlines.",
            parameters: .object(properties: ["id": .string(maxLength: 36), "title": .string(maxLength: 180), "project": .string(maxLength: 100), "due": .string(maxLength: 10),
                "status": .choice(TaskStatus.allCases.map(\.rawValue)), "parent": .string(maxLength: 36), "notes": .string(maxLength: 8000)], required: []), effect: .preparesChanges)) { args in
                var item: WorkItem
                if let raw = args["id"]?.stringValue {
                    guard let id = UUID(uuidString: raw), let found = await store.item(id) else { throw DaisyError.message("That task does not exist. Find it with list_tasks first.") }
                    item = found
                } else { item = WorkItem(title: args["title"]?.stringValue ?? "") }
                if let value = args["title"]?.stringValue { item.title = value }
                if let value = args["project"]?.stringValue { item.project = value }
                if let value = args["due"]?.stringValue { item.due = value }
                if let value = args["status"]?.stringValue { item.status = TaskStatus.read(value).status }
                if let value = args["notes"]?.stringValue { item.notes = value }
                var under: WorkItem?
                if let raw = args["parent"]?.stringValue {
                    if raw.isEmpty { item.parent = nil } else {
                        guard let id = UUID(uuidString: raw), let found = await store.item(id) else { throw DaisyError.message("The parent task does not exist. Find it with list_tasks first.") }
                        item.parent = id; under = found
                        if args["project"] == nil, item.project.isEmpty { item.project = found.project }
                    }
                }
                try item.validate()
                let draft = item
                return .init(summary: "Prepared a task review card. Nothing has been saved yet.", data: .object(["title": .string(draft.title), "saved": .bool(false)]),
                    review: ReviewedAction(title: draft.revision == 0 ? "Create task" : "Update task", preview: draft.preview(under: under?.title)) {
                        let saved = try await store.save(draft, expectedRevision: draft.revision)
                        return "Saved task: \(saved.title) · revision \(saved.revision)"
                    })
            }
    ] }
}
