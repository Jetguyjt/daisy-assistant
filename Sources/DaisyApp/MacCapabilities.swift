import AppKit
import DaisyCore

/// App launching is deliberately distinct from controlling an app's UI.
private actor InstalledApps {
    private var references: [String: URL] = [:]
    func find(_ query: String) throws -> CapabilityOutput {
        let roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var matches: [JSONValue] = []
        for root in roots {
            guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in entries {
                try Task.checkCancellation()
                if url.pathExtension != "app" { continue }
                guard query.isEmpty || url.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(query) else { continue }
                let reference = UUID().uuidString; references[reference] = url
                matches.append(.object(["reference": .string(reference), "name": .string(url.deletingPathExtension().lastPathComponent), "path": .string(url.path)]))
                if matches.count >= 12 { break }
            }
            if matches.count >= 12 { break }
        }
        return .init(summary: "Found \(matches.count) installed app matches (up to 12). Opening an app does not grant control of it.", data: .array(matches))
    }
    func prepare(_ reference: String) throws -> CapabilityOutput {
        guard let url = references[reference] else { throw DaisyError.message("Find the app first and use its returned reference.") }
        return .init(summary: "Prepared an app launch for review. The app has not opened yet.", review: ReviewedAction(title: "Open \(url.deletingPathExtension().lastPathComponent)", preview: url.path) {
            try Task.checkCancellation()
            guard FileManager.default.fileExists(atPath: url.path) else { throw DaisyError.message("This app is no longer installed here.") }
            let application = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return "Opened \(application.localizedName ?? url.lastPathComponent). App UI control is not enabled."
        })
    }
}
struct MacCapabilityProvider: CapabilityProvider {
    private let apps = InstalledApps()
    func capabilities() -> [Capability] { [
        Capability(.init(name: "find_apps", title: "Find Mac apps", provider: "macOS",
            description: "Find installed apps by name in Applications and System Applications. Returns references for prepare_open_app. Does not read their data or control their UI.",
            parameters: .object(properties: ["query": .string(maxLength: 100)], required: ["query"]))) { args in try await apps.find(args["query"]!.stringValue!) },
        Capability(.init(name: "prepare_open_app", title: "Open a Mac app", provider: "macOS",
            description: "Prepare launch of an exact installed app reference returned by find_apps in this request. User clicks Apply to open it. Opening is not evidence that an app task was completed.",
            parameters: .object(properties: ["reference": .string(maxLength: 36)], required: ["reference"]), effect: .preparesChanges)) { args in try await apps.prepare(args["reference"]!.stringValue!) }
    ] }
}
