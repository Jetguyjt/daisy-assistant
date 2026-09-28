import Foundation
import DaisyCore

/// Helper processes must not outlive Daisy. These use /bin/sleep and /bin/sh as the children, a
/// registry file in a temporary folder, and signatures that only match their own sleepers, so
/// nothing outside the test can be touched.
final class ChildProcessTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("daisy-children-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }
    private func wait(timeout: TimeInterval = 5, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }
    private func start(_ executable: String, _ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }
    /// A sleeper whose parent has already exited, so launchd adopts it: what a crash leaves behind.
    private func orphan(_ seconds: String) async throws -> (pid: Int32, formerParent: Int32) {
        let shell = Process(), output = Pipe()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "/bin/sleep \"$1\" </dev/null >/dev/null 2>&1 & echo $!", "sh", seconds]
        shell.standardOutput = output; shell.standardError = FileHandle.nullDevice
        try shell.run()
        shell.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw DaisyError.message("no pid from sh") }
        _ = await wait { ChildProcesses.snapshot(pid)?.parent == 1 }
        return (pid, shell.processIdentifier)
    }

    func testWatchdogStopsTheWholeGroupWhenTheLifelineCloses() async throws {
        // sh with two sleeps: a process group of three, like ollama serve with its runners.
        let child = try start("/bin/sh", ["-c", "/bin/sleep 30 & /bin/sleep 31; wait"])
        let pid = child.processIdentifier
        defer { kill(-pid, SIGKILL) }
        let lifeline = Pipe()
        let watchdog = try ChildProcesses.watchdog(for: pid, lifeline: lifeline)
        try? lifeline.fileHandleForReading.close()
        try await Task.sleep(nanoseconds: 300_000_000)
        expectTrue(child.isRunning)
        expectTrue(watchdog.isRunning)
        // Closing the last write end is exactly what the kernel does when the owner dies.
        try lifeline.fileHandleForWriting.close()
        let groupGone = await wait { kill(-pid, 0) != 0 }
        expectTrue(groupGone)
        let watchdogDone = await wait { !watchdog.isRunning }
        expectTrue(watchdogDone)
    }

    func testWatchdogStopsTheChildWhenItsOwnerIsKilled() async throws {
        let child = try start("/bin/sleep", ["30"])
        defer { child.terminate() }
        let lifeline = Pipe()
        _ = try ChildProcesses.watchdog(for: child.processIdentifier, lifeline: lifeline)
        // A stand-in owner holds the only write end, then dies the way a force quit ends Daisy.
        let owner = Process()
        owner.executableURL = URL(fileURLWithPath: "/bin/sleep"); owner.arguments = ["30"]
        owner.standardInput = FileHandle.nullDevice; owner.standardOutput = lifeline; owner.standardError = FileHandle.nullDevice
        try owner.run()
        try? lifeline.fileHandleForWriting.close(); try? lifeline.fileHandleForReading.close()
        try await Task.sleep(nanoseconds: 400_000_000)
        expectTrue(child.isRunning)
        kill(owner.processIdentifier, SIGKILL)
        let childGone = await wait { !child.isRunning }
        expectTrue(childGone)
    }

    func testLaunchRecordsTheChildAndForgetsItWhenItExits() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ChildProcesses(records: root.appendingPathComponent("children.json"), signatures: [])
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["0.6"]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try registry.launch(child, label: "nap")
        let entries = registry.recorded
        expectEqual(entries.map(\.label), ["nap"])
        expectEqual(entries.first?.arguments, ["0.6"])
        expectEqual(entries.first?.pid, child.processIdentifier)
        expectEqual(entries.first?.owner, getpid())
        expectEqual(entries.first?.started, ChildProcesses.startTime(child.processIdentifier))
        let forgotten = await wait { registry.recorded.isEmpty }
        expectTrue(forgotten)
        expectFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("children.json").path))
    }

    func testSweepStopsRecordedChildrenOfAGoneOwnerOnly() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ChildProcesses(records: root.appendingPathComponent("children.json"), signatures: [])
        let left = try await orphan("41.25"), kept = try await orphan("41.5"), reused = try await orphan("41.75")
        defer { kill(kept.pid, SIGKILL); kill(reused.pid, SIGKILL); kill(left.pid, SIGKILL) }
        expectEqual(ChildProcesses.snapshot(left.pid)?.parent, 1)
        let me = getpid(), myStart = ChildProcesses.startTime(getpid()) ?? 0
        // Left by an owner that is gone: stopped.
        registry.record(.init(pid: left.pid, label: "left", arguments: ["41.25"], started: ChildProcesses.startTime(left.pid) ?? 0,
                              owner: left.formerParent, ownerStarted: 12345))
        // Its owner (this test) is still running: kept.
        registry.record(.init(pid: kept.pid, label: "kept", arguments: ["41.5"], started: ChildProcesses.startTime(kept.pid) ?? 0,
                              owner: me, ownerStarted: myStart))
        // Same pid but a different start time: the pid was reused by something else, so hands off.
        registry.record(.init(pid: reused.pid, label: "reused", arguments: ["41.75"], started: (ChildProcesses.startTime(reused.pid) ?? 0) - 60,
                              owner: reused.formerParent, ownerStarted: 12345))
        let stopped = registry.sweep()
        expectEqual(stopped, ["left (pid \(left.pid))"])
        let leftGone = await wait { !self.alive(left.pid) }
        expectTrue(leftGone)
        expectTrue(alive(kept.pid))
        expectTrue(alive(reused.pid))
        expectEqual(registry.recorded.map(\.label), ["kept"])
    }

    func testSweepStopsOrphansThatMatchASignatureOnly() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = "42.\(Int.random(in: 1000...9999))"
        let signature = ChildProcesses.Signature(label: "test sleeper") { $0.name == "sleep" && $0.arguments.dropFirst().first == marker }
        let registry = ChildProcesses(records: root.appendingPathComponent("children.json"), signatures: [signature])
        let left = try await orphan(marker)
        // The same command with a live parent (this test) is somebody's child, not a leftover.
        let owned = try start("/bin/sleep", [marker])
        defer { owned.terminate(); kill(left.pid, SIGKILL) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let stopped = registry.sweep()
        expectEqual(stopped, ["test sleeper (pid \(left.pid))"])
        let orphanGone = await wait { !self.alive(left.pid) }
        expectTrue(orphanGone)
        expectTrue(owned.isRunning)
        // sweepOnce sweeps the first time it's called and never again.
        let again = try await orphan(marker)
        defer { kill(again.pid, SIGKILL) }
        registry.sweepOnce()
        registry.sweepOnce()
        let againGone = await wait { !self.alive(again.pid) }
        expectTrue(againGone)
        let third = try await orphan(marker)
        defer { kill(third.pid, SIGKILL) }
        registry.sweepOnce()
        try await Task.sleep(nanoseconds: 200_000_000)
        expectTrue(alive(third.pid))
    }

    func testDaisySignaturesMatchWhatDaisyStartsAndNothingElse() {
        func label(_ path: String, _ arguments: [String], _ environment: [String] = []) -> String? {
            let process = ChildProcesses.Snapshot(pid: 500, parent: 1, group: 500, started: 1, path: path,
                                                  arguments: [path] + arguments, environment: environment)
            return ChildProcesses.Signature.daisy.first { $0.matches(process) }?.label
        }
        let whisper = "/opt/homebrew/Cellar/whisper.cpp/1.9.4/bin/whisper-server"
        expectEqual(label(whisper, ["-m", "base.bin", "--host", "127.0.0.1", "--port", "11437", "-t", "4", "-l", "en"]), "whisper-server")
        expectEqual(label(whisper, ["-m", "base.bin", "--port", "8080"]), nil)
        let ollama = "/opt/homebrew/Cellar/ollama/0.34.4/bin/ollama"
        expectEqual(label(ollama, ["serve"], ["HOME=/Users/x", "OLLAMA_HOST=127.0.0.1:11435", "OLLAMA_NO_CLOUD=1"]), "ollama serve")
        expectEqual(label(ollama, ["serve"], ["OLLAMA_HOST=127.0.0.1:11434"]), nil)       // Ollama.app or brew services
        expectEqual(label(ollama, ["run", "qwen3.5:4b"], ["OLLAMA_HOST=127.0.0.1:11435"]), nil)
        let python = "/opt/homebrew/Cellar/python@3.11/3.11.15_1/Frameworks/Python.framework/Versions/3.11/Resources/Python.app/Contents/MacOS/Python"
        expectEqual(label(python, ["/Users/x/Library/Application Support/Daisy/Runtime/voice/synthesize.py", "--serve"]), "voice worker")
        expectEqual(label(python, ["/Users/x/Library/Application Support/Jarvis/Runtime/voice/synthesize.py", "--serve"]), "voice worker")
        expectEqual(label(python, ["/Users/x/Library/Application Support/Daisy/Runtime/voice/synthesize.py", "--input", "a.txt"]), nil)
        expectEqual(label(python, ["/Users/x/Library/Application Support/Daisy/Runtime/speech/wakeword.py", "--melspec", "m.onnx"]), "wake word worker")
        expectEqual(label(python, ["/Users/x/projects/other/wakeword.py"]), nil)
    }
}
