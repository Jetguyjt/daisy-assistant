import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var occlusion: NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        // Pause the core animation while no Jarvis window can be seen.
        occlusion = NotificationCenter.default.addObserver(forName: NSApplication.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] _ in
            let visible = NSApp.occlusionState.contains(.visible)
            MainActor.assumeIsolated { self?.model?.appVisible = visible }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in await model?.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@main struct JarvisDesktop: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("Jarvis") {
            ContentView(model: model).preferredColorScheme(.dark)
                .onAppear { delegate.model = model }
                .frame(minWidth: 1040, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 840)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New conversation") { model.clearConversation() }.keyboardShortcut("n")
                Button("Choose search folder…") { model.chooseFolder() }.keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(before: .sidebar) {
                ForEach(Array(["Assistant", "Tasks", "Memory", "Connections", "Capabilities", "Settings"].enumerated()), id: \.offset) { index, tab in
                    Button(tab == "Connections" ? "Links" : tab == "Capabilities" ? "Tools" : tab) { model.tab = tab }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
                Divider()
            }
            CommandGroup(after: .textEditing) {
                Button(model.composerExpanded ? "Collapse message editor" : "Expand message editor") { model.composerExpanded.toggle() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandMenu("Voice") {
                Button("Start / finish recording") { model.toggleListening() }.keyboardShortcut(.space, modifiers: [.command, .shift])
                Button(model.alwaysListening ? "Turn off always listening" : "Turn on always listening") {
                    model.setAlwaysListening(!model.alwaysListening)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Stop Jarvis") { model.interrupt() }.keyboardShortcut(".", modifiers: [.command])
            }
        }
    }
}
