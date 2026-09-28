import Darwin
import Foundation

/// Keeps the helper processes Daisy starts (whisper-server, ollama serve, the wake word worker)
/// from outliving it. On 2026-09-25 whisper-server and ollama serve survived the app and ran for
/// two days, and the next launch reused them without owning them. Three layers:
///
/// - Normal stop: the owner still terminates its child. `launch` also drops the child's record
///   and watchdog as soon as it exits.
/// - A watchdog per child: a fixed /bin/sh script blocked reading a pipe only Daisy holds open.
///   Daisy never writes to it, so the read returns only when Daisy lets go or exits, however it
///   exits (quit, crash, force quit): the kernel closes the pipe. The watchdog then checks the pid
///   still belongs to the same process (start time) and stops its process group, TERM then KILL.
///   Foundation starts every child as its own group leader, so ollama's runners go with it.
/// - At launch, `sweep` stops leftovers: recorded children whose owner is gone (same pid, start
///   time and arguments), and orphans (parent is launchd) that exactly match what Daisy starts.
///   The second part also catches ones left by builds from before this existed.
public final class ChildProcesses: @unchecked Sendable {
    public static let shared = ChildProcesses(records: Configuration.dataDirectory.appendingPathComponent("child-processes.json"),
                                              signatures: Signature.daisy)

    /// A child as written to the records file.
    public struct Entry: Codable, Equatable, Sendable {
        public var pid: Int32
        public var label: String
        /// Arguments after the executable, as launched. Python re-executes itself, so the path can
        /// change; these don't.
        public var arguments: [String]
        /// Process start time in seconds since 1970, to the microsecond. Survives exec, unlike the name.
        public var started: Double
        public var owner: Int32
        public var ownerStarted: Double
        public init(pid: Int32, label: String, arguments: [String], started: Double, owner: Int32, ownerStarted: Double) {
            self.pid = pid; self.label = label; self.arguments = arguments; self.started = started
            self.owner = owner; self.ownerStarted = ownerStarted
        }
    }

    /// A running process as the sweep sees it.
    public struct Snapshot: Sendable {
        public let pid: Int32
        public let parent: Int32
        public let group: Int32
        public let started: Double
        public let path: String
        public let arguments: [String]
        public let environment: [String]
        public var name: String { URL(fileURLWithPath: path).lastPathComponent }
        public init(pid: Int32, parent: Int32, group: Int32, started: Double, path: String, arguments: [String], environment: [String]) {
            self.pid = pid; self.parent = parent; self.group = group; self.started = started
            self.path = path; self.arguments = arguments; self.environment = environment
        }
    }

    /// An orphan Daisy would have started. Only processes whose parent is launchd are considered.
    public struct Signature: Sendable {
        public let label: String
        public let matches: @Sendable (Snapshot) -> Bool
        public init(label: String, matches: @escaping @Sendable (Snapshot) -> Bool) { self.label = label; self.matches = matches }

        public static let daisy: [Signature] = [
            Signature(label: "whisper-server") { process in
                process.name == "whisper-server" && zip(process.arguments, process.arguments.dropFirst()).contains { $0 == "--port" && $1 == "11437" }
            },
            Signature(label: "ollama serve") { process in
                process.name == "ollama" && process.arguments.dropFirst().first == "serve"
                    && process.environment.contains("OLLAMA_HOST=127.0.0.1:11435")
            },
            Signature(label: "voice worker") { process in
                process.arguments.contains("--serve") && process.arguments.contains { argument in
                    ["/Application Support/Daisy/Runtime/voice/synthesize.py", "/Application Support/Jarvis/Runtime/voice/synthesize.py"]
                        .contains { argument.hasSuffix($0) }
                }
            },
            Signature(label: "wake word worker") { process in
                process.arguments.contains { $0.hasSuffix("/Application Support/Daisy/Runtime/speech/wakeword.py") }
            }
        ]
    }

