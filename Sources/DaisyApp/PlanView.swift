import SwiftUI
import DaisyCore

/// The agent's plan as a short checklist: done, doing now, still to do. Dropped items stay on the
/// list, struck through, the way Hermes keeps them.
struct PlanView: View {
    let plan: AgentPlan
    var limit = 8

    var body: some View {
        let kept = plan.entries.filter { !$0.cancelled }.count
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("PLAN").hudCaption()
                Spacer()
                Text("\(plan.completed)/\(kept)").font(HUD.readout(9.5)).foregroundStyle(HUD.dim).monospacedDigit()
            }
            ForEach(plan.entries.prefix(limit)) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    icon(entry).font(.system(size: 10)).frame(width: 12)
                    Text(entry.content)
                        .font(.system(size: 11.5))
                        .foregroundStyle(entry.status == .inProgress ? HUD.ice : entry.status == .completed ? HUD.dim : HUD.steel)
                        .strikethrough(entry.cancelled, color: HUD.dim)
                        .lineLimit(2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(entry.content + ", " + spoken(entry))
            }
            if plan.entries.count > limit {
                Text("+\(plan.entries.count - limit) more").font(.system(size: 10.5)).foregroundStyle(HUD.dim)
            }
        }
    }

    @ViewBuilder private func icon(_ entry: AgentPlan.Entry) -> some View {
        if entry.cancelled {
            Image(systemName: "minus.circle").foregroundStyle(HUD.dim)
        } else {
            switch entry.status {
            case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(HUD.accent)
            case .inProgress: Image(systemName: "circle.lefthalf.filled").foregroundStyle(HUD.accent)
            case .pending: Image(systemName: "circle").foregroundStyle(HUD.dim)
            }
        }
    }

    private func spoken(_ entry: AgentPlan.Entry) -> String {
        if entry.cancelled { return "dropped" }
        switch entry.status {
        case .completed: return "done"
        case .inProgress: return "in progress"
        case .pending: return "to do"
        }
    }
}
