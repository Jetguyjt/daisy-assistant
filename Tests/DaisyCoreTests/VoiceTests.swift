import AVFoundation
import Foundation
import DaisyCore

/// Synthetic power traces in dBFS, 50 ms per reading. Quiet room around -60, speech around -25.
final class VoiceTests {
    private func run(_ endpointer: inout SpeechEndpointer, power: Float, seconds: TimeInterval, step: TimeInterval = 0.05) -> [SpeechEndpointer.Event] {
        var events: [SpeechEndpointer.Event] = []
        var remaining = seconds
        while remaining > 0.0001 { events.append(endpointer.observe(power: power, duration: step)); remaining -= step }
        return events
    }
    func testEndpointerStartsOnSpeechAndFinishesAfterTrailingSilence() {
        var endpointer = SpeechEndpointer()
        expectFalse(run(&endpointer, power: -60, seconds: 1).contains { $0 != .none })
        let start = run(&endpointer, power: -25, seconds: 1)
        expectEqual(start.filter { $0 == .speechStarted }.count, 1)
        expectTrue(endpointer.speaking)
        // A pause inside a sentence must not end it.
        expectFalse(run(&endpointer, power: -60, seconds: 0.5).contains(.finished))
        expectFalse(run(&endpointer, power: -25, seconds: 0.5).contains { $0 != .none })
        let tail = run(&endpointer, power: -60, seconds: 1.5)
        let finishIndex = tail.firstIndex(of: .finished)
        expectTrue(finishIndex != nil)
        // 1.3 s of silence at 50 ms steps: finished on roughly the 26th reading, not the 5th.
        expectTrue((finishIndex ?? 0) >= 24 && (finishIndex ?? 0) <= 27)
        expectFalse(endpointer.speaking)
        expectEqual(endpointer.observe(power: -25, duration: 0.05), .none)
    }
    func testEndpointerTimesOutWithoutSpeechAndCapsDuration() {
        var quiet = SpeechEndpointer()
        let events = run(&quiet, power: -60, seconds: 12)
        expectEqual(events.filter { $0 == .timedOut }.count, 1)
        expectFalse(events.contains(.finished)); expectFalse(events.contains(.speechStarted))
        var followUp = SpeechEndpointer(settings: .followUp)
        expectTrue(run(&followUp, power: -60, seconds: 6.5).contains(.timedOut))
        var long = SpeechEndpointer()
        let talking = run(&long, power: -25, seconds: 61)
        expectEqual(talking.filter { $0 == .finished }.count, 1)
        expectTrue(long.elapsed >= 60)
    }
    func testEndpointerHandlesPreRollThatAlreadyContainsSpeechAndNoisyRooms() {
        var preRoll = SpeechEndpointer()
        expectTrue(run(&preRoll, power: -25, seconds: 0.4).contains(.speechStarted))
        var noisy = SpeechEndpointer()
        _ = run(&noisy, power: -38, seconds: 3)          // fan
        expectTrue(noisy.threshold > -30)                 // floor adapted upward
        expectFalse(run(&noisy, power: -38, seconds: 2).contains(.speechStarted))
        expectTrue(run(&noisy, power: -15, seconds: 0.5).contains(.speechStarted))
    }
    func testBargeInIgnoresEchoResidueButHearsAVoice() {
        var barge = SpeechEndpointer(settings: .bargeIn)
        expectFalse(run(&barge, power: -48, seconds: 3).contains { $0 != .none })
        expectFalse(run(&barge, power: -30, seconds: 0.2).contains(.speechStarted))
        expectFalse(run(&barge, power: -48, seconds: 1).contains { $0 != .none })
        expectTrue(run(&barge, power: -22, seconds: 0.5).contains(.speechStarted))
        expectFalse(run(&barge, power: -48, seconds: 20).contains(.timedOut))
    }
    func testWakePhraseMatchingAndStripping() {
        for text in ["Hey Daisy", "hey, Daisy!", "so um hey Daisy what's up", "OK Daisy.", "Hi Daisy", "Hey Daisey", "hey daisie", "Hey days he, what's up"] {
            expectTrue(WakePhrase.matches(text))
        }
        for text in ["Daisy", "hey Maisie", "hey there", "hey days", "", "hey Jarvis"] { expectFalse(WakePhrase.matches(text)) }
        expectEqual(WakePhrase.stripping("Hey days he, what time is it?"), "what time is it?")
        expectEqual(WakePhrase.stripping("Hey Daisy, what time is it?"), "what time is it?")
        expectEqual(WakePhrase.stripping(" Hey, Daisy. What time is it?"), "What time is it?")
        expectEqual(WakePhrase.stripping("Hey Daisy"), "")
        expectEqual(WakePhrase.stripping("What time is it, Daisy?"), "What time is it, Daisy?")
    }
    func testWakePhraseFindsTheRequestInPartialsAndNeedsWholeWords() {
        // Apple's partials come punctuated and grow word by word.
        expectEqual(WakePhrase.request(after: "Hey, Daisy"), "")
        expectEqual(WakePhrase.request(after: "Hey, Daisy, what"), "what")
        expectEqual(WakePhrase.request(after: "Hey, Daisy, what time is it?"), "what time is it?")
        expectEqual(WakePhrase.request(after: "so, hey Daisy, turn it down"), "turn it down")
        expectEqual(WakePhrase.request(after: "Okay Daisy’s timer"), "timer")
        expectEqual(WakePhrase.request(after: "Hey, Dais"), nil)
        expectEqual(WakePhrase.request(after: "What time is it, Daisy?"), nil)
        // Substrings of other words used to count: "they, Daisy" and "hey days here".
        expectFalse(WakePhrase.matches("they, Daisy, come here"))
        expectFalse(WakePhrase.matches("hey days here we go"))
        expectFalse(WakePhrase.matches("okay daisyfield"))
        expectTrue(WakePhrase.phrases.contains("hey daisy"))
    }
    func testEndpointerFollowsVoiceActivityOverEnergy() {
        // A loud clatter the detector doesn't call speech never starts an utterance...
        var vad = SpeechEndpointer()
        var events: [SpeechEndpointer.Event] = []
        for _ in 0..<20 { events.append(vad.observe(power: -60, duration: 0.05, speech: 0.02)) }
        for _ in 0..<20 { events.append(vad.observe(power: -20, duration: 0.05, speech: 0.05)) }
        expectFalse(events.contains(.speechStarted))
        // ...a quiet voice across the room does, below where energy would have fired.
        for _ in 0..<6 { events.append(vad.observe(power: -54, duration: 0.05, speech: 0.9)) }
        expectEqual(events.filter { $0 == .speechStarted }.count, 1)
        // A dip between words (0.4, above the 0.35 release) keeps it going; real silence ends it.
        expectFalse((0..<10).map { _ in vad.observe(power: -58, duration: 0.05, speech: 0.4) }.contains(.finished))
        let tail = (0..<30).map { _ in vad.observe(power: -58, duration: 0.05, speech: 0.05) }
        let finish = tail.firstIndex(of: .finished) ?? -1
        expectTrue(finish >= 24 && finish <= 27)
        // Without probabilities it's the energy endpointer, unchanged.
        var energy = SpeechEndpointer()
        expectTrue((0..<10).map { _ in energy.observe(power: -54, duration: 0.05) }.allSatisfy { $0 == .none })
    }
    func testBargeInWithVoiceActivityStillNeedsToBeLouderThanTheEcho() {
        // Daisy's own echo is speech to the detector; only a voice over the echo level interrupts.
        var barge = SpeechEndpointer(settings: .bargeIn)
        var heard: [SpeechEndpointer.Event] = []
        for _ in 0..<80 { heard.append(barge.observe(power: -30, duration: 0.05, speech: 0.95)) }
        expectFalse(heard.contains(.speechStarted))
        // Loud but not speech (a cough into the mic, a dropped cup) doesn't either.
        expectFalse((0..<12).map { _ in barge.observe(power: -10, duration: 0.05, speech: 0.1) }.contains(.speechStarted))
        expectTrue((0..<12).map { _ in barge.observe(power: -10, duration: 0.05, speech: 0.95) }.contains(.speechStarted))
    }
    func testEndpointerCanContinueAnUtteranceUnderNewSettings() {
        var standby = SpeechEndpointer(settings: .standby)
        for _ in 0..<20 { _ = standby.observe(power: -60, duration: 0.05) }
        for _ in 0..<10 { _ = standby.observe(power: -25, duration: 0.05) }
        expectTrue(standby.speaking)
        // "Hey Daisy" was in it: the request keeps the utterance and floor but gets the longer pause.
        var request = SpeechEndpointer(settings: .afterWake, continuing: standby)
        expectTrue(request.spoke); expectEqual(request.noiseFloor, standby.noiseFloor)
        expectFalse((0..<22).map { _ in request.observe(power: -60, duration: 0.05) }.contains(.finished))   // 1.1 s would end standby
        expectTrue((0..<6).map { _ in request.observe(power: -60, duration: 0.05) }.contains(.finished))
        // A finished utterance carries over only its floor.
        var fresh = SpeechEndpointer(settings: .afterWake, continuing: request)
        expectFalse(fresh.spoke)
        expectTrue((0..<170).map { _ in fresh.observe(power: -60, duration: 0.05) }.contains(.timedOut))
    }
    func testWAVFileWritesReadableSixteenKilohertzMono() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("daisy-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = (0..<16000).map { Int16(truncatingIfNeeded: Int(sin(Double($0) / 20) * 8000)) }
        try WAVFile.write(samples: samples, sampleRate: 16000, to: url)
        let data = try Data(contentsOf: url)
        expectEqual(data.count, 44 + 32000)
        expectEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        expectEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        let info = try await LocalProcess.capture(executable: URL(fileURLWithPath: "/usr/bin/afinfo"), arguments: [url.path])
        expectTrue(info.contains("16000 Hz")); expectTrue(info.contains("1 ch")); expectTrue(info.contains("duration: 1.0"))
    }
    func testSentencesChunkForEarlyFirstAudio() {
        let text = "Sure. The draft is due mid-October. Start with the results section, since the figures already exist. Then write the methods! Does that plan work?"
        let chunks = SpeechText.sentences(from: text)
        expectEqual(chunks.first, "Sure. The draft is due mid-October.")
        expectEqual(chunks.joined(separator: " "), text)
        expectTrue(chunks.allSatisfy { ".!?".contains($0.last!) })
        expectTrue(SpeechText.sentences(from: "   ").isEmpty)
        expectEqual(SpeechText.sentences(from: "no punctuation at all"), ["no punctuation at all"])
        let long = String(repeating: "word ", count: 200).trimmingCharacters(in: .whitespaces) + "."
        expectTrue(SpeechText.sentences(from: long).allSatisfy { $0.count <= 600 })
    }
    func testSpeechWorkerSpeaksTheLineProtocolAndSurvivesErrors() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("worker_fixture.py")
        try """
        import json, sys, struct
        out = sys.stdout; sys.stdout = sys.stderr
        print("library chatter that must not reach the protocol")
        for line in sys.stdin:
            req = json.loads(line)
            if not req["text"].strip():
                out.write(json.dumps({"error": "empty"}) + "\\n"); out.flush(); continue
            data = struct.pack("<8000h", *([0] * 8000))
            hdr = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, 16000, 32000, 2, 16) + b"data" + struct.pack("<I", len(data))
            open(req["output"], "wb").write(hdr + data)
            out.write(json.dumps({"ok": True, "seconds": 0.01}) + "\\n"); out.flush()
        """.write(to: script, atomically: true, encoding: .utf8)
        let worker = SpeechWorker(python: URL(fileURLWithPath: "/usr/bin/python3"), script: script)
        let first = root.appendingPathComponent("first.wav")
        _ = try await worker.synthesize(text: "Hello there.", voice: "bm_george", speed: 1, output: first)
        expectTrue(FileManager.default.fileExists(atPath: first.path))
        let running = await worker.isRunning; expectTrue(running)
        do { _ = try await worker.synthesize(text: "   ", voice: "bm_george", speed: 1, output: root.appendingPathComponent("none.wav")); fail("empty text should fail") }
        catch { expectTrue(error.localizedDescription.contains("empty")) }
        let second = root.appendingPathComponent("second.wav")
        _ = try await worker.synthesize(text: "Still here.", voice: "bm_george", speed: 1, output: second)
        expectTrue(FileManager.default.fileExists(atPath: second.path))
        await worker.stop()
        let stopped = await worker.isRunning; expectFalse(stopped)
    }
    func testStandbyPresetWaitsIndefinitelyAndClosesUtterances() {
        var standby = SpeechEndpointer(settings: .standby)
        var events: [SpeechEndpointer.Event] = []
        for _ in 0..<1200 { events.append(standby.observe(power: -60, duration: 0.05)) }   // a quiet minute
        expectTrue(events.allSatisfy { $0 == .none })
        for _ in 0..<20 { events.append(standby.observe(power: -25, duration: 0.05)) }
        expectTrue(events.contains(.speechStarted))
        var closed = false
        for _ in 0..<30 { if standby.observe(power: -60, duration: 0.05) == .finished { closed = true } }
        expectTrue(closed)
    }
    private func buffer(channels: AVAudioChannelCount, interleaved: Bool, frames: Int, fill: (Int, Int) -> Float) -> AVAudioPCMBuffer {
        // More than two channels needs an explicit layout; the device reports discrete channels too.
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, interleaved: interleaved, channelLayout: layout)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1)))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = buffer.floatChannelData!
        for c in 0..<Int(channels) {
            for i in 0..<frames {
                if interleaved { data[0][i * Int(channels) + c] = fill(c, i) } else { data[c][i] = fill(c, i) }
            }
        }
        return buffer
    }
    func testDownsamplerKeepsChannelZeroOfMultichannelInput() {
        // Voice processing delivers seven channels; a straight AVAudioConverter downmix wrote zeros.
        let tone: (Int, Int) -> Float = { c, i in c == 0 ? 0.5 * sin(Float(i) * 2 * .pi * 440 / 48000) : 0 }
        let seven = buffer(channels: 7, interleaved: false, frames: 4800, fill: tone)
        let downsampler = MicDownsampler(inputFormat: seven.format)!
        let result = downsampler.convert(seven)
        expectTrue(result != nil)
        expectTrue(abs((result?.power ?? -140) - (-9.0)) < 1.5)          // 0.5 amplitude sine is about -9 dBFS
        // The resampler emits in blocks (1360 first, then mostly 1664), averaging 1,600 per 100 ms.
        var total = result?.samples.count ?? 0
        for _ in 0..<9 { total += downsampler.convert(seven)?.samples.count ?? 0 }
        expectTrue(abs(total - 16000) <= 400)
        let quietVoice = buffer(channels: 7, interleaved: false, frames: 4800) { c, i in c == 0 ? 0 : 0.8 * sin(Float(i) / 7) }
        expectTrue((MicDownsampler(inputFormat: quietVoice.format)!.convert(quietVoice)?.power ?? 0) < -60)
        let interleaved = buffer(channels: 2, interleaved: true, frames: 4800, fill: tone)
        expectTrue(abs((MicDownsampler(inputFormat: interleaved.format)!.convert(interleaved)?.power ?? -140) - (-9.0)) < 1.5)
        let empty = buffer(channels: 3, interleaved: false, frames: 0) { _, _ in 0 }
        expectTrue(MicDownsampler(inputFormat: empty.format)!.convert(empty) == nil)
    }
    func testBargeInCalibratesToEchoAndIgnoresSentenceGaps() {
        var barge = SpeechEndpointer(settings: .bargeIn)
        func feed(_ power: Float, _ seconds: Double) -> [SpeechEndpointer.Event] {
            var events: [SpeechEndpointer.Event] = []
            var t = 0.0
            while t < seconds - 0.0001 { events.append(barge.observe(power: power, duration: 0.05)); t += 0.05 }
            return events
        }
        // Daisy speaking: echo residue at -30 dB, with quiet gaps between sentences.
        var heard: [SpeechEndpointer.Event] = []
        for _ in 0..<4 { heard += feed(-30, 2.0); heard += feed(-55, 0.4) }
        expectFalse(heard.contains(.speechStarted))
        // The user talks over it, clearly louder than the echo.
        expectTrue(feed(-10, 0.6).contains(.speechStarted))
        // Loud echo from the very first reading must not trigger during calibration.
        var early = SpeechEndpointer(settings: .bargeIn)
        var first: [SpeechEndpointer.Event] = []
        for _ in 0..<40 { first.append(early.observe(power: -20, duration: 0.05)) }
        expectFalse(first.contains(.speechStarted))
    }
    func testConfigurationDecodesFilesWrittenBeforeNewFields() throws {
        let older = """
        {"model":"qwen3.5:4b","whisperExecutable":"/opt/homebrew/bin/whisper-cli","whisperModel":"","ollamaExecutable":"/opt/homebrew/bin/ollama","ollamaModels":"","speakResponses":true,"allowFileSearch":true,"voice":"Samantha"}
        """
        let config = try JSONDecoder().decode(Configuration.self, from: Data(older.utf8))
        expectEqual(config.listeningMode, nil); expectEqual(config.naturalVoice, nil); expectEqual(config.browserNode, nil)
        expectTrue(config.speakResponses)
        let roundTrip = try JSONDecoder().decode(Configuration.self, from: try JSONEncoder().encode(config))
        expectEqual(roundTrip.model, "qwen3.5:4b")
    }
}
