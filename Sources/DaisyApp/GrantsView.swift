import SwiftUI
import DaisyCore

/// Setup's pointer to standing permissions. They're listed, turned on and turned off in Tools →
/// Permissions (PermissionsSection); this keeps the old place saying where they went, and how many are on.
struct GrantsSection: View {
    @ObservedObject var store: GrantStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STANDING PERMISSIONS").hudCaption(HUD.accent)
            note("Standing permissions are in Tools → Permissions: what Daisy can do without asking, what she asks "
                 + "about often, and a switch for each. Sends, shares and deletes always ask.")
            if !summary.isEmpty {
                Text(summary).font(HUD.label(9)).tracking(1.2).foregroundStyle(HUD.dim)
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Rectangle().fill(HUD.line.opacity(0.09)).frame(height: 1) }
        .task { store.reload() }
    }

    /// "2 ON FROM NOW ON · 1 FOR THIS REQUEST"
    private var summary: String {
        let forever = store.grants.filter(\.forever).count
        let request = store.grants.count - forever
        return [forever > 0 ? "\(forever) ON FROM NOW ON" : "", request > 0 ? "\(request) FOR THIS REQUEST" : ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(HUD.dim).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}
