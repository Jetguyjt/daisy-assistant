import Foundation

/// The recall check behind `daisy-check --recall`: does Daisy remember what it's told, in a new chat?
/// It stands in for "tell it something on day one, ask on day seven".
///
/// - First chat: a few made-up, harmless facts. One said in passing (no "remember") and followed by
///   two plain questions, so Hermes's background review gets its chance; one with "remember that"; and
///   one that's corrected a turn later.
/// - Second chat, a new Hermes session with memory loaded fresh: a question about each, plus one thing
///   it was never told, which it should say it doesn't know.
/// - One PASS or FAIL line per case. Approvals are declined, so nothing is ever sent or changed.
/// - Afterwards the entries it taught come back out of Hermes's memory files, found by made-up words
///   only this run used. If Hermes folded one into an entry that was there before, nothing in that
///   file is touched and the entries are listed to tidy by hand. The two chats stay in Hermes's history.
public enum LearnedRecall {
    public struct Case: Sendable, Equatable {
        public let name: String
        public let question: String
        /// Words the answer has to contain (case and accents don't matter).
        public let expect: [String]
        /// Words it mustn't contain.
        public let forbid: [String]
        /// The answer has to say it doesn't know.
        public let abstain: Bool
        public init(name: String, question: String, expect: [String] = [], forbid: [String] = [], abstain: Bool = false) {
            self.name = name; self.question = question; self.expect = expect; self.forbid = forbid; self.abstain = abstain
        }
    }

    public struct Plan: Sendable, Equatable {
        /// The first chat, in order.
        public let teach: [String]
        public let cases: [Case]
        /// Words only this run used, to find what it taught afterwards.
        public let markers: [String]
        /// The ones that should be in memory after the first chat (not the bike's old name).
        public let saved: [String]
        public init(teach: [String], cases: [Case], markers: [String], saved: [String]) {
            self.teach = teach; self.cases = cases; self.markers = markers; self.saved = saved
        }
    }

    public struct Outcome: Sendable, Equatable {
        public let name: String
        public let passed: Bool
        public let reason: String
        public let answer: String
    }

    public struct Report: Sendable {
        public var outcomes: [Outcome] = []
        /// Entries taken back out of the memory files.
        public var cleaned: [String] = []
        /// Entries with a test word that were left for the user to tidy.
        public var leftAlone: [String] = []
        /// Why it couldn't run at all.
        public var problem: String?
        public var passed: Bool { problem == nil && !outcomes.isEmpty && outcomes.allSatisfy(\.passed) }
    }

    static let cousins = ["Zephyrine", "Odalys", "Thessaly", "Ottoline", "Seraphina", "Wilhelmina", "Philippa", "Rosamund"]
    static let instruments = ["bassoon", "marimba", "harpsichord", "euphonium", "theremin", "vibraphone", "glockenspiel", "sitar"]
    static let snacks = [("candied kumquats", "kumquat"), ("rambutan", "rambutan"), ("jicama sticks", "jicama"),
                         ("kohlrabi chips", "kohlrabi"), ("roasted sunchokes", "sunchoke"), ("salted lupini beans", "lupini")]
    static let bikes = ["Pumpernickel", "Snickerdoodle", "Gingersnap", "Stroopwafel", "Shortbread", "Macaroon", "Biscotti", "Marzipan"]

    /// A fresh set of made-up facts.
    public static func plan<G: RandomNumberGenerator>(using generator: inout G) -> Plan {
        let cousin = cousins.randomElement(using: &generator)!
        let instrument = instruments.randomElement(using: &generator)!
        let snack = snacks.randomElement(using: &generator)!
        let pair = bikes.shuffled(using: &generator).prefix(2)
        let (oldBike, newBike) = (pair.first!, pair.last!)
        return Plan(
            teach: [
                "Random thing, but my go-to snack lately is \(snack.0).",
                "What's 17 times 23?",
                "What day of the week was July 4, 1976?",
                "Remember that my cousin \(cousin) plays the \(instrument).",
                "Also remember that my bike is named \(oldBike).",
                "Wait, I renamed my bike. It's \(newBike) now, not \(oldBike)."
            ],
            cases: [
                Case(name: "said in passing", question: "What's my go-to snack lately?", expect: [snack.1]),
                Case(name: "asked to remember", question: "What instrument does my cousin \(cousin) play?", expect: [instrument]),
                Case(name: "correction", question: "What's my bike called?", expect: [newBike], forbid: [oldBike]),
                Case(name: "never told", question: "What's my pet iguana's name?", forbid: [oldBike, newBike, cousin], abstain: true)
            ],
            markers: [snack.1, cousin, oldBike, newBike],
            saved: [snack.1, cousin, newBike])
    }

    public static func plan() -> Plan {
        var generator = SystemRandomNumberGenerator()
        return plan(using: &generator)
    }

    // MARK: Verdicts

    static let dontKnow = [
        "don't know", "do not know", "not sure", "no idea", "haven't told", "have not told", "didn't tell", "did not tell",
        "never told", "wasn't told", "haven't mentioned", "have not mentioned", "never mentioned", "didn't mention",
        "did not mention", "haven't said", "don't have", "do not have", "no record", "not aware", "don't recall",
        "do not recall", "don't remember", "do not remember", "can't find", "cannot find", "couldn't find", "could not find",
        "no information", "nothing saved", "nothing about", "don't see", "do not see", "not in my memory", "i'm not aware"
    ]

