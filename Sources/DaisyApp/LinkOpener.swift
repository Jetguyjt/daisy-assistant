import AppKit
import DaisyCore
import UniformTypeIdentifiers

/// Opens a task's or project's link: files in their own app, anything on the web in the browser, notes in
/// Notes, reminders in Reminders. Apps and scripts are shown in Finder instead of run, since links can
/// come from Hermes.
@MainActor enum LinkOpener {
    /// Opens it and returns nil, or says what went wrong. A note opens a moment later; if Notes can't
    /// show it, `later` hears why.
    static func open(_ link: TaskLink, later: @escaping @MainActor (String) -> Void = { _ in }) -> String? {
        do { try link.validate() } catch { return error.localizedDescription }
        switch link.kind {
        case .file:
            guard let url = link.resolvedFile() else {
                return "“\(link.title)” isn't at \(link.detail) anymore, and Daisy couldn't find where it went. Link it again."
            }
            if runs(url) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return nil
            }
            return NSWorkspace.shared.open(url) ? nil : "macOS couldn't open “\(link.title)”."
        case .note:
            showNote(link.noteID, title: link.title, later: later)
            return nil
        case .reminder:
            if let url = URL(string: "x-apple-reminderkit://REMCDReminder/\(link.reminderID)"), NSWorkspace.shared.open(url) { return nil }
            return NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Reminders.app")) ? nil : "Reminders didn't open."
        default:
            let text = link.webLink
            guard TaskLink.isWeb(text), let url = URL(string: text) else { return "“\(link.title)” has no web link to open." }
            return NSWorkspace.shared.open(url) ? nil : "macOS couldn't open “\(link.title)” in the browser."
        }
    }

    /// Apps, installers and scripts: anything that would run on a double-click.
    static func runs(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .isPackageKey, .isExecutableKey])
        let kinds: [UTType] = [.application, .applicationBundle, .executable, .script, .shellScript, .unixExecutable]
        if let type = values?.contentType, kinds.contains(where: { type.conforms(to: $0) }) { return true }
        if values?.isDirectory == true { return values?.isPackage == true && url.pathExtension.lowercased() != "rtfd" }
        if ["command", "tool", "workflow", "terminal", "pkg", "mpkg", "scpt", "applescript", "action", "prefpane"]
            .contains(url.pathExtension.lowercased()) { return true }
        return values?.isExecutable == true
    }

    /// Asks Notes to show the note. The id goes in as an argument, never into the script.
    private static func showNote(_ id: String, title: String, later: @escaping @MainActor (String) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "on run argv", "-e", "tell application \"Notes\"", "-e", "show note id (item 1 of argv)",
                             "-e", "activate", "-e", "end tell", "-e", "end run", id]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished in
            guard finished.terminationStatus != 0 else { return }
            Task { @MainActor in
                later("Notes couldn't show “\(title)”. It may have been deleted, or Daisy needs permission to use Notes (System Settings › Privacy & Security › Automation).")
            }
        }
        do { try process.run() } catch { later("Notes didn't open: \(error.localizedDescription)") }
    }
}
