import Combine
import Foundation

/// Approval cards waiting on the user, from the conversation and from background jobs.
/// - No answer means no. A card nobody answers is declined just before Hermes's own 60-second
///   limit and taken down, so a late tap can't look like it worked.
/// - A card goes as soon as its turn or job ends (`withdraw`).
/// - Allow means allow once. Nothing is ever answered as always allowed.
/// - During a voice turn, a card left waiting lets go of the voice: `onPark` gets the line to say,
///   and the app goes back to listening while the card stays up.
/// - A few cards at once is plenty. More than `limit` reads as a runaway, and the extras are declined.
@MainActor public final class ApprovalQueue: ObservableObject {
    public enum Source: Hashable, Sendable {
        case conversation
        case job(UUID)
    }
    public struct Item: Identifiable, Equatable, Sendable {
        public let approval: AgentApproval
        public let source: Source
        /// Which job asked, for the card ("repo digest").
        public let label: String?
        public let arrived: Date
        /// When it counts as no.
        public let expires: Date
        public var id: String { approval.id }
        /// The only yes this card can give. nil when the request doesn't offer "once".
        public var allowOnce: AgentApproval.Option? { approval.options.first { $0.kind == .allowOnce } }
    }
    public enum Outcome: String, Sendable {
        case allowed, declined
        /// Nobody answered in time.
        case expired
        /// Its turn or job ended first.
        case withdrawn
        /// Too many cards were already up.
        case overflow
    }

    public static let parkLine = "I've left that for you to approve."

    @Published public private(set) var items: [Item] = []
    /// A card is waiting from a voice turn and Daisy has let go of the voice for it.
    @Published public private(set) var parked = false
    /// Called once when a voice turn's card has been waiting `parkDelay`, with the line to say.
    public var onPark: ((String) -> Void)?
    /// Every card's end, for the transcript ("Approved: Send an iMessage to Dad").
    public var onDecision: ((Item, Outcome) -> Void)?

    public let window: TimeInterval
    public let parkDelay: TimeInterval
    public let limit: Int
    private let respond: @MainActor (String, String?) async -> Void
    private var timers: [String: Task<Void, Never>] = [:]
    private var voiceCards: Set<String> = []
    private var parkTimer: Task<Void, Never>?

    /// `respond` passes the answer to the backend: the approval id and the option chosen, nil for no.
    /// `window` stays under Hermes's 60 seconds and under the backend's own backstop
    /// (`HermesBackend.Settings.approvalWindow`, 57), so the card is gone before either gives up.
    public init(window: TimeInterval = 54, parkDelay: TimeInterval = 3, limit: Int = 5,
                respond: @escaping @MainActor (String, String?) async -> Void) {
        self.window = window; self.parkDelay = parkDelay; self.limit = max(1, limit); self.respond = respond
    }

    public func add(_ approval: AgentApproval, from source: Source, label: String? = nil, voice: Bool = false) {
        guard !items.contains(where: { $0.id == approval.id }) else { return }
        let now = Date()
        let item = Item(approval: approval, source: source, label: label, arrived: now, expires: now.addingTimeInterval(window))
        guard items.count < limit else {
            send(item.id, nil)
            onDecision?(item, .overflow)
            return
        }
        items.append(item)
        let window = self.window
        timers[item.id] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0.01, window) * 1_000_000_000)) } catch { return }
            self?.expire(item.id)
        }
        if voice { voiceCards.insert(item.id); scheduleParking() }
    }

    /// The user's tap. Allowing needs an allow-once option; without one the answer is no, never
    /// "always".
    public func answer(_ id: String, allow: Bool) {
        guard let item = take(id) else { return }
        let yes = allow ? item.allowOnce : nil
        let choice = yes ?? item.approval.options.first { $0.kind == .rejectOnce }
        send(id, choice?.id)
        onDecision?(item, yes != nil ? .allowed : .declined)
    }

    /// The backend says the request is settled: answered elsewhere, timed out, or its turn stopped.
    public func settled(_ id: String, allowed: Bool) {
        guard let item = take(id) else { return }
        let lapsed = Date() >= item.expires.addingTimeInterval(-1)
        onDecision?(item, allowed ? .allowed : lapsed ? .expired : .declined)
    }

    /// Takes down a turn's or job's cards once it has ended. The backend has already counted them as no.
    public func withdraw(from source: Source) {
        for item in items where item.source == source {
            if take(item.id) != nil { onDecision?(item, .withdrawn) }
        }
    }

    public func withdrawAll() {
        for item in items {
            if take(item.id) != nil { onDecision?(item, .withdrawn) }
        }
    }

    public func items(from source: Source) -> [Item] { items.filter { $0.source == source } }

    private func expire(_ id: String) {
        guard let item = take(id) else { return }
        send(id, nil)
        onDecision?(item, .expired)
    }

    private func take(_ id: String) -> Item? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let item = items.remove(at: index)
        timers.removeValue(forKey: id)?.cancel()
        voiceCards.remove(id)
        if voiceCards.isEmpty { parkTimer?.cancel(); parkTimer = nil; parked = false }
        return item
    }

    private func send(_ id: String, _ option: String?) {
        let respond = self.respond
        Task { await respond(id, option) }
    }

    private func scheduleParking() {
        guard !parked, parkTimer == nil else { return }
        let delay = parkDelay
        parkTimer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000)) } catch { return }
            guard let self, !self.voiceCards.isEmpty, !self.parked else { return }
            self.parkTimer = nil
            self.parked = true
            self.onPark?(Self.parkLine)
        }
    }
}
