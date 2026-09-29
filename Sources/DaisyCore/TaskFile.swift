import CryptoKit
import Foundation

/// What tasks.json holds: the tasks, and the projects they sit in.
public struct TaskDocument: Sendable, Equatable {
    public var tasks: [WorkItem]
    /// The saved projects, then one for each name a task uses that has no project yet.
    public var projects: [Project]
    /// The projects only there because a task names them. One that's saved stops being one; one no task
    /// names anymore isn't written.
    var namedOnly: Set<UUID> = []

    public init(tasks: [WorkItem] = [], projects: [Project] = []) {
        self.tasks = tasks; self.projects = projects
        addNamedProjects()
    }

    /// The project with this name, in any case.
    public func project(named name: String) -> Project? {
        let key = Project.key(name)
        return key.isEmpty ? nil : projects.first { $0.key == key }
    }
    public func tasks(in project: Project) -> [WorkItem] { tasks.filter { Project.key($0.project) == project.key } }

    /// Gives every name a task uses a project, in the order the tasks come, and drops the ones that were
    /// only there for a name no task uses now.
    public mutating func addNamedProjects() {
        let used = Set(tasks.map { Project.key($0.project) })
        projects.removeAll { namedOnly.contains($0.id) && !used.contains($0.key) }
        var known = Set(projects.map(\.key))
        for task in tasks {
            let key = Project.key(task.project)
            guard !key.isEmpty, !known.contains(key) else { continue }
            known.insert(key)
            let project = Project.named(task.project)
            projects.append(project)
            namedOnly.insert(project.id)
        }
    }

    /// Adds or replaces a project; from then on it's saved whether or not a task names it.
    mutating func put(_ project: Project) {
        namedOnly.remove(project.id)
        if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = project } else { projects.append(project) }
    }

    /// Moves every task in the project called `key` to `name` ("" for no project), bumping each one's revision.
    mutating func renameTasks(from key: String, to name: String) {
        let now = Date()
        for index in tasks.indices where Project.key(tasks[index].project) == key {
            tasks[index].project = name; tasks[index].revision += 1; tasks[index].updatedAt = now
        }
    }
}

/// tasks.json on disk, shared by the app and Hermes's tasks tools (hermes/daisy/tools/tasks.py). Both
/// take an exclusive flock on tasks.json.lock, read the file again inside it, and swap the new file in
/// with a rename, 0600.
///
/// The file is `{"version": 2, "projects": [...], "tasks": [...]}`. Older files are a plain list of tasks
/// (or `{"tasks": [...]}`); they read the same, their project names become projects, and they're
/// written in the new form the next time something changes.
public enum TaskFile {
    public static let lockWait: TimeInterval = 2

    public struct Stamp: Equatable, Sendable {
        let seconds: Int, nanoseconds: Int, size: Int64, inode: UInt64
    }

