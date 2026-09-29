import SwiftUI
import DaisyCore

/// The approval cards waiting now, oldest first. Pass a source to show one turn's or job's only.
struct ApprovalQueueList: View {
    @ObservedObject var queue: ApprovalQueue
    var source: ApprovalQueue.Source?

    var body: some View {
        ForEach(source.map(queue.items(from:)) ?? queue.items) { item in
            QueuedApprovalCard(queue: queue, item: item).id(item.id)
        }
    }
}

/// A step the agent won't take without a yes, with who asked and how long is left before it
/// counts as no. Only "once" is offered, plus "Yes to all like this" where a grant can cover it.
struct QueuedApprovalCard: View {
    let queue: ApprovalQueue
    let item: ApprovalQueue.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(HUD.amber)
                Text(item.label.map { "JOB · " + $0.uppercased() + " · NEEDS YOUR OK" } ?? "NEEDS YOUR OK")
                    .font(HUD.label(9)).tracking(1.6).foregroundStyle(HUD.amber).lineLimit(1)
                Spacer(minLength: 8)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(item.expires.timeIntervalSince(context.date).rounded(.up)))
                    Text("\(left)S").font(HUD.readout(9.5)).foregroundStyle(left <= 10 ? HUD.amber : HUD.dim).monospacedDigit()
                        .accessibilityLabel("\(left) seconds before this counts as no")
                }
                .help("No answer counts as no")
            }
            Text(item.approval.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(HUD.ice)
            if let detail = item.approval.detail, !detail.isEmpty {
                // Never cut short: the card is the only place the user sees everything that will run.
                // Long ones scroll instead.
                let text = Text(detail).font(looksLikeCode(detail) ? .system(size: 12, design: .monospaced) : .system(size: 14))
                    .foregroundStyle(HUD.ice.opacity(0.92)).textSelection(.enabled)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    if detail.count > 1_200 || detail.split(separator: "\n", omittingEmptySubsequences: false).count > 14 {
                        ScrollView { text }.frame(height: 280)
                    } else {
                        text
                    }
                }
                .background(Rectangle().fill(HUD.void.opacity(0.6)))
            }
            HStack(spacing: 10) {
                Button("Cancel") { queue.answer(item.id, allow: false) }.buttonStyle(HUDButtonStyle(kind: .ghost))
                if item.allowOnce != nil {
                    Button(verb) { queue.answer(item.id, allow: true) }.buttonStyle(HUDButtonStyle(kind: .critical))
                    if item.offer != nil {
                        // Only on cards the guard said a grant can cover, never a send, share or delete.
                        Button("Yes to all like this") { queue.answerAll(item.id) }
                            .buttonStyle(HUDButtonStyle(kind: .ghost))
                            .help("Allows this, and steps like it without a card until this request is done. "
                                  + "Sends, shares and deletes still ask.")
                    }
                } else {
                    Text("This request can't be allowed just once, so it can only be declined here.")
                        .font(.system(size: 11)).foregroundStyle(HUD.dim)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 560, alignment: .leading)
        .hudPanel(tint: HUD.amber)
    }

    /// The button says what will happen: Send, Delete, Run… or Allow.
    private var verb: String {
        let first = item.approval.title.split(separator: " ").first.map(String.init) ?? ""
        return ["Send", "Delete", "Create", "Change", "Run", "Move", "Post", "Update", "Open", "Edit", "Share", "Upload", "Install", "Push", "Publish", "Type", "Press", "Click", "Save", "Empty"].contains(first) ? first : "Allow"
    }

    private func looksLikeCode(_ detail: String) -> Bool {
        detail.hasPrefix("/") || detail.contains("$ ") || detail.contains(" --") || detail.contains("\n\n")
    }
}