    /// Whether an answer passes, and why, in a few words.
    public static func verdict(_ check: Case, answer: String) -> (passed: Bool, reason: String) {
        let said = normalize(answer)
        guard !said.isEmpty else { return (false, "no answer") }
        if let slip = check.forbid.first(where: { said.contains(normalize($0)) }) {
            return (false, check.abstain ? "made something up (\(slip))" : "still said \(slip)")
        }
        if check.abstain {
            return dontKnow.contains(where: said.contains) ? (true, "said it didn't know")
                : (false, "answered instead of saying it didn't know")
        }
        let missing = check.expect.filter { !said.contains(normalize($0)) }
        return missing.isEmpty ? (true, "remembered \(check.expect.joined(separator: ", "))")
            : (false, "didn't say \(missing.joined(separator: ", "))")
    }

    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Running it

    /// Runs the check on `backend` (a Hermes started the way the app starts it). `memory` is where it
    /// watches for the facts to land and cleans up afterwards; nil skips both. `settle` is how long to
    /// wait for Hermes's background review to save them before the second chat.
    public static func run(_ plan: Plan, backend: AgentBackend, memory: HermesMemoryFiles?, log: URL? = nil,
                           settle: TimeInterval = 120, keep: Bool = false,
                           say: @escaping @Sendable (String) -> Void) async -> Report {
        var report = Report()
        guard case .ready = await backend.connect() else {
            report.problem = "Hermes isn't ready. Run daisy-check --hermes to see why."
            return report
        }
        let before = memory.map(snapshot) ?? [:]
        do {
            say("First chat: telling it a few made-up things.")
            await backend.newSession()
            for prompt in plan.teach {
                say("> " + prompt)
                say("  " + oneLine(try await turn(backend, prompt).text))
            }
            if let memory {
                await wait(for: plan.saved, in: memory, seconds: settle, say: say)
                for marker in plan.markers { say("  \(marker): " + landed(marker, in: memory, log: log)) }
            }
            say("Second chat: asking about them.")
            await backend.newSession()
            for check in plan.cases {
                let answer = try await turn(backend, check.question)
                let verdict = verdict(check, answer: answer.text)
                let lookedUp = answer.searchedPastChats ? " (looked through past chats)" : ""
                report.outcomes.append(Outcome(name: check.name, passed: verdict.passed, reason: verdict.reason + lookedUp, answer: answer.text))
                say("> " + check.question)
                say("  " + oneLine(answer.text))
                say("\(verdict.passed ? "PASS" : "FAIL") \(check.name): \(verdict.reason)\(lookedUp)")
            }
        } catch {
            report.problem = "The check stopped: \(error.localizedDescription)"
        }
        if let memory, !keep { clean(plan.markers, in: memory, before: before, report: &report) }
        return report
    }

    struct Answer { var text = ""; var searchedPastChats = false }

    static func turn(_ backend: AgentBackend, _ prompt: String) async throws -> Answer {
        var answer = Answer()
        for try await event in backend.send(prompt) {
            switch event {
            case .text(let delta): answer.text += delta
            case .tool(let tool): if tool.title == "Searching past conversations" { answer.searchedPastChats = true }
            case .approval(let request): await backend.resolve(approval: request.id, optionID: nil)
            default: break
            }
        }
        return answer
    }

    static func oneLine(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > 240 ? String(flat.prefix(240)) + "…" : flat
    }

    static func snapshot(_ memory: HermesMemoryFiles) -> [HermesMemory.Target: [String]] {
        var entries: [HermesMemory.Target: [String]] = [:]
        for target in HermesMemory.Target.allCases { entries[target] = (try? memory.entries(target)) ?? [] }
        return entries
    }

    static func mentions(_ entry: String, _ marker: String) -> Bool {
        entry.range(of: marker, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Waits until every word shows up in the memory files, or the time's up.
    static func wait(for markers: [String], in memory: HermesMemoryFiles, seconds: TimeInterval,
                     say: @Sendable (String) -> Void) async {
        guard seconds > 0 else { return }
        say("Waiting up to \(Int(seconds))s for Hermes to save them…")
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let entries = snapshot(memory).values.flatMap { $0 }
            if markers.allSatisfy({ marker in entries.contains { mentions($0, marker) } }) { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    /// Where a made-up word ended up, and who put it there.
    static func landed(_ marker: String, in memory: HermesMemoryFiles, log: URL?) -> String {
        let place = HermesMemory.Target.allCases.first { target in ((try? memory.entries(target)) ?? []).contains { mentions($0, marker) } }
        guard let place else { return "not in memory" }
        let record = log.map(LearnedLog.read)?.last { $0.target == place && ($0.entry.map { mentions($0, marker) } ?? false) }
        let who = record.map { $0.onItsOwn ? "saved by Hermes on its own (\($0.origin))" : "saved in the chat" } ?? "no log line"
        return "in \(place.fileName), \(who)"
    }

    /// Takes out what this run taught: entries with one of its words that weren't there before. A file
    /// where an entry from before went missing during the run is left alone; Hermes may have folded the
    /// test into it.
    static func clean(_ markers: [String], in memory: HermesMemoryFiles, before: [HermesMemory.Target: [String]], report: inout Report) {
        for target in HermesMemory.Target.allCases {
            let earlier = before[target] ?? []
            var removed: [String] = []
            var left: [String] = []
            do {
                try memory.edit(target) { entries in
                    removed = []; left = []
                    let ours = entries.filter { entry in
                        markers.contains { mentions(entry, $0) } && !earlier.contains { HermesMemory.same($0, entry) }
                    }
                    guard !ours.isEmpty else { return }
                    let lost = earlier.contains { old in !entries.contains { HermesMemory.same($0, old) } }
                    if lost { left = ours; return }
                    removed = ours
                    entries.removeAll { entry in ours.contains { HermesMemory.same($0, entry) } }
                }
                report.cleaned += removed
                report.leftAlone += left
            } catch {
                report.leftAlone += ((try? memory.entries(target)) ?? []).filter { entry in markers.contains { mentions(entry, $0) } }
            }
        }
    }
}
