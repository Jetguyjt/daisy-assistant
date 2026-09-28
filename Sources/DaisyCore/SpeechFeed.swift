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
    /// How much of the source the chunks handed out so far came from.
    private var covered = 0
    private let limit: Int
    /// One entry per chunk handed out, in order: how much of the source text (in characters) can
    /// be on screen once that chunk starts playing, so the transcript keeps pace with the voice.
    /// `Int.max` means all of it (the voice stops there, so the rest shows with it).
    public private(set) var reveals: [Int] = []
    /// Fragments shorter than this ("1.", "Ok.") wait for the next sentence unless the answer is done.
    static let minimumChunk = 12
    /// Once the voice is talking, a short sentence ("Found it.") waits to go out with the next one,
    /// since it sounds clipped on its own. `flush` sends it anyway when the agent stops to work.
    static let minimumFollowUp = SpeechText.shortFragment

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

    /// Call when the agent pauses mid-answer (a tool starts). Returns every finished sentence
    /// still waiting, however short, so "Let me check." is said before the tool runs.
    public mutating func flush(_ text: String) -> [String] {
        restartIfNeeded(text)
        source = text
        boundary = max(boundary, Self.readyLength(of: text))
        return take(SpeechText.spoken(from: String(text.prefix(boundary)), limit: .max), final: true)
    }

    /// Call once with the final answer. Returns whatever is left to say.
    public mutating func finish(_ text: String) -> [String] {
        restartIfNeeded(text)
        source = text; boundary = text.count
        return take(SpeechText.spoken(from: text, limit: .max), final: true)
    }

    /// A reply that no longer extends what was seen (a new agent turn, or a canned final message)
    /// starts over. What was already said stays said. Whitespace at either end doesn't count, so the
    /// finished answer trimmed of its last newline is still the same reply, not a new one to say again.
    private mutating func restartIfNeeded(_ text: String) {
        guard !text.hasPrefix(source) else { return }
        let seen = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(seen) else { return }
        source = ""; boundary = 0; handedOut = 0; covered = 0
    }

    private mutating func take(_ cleaned: String, final: Bool) -> [String] {
        guard total < limit, cleaned.count > handedOut else { return [] }
        var pending = String(cleaned.dropFirst(handedOut)).trimmingCharacters(in: .whitespaces)
        guard final || pending.count >= (started ? Self.minimumFollowUp : Self.minimumChunk) else { return [] }
        handedOut = cleaned.count
        let cut = total + pending.count > limit
        if cut { pending = SpeechText.truncated(pending, limit: limit - total) }
        guard !pending.isEmpty else { return [] }
        total += pending.count
        let chunks = SpeechText.sentences(from: pending, firstTarget: started ? 160 : 60)
        started = started || !chunks.isEmpty
        mark(chunks, through: cut ? Int.max : boundary)
        return chunks
    }

    /// Shares out the source text these chunks came from: each chunk reveals up to the sentence or
    /// line end nearest its share of the spoken words, and the last one everything up to `end`.
    private mutating func mark(_ chunks: [String], through end: Int) {
        guard !chunks.isEmpty else { return }
        let characters = Array(source)
        let stop = min(end, characters.count)
        let lineEnds = characters.indices.filter { characters[$0] == "\n" }.map { $0 + 1 }
        let stops = Set(SpeechText.sentenceBreaks(in: characters) + lineEnds).filter { $0 > covered && $0 < stop }.sorted()
        let spoken = max(1, chunks.reduce(0) { $0 + $1.count })
        var said = 0, shown = covered
        for chunk in chunks.dropLast() {
            said += chunk.count
            let share = covered + (stop - covered) * said / spoken
            shown = max(shown, stops.first { $0 >= share } ?? stop)
            reveals.append(shown)
        }
        reveals.append(end)
        covered = stop
    }

    /// Length of the prefix that ends at a line break, or at a sentence end followed by a space.
    /// Sentence ends are `SpeechText`'s: a period after a number ("1. " in a list) or after an
    /// abbreviation ("Dr. ", "e.g. ") doesn't count, since what follows changes how it's read.
    static func readyLength(of text: String) -> Int {
        let characters = Array(text)
        var ready = (characters.lastIndex(of: "\n") ?? -1) + 1
        for end in SpeechText.sentenceBreaks(in: characters) where end < characters.count {
            ready = max(ready, end + 1)
        }
        return ready
    }
}
