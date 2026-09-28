import Foundation
import DaisyCore

/// The app was called Jarvis until 2026-09-27; its data folder has to follow it to the new name.
final class RenameTests {
    func testLegacyFolderMovesOnceAndSavedPathsFollow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rename-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("Jarvis"), current = root.appendingPathComponent("Daisy")
        try FileManager.default.createDirectory(at: legacy.appendingPathComponent("Runtime/models"), withIntermediateDirectories: true)
        var config = Configuration()
        config.whisperModel = legacy.path + "/Runtime/models/ggml-base.en.bin"
        config.ollamaModels = legacy.path + "/Runtime/ollama/models"
        try JSONEncoder().encode(config).write(to: legacy.appendingPathComponent("config.json"))

        expectEqual(Configuration.adoptLegacyFolder(from: legacy, to: current), current)
        expectFalse(FileManager.default.fileExists(atPath: legacy.path))
        expectTrue(FileManager.default.fileExists(atPath: current.appendingPathComponent("Runtime/models").path))
        let moved = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: current.appendingPathComponent("config.json")))
        expectEqual(moved.whisperModel, current.path + "/Runtime/models/ggml-base.en.bin")
        expectEqual(moved.ollamaModels, current.path + "/Runtime/ollama/models")
        // Running again changes nothing.
        expectEqual(Configuration.adoptLegacyFolder(from: legacy, to: current), current)
    }
    func testFailedMoveKeepsUsingTheOldFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rename-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("Jarvis")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let unreachable = root.appendingPathComponent("missing/parent/Daisy")
        expectEqual(Configuration.adoptLegacyFolder(from: legacy, to: unreachable), legacy)
        expectTrue(FileManager.default.fileExists(atPath: legacy.path))
    }
}
