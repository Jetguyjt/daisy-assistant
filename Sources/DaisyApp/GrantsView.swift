import SwiftUI
import DaisyCore

/// The Setup section for standing permissions: what Daisy can do without asking right now, for how
/// long, and Revoke. Grants only come from a card the user approved, so nothing is added here.
struct GrantsSection: View {
    @ObservedObject var store: GrantStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("STANDING PERMISSIONS").hudCaption(HUD.accent)
            if store.grants.isEmpty {
                note("None right now. When you tell Daisy she can do something without asking, she asks once with a "
                     + "card, and it shows up here until the request is done, or until you turn it off.")
            } else {
                ForEach(store.grants) { grant in
                    GrantRow(grant: grant) { store.revoke(grant.id) }
                }
            }
            note("Sends, shares and deletes always get their own card, whatever is here.")
            if let problem = store.problem {
                Text(problem).font(.system(size: 11)).foregroundStyle(HUD.amber).textSelection(.enabled)
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Rectangle().fill(HUD.line.opacity(0.09)).frame(height: 1) }
        .task {
            // The guard adds and the request ends while Setup is open; the file is small.
            while !Task.isCancelled {
                store.reload()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(HUD.dim).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GrantRow: View {
    let grant: StandingGrant
    let revoke: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(grant.fromCard ? grant.what : "“\(grant.what)”")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(HUD.ice).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(grant.covers.enumerated()), id: \.offset) { _, line in
                    Text("• " + line).font(.system(size: 11)).foregroundStyle(HUD.steel).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("\(grant.lasts.uppercased()) · GIVEN \(given.uppercased())")
                    .font(HUD.label(9)).tracking(1.2).foregroundStyle(grant.forever ? HUD.amber : HUD.dim)
            }
            Spacer(minLength: 8)
            Button("Revoke", action: revoke).buttonStyle(HUDButtonStyle(kind: .danger, compact: true))
                .help("Turns this off now. The next step like it gets a card again.")
        }
        .padding(12)
        .background(Rectangle().fill(HUD.void.opacity(0.35)))
    }

    private var given: String {
        Calendar.current.isDateInToday(grant.given)
            ? grant.given.formatted(date: .omitted, time: .shortened)
            : grant.given.formatted(date: .abbreviated, time: .shortened)
    }
}
