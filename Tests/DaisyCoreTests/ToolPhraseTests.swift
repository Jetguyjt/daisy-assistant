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

    func testGoogleToolsReadAsPlainWords() {
        expectEqual(ToolPhrases.describe(title: "gmail_search", kind: "other").title, "Checking your email")
        expectEqual(ToolPhrases.describe(title: "gmail_send", kind: "other", input: ["to": "dad@example.com"]).title, "Sending an email")
        expectEqual(ToolPhrases.describe(title: "calendar_write", kind: "other").title, "Updating your calendar")
        expectEqual(ToolPhrases.describe(title: "drive_share", kind: "other").title, "Sharing a Drive file")
        expectEqual(ToolPhrases.describe(title: "tool_describe", kind: "other").title, "Getting a tool ready")
    }

    func testMessagesRemindersAndNotesReadAsPlainWords() {
        let text: JSONValue = ["to": "Dad", "text": "secret words"]
        expectEqual(ToolPhrases.describe(title: "imsg_send", kind: "other", input: text).title, "Texting Dad")
        expectFalse(ToolPhrases.describe(title: "imsg_send", kind: "other", input: text).title.contains("secret"))
        expectEqual(ToolPhrases.describe(title: "imsg_send", kind: "other").title, "Sending a text")
        expectEqual(ToolPhrases.describe(title: "imsg_send", kind: "other", input: ["to": "Dad\nand everyone"]).title, "Sending a text")
        expectEqual(ToolPhrases.describe(title: "reminders_add", kind: "other").title, "Adding a reminder")
        expectEqual(ToolPhrases.describe(title: "reminders_list", kind: "other").title, "Checking your reminders")
        expectEqual(ToolPhrases.describe(title: "notes_search", kind: "other").title, "Checking your notes")
        expectEqual(ToolPhrases.describe(title: "notes_append", kind: "other").title, "Adding to a note")
        let twelve = JSONValue.object(["tasks": .array((0..<12).map { _ in .object(["title": "Essay"]) })])
        expectEqual(ToolPhrases.describe(title: "tasks_add", kind: "other", input: twelve).title, "Adding 12 tasks")
        expectEqual(ToolPhrases.describe(title: "tasks_update", kind: "other").title, "Updating your tasks")
        expectEqual(ToolPhrases.describe(title: "tasks_list", kind: "other").title, "Checking your tasks")
        let doc = JSONValue.object(["changes": .array([.object(["task": "Why Harvard",
            "add_links": .array([.string("https://docs.google.com/document/d/1AbCdEfGhIjKlMnOpQrStUv/edit")])])])])
        expectEqual(ToolPhrases.describe(title: "tasks_update", kind: "other", input: doc).title, "Linking a doc")
        let event = JSONValue.object(["changes": .array([.object(["project": "Colleges",
            "add_links": .array([.object(["kind": "calendar_event", "event_id": "abc123def456"])])])])])
        expectEqual(ToolPhrases.describe(title: "projects_update", kind: "other", input: event).title, "Linking an event")
        expectEqual(ToolPhrases.describe(title: "projects_update", kind: "other").title, "Updating your projects")
        let two = JSONValue.object(["projects": .array([.object(["name": "Robotics"]), .object(["name": "Band"])])])
        expectEqual(ToolPhrases.describe(title: "projects_add", kind: "other", input: two).title, "Adding 2 projects")
        expectEqual(ToolPhrases.describe(title: "projects_list", kind: "other").title, "Checking your projects")
        expectEqual(ToolPhrases.describe(title: "projects_remove", kind: "other").title, "Removing a project")
    }
}
