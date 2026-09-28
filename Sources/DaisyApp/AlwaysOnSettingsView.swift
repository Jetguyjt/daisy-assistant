import SwiftUI
import DaisyCore

/// The Setup section for the always-on layer: open at login, click to talk on battery, and holding
/// background jobs near the usage limit.
struct AlwaysOnSettingsSection: View {
    @ObservedObject var loginItem: LoginItem
    @ObservedObject var power: PowerMonitor
    @ObservedObject var budget: BudgetMonitor
    @Binding var clickToTalkOnBattery: Bool
    @Binding var holdJobsNearLimit: Bool
    var usesHermes = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ALWAYS ON").hudCaption(HUD.accent)
            Toggle("Open Daisy at login", isOn: Binding(get: { loginItem.isOn }, set: { loginItem.set($0) }))
                .toggleStyle(.switch)
            note(loginItem.note)
            if loginItem.needsApproval {
                Button("Open Login Items") { loginItem.openSettings() }
                    .buttonStyle(HUDButtonStyle(kind: .ghost, compact: true))
            }
            if let problem = loginItem.problem {
                Text(problem).font(.system(size: 11)).foregroundStyle(HUD.amber).textSelection(.enabled)
            }
            Toggle("Click to talk on battery", isOn: $clickToTalkOnBattery).toggleStyle(.switch)
            note("With the wake word on, the mic stays open, and an open mic keeps the Mac awake. On battery Daisy "
                 + "switches to click to talk, and back to the wake word on the charger."
                 + (power.onBattery ? " Running on battery now." : ""))
            if usesHermes {
                Toggle("Hold background jobs near the usage limit", isOn: $holdJobsNearLimit).toggleStyle(.switch)
                note("ChatGPT usage: \(budget.summary). New background jobs wait once a window is 80% used, "
                     + "so the rest is there for talking; jobs already running finish.")
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Rectangle().fill(HUD.line.opacity(0.09)).frame(height: 1) }
        .onAppear { loginItem.refresh() }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(HUD.dim).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}
