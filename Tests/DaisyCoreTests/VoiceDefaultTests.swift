import Foundation
import DaisyCore

final class VoiceDefaultTests {
    func testJarvisGeorgeAndMissingVoiceBecomeHeart() {
        var george = Configuration(); george.naturalVoice = "bm_george"
        expectEqual(george.withDaisyVoice().naturalVoice, "af_heart")
        expectEqual(george.withDaisyVoice().daisyVoiceApplied, true)
        expectEqual(Configuration().withDaisyVoice().naturalVoice, "af_heart")
    }

    func testOtherChoicesAreKept() {
        var michael = Configuration(); michael.naturalVoice = "am_michael"
        expectEqual(michael.withDaisyVoice().naturalVoice, "am_michael")
    }

    func testGeorgeChosenAfterTheSwitchSticks() {
        var chosen = Configuration(); chosen.naturalVoice = "bm_george"; chosen.daisyVoiceApplied = true
        expectEqual(chosen.withDaisyVoice().naturalVoice, "bm_george")
    }
}
