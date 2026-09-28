import Foundation
import DaisyCore

/// The recall check (`daisy-check --recall`): its verdicts, and the whole run against scripted
/// stand-ins for hermes-acp. One remembers, so every case passes and the cleanup takes the test back
/// out; the one in HermesTests remembers nothing, so every case fails; one folds the test into an
/// older entry, so the cleanup leaves that file alone.
final class RecallTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("recall-\(UUID().uuidString)")
    var agent: URL { root.appendingPathComponent("fake-hermes-acp") }
    var forgetful: URL { root.appendingPathComponent("forgetful-hermes-acp") }
    var memories: URL { root.appendingPathComponent("memories") }

    func setUp() throws {
        try FileManager.default.createDirectory(at: memories, withIntermediateDirectories: true)
        try Self.fixture.write(to: agent, atomically: true, encoding: .utf8)
        try HermesTests.fixture.write(to: forgetful, atomically: true, encoding: .utf8)
        for script in [agent, forgetful] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path) }
    }
    func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func backend(_ executable: URL, _ environment: [String: String] = [:]) -> HermesBackend {
        HermesBackend(settings: .init(executable: executable, workingDirectory: root, sessionFile: root.appendingPathComponent("session"),
                                      environment: environment.merging(["FAKE_MEMORY": memories.path]) { a, _ in a },
                                      rolesFile: root.appendingPathComponent("roles.json")))
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    func testVerdicts() {
        let snack = LearnedRecall.Case(name: "snack", question: "?", expect: ["kumquat"])
        expectTrue(LearnedRecall.verdict(snack, answer: "Candied KUMQUATS, lately.").passed)
        expectEqual(LearnedRecall.verdict(snack, answer: "Pretzels?").reason, "didn't say kumquat")
        expectEqual(LearnedRecall.verdict(snack, answer: "  ").reason, "no answer")
        let bike = LearnedRecall.Case(name: "bike", question: "?", expect: ["Stroopwafel"], forbid: ["Gingersnap"])
        expectTrue(LearnedRecall.verdict(bike, answer: "It's Stroopwafel now.").passed)
        expectEqual(LearnedRecall.verdict(bike, answer: "Stroopwafel, formerly Gingersnap.").reason, "still said Gingersnap")
        let iguana = LearnedRecall.Case(name: "iguana", question: "?", forbid: ["Gingersnap", "Zephyrine"], abstain: true)
        expectTrue(LearnedRecall.verdict(iguana, answer: "You haven’t told me about an iguana.").passed)
        expectTrue(LearnedRecall.verdict(iguana, answer: "I don't know its name.").passed)
        expectFalse(LearnedRecall.verdict(iguana, answer: "Your iguana is called Spike.").passed)
        expectEqual(LearnedRecall.verdict(iguana, answer: "I don't know, maybe Gingersnap?").reason, "made something up (Gingersnap)")
        // Accents and case don't matter either way.
        let cousin = LearnedRecall.Case(name: "cousin", question: "?", expect: ["Seraphina"])
        expectTrue(LearnedRecall.verdict(cousin, answer: "SÉRAPHINA plays it.").passed)
    }

    func testPlanUsesFreshMadeUpWords() {
        var generator = Seeded(state: 7)
        let plan = LearnedRecall.plan(using: &generator)
        expectEqual(plan.cases.map(\.name), ["said in passing", "asked to remember", "correction", "never told"])
        expectEqual(plan.teach.count, 6)
        expectEqual(Set(plan.markers).count, 4)
        // The bike's old name is taught but shouldn't stay in memory.
        expectEqual(plan.saved, [plan.markers[0], plan.markers[1], plan.markers[3]])
        expectTrue(plan.teach[5].contains(plan.markers[2]) && plan.teach[5].contains(plan.markers[3]))
        // "Remember" only comes after the one said in passing and the two plain questions.
        expectFalse(plan.teach.prefix(3).contains { $0.lowercased().contains("remember") })
        expectEqual(plan.cases[2].forbid, [plan.markers[2]])
        var again = Seeded(state: 7)
        expectEqual(LearnedRecall.plan(using: &again), plan)
    }

    func testEveryCasePassesWhenItRemembersAndTheTestComesBackOut() async throws {
        try Data("Is in high school".utf8).write(to: memories.appendingPathComponent("USER.md"))
        let hermes = backend(agent)
        let lines = Lines()
        var generator = Seeded(state: 42)
        let plan = LearnedRecall.plan(using: &generator)
        let report = await LearnedRecall.run(plan, backend: hermes, memory: HermesMemoryFiles(directory: memories), settle: 5) { lines.add($0) }
        await hermes.shutdown()
        expectEqual(report.problem, nil)
        expectEqual(report.outcomes.map(\.passed), [true, true, true, true])
        expectTrue(report.passed)
        expectEqual(lines.all.filter { $0.hasPrefix("PASS") }.count, 4)
        expectEqual(report.cleaned.count, 3)
        expectEqual(report.leftAlone, [])
        try expectEqual(String(contentsOf: memories.appendingPathComponent("USER.md"), encoding: .utf8), "Is in high school")
    }

    func testEveryCaseFailsAgainstAStandInThatRemembersNothing() async {
        let hermes = backend(forgetful)
        let lines = Lines()
        let report = await LearnedRecall.run(LearnedRecall.plan(), backend: hermes, memory: nil, settle: 0) { lines.add($0) }
        await hermes.shutdown()
        expectEqual(report.problem, nil)
        expectEqual(report.outcomes.map(\.passed), [false, false, false, false])
        expectFalse(report.passed)
        expectEqual(report.outcomes.last?.reason, "answered instead of saying it didn't know")
        expectEqual(lines.all.filter { $0.hasPrefix("FAIL") }.count, 4)
    }

    func testCleanupLeavesAFileAloneWhenTheTestWasFoldedIntoAnOlderEntry() async throws {
        try Data("Is in high school\n§\nPlays tennis".utf8).write(to: memories.appendingPathComponent("USER.md"))
        let hermes = backend(agent, ["FAKE_MODE": "merge"])
        let report = await LearnedRecall.run(LearnedRecall.plan(), backend: hermes, memory: HermesMemoryFiles(directory: memories), settle: 5) { _ in }
        await hermes.shutdown()
        let user = try String(contentsOf: memories.appendingPathComponent("USER.md"), encoding: .utf8)
        expectTrue(user.hasPrefix("Is in high school "))
        expectTrue(user.hasSuffix("\n§\nPlays tennis"))
        expectEqual(report.cleaned, [])
        expectEqual(report.leftAlone.count, 1)
        expectTrue(report.leftAlone.first?.hasPrefix("Is in high school ") ?? false)
    }

    func testNoHermesMeansItCantRun() async {
        let missing = backend(root.appendingPathComponent("nope"))
        let report = await LearnedRecall.run(LearnedRecall.plan(), backend: missing, memory: nil, settle: 0) { _ in }
        expectTrue(report.problem != nil)
        expectTrue(report.outcomes.isEmpty)
        expectFalse(report.passed)
    }

    /// A stand-in for hermes-acp with a memory: what it's told goes into $FAKE_MEMORY/USER.md in
    /// Hermes's format, and a new session answers from that file. FAKE_MODE=merge folds every fact
    /// into the first entry instead.
    static let fixture = #"""
    #!/usr/bin/python3
    import json, os, re, sys
    out = sys.stdout
    memory = os.path.join(os.environ["FAKE_MEMORY"], "USER.md")
    mode = os.environ.get("FAKE_MODE", "remember")
    def send(obj):
        out.write(json.dumps(obj) + "\n"); out.flush()
    def chunk(sid, text):
        send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {
              "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}})
    def entries():
        try:
            raw = open(memory, encoding="utf-8").read()
        except FileNotFoundError:
            return []
        return [e.strip() for e in raw.split("\n§\n") if e.strip()]
    def remember(fact, replacing=None):
        items = entries()
        if mode == "merge" and items:
            items[0] = items[0] + " " + fact
        elif replacing:
            items = [fact if replacing in e else e for e in items]
        else:
            items.append(fact)
        open(memory, "w", encoding="utf-8").write("\n§\n".join(items))
    def find(word):
        return next((e for e in entries() if word.lower() in e.lower()), None)
    counter = 0
    for line in iter(sys.stdin.readline, ""):
        msg = json.loads(line)
        method, mid, params = msg.get("method"), msg.get("id"), msg.get("params", {})
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": 1, "agentCapabilities": {"loadSession": True},
                  "authMethods": [{"id": "openai-codex", "name": "openai-codex runtime credentials"}]}})
        elif method == "session/new":
            counter += 1
            send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": "s-%d" % counter,
                  "models": {"currentModelId": "openai-codex:gpt-test", "availableModels": []}, "modes": {}}})
        elif method == "session/prompt":
            sid = params["sessionId"]
            text = next((b.get("text", "") for b in params["prompt"] if b.get("type") == "text"), "")
            reply = "Got it."
            teach = re.search(r"go-to snack lately is (.+)\.$", text)
            cousin = re.search(r"my cousin (\w+) plays the (.+)\.$", text)
            bike = re.search(r"my bike is named (\w+)\.$", text)
            renamed = re.search(r"It's (\w+) now, not (\w+)\.$", text)
            if teach:
                remember("Josh's go-to snack lately is %s." % teach.group(1))
            elif cousin:
                remember("Josh's cousin %s plays the %s." % cousin.groups())
            elif bike:
                remember("Josh's bike is named %s." % bike.group(1))
            elif renamed:
                remember("Josh's bike is named %s." % renamed.group(1), replacing=renamed.group(2))
            elif "17 times 23" in text:
                reply = "391."
            elif "1976" in text:
                reply = "A Sunday."
            elif "snack" in text:
                reply = find("snack") or "I don't know."
            elif re.search(r"cousin (\w+) play", text):
                reply = find(re.search(r"cousin (\w+) play", text).group(1)) or "I'm not sure."
            elif "bike" in text:
                reply = find("bike") or "You haven't told me."
            elif "iguana" in text:
                reply = "You haven't told me about an iguana."
            chunk(sid, reply)
            send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
        elif mid is not None and method is not None:
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "Method not found"}})
    """#
}
