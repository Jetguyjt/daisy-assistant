import Foundation
import DaisyCore

/// hermes/fixtures/tasks, shared with the plugin's tests so both sides read tasks the same way.
func taskFixture(_ name: String) throws -> Data {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: repo.appendingPathComponent("hermes/fixtures/tasks/\(name)"))
}

final class TaskStatusTests {
    func testStatusTextReadsLikeThePlugin() throws {
        struct Case: Decodable { let text: String; let status: String; let leftover: String? }
        struct Cases: Decodable { let cases: [Case] }
        let cases = try JSONDecoder().decode(Cases.self, from: try taskFixture("status-cases.json")).cases
        expectTrue(cases.count > 40)
        for item in cases {
            let read = TaskStatus.read(item.text)
            if read.status.rawValue != item.status || read.leftover != item.leftover {
                fail("\(item.text.debugDescription) read as \(read.status.rawValue), leftover \(read.leftover ?? "none")")
            }
        }
    }

    func testNamesOpenAndFinished() {
        expectEqual(TaskStatus.allCases.map(\.rawValue), ["idea", "todo", "in_progress", "needs_review", "waiting", "blocked", "submitted", "done", "dropped"])
        expectEqual(TaskStatus.allCases.map(\.title), ["Idea", "To do", "In progress", "Needs review", "Waiting", "Blocked", "Submitted", "Done", "Dropped"])
        expectEqual(TaskStatus.allCases.filter(\.isOpen), [.idea, .todo, .inProgress, .needsReview, .waiting, .blocked])
        expectEqual(TaskStatus.allCases.filter(\.isFinished), [.submitted, .done, .dropped])
        let legacy: TaskStatus = "planned", custom: TaskStatus = "needs to get started"
        expectEqual(legacy, .todo); expectEqual(custom, .todo)
        expectTrue(TaskStatus.allCases.allSatisfy { !$0.hint.isEmpty })
    }

    func testStatusDecodesFromAnyText() throws {
        let decoded = try JSONDecoder().decode([TaskStatus].self, from: Data(#"["done", "Needs review", "planned", "stuck"]"#.utf8))
        expectEqual(decoded, [.done, .needsReview, .todo, .blocked])
        let encoded = String(decoding: try JSONEncoder().encode([TaskStatus.inProgress]), as: UTF8.self)
        expectEqual(encoded, #"["in_progress"]"#)
    }

    func testChipColorsStayApartInEveryAccent() {
        func distance(_ a: RGB, _ b: RGB) -> Double { ((a.r - b.r) * (a.r - b.r) + (a.g - b.g) * (a.g - b.g) + (a.b - b.b) * (a.b - b.b)).squareRoot() }
        for (name, accent) in ThemePalette.presets {
            let palette = ThemePalette.derived(from: accent)
            let colors = TaskStatus.allCases.map { $0.tint(in: palette) }
            for i in colors.indices {
                for j in colors.indices where j > i && distance(colors[i], colors[j]) < 0.1 {
                    fail("\(name): \(TaskStatus.allCases[i].title) and \(TaskStatus.allCases[j].title) look alike (\(distance(colors[i], colors[j])))")
                }
            }
            // Review, waiting, blocked and submitted never share the accent's hue.
            let accentHue = palette.accent.hsb.h
            for status in [TaskStatus.needsReview, .waiting, .blocked, .submitted] where palette.accent.hsb.s > 0.25 {
                if ThemePalette.hueDistance(status.tint(in: palette).hsb.h, accentHue) < 25.0 / 360 { fail("\(name): \(status.title) sits on the accent") }
            }
        }
    }
}
