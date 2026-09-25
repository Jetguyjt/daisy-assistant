import Foundation

/// New text artifacts only. An exclusive create never overwrites an existing file.
public enum DraftFile {
    public static func destination(root: URL, name: String) throws -> URL {
        guard !name.isEmpty, name.count <= 160, !name.hasPrefix("."), !name.contains("/"), !name.contains("\\"),
              !name.contains(":"), !name.contains("\0"), name == name.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw JarvisError.message("Use a simple new filename without folders or hidden-file prefixes.")
        }
        let target = root.appendingPathComponent(name)
        guard FileSearch.isInside(target, root: root), !FileManager.default.fileExists(atPath: target.path),
              (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw JarvisError.message("That file already exists, or the chosen folder is unavailable. Choose a new filename.")
        }
        return target
    }
    public static func write(root: URL, name: String, text: String) throws -> URL {
        try Task.checkCancellation()
        let target = try destination(root: root, name: name)
        // withoutOverwriting uses an exclusive create and rejects existing paths, including a raced symlink.
        try Data(text.utf8).write(to: target, options: [.withoutOverwriting])
        return target
    }
}
public struct DraftCapabilityProvider: CapabilityProvider {
    public let root: URL?
    public init(root: URL?) { self.root = root?.resolvingSymlinksInPath().standardizedFileURL }
    public func capabilities() -> [Capability] { [
        Capability(.init(name: "prepare_file", title: "Draft documents and code", provider: "Local workspace",
            description: "Prepare a NEW text/code/Markdown file in the chosen folder. Show full content in a review card; user clicks Apply to save. Cannot overwrite files, run code, install packages or submit homework. Use to draft essays, study notes, plans or code from the user's instructions.",
            parameters: .object(properties: ["filename": .string(maxLength: 160), "content": .string(maxLength: 9000)], required: ["filename", "content"]), effect: .preparesChanges),
            unavailableReason: root == nil ? "Choose a folder first." : nil) { args in
                guard let root else { throw JarvisError.message("Choose a folder first.") }
                let name = args["filename"]!.stringValue!, content = args["content"]!.stringValue!
                let target = try DraftFile.destination(root: root, name: name)
                return .init(summary: "Prepared \(name) for review. The file has not been saved.", data: .object(["filename": .string(name), "saved": .bool(false)]),
                    review: ReviewedAction(title: "Create \(name)", preview: target.path + "\n\n" + content) {
                        let saved = try DraftFile.write(root: root, name: name, text: content)
                        return "Created \(saved.path)"
                    })
            }
    ] }
}
