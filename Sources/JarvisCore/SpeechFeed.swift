import Foundation

/// Hands an answer that is still being written to the voice a finished sentence at a time, so
/// speech starts before the agent is done. Only text up to the last sentence end or line end is
/// cleaned and split; the tail waits for more text or `finish`. Cleanup is `SpeechText.spoken`.
public struct SpeechFeed: Sendable {
    private var source = ""
    private var boundary = 0
    private var handedOut = 0
    private var total = 0
    private var started = false
    private let limit: Int
    /// Fragments shorter than this ("1.", "Mr.") wait for the next sentence unless the answer is done.
    static let minimumChunk = 12

    public init(limit: Int = 2200) { self.limit = limit }

    /// Call with the whole answer so far. Returns chunks ready to synthesize, in order.
    public mutating func update(_ text: String) -> [String] {
        restartIfNeeded(text)
        source = text
        let ready = Self.readyLength(of: text)
        guard ready > boundary else { return [] }
        boundary = ready
        return take(SpeechText.spoken(from: String(text.prefix(ready)), limit: .max), final: false)
    }

    /// Call once with the final answer. Returns whatever is left to say.
    public mutating func finish(_ text: String) -> [String] {
        restartIfNeeded(text)
        source = text; boundary = text.count
        return take(SpeechText.spoken(from: text, limit: .max), final: true)
    }

    /// A reply that no longer extends what was seen (a new agent turn, or a canned final message)
    /// starts over. What was already said stays said.
    private mutating func restartIfNeeded(_ text: String) {
        guard !text.hasPrefix(source) else { return }
        source = ""; boundary = 0; handedOut = 0
    }

    private mutating func take(_ cleaned: String, final: Bool) -> [String] {
        guard total < limit, cleaned.count > handedOut else { return [] }
        var pending = String(cleaned.dropFirst(handedOut)).trimmingCharacters(in: .whitespaces)
        guard final || pending.count >= Self.minimumChunk else { return [] }
        handedOut = cleaned.count
        if total + pending.count > limit { pending = SpeechText.truncated(pending, limit: limit - total) }
        guard !pending.isEmpty else { return [] }
        total += pending.count
        let chunks = SpeechText.sentences(from: pending, firstTarget: started ? 160 : 60)
        started = started || !chunks.isEmpty
        return chunks
    }

    /// Length of the prefix that ends at a line break, or at a sentence end followed by a space.
    /// A period after a digit ("1. ", "3. ") is a list marker, not a sentence end.
    static func readyLength(of text: String) -> Int {
        let characters = Array(text)
        var ready = 0
        for index in characters.indices {
            let character = characters[index]
            if character == "\n" { ready = index + 1; continue }
            guard character == " " || character == "\t", index > 0 else { continue }
            var end = index - 1
            if "\"'”’)".contains(characters[end]), end > 0 { end -= 1 }
            guard ".!?".contains(characters[end]) else { continue }
            if characters[end] == ".", end > 0, characters[end - 1].isNumber { continue }
            ready = index + 1
        }
        return ready
    }
}