    private let lock = NSLock()
    private let sweeping = NSLock()
    private let records: URL
    private let signatures: [Signature]
    private var watches: [Int32: (lifeline: FileHandle, watchdog: Process?)] = [:]
    private var swept = false

    public init(records: URL, signatures: [Signature]) {
        self.records = records
        self.signatures = signatures
    }

    // MARK: Launching

    /// Runs `process` (instead of `process.run()`), records it and starts its watchdog.
    public func launch(_ process: Process, label: String) throws {
        let arguments = process.arguments ?? []
        let previous = process.terminationHandler
        process.terminationHandler = { [weak self] finished in
            self?.release(finished.processIdentifier)
            previous?(finished)
        }
        try process.run()
        let pid = process.processIdentifier
        guard let started = Self.startTime(pid) else { return }
        let lifeline = Pipe()
        let watchdog = try? Self.watchdog(for: pid, lifeline: lifeline)
        try? lifeline.fileHandleForReading.close()
        lock.withLock { watches[pid] = (lifeline.fileHandleForWriting, watchdog) }
        update { $0.append(Entry(pid: pid, label: label, arguments: arguments, started: started,
                                 owner: getpid(), ownerStarted: Self.startTime(getpid()) ?? 0)) }
        // It may have exited before the watch existed; then nothing will release it.
        if !process.isRunning { release(pid) }
    }

    /// Adds a record by hand. The watchdog is only for children started through `launch`.
    public func record(_ entry: Entry) { update { $0.append(entry) } }
    public var recorded: [Entry] { update { $0 } }

    private func release(_ pid: Int32) {
        let watch = lock.withLock { watches.removeValue(forKey: pid) }
        watch?.watchdog?.terminate()
        try? watch?.lifeline.close()
        update { $0.removeAll { $0.pid == pid && $0.owner == getpid() } }
    }

    /// The watchdog for `pid`: blocks reading `lifeline` and stops the process group once the
    /// other end closes. Fixed script, arguments only; nothing here comes from a model or a user.
    public static func watchdog(for pid: Int32, lifeline: Pipe) throws -> Process {
        let script = """
        id=$(/bin/ps -o lstart= -p "$1" 2>/dev/null)
        [ -n "$id" ] || exit 0
        while read -r _; do :; done
        [ "$(/bin/ps -o lstart= -p "$1" 2>/dev/null)" = "$id" ] || exit 0
        /bin/kill -TERM -- "-$1" 2>/dev/null || /bin/kill -TERM "$1" 2>/dev/null
        i=0
        while [ "$i" -lt 30 ] && /bin/kill -0 -- "-$1" 2>/dev/null; do /bin/sleep 0.1; i=$((i + 1)); done
        /bin/kill -KILL -- "-$1" 2>/dev/null
        exit 0
        """
        let watchdog = Process()
        watchdog.executableURL = URL(fileURLWithPath: "/bin/sh")
        watchdog.arguments = ["-c", script, "daisy-watchdog", String(pid)]
        watchdog.standardInput = lifeline
        watchdog.standardOutput = FileHandle.nullDevice
        watchdog.standardError = FileHandle.nullDevice
        try watchdog.run()
        return watchdog
    }

    // MARK: Sweeping

    /// `sweep()` the first time it's called in this process; later calls do nothing, but wait for
    /// that first sweep to finish, so nobody mistakes a leftover that's being stopped for a live server.
    public func sweepOnce() {
        sweeping.lock(); defer { sweeping.unlock() }
        guard !swept else { return }
        swept = true
        sweep()
    }

