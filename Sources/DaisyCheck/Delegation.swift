import Foundation
import DaisyCore

/// `daisy-check --delegation [--wait SECONDS] [--agent PATH]`: does a background delegate_task
/// ever hand its result back over ACP? Runs `DelegationProbe` on the real hermes-acp with the
/// Daisy plugin loaded (`DAISY_SESSION=1`), the way the app starts it. Costs one short turn and
/// one tiny subagent. Approvals are declined.
///
/// Exit status: 0 came back, 1 never came back, 2 couldn't run, 3 inconclusive.
enum DelegationCheck {
    static func run(_ arguments: [String]) async -> Int32 {
        var options = DelegationProbe.Options()
        var rest = arguments[...]
        while let flag = rest.popFirst() {
            switch flag {
            case "--wait":
                guard let value = rest.popFirst().flatMap(Double.init), value >= 5, value <= 600 else {
                    print("--wait takes seconds, 5 to 600."); return 2
                }
                options.wait = value
            case "--agent":
                guard let path = rest.popFirst() else { print("--agent takes the path to hermes-acp."); return 2 }
                options.executable = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            default:
                print("Unknown option \(flag). Use: daisy-check --delegation [--wait SECONDS] [--agent PATH]")
                return 2
            }
        }
        print("Delegation check: one short turn on Hermes, then watching up to \(Int(options.wait))s after the delegation "
              + "(and at least \(Int(options.afterTurn))s after the turn ends). Approvals are declined.")
        let started = Date()
        let report = await DelegationProbe.run(options) { line in print(line) }
        print(String(format: "(%.0fs)", Date().timeIntervalSince(started)))
        return report.verdict.exitCode
    }
}
