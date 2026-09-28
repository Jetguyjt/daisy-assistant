import Foundation
import DaisyCore

final class ChromePhraseTests {
    // Hermes titles plugin tools with just their name and passes the arguments as rawInput.
    func testChromeToolsReadAsPlainWords() {
        expectEqual(ToolPhrases.describe(title: "chrome_tabs", kind: "other").title, "Checking your tabs")
        expectEqual(ToolPhrases.describe(title: "chrome_tabs", kind: "other", input: ["query": "essay"]).title, "Checking your tabs")
        let email: JSONValue = ["url": "https://mail.google.com/", "reuse": .bool(true)]
        expectEqual(ToolPhrases.describe(title: "chrome_open", kind: "other", input: email).title, "Switching to Gmail")
        let search: JSONValue = ["url": "https://www.google.com/search?q=cheap%20flights"]
        expectEqual(ToolPhrases.describe(title: "chrome_open", kind: "other", input: search).title, "Opening google.com")
        let tab: JSONValue = ["window": .number(2), "tab": .number(5), "url": "https://mail.google.com/mail/u/0/#inbox"]
        expectEqual(ToolPhrases.describe(title: "chrome_focus", kind: "other", input: tab).title, "Switching to Gmail")
        expectEqual(ToolPhrases.describe(title: "chrome_focus", kind: "other", input: ["url": "docs.google.com"]).title, "Switching to Google Docs")
        expectEqual(ToolPhrases.describe(title: "chrome_open", kind: "other", input: ["url": "https://WWW.YouTube.com/watch?v=x"]).title, "Opening youtube.com")
        expectEqual(ToolPhrases.describe(title: "chrome_open", kind: "other", input: ["url": "https://www.google.com/"]).detail, nil)
    }

    func testChromePhrasesWithoutAnAddressStayGeneric() {
        expectEqual(ToolPhrases.describe(title: "chrome_focus", kind: "other", input: ["window": .number(1), "tab": .number(3)]).title, "Switching tabs")
        expectEqual(ToolPhrases.describe(title: "chrome_focus", kind: "other").title, "Switching tabs")
        expectEqual(ToolPhrases.describe(title: "chrome_open", kind: "other").title, "Opening a page")
        expectEqual(ToolPhrases.describe(title: "chrome_open", kind: "other", input: ["url": .number(42)]).title, "Opening a page")
        expectEqual(ToolPhrases.describe(title: "chrome_open", kind: "other", input: ["url": "   "]).title, "Opening a page")
        expectEqual(ToolPhrases.describe(title: "chrome_open", kind: "other", input: ["url": "not a url at all"]).title, "Opening a page")
        // Other tools don't change because an input came along.
        expectEqual(ToolPhrases.describe(title: "web search: weather", kind: "fetch", input: ["query": "weather"]).title, "Searching the web")
    }
}
