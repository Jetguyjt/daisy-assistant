import ServiceManagement
import SwiftUI

/// Open Daisy at login, through SMAppService.mainApp. macOS keeps that list (System Settings → General →
/// Login Items → Open at Login), so the switch reads the state back from there instead of saving a copy
/// of its own, and it starts off. Turning it on can come back as `requiresApproval` for an ad-hoc signed
/// app; the row then says so and opens Login Items.
@MainActor final class LoginItem: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var problem: String?
    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
        refresh()
    }

    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    /// Someone can change it in System Settings while Daisy runs, so read it again when shown.
    func refresh() { status = service.status }

    func set(_ on: Bool) {
        problem = nil
        do {
            if on { try service.register() } else if status != .notRegistered { try service.unregister() }
        } catch {
            problem = (on ? "macOS didn't add Daisy to Login Items: " : "macOS didn't take Daisy out of Login Items: ")
                + error.localizedDescription
        }
        refresh()
    }

    func openSettings() { SMAppService.openSystemSettingsLoginItems() }

    var note: String {
        switch status {
        case .enabled:
            return "Daisy opens when you log in. It's listed under System Settings → General → Login Items."
        case .requiresApproval:
            return "macOS wants a yes first: in System Settings → General → Login Items, turn Daisy on under Open at Login."
        case .notFound:
            return "macOS can't find this copy of Daisy to open at login; it has to be the installed Daisy.app."
        default:
            return "Off: Daisy starts when you open it."
        }
    }
}
