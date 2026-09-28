import Foundation
import DaisyCore

/// The model answers in Markdown; espeak reads "*" as "asterisk" and "#" as "hash", and a line with
/// no end punctuation runs straight into the next one. These pin the spoken form of real answers.
final class SpeechTests {
    func testSpokenStripsInlineMarkdown() {
        expectEqual(SpeechText.spoken(from: "I am **Daisy**, your `local` *assistant* with __bold__ and ~~gone~~ text."),
                    "I am Daisy, your local assistant with bold and gone text.")
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
                    "How I can help. Writing & Editing: Draft emails. Explanations. One. Define the Core Narrative. Identify the single moment. quoted line.")
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
                    "Use append: Code is shown on screen. See the docs or docs dot ollama dot com for more.")
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
    func testSpokenDoesntDoubleThePeriodInsideQuotesOrBrackets() {
        expectEqual(SpeechText.spoken(from: "He said \"stop right there.\"\n(See the notes above.)"),
                    "He said \"stop right there.\" (See the notes above.)")
        expectEqual(SpeechText.spoken(from: "It's called \"Daisy\""), "It's called \"Daisy\".")
    }

    // Chunking: sentence ends only, and never a fragment too short to sound right on its own.
    func testSentencesDontSplitInsideNumbersOrAbbreviations() {
        let text = "The price went up by 3.5 percent overall. The U.S. market e.g. stayed flat all week. Dr. Smith said it was fine."
        expectEqual(SpeechText.sentences(from: text, firstTarget: 1, target: 1),
                    ["The price went up by 3.5 percent overall.", "The U.S. market e.g. stayed flat all week.", "Dr. Smith said it was fine."])
        let trailing = "Well... I think that is right for now. And so it goes on for a while. Next is J. K. Rowling herself."
        expectEqual(SpeechText.sentences(from: trailing, firstTarget: 1, target: 1),
                    ["Well... I think that is right for now.", "And so it goes on for a while.", "Next is J. K. Rowling herself."])
        let quoted = "He said \"stop right there, please.\" Then he left the room quickly. Really?! That is a big surprise."
        expectEqual(SpeechText.sentences(from: quoted, firstTarget: 1, target: 1),
                    ["He said \"stop right there, please.\"", "Then he left the room quickly.", "Really?! That is a big surprise."])
    }
    func testSentencesMergeShortFragments() {
        // Alone, "Sure." would be its own chunk: the next sentence is too long for the first target.
        let answer = "Sure. The capital of France is Paris, which sits on the Seine river in the north of the country."
        expectEqual(SpeechText.sentences(from: answer), [answer])
        // A real first sentence still goes first on its own, so the audio starts early.
        let greeting = "Hi, I'm Daisy. Your draft is due October fifteenth, so let's block out forty-five minutes a day for it."
        expectEqual(SpeechText.sentences(from: greeting),
                    ["Hi, I'm Daisy.", "Your draft is due October fifteenth, so let's block out forty-five minutes a day for it."])
        // A short last sentence joins the chunk before it.
        let long = "Start with the results section, since the figures already exist and the draft only needs the words around them."
        let ending = SpeechText.sentences(from: "\(long) \(long) Okay.", firstTarget: 60, target: 100)
        expectEqual(ending.count, 2)
        expectEqual(ending.last, "\(long) Okay.")
        // A short one between two long ones joins the next.
        let middle = SpeechText.sentences(from: "\(long) Got it. \(long)", firstTarget: 1, target: 1)
        expectEqual(middle, [long, "Got it. \(long)"])
        expectTrue(SpeechText.sentences(from: "Sure.") == ["Sure."])
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
        // Once talking, a short line waits for company.
        expectEqual(feed.update("Ok. Here are the steps.\n1. Open the folder\n"), [])
        expectEqual(feed.update("Ok. Here are the steps.\n1. Open the folder\n2. Delete the old draft\n"),
                    ["One. Open the folder. Two. Delete the old draft."])
        expectEqual(feed.finish("Ok. Here are the steps.\n1. Open the folder\n2. Delete the old draft\nDone."), ["Done."])
    }
    func testFeedWaitsOutAbbreviationsAndDecimals() {
        var feed = SpeechFeed()
        // "Dr. " could be the end of a sentence, but it isn't, and "Doctor" depends on the name after it.
        expectEqual(feed.update("I spoke with Dr. "), [])
        expectEqual(feed.update("I spoke with Dr. Smith about the U.S. "), [])
        expectEqual(feed.update("I spoke with Dr. Smith about the U.S. rates today. "),
                    ["I spoke with Doctor Smith about the US rates today."])
        var money = SpeechFeed()
        expectEqual(money.update("It costs $4."), [])
        expectEqual(money.update("It costs $4.50 at the store near you. "), ["It costs four dollars and fifty cents at the store near you."])
        // A sentence that ends inside bold is still a sentence end.
        var bold = SpeechFeed()
        expectEqual(bold.update("**That part is finished.** "), ["That part is finished."])
    }
    func testFeedHoldsShortFollowUpsUntilFlushed() {
        var feed = SpeechFeed()
        expectEqual(feed.update("Let me check that for you. "), ["Let me check that for you."])
        expectEqual(feed.update("Let me check that for you. Found it. "), [])
        expectEqual(feed.update("Let me check that for you. Found it. The file is in Documents. "), ["Found it. The file is in Documents."])
        // A tool starts: whatever is finished goes out now, however short.
        var tool = SpeechFeed()
        expectEqual(tool.update("Sure. "), [])
        expectEqual(tool.flush("Sure. "), ["Sure."])
        expectEqual(tool.flush("Sure. "), [])
        expectEqual(tool.update("Sure. One sec. "), [])
        expectEqual(tool.flush("Sure. One sec. Still wri"), ["One sec."])
        expectEqual(tool.finish("Sure. One sec. Still writing."), ["Still writing."])
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
    func testStreamedAnswersSayTheSameAsOneShot() {
        // Every expansion has to read the same on a prefix cut at a sentence end as on the whole answer.
        let answers = [
            "Dr. Smith said the U.S. rate rose 3.5% in 2026. Then it fell, e.g. in the Oct. 15, 2026 report. Meet at 3:30 p.m. Then we eat at 6 pm. It costs $4.50 each, etc. That's all.",
            "Here are the steps:\n1. Open the folder\n2. Click No. 5\n3. Wait 5-10 minutes\nDone. It's 70°F and 5 km away.",
            "He said \"hi.\" Then left. See docs.ollama.com for more. Coffee w/ milk costs ~$5. Mr. Jones vs. Ms. Park, i.e. round two.",
            "The 1990s were fun. In the '90s we danced until 2:00. Call 555-123-4567 or email josh@example.com today.",
            """
            ## Quick plan

            Sure! Here's what I'd do before **Oct. 15**:

            1. Finish the results (≈2 hrs) - the figures are done.
            2. Email Dr. Patel by 5 p.m. Friday, i.e. before the U.S. holiday.

            | Task | Time |
            | --- | --- |
            | Results | 2h |

            ```python
            print("hi. there")
            ```
            It runs at ~20 tokens/s for $5/mo. Want 3 reminders?
            """,
        ]
        for answer in answers {
            for step in [1, 5] {
                var feed = SpeechFeed()
                var said: [String] = []
                var text = ""
                for character in answer {
                    text.append(character)
                    if text.count % step == 0 { said += feed.update(text) }
                }
                said += feed.finish(answer)
                expectEqual(said.joined(separator: " "), SpeechText.spoken(from: answer))
            }
        }
    }
}
