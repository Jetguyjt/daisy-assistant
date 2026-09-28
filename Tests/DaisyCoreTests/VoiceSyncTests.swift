import Foundation
import DaisyCore

/// While Daisy talks, the reply shows a sentence at a time as the voice reaches it. These pin
/// how much of the text each spoken chunk lets onto the screen.
final class VoiceSyncTests {
    func testEachStreamedChunkRevealsItsOwnSentence() {
        var feed = SpeechFeed()
        let first = "Let me check that for you. "
        expectEqual(feed.update(first), ["Let me check that for you."])
        expectEqual(feed.reveals, [first.count])
        let second = first + "The file is in your Documents folder. "
        expectEqual(feed.update(second), ["The file is in your Documents folder."])
        expectEqual(feed.reveals, [first.count, second.count])
    }

    func testChunksFromOneBatchRevealAtSentenceEnds() {
        var feed = SpeechFeed()
        let answer = "Sure thing. Your essay draft is due on the fifteenth, which is a Wednesday. "
            + "I'd block out forty minutes each evening this week so it doesn't pile up at the end. "
            + "Want me to add those blocks to your calendar?"
        let chunks = feed.finish(answer)
        expectTrue(chunks.count > 1)
        expectEqual(feed.reveals.count, chunks.count)
        expectEqual(feed.reveals.last, answer.count)
        let characters = Array(answer)
        for (earlier, later) in zip(feed.reveals, feed.reveals.dropFirst()) { expectTrue(earlier <= later) }
        for reveal in feed.reveals.dropLast() {
            // Never mid-word: every earlier stop lands just after a sentence's end.
            expectTrue(reveal > 0 && reveal < characters.count)
            expectTrue(".!?".contains(characters[reveal - 1]))
        }
    }

    func testHeldBackTextIsRevealedWithTheChunkThatSaysIt() {
        var feed = SpeechFeed()
        expectEqual(feed.update("Let me check that for you. "), ["Let me check that for you."])
        // "Found it." is short, so it waits for the next sentence; nothing new shows yet.
        expectEqual(feed.update("Let me check that for you. Found it. "), [])
        expectEqual(feed.reveals.count, 1)
        let text = "Let me check that for you. Found it. The file is in Documents. "
        expectEqual(feed.update(text), ["Found it. The file is in Documents."])
        expectEqual(feed.reveals.last, text.count)
    }

    func testTextTheVoiceSkipsShowsWithTheNextSentence() {
        var feed = SpeechFeed()
        _ = feed.update("Use this:\n```swift\nlet x = 1\n")
        let answer = "Use this:\n```swift\nlet x = 1\n```\nThat is all."
        expectEqual(feed.finish(answer), ["That is all."])
        expectEqual(feed.reveals.last, answer.count)
    }

    func testWhereTheVoiceStopsEverythingShows() {
        var feed = SpeechFeed(limit: 300)
        let long = String(repeating: "This is a sentence that keeps going for a while. ", count: 40)
        _ = feed.update(long)
        _ = feed.finish(long)
        expectEqual(feed.reveals.last, Int.max)
    }

    func testANewReplyStartsCountingFromItsOwnText() {
        var feed = SpeechFeed()
        _ = feed.update("Let me check that for you. ")
        let other = "Something else entirely happened here. "
        expectEqual(feed.update(other), ["Something else entirely happened here."])
        expectEqual(feed.reveals.last, other.count)
    }
}
