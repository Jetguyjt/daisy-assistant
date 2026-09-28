import Foundation
import DaisyCore

/// The usage windows read through Hermes, the 80% hold for new background jobs, and the helper script
/// Daisy runs with Hermes's Python, tried against a stand-in for Hermes's modules (it never touches the
/// real Hermes or its sign-in).
final class BudgetTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("budget-\(UUID().uuidString)")
    let now = Date(timeIntervalSince1970: 1_790_600_000)

    func setUp() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func tearDown() { try? FileManager.default.removeItem(at: root) }

    /// What HermesUsageSource prints for the Codex sign-in, with the windows at these percentages.
    private func reading(session: Double?, weekly: Double?, sessionReset: TimeInterval = 7200, weeklyReset: TimeInterval = 300_000) -> Data {
        func stamp(_ offset: TimeInterval) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: now.addingTimeInterval(offset)).replacingOccurrences(of: "Z", with: "123+00:00")
        }
        func number(_ value: Double?) -> String { value.map { String($0) } ?? "null" }
        return Data("""
        {"version": 1, "provider": "openai-codex", "available": true, "plan": "Plus", "reason": null, "windows": [\
        {"label": "Session", "used_percent": \(number(session)), "reset_at": "\(stamp(sessionReset))"}, \
        {"label": "Weekly", "used_percent": \(number(weekly)), "reset_at": "\(stamp(weeklyReset))"}]}
        """.utf8)
    }

    func testReadsHermesUsage() throws {
        let snapshot = try UsageParser.parse(reading(session: 62, weekly: 41.4), fetched: now)
        expectEqual(snapshot.provider, "openai-codex")
        expectEqual(snapshot.plan, "Plus")
        expectEqual(snapshot.windows.map(\.name), ["5-hour window", "week"])
        expectEqual(snapshot.windows.map(\.usedPercent), [62, 41.4])
        let reset = try unwrap(snapshot.windows.first?.resetsAt)
        expectTrue(abs(reset.timeIntervalSince(now.addingTimeInterval(7200))) < 1)
        expectTrue(snapshot.unavailable == nil)
        expectEqual(BudgetPolicy.summary(snapshot, now: now), "62% of the 5-hour window · 41% of the week")
        expectEqual(BudgetPolicy.headline(snapshot, now: now), "Usage: 62% of the 5-hour window · 41% of the week")
        // Anything Hermes printed first is skipped.
        let noisy = Data("warning: something\n".utf8) + reading(session: 10, weekly: 5)
        try expectEqual(UsageParser.parse(noisy, fetched: now).windows.count, 2)
    }

    func testUnavailableAndBrokenReadings() throws {
        let unavailable = try UsageParser.parse(Data(#"{"version": 1, "provider": "openai-codex", "available": false, "windows": [], "reason": "Hermes couldn't read the usage windows just now"}"#.utf8), fetched: now)
        expectEqual(unavailable.unavailable, "Hermes couldn't read the usage windows just now")
        let empty = try UsageParser.parse(Data(#"{"provider": "nous", "windows": []}"#.utf8), fetched: now)
        expectEqual(empty.unavailable, "Hermes didn't report any usage windows")
        expectThrows(try UsageParser.parse(Data("Traceback (most recent call last):".utf8), fetched: now))
        expectEqual(BudgetPolicy.summary(nil, now: now), "Not read yet")
        expectEqual(BudgetPolicy.summary(nil, problem: "no", now: now), "Unavailable")
    }

    func testHoldsNewJobsAtEightyPercent() throws {
        func hold(_ session: Double?, _ weekly: Double?, fetched: Date? = nil, sessionReset: TimeInterval = 7200,
                  allowedUntil: Date? = nil) throws -> String? {
            let snapshot = try UsageParser.parse(reading(session: session, weekly: weekly, sessionReset: sessionReset), fetched: fetched ?? now)
            return BudgetPolicy.holdReason(snapshot, now: now, allowedUntil: allowedUntil)
        }
        try expectTrue(hold(79.4, 10) == nil)
        let atLimit = try unwrap(try hold(80, 10))
        expectTrue(atLimit.hasPrefix("80% of the 5-hour window is used, so new background jobs wait until it resets at "))
        let weekly = try unwrap(try hold(20, 91))
        expectTrue(weekly.hasPrefix("91% of the week is used"))
        let both = try unwrap(try hold(85, 97))
        expectTrue(both.hasPrefix("97% of the week"))
        // The 5-hour window already reset: it doesn't count any more.
        try expectTrue(hold(95, 10, sessionReset: -60) == nil)
        // A reading from over half an hour ago holds nothing.
        try expectTrue(hold(95, 10, fetched: now.addingTimeInterval(-31 * 60)) == nil)
        try expectTrue(hold(95, 10, fetched: now.addingTimeInterval(-29 * 60)) != nil)
        // "Run them anyway" until the window resets.
        try expectTrue(hold(95, 10, allowedUntil: now.addingTimeInterval(60)) == nil)
        try expectTrue(hold(95, 10, allowedUntil: now.addingTimeInterval(-60)) != nil)
        try expectTrue(hold(nil, nil) == nil)
        expectTrue(BudgetPolicy.holdReason(nil, now: now) == nil)
    }

    func testLevelIsTheFullestLiveWindow() throws {
        let snapshot = try UsageParser.parse(reading(session: 30, weekly: 55), fetched: now)
        expectEqual(BudgetPolicy.level(snapshot, now: now), 0.55)
        let stale = try UsageParser.parse(reading(session: 90, weekly: 20, sessionReset: -10), fetched: now)
        expectEqual(BudgetPolicy.level(stale, now: now), 0.2)
        let old = try UsageParser.parse(reading(session: 30, weekly: 55), fetched: now.addingTimeInterval(-3600))
        expectTrue(BudgetPolicy.summary(old, now: now).contains("(as of "))
    }

    private final class FakeUsage: UsageSource, @unchecked Sendable {
        private let lock = NSLock()
        private var next: Result<Data, Error>
        private(set) var reads = 0
        init(_ first: Result<Data, Error>) { next = first }
        func set(_ result: Result<Data, Error>) { lock.withLock { next = result } }
        func read() async throws -> Data {
            try lock.withLock { reads += 1; return try next.get() }
        }
    }

    @MainActor
    func testMonitorHoldsAndLetsGo() async throws {
        let source = FakeUsage(.success(reading(session: 85, weekly: 30)))
        let monitor = BudgetMonitor(source: source, clock: { self.now })
        var changes = 0
        monitor.onChange = { changes += 1 }
        expectTrue(monitor.holdReason == nil)
        expectEqual(monitor.summary, "Not read yet")
        await monitor.refresh()
        expectEqual(changes, 1)
        expectEqual(monitor.summary, "85% of the 5-hour window · 30% of the week")
        let reason = try unwrap(monitor.holdReason)
        expectTrue(reason.hasPrefix("85% of the 5-hour window is used"))
        monitor.allowAnyway()
        expectTrue(monitor.holdReason == nil)
        expectEqual(changes, 2)
        let until = try unwrap(monitor.allowedUntil)
        expectTrue(abs(until.timeIntervalSince(now.addingTimeInterval(7200))) < 1)

        // A failed reading keeps the last good one and says why.
        source.set(.failure(DaisyError.message("The binary is missing or not executable at /nowhere/python.")))
        await monitor.refresh()
        expectEqual(monitor.problem, "The binary is missing or not executable at /nowhere/python.")
        expectEqual(monitor.summary, "85% of the 5-hour window · 30% of the week")
        expectEqual(changes, 3)
        source.set(.success(Data(#"{"provider": "openai-codex", "windows": [], "reason": "Hermes couldn't read the usage windows just now"}"#.utf8)))
        await monitor.refresh()
        expectEqual(monitor.problem, "Hermes couldn't read the usage windows just now")
        expectTrue(monitor.snapshot != nil)
        source.set(.success(reading(session: 12, weekly: 30)))
        await monitor.refresh()
        expectTrue(monitor.problem == nil)
        expectEqual(monitor.level, 0.3)
    }

    @MainActor
    func testPollingStartsAndStops() async throws {
        let source = FakeUsage(.success(reading(session: 5, weekly: 5)))
        let monitor = BudgetMonitor(source: source, interval: 600, clock: { self.now })
        monitor.start()
        monitor.start()
        expectTrue(monitor.polling)
        let deadline = Date().addingTimeInterval(5)
        while monitor.snapshot == nil, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        expectTrue(monitor.snapshot != nil)
        expectEqual(source.reads, 1)
        monitor.stop()
        expectFalse(monitor.polling)
    }

    /// The script HermesUsageSource hands Hermes's Python, run by python3 against stand-ins for
    /// hermes_cli.config and agent.account_usage.
    func testHelperScriptAgainstStandInHermes() async throws {
        let modules = root.appendingPathComponent("modules")
        try FileManager.default.createDirectory(at: modules.appendingPathComponent("hermes_cli"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modules.appendingPathComponent("agent"), withIntermediateDirectories: true)
        try "".write(to: modules.appendingPathComponent("hermes_cli/__init__.py"), atomically: true, encoding: .utf8)
        try "".write(to: modules.appendingPathComponent("agent/__init__.py"), atomically: true, encoding: .utf8)
        try """
        import os
        def load_config():
            provider = os.environ.get("STAND_IN_PROVIDER", "openai-codex")
            return {"model": {"default": "gpt-5.6-sol", "provider": provider}}
        """.write(to: modules.appendingPathComponent("hermes_cli/config.py"), atomically: true, encoding: .utf8)
        try """
        import os
        from dataclasses import dataclass
        from datetime import datetime, timezone
        from typing import Optional

        @dataclass(frozen=True)
        class AccountUsageWindow:
            label: str
            used_percent: Optional[float] = None
            reset_at: Optional[datetime] = None

        @dataclass(frozen=True)
        class AccountUsageSnapshot:
            provider: str
            plan: Optional[str] = None
            windows: tuple = ()
            unavailable_reason: Optional[str] = None

        _USAGE_FETCHERS = {"openai-codex": None, "anthropic": None}

        def fetch_account_usage(provider, base_url=None, api_key=None):
            if os.environ.get("STAND_IN_MODE") == "none":
                return None
            if os.environ.get("STAND_IN_MODE") == "boom":
                raise RuntimeError("secret-looking detail that must not be shown")
            reset = datetime(2026, 9, 28, 16, 10, 0, 123456, tzinfo=timezone.utc)
            return AccountUsageSnapshot(provider=provider, plan="Plus", windows=(
                AccountUsageWindow("Session", 62.0, reset), AccountUsageWindow("Weekly", 41.0, None)))
        """.write(to: modules.appendingPathComponent("agent/account_usage.py"), atomically: true, encoding: .utf8)

        func run(_ environment: String) async throws -> UsageSnapshot {
            // Stands in for Hermes's Python: gets "-I -B -c <script>" and runs the script with the stand-ins.
            let python = root.appendingPathComponent("python-\(UUID().uuidString)")
            try """
            #!/bin/bash
            export PYTHONPATH=\(modules.path) \(environment)
            exec /usr/bin/env python3 -B -c "$4"
            """.write(to: python, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
            return try UsageParser.parse(try await HermesUsageSource(python: python).read(), fetched: now)
        }

        let codex = try await run("")
        expectEqual(codex.provider, "openai-codex")
        expectEqual(codex.plan, "Plus")
        expectEqual(codex.windows.map(\.name), ["5-hour window", "week"])
        expectEqual(codex.windows.map(\.usedPercent), [62, 41])
        let reset = try unwrap(codex.windows.first?.resetsAt)
        expectTrue(abs(reset.timeIntervalSince1970 - 1_790_611_800.123) < 0.001)
        expectTrue(codex.windows.last?.resetsAt == nil)
        let none = try await run("STAND_IN_MODE=none")
        expectEqual(none.unavailable, "Hermes couldn't read the usage windows just now")
        let broken = try await run("STAND_IN_MODE=boom")
        expectEqual(broken.unavailable, "Hermes's usage check failed (RuntimeError)")
        let other = try await run("STAND_IN_PROVIDER=nous")
        expectEqual(other.unavailable, "Hermes can't read usage windows for nous")
        let unset = try await run("STAND_IN_PROVIDER=")
        expectEqual(unset.unavailable, "Hermes has no provider set")
    }

    func testPythonNextToHermes() {
        let acp = URL(fileURLWithPath: "/opt/hermes/venv/bin/hermes-acp")
        expectEqual(HermesUsageSource.python(nextTo: acp).path, "/opt/hermes/venv/bin/python")
        expectTrue(HermesUsageSource.python(nextTo: nil).path.hasSuffix("hermes-agent/venv/bin/python"))
    }
}