    /// Changes whenever the file is replaced or rewritten; nil when there's no file.
    public static func stamp(_ url: URL) -> Stamp? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return Stamp(seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec, size: Int64(info.st_size),
                     inode: UInt64(info.st_ino))
    }

    /// The tasks in the file.
    public static func read(_ url: URL) throws -> [WorkItem] { try readDocument(url).tasks }

    /// The tasks and projects in the file. Missing or empty is nothing yet; a file that isn't a task list
    /// throws, so nothing ever writes over it.
    public static func readDocument(_ url: URL) throws -> TaskDocument {
        let data: Data
        do { data = try Data(contentsOf: url) } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return TaskDocument()
        }
        if data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) { return TaskDocument() }
        let decoder = JSONDecoder()
        if let items = try? decoder.decode([Lenient].self, from: data) { return TaskDocument(tasks: items.compactMap(\.item)) }
        if let wrapped = try? decoder.decode(Wrapped.self, from: data) {
            return TaskDocument(tasks: wrapped.tasks.compactMap(\.item), projects: (wrapped.projects ?? []).compactMap(\.project))
        }
        throw DaisyError.message("Daisy couldn't read its task list (\(url.lastPathComponent) isn't a list of tasks). It's been left as it is; fix or move it and open Daisy again.")
    }

    public static func encode(_ document: TaskDocument) throws -> Data {
        try encoder().encode(Stored(projects: document.projects, tasks: document.tasks)) + Data("\n".utf8)
    }
    /// The tasks alone, as a list: each task's stored form.
    public static func encode(_ items: [WorkItem]) throws -> Data { try encoder().encode(items) + Data("\n".utf8) }
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Writes tasks with the projects their names make.
    public static func write(_ items: [WorkItem], to url: URL) throws { try write(TaskDocument(tasks: items), to: url) }

    /// Writes the whole file: a new file next to it, flushed, then renamed over it. Every name a task
    /// uses gets its project written too.
    public static func write(_ document: TaskDocument, to url: URL) throws {
        var document = document
        document.addNamedProjects()
        let data = try encode(document)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw DaisyError.message("Couldn't save the task list (\(String(cString: strerror(errno)))).") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temporary.path, url.path) == 0 else {
                throw DaisyError.message("Couldn't save the task list (\(String(cString: strerror(errno)))).")
            }
        } catch {
            unlink(temporary.path)
            throw error
        }
    }

    /// Runs `body` holding the exclusive lock on tasks.json.lock, the one the plugin takes too.
    public static func withLock<T>(_ url: URL, wait: TimeInterval = lockWait, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = open(url.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw DaisyError.message("Couldn't open the task list's lock (\(String(cString: strerror(errno)))).") }
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(wait)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else {
                throw DaisyError.message("The task list is busy (Daisy is saving it). Try again in a moment.")
            }
            usleep(20_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    /// Fires when tasks.json changes: right away when something renames a new file into its folder, and
    /// within `poll` seconds for anything else. Ends when the consumer stops listening.
    public static func changes(of url: URL, poll: TimeInterval = 2) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let watcher = Watcher(url: url, poll: poll) { continuation.yield() }
            continuation.onTermination = { _ in watcher.stop() }
        }
    }

    /// A stable id for a task, project or link whose id isn't a UUID (a hand-edited file): the same one the
    /// plugin makes.
    public static func stableID(_ text: String) -> UUID {
        if let id = UUID(uuidString: text), text.count == 36 { return id }
        var bytes = Array(SHA256.hash(data: Data(("daisy-task:" + text).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private struct Lenient: Decodable {
        let item: WorkItem?
        init(from decoder: Decoder) throws { item = try? WorkItem(from: decoder) }
    }
    private struct LenientProject: Decodable {
        let project: Project?
        init(from decoder: Decoder) throws { project = try? Project(from: decoder) }
    }
    /// A `projects` that's there but isn't a list fails the read, so the file is left alone.
    private struct Wrapped: Decodable { let tasks: [Lenient]; let projects: [LenientProject]? }
    private struct Stored: Encodable {
        let projects: [Project], tasks: [WorkItem]
        enum Keys: String, CodingKey { case version, projects, tasks }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(2, forKey: .version); try c.encode(projects, forKey: .projects); try c.encode(tasks, forKey: .tasks)
        }
    }

    private final class Watcher: @unchecked Sendable {
        private let queue = DispatchQueue(label: "daisy.tasks.watch")
        private var sources: [DispatchSourceProtocol] = []
        private var last: Stamp?

        init(url: URL, poll: TimeInterval, changed: @escaping @Sendable () -> Void) {
            last = TaskFile.stamp(url)
            let check: @Sendable () -> Void = { [weak self] in
                guard let self else { return }
                let now = TaskFile.stamp(url)
                if now != self.last { self.last = now; changed() }
            }
            queue.sync {
                let folder = open(url.deletingLastPathComponent().path, O_EVTONLY)
                if folder >= 0 {
                    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: folder, eventMask: [.write, .rename, .delete], queue: queue)
                    source.setEventHandler(handler: check)
                    source.setCancelHandler { close(folder) }
                    source.resume()
                    sources.append(source)
                }
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + poll, repeating: poll, leeway: .milliseconds(250))
                timer.setEventHandler(handler: check)
                timer.resume()
                sources.append(timer)
            }
        }

        func stop() { queue.async { self.sources.forEach { $0.cancel() }; self.sources = [] } }
    }
}
