import Foundation
import DaisyCore

/// Heart is the default; any English Kokoro voice, or a weighted blend written the way
/// synthesize.py reads it ("af_heart:0.7,af_bella:0.3"), can be chosen instead.
final class VoiceBlendTests {
    func testDefaultVoiceAndTheCatalog() {
        expectEqual(NaturalSpeech.defaultVoice, "af_heart")
        expectEqual(NaturalSpeech.heartBellaBlend, "af_heart:0.7,af_bella:0.3")
        let ids = NaturalSpeech.voices.map(\.id)
        expectEqual(Set(ids).count, ids.count)
        expectEqual(ids.first, NaturalSpeech.heartBellaBlend)
        expectEqual(NaturalSpeech.voices.first?.name, "Heart + Bella blend")
        expectTrue(NaturalSpeech.voices.first?.isBlend == true)
        expectEqual(NaturalSpeech.voices.filter { !$0.isBlend }.count, 28)
        for id in ["af_heart", "af_bella", "am_michael", "bm_george", "bm_fable", "bf_emma", "bm_lewis", "bf_isabella"] {
            expectTrue(ids.contains(id))
        }
        expectEqual(NaturalSpeech.voices.filter { $0.accent == .british }.count, 8)
        let george = NaturalSpeech.voices.first { $0.id == "bm_george" }
        expectEqual(george?.name, "George · British")
        expectEqual(george?.female, false)
        expectEqual(NaturalSpeech.voices.first { $0.id == "af_heart" }?.female, true)
    }
    func testBlendsReadLikeSynthesizePy() throws {
        let single = try NaturalSpeech.blend("af_heart")
        expectEqual(single.map(\.voice), ["af_heart"])
        expectEqual(single.map(\.weight), [1])
        let blend = try NaturalSpeech.blend(NaturalSpeech.heartBellaBlend)
        expectEqual(blend.map(\.voice), ["af_heart", "af_bella"])
        expectTrue(abs(blend[0].weight - 0.7) < 1e-9 && abs(blend[1].weight - 0.3) < 1e-9)
        let scaled = try NaturalSpeech.blend(" af_heart:7 , af_bella:3 ")
        expectTrue(abs(scaled[0].weight - 0.7) < 1e-9 && abs(scaled.reduce(0) { $0 + $1.weight } - 1) < 1e-9)
        try expectEqual(try NaturalSpeech.blend("af_heart,bf_emma").map(\.weight), [0.5, 0.5])
        try expectEqual(try NaturalSpeech.blend("bm_george:1").map(\.voice), ["bm_george"])
        try expectEqual(try NaturalSpeech.blend("af_heart:3,af_bella").map(\.weight), [0.75, 0.25])
    }
    func testBadBlendsSayWhatIsWrong() {
        let cases = [("", "empty entry"), ("af_heart,,af_bella", "empty entry"), ("af_hert", "not a Kokoro voice"),
                     ("jf_alpha", "not a Kokoro voice"), ("AF_HEART", "not a Kokoro voice"), ("af_heart:0", "above zero"),
                     ("af_heart:-1,af_bella:2", "above zero"), ("af_heart:lots", "above zero"), ("af_heart:", "above zero"),
                     ("af_heart:nan", "above zero"), ("af_heart:inf", "above zero"), ("af_heart:0.5,af_heart:0.5", "listed twice"),
                     ("af_heart:0.7;af_bella:0.3", "above zero")]
        for (setting, reason) in cases {
            do { _ = try NaturalSpeech.blend(setting); fail("\"\(setting)\" should be rejected") }
            catch { expectTrue(error.localizedDescription.contains(reason)) }
        }
    }
    func testShortNames() {
        expectEqual(NaturalSpeech.shortName(for: "af_heart"), "Heart")
        expectEqual(NaturalSpeech.shortName(for: NaturalSpeech.heartBellaBlend), "Heart + Bella")
        expectEqual(NaturalSpeech.shortName(for: "af_heart:0.5,bm_george:0.5"), "Heart + George")
        expectEqual(NaturalSpeech.shortName(for: "nobody"), "nobody")
    }
    func testSynthesisChecksTheVoiceBeforeAnythingRuns() async {
        // Tests use an empty data folder, so a good setting gets as far as "not installed".
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).wav")
        do { try await NaturalSpeech.synthesize(text: "Hi.", voice: NaturalSpeech.heartBellaBlend, speed: 1, output: output, worker: nil); fail("needs the runtime") }
        catch { expectTrue(error.localizedDescription.contains("not installed")) }
        do { try await NaturalSpeech.synthesize(text: "Hi.", voice: "af_heart:0", speed: 1, output: output, worker: nil); fail("bad weight") }
        catch { expectTrue(error.localizedDescription.contains("weight for af_heart")) }
        do { try await NaturalSpeech.synthesize(text: "Hi.", voice: NaturalSpeech.defaultVoice, speed: 2, output: output, worker: nil); fail("too fast") }
        catch { expectTrue(error.localizedDescription.contains("speed")) }
    }
    func testWorkerPassesTheVoiceSettingAndArgumentsThrough() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("echo_fixture.py")
        try """
        import json, sys
        out = sys.stdout; sys.stdout = sys.stderr
        for line in sys.stdin:
            req = json.loads(line)
            open(req["output"], "w").write(json.dumps({"voice": req["voice"], "argv": sys.argv[1:]}))
            out.write(json.dumps({"ok": True, "seconds": 0.01}) + "\\n"); out.flush()
        """.write(to: script, atomically: true, encoding: .utf8)
        let worker = SpeechWorker(python: URL(fileURLWithPath: "/usr/bin/python3"), script: script, arguments: ["--models", "/tmp/models"])
        let output = root.appendingPathComponent("echo.json")
        _ = try await worker.synthesize(text: "Hello there.", voice: NaturalSpeech.heartBellaBlend, speed: 1, output: output)
        await worker.stop()
        let echoed = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any]
        expectEqual(echoed?["voice"] as? String, NaturalSpeech.heartBellaBlend)
        expectEqual(echoed?["argv"] as? [String], ["--serve", "--models", "/tmp/models"])
    }
}
