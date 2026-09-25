import Foundation

/// JSON values, not arbitrary executable code, cross the model/provider boundary.
public indirect enum JSONValue: Codable, Sendable, Equatable, ExpressibleByStringLiteral {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null
    public init(stringLiteral value: String) { self = .string(value) }
    public var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public func json() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

/// Small strict JSON-schema vocabulary. Provider schemas are also runtime validators.
public indirect enum ValueSchema: Sendable {
    case string(maxLength: Int), number, boolean, choice([String])
    case array(ValueSchema, maxItems: Int)
    case object(properties: [String: ValueSchema], required: Set<String>)
    public var json: JSONValue {
        switch self {
        case .string(let limit): return .object(["type": "string", "maxLength": .number(Double(limit))])
        case .number: return .object(["type": "number"])
        case .boolean: return .object(["type": "boolean"])
        case .choice(let values): return .object(["type": "string", "enum": .array(values.map(JSONValue.string))])
        case .array(let item, let limit): return .object(["type": "array", "items": item.json, "maxItems": .number(Double(limit))])
        case .object(let properties, let required): return .object([
            "type": "object", "properties": .object(properties.mapValues(\.json)),
            "required": .array(required.sorted().map(JSONValue.string)), "additionalProperties": .bool(false)
        ])
        }
    }
    public func validate(_ value: JSONValue, depth: Int = 0) throws {
        guard depth < 12 else { throw JarvisError.message("Arguments exceed the nesting limit.") }
        switch (self, value) {
        case (.string(let max), .string(let v)) where v.count <= max: return
        case (.number, .number(let v)) where v.isFinite: return
        case (.boolean, .bool): return
        case (.choice(let allowed), .string(let v)) where allowed.contains(v): return
        case (.array(let schema, let limit), .array(let items)) where items.count <= limit:
            for item in items { try schema.validate(item, depth: depth + 1) }; return
        case (.object(let fields, let required), .object(let values)):
            guard required.isSubset(of: Set(values.keys)), Set(values.keys).isSubset(of: Set(fields.keys)) else {
                throw JarvisError.message("Missing or unexpected capability arguments.")
            }
            for (key, value) in values { try fields[key]!.validate(value, depth: depth + 1) }; return
        default: throw JarvisError.message("Capability argument type or value is invalid.")
        }
    }
}

public enum CapabilityEffect: String, Sendable { case readOnly, preparesChanges, changesData, communicatesExternally }
/// Created by trusted provider code. Model output cannot invoke its commit closure.
public struct ReviewedAction: Identifiable, Sendable {
    public let id = UUID()
    public let title: String
    public let preview: String
    public let commit: @Sendable () async throws -> String
    public init(title: String, preview: String, commit: @escaping @Sendable () async throws -> String) {
        self.title = title; self.preview = preview; self.commit = commit
    }
}
public struct CapabilityDefinition: Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let title: String
    public let provider: String
    public let description: String
    public let parameters: ValueSchema
    public let effect: CapabilityEffect
    public init(name: String, title: String, provider: String, description: String,
                parameters: ValueSchema, effect: CapabilityEffect = .readOnly) {
        self.name = name; self.title = title; self.provider = provider; self.description = description
        self.parameters = parameters; self.effect = effect
    }
    public var modelSchema: JSONValue { .object(["type": "function", "function": .object([
        "name": .string(name), "description": .string(description), "parameters": parameters.json
    ])]) }
}
public struct CapabilityOutput: Sendable {
    public let summary: String
    public let data: JSONValue
    public let files: SearchReport?
    public let review: ReviewedAction?
    public init(summary: String, data: JSONValue = .null, files: SearchReport? = nil, review: ReviewedAction? = nil) {
        self.summary = summary; self.data = data; self.files = files; self.review = review
    }
}
public struct Capability: Sendable {
    public let definition: CapabilityDefinition
    public let unavailableReason: String?
    public let execute: @Sendable ([String: JSONValue]) async throws -> CapabilityOutput
    public init(_ definition: CapabilityDefinition, unavailableReason: String? = nil,
                execute: @escaping @Sendable ([String: JSONValue]) async throws -> CapabilityOutput) {
        self.definition = definition; self.unavailableReason = unavailableReason; self.execute = execute
    }
}

