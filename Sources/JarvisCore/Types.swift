import Foundation
import CryptoKit

public enum JarvisError: LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let text): return text } }
}

public struct Configuration: Codable, Sendable {
    public var model = "qwen3.5:4b"
    public var whisperExecutable = "/opt/homebrew/bin/whisper-cli"
    public var whisperModel = ""
    public var ollamaExecutable = "/opt/homebrew/bin/ollama"
    public var ollamaModels = ""
    public var speakResponses = true
    public var allowFileSearch = true
    // Optional for backwards-compatible decoding of existing settings.
    public var capabilityPermissions: [String: Bool]?
    public var voice = "Samantha"
    public var naturalVoice: String?
    public var speechRate: Double?
    public var browserNode: String?
    /// manual, handsFree or wakeWord. Optional so settings saved before it existed still decode.
    public var listeningMode: String?
    public init() {}

    public static var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jarvis", isDirectory: true)
    }
    public static func load() throws -> Configuration {
        let saved = dataDirectory.appendingPathComponent("config.json")
        if FileManager.default.fileExists(atPath: saved.path) {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: saved))
        }
        if let bundled = Bundle.main.url(forResource: "RuntimeDefaults", withExtension: "json") {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: bundled))
        }
        return Self()
    }
    public func save() throws {
        try FileManager.default.createDirectory(at: Self.dataDirectory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let url = Self.dataDirectory.appendingPathComponent("config.json")
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public struct Memory: Identifiable, Codable, Sendable, Equatable {
    public var id: String { key }
    public let key: String
    public let value: String
    public let source: String
    public let updatedAt: Date
    public let revision: Int
    public init(key: String, value: String, source: String, updatedAt: Date, revision: Int) {
        self.key = key; self.value = value; self.source = source; self.updatedAt = updatedAt; self.revision = revision
    }
}

public struct MemoryCommand: Equatable {
    public let key: String
    public let value: String
    public static func parse(_ text: String) throws -> Self? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("/remember ") {
            let body = String(text.dropFirst(10))
            guard let equal = body.firstIndex(of: "=") else {
                throw JarvisError.message("Use /remember key = value. Reuse a key to correct a memory.")
            }
            return try validated(key: String(body[..<equal]), value: String(body[body.index(after: equal)...]))
        }
        if text.lowercased().hasPrefix("remember that ") {
            let value = String(text.dropFirst(14)).trimmingCharacters(in: .whitespacesAndNewlines)
            let digest = SHA256.hash(data: Data(value.lowercased().utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
            return try validated(key: "note.\(digest)", value: value)
        }
        return nil
    }
    private static func validated(key: String, value: String) throws -> Self {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= 80, !value.isEmpty, value.count <= 2000 else {
            throw JarvisError.message("Memory needs a key (1–80 characters) and a value (1–2,000 characters).")
        }
        return Self(key: key, value: value)
    }
}

public struct ChatMessage: Codable, Sendable {
    public let role: String
    public var content: String
    public var tool_calls: [ToolCall]?
    public var tool_name: String?
    public init(role: String, content: String, toolCalls: [ToolCall]? = nil, toolName: String? = nil) {
        self.role = role; self.content = content; self.tool_calls = toolCalls; self.tool_name = toolName
    }
}
public struct ToolCall: Codable, Sendable {
    public struct Function: Codable, Sendable {
        public let name: String
        public let arguments: [String: JSONValue]
        public init(name: String, arguments: [String: JSONValue]) { self.name = name; self.arguments = arguments }
    }
    public let function: Function
    public init(name: String, arguments: [String: JSONValue]) { function = Function(name: name, arguments: arguments) }
}
