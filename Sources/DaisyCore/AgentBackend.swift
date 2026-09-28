import Foundation

/// The seam between the Daisy interface and whatever agent answers. The UI only sees these
/// types; protocol details (ACP, the local engine) stay inside each backend.
public protocol AgentBackend: AnyObject, Sendable {
    /// Short name for the link readout, e.g. "Hermes" or "Local".
    var name: String { get }
    /// Starts the agent or checks it is still there. Safe to call repeatedly.
    func connect() async -> AgentLink
    /// Runs one turn. Events arrive in order; the stream finishes with the turn and throws
    /// `AgentFailure` when it can't complete. Cancelling the consuming task cancels the turn.
    func send(_ prompt: AgentPrompt) -> AsyncThrowingStream<AgentEvent, Error>
    /// Stops the turn in progress, if any.
    func cancel() async
    /// Answers a pending approval. `optionID` nil means no.
    func resolve(approval id: String, optionID: String?) async
    /// Starts a fresh conversation; the agent's own memory is untouched.
    func newSession() async
    /// The conversation so far, when the agent resumed one from an earlier launch.
    func history() async -> [AgentMessage]
    /// Earlier conversations, newest first. Empty when the backend doesn't keep them.
    func sessions() async -> [AgentSession]
    /// Reopens an earlier conversation and returns its messages, or nil if it couldn't.
    func open(session id: String) async -> [AgentMessage]?
    func shutdown() async
}

public extension AgentBackend {
    func send(_ text: String) -> AsyncThrowingStream<AgentEvent, Error> { send(AgentPrompt(text: text)) }
}

/// What the user sends in one turn.
public struct AgentPrompt: Sendable, Equatable {
    public var text: String
    public var attachments: [AgentAttachment]
    public init(text: String, attachments: [AgentAttachment] = []) { self.text = text; self.attachments = attachments }
}

/// A file sent with a message. Its content goes to the model, so the user picks it explicitly.
public enum AgentAttachment: Sendable, Equatable {
    /// An image, inlined.
    case image(name: String, mimeType: String, data: Data)
    /// Text pulled out of a document on this Mac (PDF, Word) because the agent can't read it raw.
    case document(name: String, uri: String, text: String)
    /// A file the agent reads itself.
    case file(URL)
    public var name: String {
        switch self {
        case .image(let name, _, _), .document(let name, _, _): return name
        case .file(let url): return url.lastPathComponent
        }
    }
}

/// An earlier conversation, for the chat list.
public struct AgentSession: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let updated: Date?
    public init(id: String, title: String, updated: Date?) { self.id = id; self.title = title; self.updated = updated }
}

/// One line of a resumed conversation.
public struct AgentMessage: Sendable, Equatable {
    public let role: String
    public var text: String
    public init(role: String, text: String) { self.role = role; self.text = text }
}

/// Where the agent stands.
public enum AgentLink: Sendable, Equatable {
    case starting
    /// `detail` is what the agent reports about itself, such as the provider and model.
    case ready(detail: String?)
    case needsSetup(AgentSetupIssue)
    case offline(String)

    public var isReady: Bool { if case .ready = self { return true }; return false }
}

/// Something the user has to do before the agent can work, with the command that does it.
public struct AgentSetupIssue: Sendable, Equatable {
    public let title: String
    public let detail: String
    public let command: String?
    public init(title: String, detail: String, command: String? = nil) {
        self.title = title; self.detail = detail; self.command = command
    }
}

/// A tool call as the HUD shows it: plain words, no payloads.
public struct AgentToolActivity: Sendable, Equatable, Identifiable {
    public enum State: String, Sendable { case pending, running, completed, failed }
    public let id: String
    public var title: String
    /// A file name or search query worth showing next to the title. Never a raw command.
    public var detail: String?
    public var kind: String?
    public var state: State
    public init(id: String, title: String, detail: String? = nil, kind: String? = nil, state: State) {
        self.id = id; self.title = title; self.detail = detail; self.kind = kind; self.state = state
    }
}

/// A decision the agent needs before it acts, such as sending a message or running a command.
public struct AgentApproval: Sendable, Equatable, Identifiable {
    public struct Option: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable { case allowOnce = "allow_once", allowAlways = "allow_always", rejectOnce = "reject_once", rejectAlways = "reject_always" }
        public let id: String
        public let name: String
        public let kind: Kind
        public init(id: String, name: String, kind: Kind) { self.id = id; self.name = name; self.kind = kind }
        public var allows: Bool { kind == .allowOnce || kind == .allowAlways }
    }
    public let id: String
    public let title: String
    /// The exact thing being approved: the message text, the command, the file change.
    public let detail: String?
    public let options: [Option]
    public init(id: String, title: String, detail: String?, options: [Option]) {
        self.id = id; self.title = title; self.detail = detail; self.options = options
    }
}

public enum AgentEvent: Sendable {
    /// Visible answer text, to append.
    case text(String)
    /// A tool started or changed state; the same id repeats as it progresses.
    case tool(AgentToolActivity)
    case approval(AgentApproval)
    case approvalResolved(id: String, allowed: Bool)
    /// Structured results the local engine can show directly (file matches, review cards).
    case receipts([CapabilityReceipt])
    case finished(stopReason: String)
}

/// Why a turn failed, in words fit for the screen.
public enum AgentFailure: LocalizedError, Sendable, Equatable {
    case setup(AgentSetupIssue)
    case offline(String)
    case failed(String)
    public var errorDescription: String? {
        switch self {
        case .setup(let issue): return issue.title + ". " + issue.detail
        case .offline(let reason): return reason
        case .failed(let reason): return reason
        }
    }
}
