import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
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
                .frame(minWidth: 1000, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New conversation") { model.clearConversation() }.keyboardShortcut("n")
                Button("Choose search folder…") { model.chooseFolder() }.keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("Voice") {
                Button("Start / finish recording") { model.toggleListening() }.keyboardShortcut(.space, modifiers: [.command, .shift])
                Button("Stop Jarvis") { model.interrupt() }.keyboardShortcut(".", modifiers: [.command])
            }
        }
    }
}
