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

    // Streaming: the voice starts on the first finished sentence and ends up saying the same thing.
    func testFeedStartsEarlyAndMatchesOneShot() {
        let answer = "Sure thing. The capital of France is Paris, on the **Seine**.\nIt has about two million people. Want the history too?"
        var feed = SpeechFeed()
        var chunks: [String] = []
        var firstAt: Int?
        var text = ""
        for character in answer {
            text.append(character)
            let ready = feed.update(text)
            if firstAt == nil, !ready.isEmpty { firstAt = text.count }
            chunks += ready
        }
        chunks += feed.finish(answer)
        expectEqual(chunks.joined(separator: " "), SpeechText.spoken(from: answer))
        expectTrue((firstAt ?? .max) < answer.count * 2 / 3)
    }
    func testFeedHoldsListMarkersAndShortFragments() {
        var feed = SpeechFeed()
        expectEqual(feed.update("1. "), [])
        expectEqual(feed.update("Ok. "), [])
        expectEqual(feed.update("Ok. Here are the steps.\n"), ["Ok. Here are the steps."])
        expectEqual(feed.update("Ok. Here are the steps.\n1. Open the folder\n"), ["1. Open the folder."])
        expectEqual(feed.finish("Ok. Here are the steps.\n1. Open the folder\n"), [])
    }
    func testFeedRestartsForANewTurnAndKeepsCodeOffTheVoice() {
        var feed = SpeechFeed()
        expectEqual(feed.update("Let me check that for you. "), ["Let me check that for you."])
        expectEqual(feed.update("Use this:\n```swift\nlet x = 1. y = 2\n"), ["Use this: Code is shown on screen."])
        expectEqual(feed.finish("Use this:\n```swift\nlet x = 1. y = 2\n```\nThat is all."), ["That is all."])
    }
    func testFeedRespectsTheSpokenLimit() {
        var feed = SpeechFeed(limit: 300)
        let long = String(repeating: "This is a sentence that keeps going for a while. ", count: 40)
        var said = feed.update(long)
        said += feed.finish(long)
        let total = said.joined(separator: " ")
        expectTrue(total.count <= 310)
        expectTrue(total.hasSuffix("while."))
    }
}
