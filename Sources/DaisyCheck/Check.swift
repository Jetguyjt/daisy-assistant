import AVFoundation
import Foundation
import DaisyCore

@main struct DaisyCheck {
    static func main() async {
        setbuf(stdout, nil)
        let runtime = LocalRuntime()
        do {
            let args = CommandLine.arguments
            if args.dropFirst().first == "--render-icon" {
                // Used by build-app.sh: the bundle icon comes from the same drawing as the Dock icon.
                guard args.count >= 3 else { print("usage: daisy-check --render-icon out.png [#RRGGBB]"); exit(2) }
                let accent = args.count >= 4 ? RGB(hex: args[3]) : ThemePalette.defaultAccent
                guard let accent, let png = AppIconArt.png(palette: .derived(from: accent)) else { print("could not render the icon"); exit(1) }
                try png.write(to: URL(fileURLWithPath: args[2]))
                exit(0)
            }
            if args.dropFirst().first == "--delegation" { exit(await DelegationCheck.run(Array(args.dropFirst(2)))) }
            if args.dropFirst().first == "--hermes" {
                // Live run through the same ACP bridge the app uses. Approvals are always declined,
                // so a check can never send, delete or change anything.
                let hermes = HermesBackend(settings: .init(workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
                    sessionFile: FileManager.default.temporaryDirectory.appendingPathComponent("daisy-check-hermes-session"),
                    environment: ["DAISY_SESSION": "1"]))
                let started = Date()
                let link = await hermes.connect()
                print(String(format: "link after %.1fs: %@", Date().timeIntervalSince(started), "\(link)"))
                guard case .ready = link else { await hermes.shutdown(); exit(1) }
                for prompt in args.dropFirst(2) {
                    print("\n> \(prompt)")
                    let turnStart = Date()
                    var first: TimeInterval?
                    for try await event in hermes.send(prompt) {
                        switch event {
                        case .text(let text):
                            if first == nil { first = Date().timeIntervalSince(turnStart) }
                            print(text, terminator: "")
                        case .tool(let tool): print("\n  [\(tool.state.rawValue)] \(tool.title)\(tool.detail.map { " · " + $0 } ?? "")")
                        case .approval(let request):
                            print("\n  [approval declined by check] \(request.title) — \(request.detail ?? "")")
                            await hermes.resolve(approval: request.id, optionID: nil)
                        case .finished(let reason): print(String(format: "\n  (%@; first text %.1fs, total %.1fs)", reason, first ?? -1, Date().timeIntervalSince(turnStart)))
                        default: break
                        }
                    }
                }
                await hermes.shutdown()
                return
            }
            if args.dropFirst().first == "--browser-metadata" {
                let connection = MCPConnection()
                let script = Configuration.dataDirectory.appendingPathComponent("Runtime/browser/node_modules/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js")
                let node = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/node")
                do {
                    try await connection.start(executable: node, arguments: ChromeConnection.adapterArguments(script: script.path), environment: ChromeConnection.adapterEnvironment)
                    let result = try await connection.request(method: "tools/list", parameters: .object([:]))
                    guard case .object(let object) = result, case .array(let list) = object["tools"] else { throw DaisyError.message("Missing tool metadata") }
                    let names = Set(list.compactMap { value -> String? in if case .object(let fields) = value { return fields["name"]?.stringValue }; return nil })
                    guard Set(["list_pages", "new_page", "take_snapshot"]).isSubset(of: names), !names.contains("evaluate_script"), !names.contains("click"), !names.contains("fill") else { throw DaisyError.message("Unexpected browser adapter configuration") }
                    print("PASS — real MCP initialize + tools/list; read/navigation metadata present; input/JavaScript disabled. No browser tool invoked or account accessed.")
                    await connection.stop(); return
                } catch { await connection.stop(); throw error }
            }
            if args.dropFirst().first == "--spoken" {
                // Print what the voice would say for a Markdown answer (file path or stdin).
                let text = args.count > 2 ? try String(contentsOfFile: args[2], encoding: .utf8)
                    : String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                print(SpeechText.spoken(from: text))
                return
            }
            if args.dropFirst().first == "--voice-ab" { try await VoiceAB.run(Array(args.dropFirst(2))); return }
            if args.dropFirst().first == "--speech", args.count > 2 {
                // Apple's recognizer (or Whisper when it isn't ready) on a WAV, and Silero's view of it.
                let configuration = try Configuration.load()
                let settings = configuration.speechInput ?? SpeechInputSettings()
                print("Apple recognizer: \(await AppleSpeech.state(locale: settings.localeIdentifier))")
                let speech = SpeechRuntime()
                await speech.configure(settings)
                let started = Date()
                let text = try await speech.transcribe(audio: URL(fileURLWithPath: args[2]), configuration: configuration)
                let status = await speech.status
                print(String(format: "transcript (%.2fs, %@): %@", Date().timeIntervalSince(started), status.active.rawValue, text))
                if let vad = SileroVAD.installed(settings) {
                    let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[2]), commonFormat: .pcmFormatInt16, interleaved: true)
                    if let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                       file.processingFormat.sampleRate == 16000, (try? file.read(into: buffer)) != nil, let data = buffer.int16ChannelData {
                        let steps = vad.process(Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))))
                        print("Silero, one per 32 ms: " + steps.map { String(format: "%.2f", $0) }.joined(separator: " "))
                    }
                } else { print("Silero isn't installed (scripts/setup-speech.sh)") }
                await speech.shutdown()
                return
            }
            if args.dropFirst().first == "--endpoint", args.count > 2 {
                // Replay a WAV through the endpointer in 50 ms steps and print what it would have done.
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[2]))
                let format = file.processingFormat
                let step = AVAudioFrameCount(format.sampleRate * 0.05)
                var endpointer = SpeechEndpointer(settings: args.count > 3 && args[3] == "barge" ? .bargeIn : .standard)
                var position = 0.0
                while file.framePosition < file.length {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: step) else { break }
                    try file.read(into: buffer, frameCount: step)
                    guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { break }
                    var sum: Float = 0
                    for i in 0..<Int(buffer.frameLength) { sum += channel[i] * channel[i] }
                    let rms = (sum / Float(buffer.frameLength)).squareRoot()
                    let power = 20 * log10(max(rms, 1e-7))
                    let duration = Double(buffer.frameLength) / format.sampleRate
                    let event = endpointer.observe(power: power, duration: duration)
                    if event != .none { print(String(format: "%.2fs  %@  (power %.1f dB, threshold %.1f dB)", position + duration, "\(event)", power, endpointer.threshold)) }
                    position += duration
                }
                print(String(format: "end of file at %.2fs; spoke=%@", position, endpointer.spoke ? "yes" : "no"))
                return
            }
            if args.dropFirst().first == "--wake-gate", args.count > 2 {
                // What the wake gate would do with a WAV: transcribe with the installed model, match the phrase.
                let configuration = try Configuration.load()
                let speech = SpeechRuntime()
                defer { Task { await speech.shutdown() } }
                let started = Date()
                let text = try await speech.transcribe(audio: URL(fileURLWithPath: args[2]), configuration: configuration)
                print(String(format: "transcript (%.2fs): %@", Date().timeIntervalSince(started), text))
                print("wake phrase: \(WakePhrase.matches(text) ? "MATCH" : "no match"); request after stripping: \(WakePhrase.stripping(text))")
                await speech.shutdown()
                return
            }
            if args.dropFirst().first == "--voice-timing", args.count > 2 {
                // Persistent transcriber and voice worker against the one-shot paths, on a real WAV.
                let configuration = try Configuration.load()
                let wav = URL(fileURLWithPath: args[2])
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("daisy-timing-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                func time(_ label: String, _ body: () async throws -> Void) async {
                    let started = Date()
                    do { try await body(); print(String(format: "%-38@ %.2fs", label, Date().timeIntervalSince(started))) }
                    catch { print("\(label) failed: \(error.localizedDescription)") }
                }
                await time("whisper-cli, one process") {
                    _ = try await SpeechDecoder.transcribe(audio: wav, executable: URL(fileURLWithPath: configuration.whisperExecutable), model: URL(fileURLWithPath: configuration.whisperModel))
                }
                let speech = SpeechRuntime()
                await time("whisper-server, start + first request") { try await speech.ensureRunning(configuration: configuration); _ = try await speech.transcribe(audio: wav) }
                await time("whisper-server, warm request") { _ = try await speech.transcribe(audio: wav) }
                await speech.shutdown()
                let sentence = "The paper draft is due in the middle of October, so the results section comes first."
                await time("kokoro, one process") {
                    try await NaturalSpeech.synthesize(text: sentence, voice: NaturalSpeech.defaultVoice, speed: 1, input: folder.appendingPathComponent("a.txt"), output: folder.appendingPathComponent("a.wav"))
                }
                let worker = SpeechWorker()
                await time("kokoro worker, start + first sentence") { _ = try await worker.synthesize(text: sentence, voice: NaturalSpeech.defaultVoice, speed: 1, output: folder.appendingPathComponent("b.wav")) }
                await time("kokoro worker, warm sentence") { _ = try await worker.synthesize(text: sentence, voice: NaturalSpeech.defaultVoice, speed: 1, output: folder.appendingPathComponent("c.wav")) }
                await time("kokoro worker, short first chunk") { _ = try await worker.synthesize(text: "Sure. The draft is due mid-October.", voice: NaturalSpeech.defaultVoice, speed: 1, output: folder.appendingPathComponent("d.wav")) }
                await worker.stop()
                return
            }
            if args.dropFirst().first == "--mic" {
                // The app's engine and downsampler on the real microphone. Optional WAV plays through
                // the engine meanwhile, fed to the barge-in endpointer to catch self-interruption.
                final class Readings: @unchecked Sendable {
                    let lock = NSLock(); var items: [(Float, Double)] = []; var downsampler: MicDownsampler?
                    func add(_ buffer: AVAudioPCMBuffer) {
                        lock.lock(); defer { lock.unlock() }
                        if downsampler == nil { downsampler = MicDownsampler(inputFormat: buffer.format) }
                        guard let converted = downsampler?.convert(buffer) else { return }
                        items.append((converted.power, Double(converted.samples.count) / MicDownsampler.sampleRate))
                    }
                }
                let readings = Readings()
                let session = try MicrophoneEngine.start(preferVoiceProcessing: !args.contains("plain")) { buffer in readings.add(buffer) }
                print("engine started · voice processing \(session.voiceProcessing ? "on" : "off (fallback)") · input \(session.inputFormat.channelCount) ch at \(Int(session.inputFormat.sampleRate)) Hz")
                let playback = args.dropFirst(2).first { $0.hasSuffix(".wav") }
                if let playback {
                    let file = try AVAudioFile(forReading: URL(fileURLWithPath: playback))
                    session.engine.connect(session.player, to: session.engine.mainMixerNode, format: file.processingFormat)
                    session.player.volume = 0.5
                    session.player.scheduleFile(file, at: nil, completionHandler: nil)
                    session.player.play()
                    print("playing \(URL(fileURLWithPath: playback).lastPathComponent) through the engine")
                }
                try await Task.sleep(nanoseconds: 4_000_000_000)
                session.stop()
                let items = readings.lock.withLock { readings.items }
                var endpointer = SpeechEndpointer(settings: playback == nil ? .standard : .bargeIn)
                var events: [String] = []
                var t = 0.0
                for (power, duration) in items {
                    t += duration
                    let event = endpointer.observe(power: power, duration: duration)
                    if event != .none { events.append(String(format: "%.2fs %@", t, "\(event)")) }
                }
                let powers = items.map(\.0)
                print("chunks \(items.count) · audio \(String(format: "%.2f", t))s · power min \(String(format: "%.1f", powers.min() ?? -140)) max \(String(format: "%.1f", powers.max() ?? -140)) dB")
                print("\(playback == nil ? "endpointer" : "barge-in endpointer") events: \(events.isEmpty ? "none" : events.joined(separator: ", "))")
                return
            }
            if args.dropFirst().first == "--runtime" {
                try await checkRuntime()
                return
            }
            let model = args.count > 1 ? args[1] : "qwen3.5:4b"
            let repo = URL(fileURLWithPath: args.count > 2 ? args[2] : FileManager.default.currentDirectoryPath)
            var configuration = Configuration()
            let installedModels = Configuration.dataDirectory.appendingPathComponent("Runtime/ollama/models")
            configuration.ollamaModels = FileManager.default.fileExists(atPath: installedModels.path) ? installedModels.path : repo.appendingPathComponent(".runtime/ollama/models").path
            try await runtime.ensureRunning(configuration: configuration)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("daisy-check-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }
            let fixtures = folder.appendingPathComponent("fixtures")
            try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
            try Data("Synthetic test file, not a personal resume.".utf8).write(to: fixtures.appendingPathComponent("resume-2026.txt"))
            let store = try MemoryStore(url: folder.appendingPathComponent("memory.sqlite"))
            try await store.put(key: "response_style", value: "Keep responses short, at most two sentences.", source: "Synthetic smoke-test preference")
            let client = OllamaClient()
            try await client.verifyLocal(model: model)
            print("LOCAL MODEL VERIFIED: \(model)")
            let engine = AssistantEngine(client: client)
            let tasks = try TaskStore(url: folder.appendingPathComponent("tasks.json"))
            var results: [[String: Any]] = []
            var failedChecks: [String] = []
            let prompts = [
                "Say hello in one short sentence.",
                "Find my latest resume.",
                "What response length do I prefer?",
                "Text my dad that I will be home at six.",
                "What is on my Google Calendar tomorrow?",
                "Calculate (125 * 0.18) + 2 using the calculator.",
                "Find resume-2026.txt, read its contents, and tell me what it says.",
                "Prepare a task titled Synthetic essay outline in project College essays due 2026-10-01. Do not save it yet.",
                "Prepare a new file hello.py containing print(2 + 2). Do not run or save it yet."
            ]
            for prompt in prompts {
                let builtins = try BuiltInCapabilities.registry(root: fixtures, allowFiles: true, memories: try await store.all(), memoryStore: store, permissions: ["read_text_file": true])
                let registry = try CapabilityRegistry(capabilities: builtins.entries + TaskCapabilityProvider(store: tasks).capabilities() + DraftCapabilityProvider(root: fixtures).capabilities() + BrowserCapabilityProvider(connection: ChromeConnection(), available: false).capabilities())
                let response = try await engine.respond(text: prompt, history: [], memories: try await store.all(), model: model, registry: registry)
                let files = response.search?.files.count ?? 0
                let lower = response.text.lowercased()
                let unavailable = lower.contains("cannot") || lower.contains("can't") || lower.contains("unavailable") || lower.contains("don't have access") || lower.contains("do not have access")
                let passed: Bool
                if prompt.contains("Prepare a task") { let saved = await tasks.all(); passed = response.receipts.contains { $0.tool == "prepare_task" && $0.output.review != nil } && saved.isEmpty }
                else if prompt.contains("Prepare a new file") { passed = response.receipts.contains { $0.tool == "prepare_file" && $0.output.review != nil } && !FileManager.default.fileExists(atPath: fixtures.appendingPathComponent("hello.py").path) }
                else if prompt.contains("read its contents") { passed = response.receipts.contains { $0.tool == "read_text_file" && $0.status == .succeeded } && lower.contains("synthetic") }
                else if prompt.contains("Calculate") { passed = response.receipts.contains { $0.tool == "calculate" && $0.status == .succeeded } && lower.contains("24.5") }
                else if prompt.contains("resume") { passed = files == 1 }
                else if prompt.contains("response length") {
                    passed = response.search == nil && (lower.contains("two sentences") || lower.contains("2 sentences")) && !lower.contains("don't have") && !lower.contains("do not have")
                }
                else if prompt.contains("dad") || prompt.contains("Calendar") { passed = response.search == nil && unavailable }
                else { passed = response.search == nil && response.text.split(separator: " ").count <= 30 }
                if !passed { failedChecks.append(prompt) }
                print(String(format: "%.2fs | %@ | files=%d | %@", response.elapsed, prompt, files, response.text))
                results.append(["prompt": prompt, "seconds": response.elapsed, "fileCount": files, "answer": response.text, "passed": passed,
                                "capabilities": response.receipts.map { "\($0.tool):\($0.status.rawValue)" },
                                "receipts": response.receipts.map { $0.output.summary }])
            }
            let audio = folder.appendingPathComponent("speech.wav")
            let phrase = "Find my latest resume."
            let voiceStart = Date()
            let natural = folder.appendingPathComponent("natural.wav")
            try await NaturalSpeech.synthesize(text: phrase, voice: NaturalSpeech.defaultVoice, speed: 1,
                input: folder.appendingPathComponent("input.txt"), output: natural)
            try await LocalProcess.run(executable: URL(fileURLWithPath: "/usr/bin/afconvert"),
                arguments: [natural.path, audio.path, "-f", "WAVE", "-d", "LEI16@16000", "-c", "1"])
            let synthesisSeconds = Date().timeIntervalSince(voiceStart)
            let transcriptionStart = Date()
            let transcript = try await SpeechDecoder.transcribe(audio: audio,
                executable: URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli"),
                model: repo.appendingPathComponent(".runtime/models/ggml-base.en.bin"))
            let transcriptionSeconds = Date().timeIntervalSince(transcriptionStart)
            print("LOCAL VOICE ROUND TRIP: \(transcript)")
            guard transcript.lowercased().contains("resume") else { throw DaisyError.message("Speech round-trip did not recognize the fixture phrase.") }
            let report: [String: Any] = ["model": model, "date": ISO8601DateFormatter().string(from: Date()), "results": results,
                "voice": ["syntheticInput": phrase, "transcript": transcript, "synthesisSeconds": synthesisSeconds, "transcriptionSeconds": transcriptionSeconds],
                "failedChecks": failedChecks,
                "note": "Synthetic fixtures only; not a live microphone test. Normal desktop applications left running. Task checks are a small smoke suite, not a general model-quality benchmark."]
            let output = repo.appendingPathComponent(".runtime/benchmark-\(model.replacingOccurrences(of: ":", with: "-" )).json")
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
            print("Report: \(output.path)")
            guard failedChecks.isEmpty else { throw DaisyError.message("\(failedChecks.count)/\(prompts.count) task checks failed for \(model). Inspect the report.") }
            print("PASS — local task and speech smoke tests")
            await runtime.shutdown()
        } catch {
            await runtime.shutdown()
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    static func checkRuntime() async throws {
        let client = OllamaClient()
        guard await !client.isReachable() else {
            throw DaisyError.message("Quit Daisy and stop the diagnostic server before the lifecycle test; it will not stop a server it doesn't own.")
        }
        var configuration = Configuration()
        configuration.ollamaModels = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".runtime/ollama/models").path
        let runtime = LocalRuntime(client: client)
        do {
            for cycle in 1...2 {
                try await runtime.ensureRunning(configuration: configuration)
                try await client.verifyLocal(model: configuration.model)
                print("PASS runtime start + local model verification, cycle \(cycle)")
                await runtime.shutdown()
                guard await !client.isReachable() else { throw DaisyError.message("Owned engine remained reachable after shutdown.") }
                print("PASS runtime shutdown, cycle \(cycle)")
            }
        } catch { await runtime.shutdown(); throw error }
    }
}
