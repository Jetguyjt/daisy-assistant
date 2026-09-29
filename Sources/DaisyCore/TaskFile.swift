import CryptoKit
import Foundation

/// tasks.json on disk, shared by the app and Hermes's tasks tools (hermes/daisy/tools/tasks.py). Both
/// take an exclusive flock on tasks.json.lock, read the file again inside it, and swap the new list in
/// with a rename, 0600. Files are a plain JSON list of tasks.
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

    /// The tasks in the file. Missing or empty is no tasks; a file that isn't a list of tasks throws, so
    /// nothing ever writes over it.
    public static func read(_ url: URL) throws -> [WorkItem] {
        let data: Data
        do { data = try Data(contentsOf: url) } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        if data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) { return [] }
        let decoder = JSONDecoder()
        if let items = try? decoder.decode([Lenient].self, from: data) { return items.compactMap(\.item) }
        if let wrapped = try? decoder.decode(Wrapped.self, from: data) { return wrapped.tasks.compactMap(\.item) }
        throw DaisyError.message("Daisy couldn't read its task list (\(url.lastPathComponent) isn't a list of tasks). It's been left as it is; fix or move it and open Daisy again.")
    }

    public static func encode(_ items: [WorkItem]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(items) + Data("\n".utf8)
    }

    /// Writes the whole list: a new file next to it, flushed, then renamed over it.
    public static func write(_ items: [WorkItem], to url: URL) throws {
        let data = try encode(items)
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

    /// A stable id for a task whose id isn't a UUID (a hand-edited file): the same one the plugin makes.
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
    private struct Wrapped: Decodable { let tasks: [Lenient] }

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
