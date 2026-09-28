import Foundation
import DaisyCore

/// What the HUD says while Daisy's own plugin tools run. Hermes titles them with their bare name and
/// passes the arguments as rawInput, which the phrase is built from.
final class ToolPhraseTests {
    func testComputerToolsReadAsPlainWords() {
        expectEqual(ToolPhrases.describe(title: "computer_look", kind: "other", input: ["app": "Mail"]).title, "Looking at Mail")
        expectEqual(ToolPhrases.describe(title: "computer_look", kind: "other", input: ["action": "list_windows"]).title, "Checking open windows")
        expectEqual(ToolPhrases.describe(title: "computer_look", kind: "other").title, "Looking at the screen")
        let typing: JSONValue = ["action": "type", "app": "Notes", "text": "secret words"]
        expectEqual(ToolPhrases.describe(title: "computer_act", kind: "other", input: typing).title, "Typing in Notes")
        expectFalse(ToolPhrases.describe(title: "computer_act", kind: "other", input: typing).title.contains("secret"))
        expectEqual(ToolPhrases.describe(title: "computer_act", kind: "other", input: ["action": "key", "app": "Messages", "keys": "return"]).title,
                    "Pressing a key in Messages")
        expectEqual(ToolPhrases.describe(title: "computer_act", kind: "other", input: ["action": "focus_app", "app": "Finder"]).title, "Switching to Finder")
        expectEqual(ToolPhrases.describe(title: "computer_act", kind: "other").title, "Using an app")
    }
}