    /// Stops what an earlier Daisy left running. Returns a line per process stopped.
    @discardableResult public func sweep() -> [String] {
        var stopped: [String] = []
        let me = getpid()
        let leftovers = update { entries -> [Entry] in
            var keep: [Entry] = [], stop: [Entry] = []
            for entry in entries {
                if entry.owner == me || Self.startTime(entry.owner) == entry.ownerStarted { keep.append(entry) } else { stop.append(entry) }
            }
            entries = keep
            return stop
        }
        for entry in leftovers {
            guard let process = Self.snapshot(entry.pid), process.started == entry.started,
                  Array(process.arguments.dropFirst()) == entry.arguments else { continue }
            Self.stop(process)
            stopped.append("\(entry.label) (pid \(entry.pid))")
        }
        for pid in signatures.isEmpty ? [] : Self.processes() where Self.bsdInfo(pid)?.pbi_ppid == 1 {
            guard let process = Self.snapshot(pid), process.parent == 1,
                  let signature = signatures.first(where: { $0.matches(process) }) else { continue }
            Self.stop(process)
            stopped.append("\(signature.label) (pid \(pid))")
        }
        return stopped
    }

    /// TERM to the process (its whole group when it leads one), then KILL after two seconds.
    static func stop(_ process: Snapshot) {
        let leader = process.group == process.pid
        let target = leader ? -process.pid : process.pid
        // A group id isn't reused while any member is alive, so the group check is safe; a lone
        // process is checked by start time.
        let alive = { leader ? kill(target, 0) == 0 : startTime(process.pid) == process.started }
        kill(target, SIGTERM)
        for _ in 0..<40 where alive() { usleep(50_000) }
        if alive() { kill(target, SIGKILL) }
    }

    // MARK: Records

    private func update<T>(_ body: (inout [Entry]) -> T) -> T {
        let folder = records.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // One writer at a time across processes too (the app and daisy-check share the file).
        let descriptor = open(records.path + ".lock", O_RDWR | O_CREAT, 0o600)
        if descriptor >= 0 { flock(descriptor, LOCK_EX) }
        defer { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor) } }
        return lock.withLock {
            var entries = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: records))) ?? []
            let before = entries
            let result = body(&entries)
            if entries != before {
                if entries.isEmpty { try? FileManager.default.removeItem(at: records) }
                else if let data = try? JSONEncoder().encode(entries) {
                    try? data.write(to: records, options: .atomic)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: records.path)
                }
            }
            return result
        }
    }

    // MARK: Looking at processes

    /// Start time in seconds since 1970, to the microsecond, or nil when there is no such process.
    public static func startTime(_ pid: Int32) -> Double? {
        guard pid > 0, let info = bsdInfo(pid) else { return nil }
        return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
    }

    public static func snapshot(_ pid: Int32) -> Snapshot? {
        guard let info = bsdInfo(pid) else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let path = proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
        let (arguments, environment) = commandLine(pid)
        return Snapshot(pid: pid, parent: Int32(info.pbi_ppid), group: Int32(info.pbi_pgid),
                        started: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000,
                        path: path, arguments: arguments, environment: environment)
    }

    /// This user's processes.
    static func processes() -> [Int32] {
        let uid = UInt32(getuid())
        let size = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard size > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(size) / MemoryLayout<Int32>.size + 64)
        let filled = proc_listpids(UInt32(PROC_UID_ONLY), uid, &pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled) / MemoryLayout<Int32>.size).filter { $0 > 0 && $0 != getpid() }
    }

    private static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    /// Arguments and environment from KERN_PROCARGS2: argc, the executable path, padding, then the
    /// argument strings followed by the environment strings.
    private static func commandLine(_ pid: Int32) -> ([String], [String]) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return ([], []) }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return ([], []) }
        let count = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = [], environment: [String] = []
        var start = index
        while index < size {
            if buffer[index] == 0 {
                let text = String(decoding: buffer[start..<index], as: UTF8.self)
                // Arguments may be empty strings; the environment ends at the first empty one.
                if arguments.count < count { arguments.append(text) } else if text.isEmpty { break } else { environment.append(text) }
                start = index + 1
            }
            index += 1
        }
        return (arguments, environment)
    }
}
