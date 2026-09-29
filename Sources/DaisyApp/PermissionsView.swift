import SwiftUI
import DaisyCore

/// Tools → Permissions: what Daisy can do without asking, what she's had to ask about often, and what
/// always asks. Nothing here is a fixed list: rows come from the cards she actually showed (the guard's
/// asks.jsonl), and a switch turns one on for good or off again.
struct PermissionsSection: View {
    @ObservedObject var grants: GrantStore
    @StateObject private var store: PermissionStore

    init(grants: GrantStore) {
        self.grants = grants
        _store = StateObject(wrappedValue: PermissionStore(file: grants.file))
    }

    var body: some View {
        let allowed = store.rows(.allowed), request = store.rows(.request)
        let often = store.rows(.often), locked = store.rows(.locked)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("PERMISSIONS").hudCaption(HUD.accent)
                note(Permissions.stillAsks + " The rest of this list comes from what Daisy has had to ask you, and "
                     + "each switch lets her do that kind of step without asking.")
                if let problem = store.problem {
                    Text(problem).font(.system(size: 11)).foregroundStyle(HUD.amber).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            group("ALWAYS ALLOWED", allowed, empty: "Nothing yet. Turn on something below, or tell Daisy “from now on, "
                  + "you don't have to ask before…” and she'll ask once with a card.")
            if !request.isEmpty { group("FOR THIS REQUEST", request, empty: "") }
            group("ASKED OFTEN", often, empty: "Nothing yet. Once Daisy has had to ask about the same kind of step "
                  + "\(Permissions.minimumAsks) times in two weeks, it shows up here with a switch.")
            if !locked.isEmpty { group("ALWAYS ASKS", locked, empty: "") }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Rectangle().fill(HUD.line.opacity(0.09)).frame(height: 1) }
        .task {
            // The guard adds to these files while this is open; the list is only rebuilt when one changed.
            while !Task.isCancelled {
                store.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func group(_ title: String, _ rows: [PermissionRow], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(HUD.label(9)).tracking(1.4).foregroundStyle(HUD.steel).padding(.bottom, 6)
            if rows.isEmpty {
                note(empty).padding(.vertical, 8)
            }
            ForEach(rows) { row in
                PermissionRowView(row: row) { on in
                    store.set(row, on: on)
                    grants.reload()
                }
            }
        }
        .padding(.top, 6)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(HUD.dim).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PermissionRowView: View {
    let row: PermissionRow
    let flip: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.label).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(row.group == .locked ? HUD.steel : HUD.ice)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(row.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 11)).foregroundStyle(HUD.steel).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !row.reason.isEmpty {
                    Text(row.reason).font(.system(size: 11)).foregroundStyle(row.group == .locked ? HUD.dim : HUD.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(meta).font(HUD.label(9)).tracking(1.2).foregroundStyle(HUD.dim)
            }
            Spacer(minLength: 10)
            PermissionPill(isOn: row.isOn, enabled: row.canSwitch, label: row.label, help: help) { flip(!row.isOn) }
                .padding(.top, 1)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(HUD.line.opacity(0.06)).frame(height: 1) }
    }

    private var meta: String {
        switch row.group {
        case .allowed:
            let ran = row.count == 0 ? "NOTHING RAN UNDER IT YET" : "\(steps) IN 2 WEEKS"
            return "ON SINCE \(when(row.given)) · \(ran)"
        case .request:
            return "UNTIL THIS REQUEST IS DONE" + (row.count == 0 ? "" : " · \(steps)")
        case .often, .locked:
            let last = row.last.map { " · LAST " + $0.formatted(.relative(presentation: .named)).uppercased() } ?? ""
            return "ASKED \(row.count) TIME\(row.count == 1 ? "" : "S") IN 2 WEEKS" + last
        }
    }

    private var steps: String { "\(row.count) STEP\(row.count == 1 ? "" : "S")" }

    private var help: String {
        switch row.group {
        case .allowed, .request: return "Turns this off now. The next step like it gets a card again."
        case .often: return "Lets Daisy do this without asking, from now on, until you turn it off."
        case .locked: return row.reason
        }
    }

    private func when(_ date: Date?) -> String {
        guard let date else { return "—" }
        return (Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
                                                     : date.formatted(date: .abbreviated, time: .omitted)).uppercased()
    }
}

/// HUDSwitch's pill on its own: a lit track when on, and dimmed with a lock on the knob when it can't
/// change.
struct PermissionPill: View {
    let isOn: Bool
    let enabled: Bool
    let label: String
    var help: String = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? HUD.accent.opacity(0.85) : Color.white.opacity(0.08))
                    .overlay(Capsule().strokeBorder(isOn ? .clear : HUD.dim.opacity(hovering ? 0.8 : 0.5), lineWidth: 1))
                    .frame(width: 34, height: 19)
                Circle().fill(isOn ? HUD.void : HUD.dim).frame(width: 13, height: 13)
                    .overlay {
                        if !enabled { Image(systemName: "lock.fill").font(.system(size: 6.5, weight: .bold)).foregroundStyle(HUD.void) }
                    }
                    .padding(3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hovering = $0 && enabled }
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isOn)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : enabled ? "Off" : "Off, always asks")
        .accessibilityAddTraits(.isToggle)
    }
}
