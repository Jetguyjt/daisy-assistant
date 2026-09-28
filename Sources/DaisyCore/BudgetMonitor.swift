import Foundation

/// One usage window of the ChatGPT plan, as Hermes reports it (agent/account_usage.py). For the Codex
/// sign-in Hermes calls the 5-hour window "Session" and the weekly one "Weekly".
public struct UsageWindow: Equatable, Sendable {
    public let label: String
    public let usedPercent: Double?
    public let resetsAt: Date?

    public init(label: String, usedPercent: Double?, resetsAt: Date?) {
        self.label = label; self.usedPercent = usedPercent; self.resetsAt = resetsAt
    }

    /// "5-hour window", "week", or Hermes's own label.
    public var name: String {
        switch label.lowercased() {
        case "session", "current session", "5h", "five_hour": return "5-hour window"
        case "weekly", "current week", "week", "seven_day": return "week"
        default: return label.lowercased()
        }
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let provider: String
    public let plan: String?
    public let windows: [UsageWindow]
    public let fetched: Date
    /// Why there are no windows, when there aren't.
    public let unavailable: String?

    public init(provider: String, plan: String? = nil, windows: [UsageWindow], fetched: Date, unavailable: String? = nil) {
        self.provider = provider; self.plan = plan; self.windows = windows; self.fetched = fetched; self.unavailable = unavailable
    }
}

/// What `HermesUsageSource` prints: {"provider", "plan", "available", "reason", "windows": [{"label",
/// "used_percent", "reset_at"}]}. Anything Hermes printed before it is skipped.
public enum UsageParser {
    public static func parse(_ data: Data, fetched: Date = Date()) throws -> UsageSnapshot {
        let text = String(decoding: data, as: UTF8.self)
        guard let line = text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).last(where: { $0.hasPrefix("{") }),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            throw DaisyError.message("Hermes's usage check printed something unexpected.")
        }
        let windows: [UsageWindow] = ((object["windows"] as? [Any]) ?? []).compactMap { item in
            guard let window = item as? [String: Any], let label = window["label"] as? String, !label.isEmpty else { return nil }
            let used = (window["used_percent"] as? NSNumber)?.doubleValue
            return UsageWindow(label: label, usedPercent: used.map { min(max($0, 0), 100) },
                               resetsAt: (window["reset_at"] as? String).flatMap(HermesDates.iso))
        }
        let reason = (object["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let provider = (object["provider"] as? String) ?? ""
        let plan = (object["plan"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let usable = windows.contains { $0.usedPercent != nil }
        return UsageSnapshot(provider: provider, plan: plan, windows: windows, fetched: fetched,
                             unavailable: usable ? nil : (reason ?? "Hermes didn't report any usage windows"))
    }
}

/// When background work should wait. New background jobs hold while any window is about 80% used
/// (and hasn't reset yet), so the rest stays for talking to Daisy. A reading older than half an hour
/// holds nothing: this saves usage, it isn't a safety check.
public enum BudgetPolicy {
    public static let holdAt = 80.0
    public static let staleAfter: TimeInterval = 30 * 60

    /// Windows that still count: a reset time that has passed means that window started over.
    public static func live(_ snapshot: UsageSnapshot, now: Date) -> [UsageWindow] {
        snapshot.windows.filter { $0.usedPercent != nil && ($0.resetsAt.map { $0 > now } ?? true) }
    }

    /// Why new background jobs should wait, or nil.
    public static func holdReason(_ snapshot: UsageSnapshot?, now: Date = Date(), allowedUntil: Date? = nil) -> String? {
        guard let snapshot, now.timeIntervalSince(snapshot.fetched) <= staleAfter else { return nil }
        if let allowedUntil, now < allowedUntil { return nil }
        guard let worst = live(snapshot, now: now).filter({ ($0.usedPercent ?? 0) >= holdAt })
            .max(by: { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) }) else { return nil }
        let used = Int((worst.usedPercent ?? 0).rounded())
        let until = worst.resetsAt.map { " until it resets \(when($0, now: now))" } ?? ""
        return "\(used)% of the \(worst.name) is used, so new background jobs wait\(until)."
    }

    /// For the telemetry panel: "62% of the 5-hour window · 41% of the week".
    public static func summary(_ snapshot: UsageSnapshot?, problem: String? = nil, now: Date = Date()) -> String {
        guard let snapshot else { return problem == nil ? "Not read yet" : "Unavailable" }
        let parts = snapshot.windows.compactMap { window in
            window.usedPercent.map { "\(Int($0.rounded()))% of the \(window.name)" }
        }
        guard !parts.isEmpty else { return "Unavailable" }
        let stale = now.timeIntervalSince(snapshot.fetched) > staleAfter
        return parts.joined(separator: " · ") + (stale ? " (as of \(clock(snapshot.fetched)))" : "")
    }

    public static func headline(_ snapshot: UsageSnapshot?, problem: String? = nil, now: Date = Date()) -> String {
        "Usage: " + summary(snapshot, problem: problem, now: now)
    }

    /// The fullest window that still counts, 0...1, for a level bar.
    public static func level(_ snapshot: UsageSnapshot?, now: Date = Date()) -> Double? {
        guard let snapshot else { return nil }
        return live(snapshot, now: now).compactMap(\.usedPercent).max().map { $0 / 100 }
    }

    /// "at 4:10 PM" today, "on Tue at 4:10 PM" later.
    static func when(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? "at \(clock(date))"
            : "on \(date.formatted(.dateTime.weekday(.abbreviated))) at \(clock(date))"
    }

    static func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}

/// Where the usage numbers come from.
public protocol UsageSource: Sendable {
    func read() async throws -> Data
}

/// Asks Hermes, the only thing that holds the ChatGPT sign-in. It runs Hermes's own Python with a short
/// script that calls agent.account_usage.fetch_account_usage for the configured provider, the same call
/// behind Hermes's /usage command, and prints the windows as JSON. Daisy never sees a token. Like any
/// Hermes process, that call can refresh the sign-in when it's about to expire. It isn't a model call.
public struct HermesUsageSource: UsageSource {
    public let python: URL

    public init(python: URL) { self.python = python }

    /// Hermes's venv Python, next to hermes-acp (or where Hermes installs itself).
    public static func python(nextTo acp: URL?) -> URL {
        if let acp { return acp.deletingLastPathComponent().appendingPathComponent("python") }
        return HermesMemory.home.appendingPathComponent("hermes-agent/venv/bin/python")
    }

    public func read() async throws -> Data {
        let output = try await LocalProcess.capture(executable: python, arguments: ["-I", "-B", "-c", Self.script],
                                                    workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
                                                    timeout: 45, maxBytes: 32_768)
        return Data(output.utf8)
    }

    /// Prints one JSON line. Errors come back as a reason, never a traceback.
    public static let script = """
    import json
    out = {"version": 1, "provider": "", "available": False, "windows": []}
    try:
        from hermes_cli.config import load_config
        model = (load_config() or {}).get("model") or {}
        provider = str(model.get("provider") or "").strip() if isinstance(model, dict) else ""
        out["provider"] = provider
        from agent import account_usage
        known = getattr(account_usage, "_USAGE_FETCHERS", None)
        if not provider:
            out["reason"] = "Hermes has no provider set"
        elif isinstance(known, dict) and provider not in known:
            out["reason"] = "Hermes can't read usage windows for " + provider
        else:
            snapshot = account_usage.fetch_account_usage(provider)
            if snapshot is None:
                out["reason"] = "Hermes couldn't read the usage windows just now"
            else:
                out["plan"] = snapshot.plan
                out["reason"] = snapshot.unavailable_reason
                out["windows"] = [{"label": w.label, "used_percent": w.used_percent,
                                   "reset_at": w.reset_at.isoformat() if w.reset_at else None}
                                  for w in snapshot.windows]
                out["available"] = bool(out["windows"]) and not snapshot.unavailable_reason
    except Exception as error:
        out["reason"] = "Hermes's usage check failed (" + type(error).__name__ + ")"
    print(json.dumps(out))
    """
}

/// Polls the usage windows (every ten minutes by default) and says when new background jobs should
/// wait. `JobsModel` asks `holdReason` before it starts a queued job; `onChange` runs after every
/// reading so it can look again.
@MainActor public final class BudgetMonitor: ObservableObject {
    @Published public private(set) var snapshot: UsageSnapshot?
    /// Why the last reading didn't work, for the screen.
    @Published public private(set) var problem: String?
    /// Set by `allowAnyway`: jobs run until then even over the limit.
    @Published public private(set) var allowedUntil: Date?
    public var onChange: (() -> Void)?
    public let interval: TimeInterval
    private let source: UsageSource
    private let clock: () -> Date
    private var poller: Task<Void, Never>?
    private var reading = false

    public init(source: UsageSource, interval: TimeInterval = 600, clock: @escaping () -> Date = Date.init) {
        self.source = source; self.interval = max(60, interval); self.clock = clock
    }

    public var holdReason: String? { BudgetPolicy.holdReason(snapshot, now: clock(), allowedUntil: allowedUntil) }
    /// "62% of the 5-hour window · 41% of the week".
    public var summary: String { BudgetPolicy.summary(snapshot, problem: problem, now: clock()) }
    public var level: Double? { BudgetPolicy.level(snapshot, now: clock()) }
    public var polling: Bool { poller != nil }

    /// Reads now, then every `interval`, until `stop`.
    public func start() {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard let wait = self?.interval else { return }
                do { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) } catch { return }
            }
        }
    }

    public func stop() {
        poller?.cancel(); poller = nil
    }

    public func refresh() async {
        guard !reading else { return }
        reading = true
        defer { reading = false }
        do {
            let latest = try UsageParser.parse(try await source.read(), fetched: clock())
            if let unavailable = latest.unavailable {
                // The last good reading stays; it stops counting once it's half an hour old.
                problem = unavailable
            } else {
                snapshot = latest; problem = nil
            }
        } catch is CancellationError {
            return
        } catch {
            problem = (error as? DaisyError)?.errorDescription ?? error.localizedDescription
        }
        onChange?()
    }

    /// Lets background jobs run over the limit until the fullest window resets (five hours when Hermes
    /// didn't say when).
    public func allowAnyway() {
        let now = clock()
        let over = snapshot.map { BudgetPolicy.live($0, now: now).filter { ($0.usedPercent ?? 0) >= BudgetPolicy.holdAt } } ?? []
        allowedUntil = over.compactMap(\.resetsAt).max() ?? now.addingTimeInterval(5 * 3600)
        onChange?()
    }
}
