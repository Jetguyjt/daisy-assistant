import Foundation
import JarvisCore

/// The model answers in Markdown; espeak reads "*" as "asterisk" and "#" as "hash", and a line with
/// no end punctuation runs straight into the next one. These pin the spoken form of real answers.
final class SpeechTests {
    func testSpokenStripsInlineMarkdown() {
        expectEqual(SpeechText.spoken(from: "I am **Jarvis**, your `local` *assistant* with __bold__ and ~~gone~~ text."),
                    "I am Jarvis, your local assistant with bold and gone text.")
        expectEqual(SpeechText.spoken(from: "Use *in media res* or my_list here."), "Use in media res or my_list here.")
    }
    func testSpokenTurnsListsAndHeadingsIntoSentences() {
        let markdown = """
        ## How I can help

        *   **Writing & Editing:** Draft emails
        -   Explanations
        1.  **Define the Core Narrative**
            Identify the single moment
        > quoted line
        ---
        """
        expectEqual(SpeechText.spoken(from: markdown),
                    "How I can help. Writing & Editing: Draft emails. Explanations. 1. Define the Core Narrative. Identify the single moment. quoted line.")
    }
    func testSpokenReplacesCodeBlocksAndLinks() {
        let markdown = """
        Use append:
        ```python
        my_list.append(4)
        ```
        See [the docs](https://docs.python.org/3/tutorial/) or https://www.docs.ollama.com/faq for more.
        """
        expectEqual(SpeechText.spoken(from: markdown),
                    "Use append: Code is shown on screen. See the docs or docs.ollama.com for more.")
        expectEqual(SpeechText.spoken(from: "```swift\nprint(1)\n```"), "Code is shown on screen.")
    }
    func testSpokenDropsLengthMarkerEmojiArrowsAndTables() {
        expectEqual(SpeechText.spoken(from: "Done 🙂 step -> next => end\n[Response length limit reached.]"), "Done step to next to end.")
        let table = """
        | Name | Role |
        | --- | --- |
        | George | British |
        """
        expectEqual(SpeechText.spoken(from: table), "Name, Role. George, British.")
        expectEqual(SpeechText.spoken(from: "   \n  "), "")
    }
    func testSpokenCutsAtSentenceBoundaryWithinLimit() {
        let long = String(repeating: "This is a sentence that keeps going for a while. ", count: 80)
        let spoken = SpeechText.spoken(from: long, limit: 300)
        expectTrue(spoken.count <= 300)
        expectTrue(spoken.hasSuffix("while."))
        expectTrue(spoken.count > 200)
    }
}
