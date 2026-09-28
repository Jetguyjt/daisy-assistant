import SwiftUI
import DaisyCore

/// One line for the telemetry panel: how much of the ChatGPT plan's usage windows is used ("62% of the
/// 5-hour window · 41% of the week"), amber once new background jobs are held back.
struct BudgetReadout: View {
    @ObservedObject var budget: BudgetMonitor

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("USAGE").font(HUD.label(10)).tracking(1.6).foregroundStyle(HUD.dim)
                Text(budget.summary).font(.system(size: 12)).foregroundStyle(held ? HUD.amber : HUD.ice)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let level = budget.level { LevelBars(level: level, bars: 8, color: held ? HUD.amber : HUD.accent) }
        }
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(HUD.line.opacity(0.12)).frame(height: 1) }
        .help(budget.holdReason ?? budget.problem ?? "ChatGPT usage, read through Hermes every ten minutes")
    }

    private var held: Bool { budget.holdReason != nil }
}

/// Under the Start job row while queued jobs are held back (JobsModel.held): why, and a way to run them
/// anyway until the window resets.
struct BudgetHoldNotice: View {
    let reason: String
    let runAnyway: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.67percent").foregroundStyle(HUD.amber)
            Text(reason).font(.system(size: 12)).foregroundStyle(HUD.amber).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Run them anyway", action: runAnyway)
                .buttonStyle(HUDButtonStyle(kind: .ghost, compact: true))
                .help("Queued jobs start again until that window resets")
        }
        .padding(.vertical, 4)
    }
}