/// Adapters supply capabilities. The agent, transport and UI never switch on provider names.
public protocol CapabilityProvider: Sendable {
    func capabilities() -> [Capability]
}
public struct CapabilityRegistry: Sendable {
    public let entries: [Capability]
    public init(providers: [any CapabilityProvider]) throws { try self.init(capabilities: providers.flatMap { $0.capabilities() }) }
    public init(capabilities: [Capability]) throws {
        var seen = Set<String>()
        for entry in capabilities {
            let name = entry.definition.name
            guard name.range(of: "^[a-z][a-z0-9_]{0,63}$", options: .regularExpression) != nil, seen.insert(name).inserted else {
                throw JarvisError.message("Invalid or duplicate capability registration: \(name)")
            }
        }
        entries = capabilities
    }
    public var modelDefinitions: [CapabilityDefinition] {
        entries.filter { $0.unavailableReason == nil && [.readOnly, .preparesChanges].contains($0.definition.effect) }.map(\.definition)
    }
    public var catalogue: String {
        entries.map { "\($0.definition.title): \($0.unavailableReason ?? ($0.definition.effect == .readOnly ? "available" : $0.definition.effect == .preparesChanges ? "prepare only; user reviews and applies" : "execution unavailable"))" }.joined(separator: "\n")
    }
}

public struct CapabilityReceipt: Identifiable, Sendable {
    public enum Status: String, Sendable { case succeeded, blocked, failed }
    public let id: UUID
    public let tool: String
    public let title: String
    public let status: Status
    public let output: CapabilityOutput
    public var modelMessage: ChatMessage {
        let evidence = JSONValue.object(["status": .string(status.rawValue), "summary": .string(output.summary), "data": output.data])
        let full = (try? evidence.json()) ?? "{\"status\":\"failed\"}"
        let text = full.utf8.count <= 5000 ? full : ((try? JSONValue.object([
            "status": .string(status.rawValue), "summary": .string(String(output.summary.prefix(500))),
            "detail": "Large result omitted. Ask for a narrower request."
        ]).json()) ?? "{}")
        return ChatMessage(role: "tool", content: text, toolName: tool)
    }
}

/// Per-request execution ledger. The model cannot supply permission or bypass validation.
/// Effectful adapters fail closed until an explicit review/commit pathway is implemented.
public actor CapabilitySession {
    public let registry: CapabilityRegistry
    private var completed: [String: CapabilityReceipt] = [:]
    private var inFlight = Set<String>()
    private var ledger: [CapabilityReceipt] = []
    public init(registry: CapabilityRegistry) { self.registry = registry }
    public func receipts() -> [CapabilityReceipt] { ledger }
    public func execute(_ call: ToolCall) async throws -> CapabilityReceipt {
        try Task.checkCancellation()
        let key = call.function.name + ":" + (try JSONValue.object(call.function.arguments).json())
        if let previous = completed[key] { return previous }
        guard !inFlight.contains(key) else { throw JarvisError.message("This operation is already in progress.") }
        inFlight.insert(key); defer { inFlight.remove(key) }
        let capability = registry.entries.first { $0.definition.name == call.function.name }
        let title = capability?.definition.title ?? call.function.name
        func result(_ status: CapabilityReceipt.Status, _ output: CapabilityOutput) -> CapabilityReceipt {
            let receipt = CapabilityReceipt(id: UUID(), tool: call.function.name, title: title, status: status, output: output)
            completed[key] = receipt; ledger.append(receipt); return receipt
        }
        guard let capability else { return result(.blocked, .init(summary: "Unregistered capability. No action was performed.")) }
        if let reason = capability.unavailableReason { return result(.blocked, .init(summary: reason + " No action was performed.")) }
        guard [.readOnly, .preparesChanges].contains(capability.definition.effect) else {
            return result(.blocked, .init(summary: "This action requires an explicit reviewed commit. That pathway is not implemented; nothing was changed or sent."))
        }
        do {
            guard key.utf8.count <= 12000 else { throw JarvisError.message("Capability arguments are too large.") }
            try capability.definition.parameters.validate(.object(call.function.arguments))
            try Task.checkCancellation()
            let output = try await capability.execute(call.function.arguments)
            try Task.checkCancellation()
            return result(.succeeded, output)
        } catch is CancellationError { throw CancellationError() }
        catch let error as JarvisError { return result(.failed, .init(summary: error.localizedDescription)) }
        catch { return result(.failed, .init(summary: "The capability failed. No successful result was confirmed.")) }
    }
}
