import Foundation
import DaisyCore

/// `daisy-check --recall [--settle SECONDS] [--keep] [--agent PATH]`: does Daisy remember what it was
/// told, in a new chat? Runs `LearnedRecall` on the real hermes-acp with the Daisy plugin loaded
/// (`DAISY_SESSION=1`), the way the app starts it: two short chats, ten turns in all. It puts a few
/// made-up facts into Hermes's memory and takes them back out at the end (`--keep` leaves them).
/// `--settle` is how long to wait for Hermes's background review before the second chat. Approvals
/// are declined.
///
/// Exit status: 0 every case passed, 1 one failed, 2 couldn't run.
enum RecallCheck {
    static func run(_ arguments: [String]) async -> Int32 {
        var settle: TimeInterval = 120
        var keep = false
        var executable: URL?
        var rest = arguments[...]
        while let flag = rest.popFirst() {
            switch flag {
            case "--settle":
                guard let value = rest.popFirst().flatMap(Double.init), value >= 0, value <= 900 else {
                    print("--settle takes seconds, 0 to 900."); return 2
                }
                settle = value
            case "--keep":
                keep = true
            case "--agent":
                guard let path = rest.popFirst() else { print("--agent takes the path to hermes-acp."); return 2 }
                executable = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            default:
                print("Unknown option \(flag). Use: daisy-check --recall [--settle SECONDS] [--keep] [--agent PATH]")
                return 2
            }
        }
        let session = FileManager.default.temporaryDirectory.appendingPathComponent("daisy-check-recall-session")
        let hermes = HermesBackend(settings: .init(executable: executable, workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
                                                   sessionFile: session, environment: ["DAISY_SESSION": "1"]))
        print("Recall check: made-up facts in one chat, questions in a new one. About ten turns on Hermes; approvals are declined.")
        let started = Date()
        let report = await LearnedRecall.run(LearnedRecall.plan(), backend: hermes, memory: .standard(), log: LearnedLog.standardURL,
                                             settle: settle, keep: keep) { line in print(line) }
        await hermes.shutdown()
        try? FileManager.default.removeItem(at: session)
        if let problem = report.problem { print("COULD NOT RUN: \(problem)") }
        if !report.cleaned.isEmpty { print("Took \(report.cleaned.count) test \(report.cleaned.count == 1 ? "entry" : "entries") back out of Hermes's memory.") }
        if !report.leftAlone.isEmpty {
            print("Left alone (Hermes may have mixed the test into something older); tidy these in the Memory tab:")
            for entry in report.leftAlone { print("  - \(entry)") }
        }
        if keep { print("--keep: the test facts are still in Hermes's memory.") }
        print("The two check chats stay in Hermes's history.")
        let passed = report.outcomes.filter(\.passed).count
        print(String(format: "%d of %d passed (%.0fs)", passed, report.outcomes.count, Date().timeIntervalSince(started)))
        return report.problem != nil ? 2 : (report.passed ? 0 : 1)
    }
}
