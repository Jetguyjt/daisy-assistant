import Foundation
import JarvisCore

@main struct JarvisCheck {
    static func main() async {
        setbuf(stdout, nil)
        let runtime = LocalRuntime()
        do {
            let args = CommandLine.arguments
            if args.dropFirst().first == "--browser-metadata" {
                let connection = MCPConnection()
                let script = Configuration.dataDirectory.appendingPathComponent("Runtime/browser/node_modules/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js")
                let node = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/node")
                do {
                    try await connection.start(executable: node, arguments: [script.path, "--autoConnect", "--no-usage-statistics", "--no-performance-crux", "--no-javascript-evaluation", "--no-source-maps", "--category-input=false", "--category-performance=false", "--category-network=false", "--category-emulation=false"])
                    let result = try await connection.request(method: "tools/list", parameters: .object([:]))
                    guard case .object(let object) = result, case .array(let list) = object["tools"] else { throw JarvisError.message("Missing tool metadata") }
                    let names = Set(list.compactMap { value -> String? in if case .object(let fields) = value { return fields["name"]?.stringValue }; return nil })
                    guard Set(["list_pages", "new_page", "take_snapshot"]).isSubset(of: names), !names.contains("evaluate_script"), !names.contains("click"), !names.contains("fill") else { throw JarvisError.message("Unexpected browser adapter configuration") }
                    print("PASS — real MCP initialize + tools/list; read/navigation metadata present; input/JavaScript disabled. No browser tool invoked or account accessed.")
                    await connection.stop(); return
                } catch { await connection.stop(); throw error }
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
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-check-\(UUID().uuidString)")
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
            try await NaturalSpeech.synthesize(text: phrase, voice: "bm_george", speed: 1,
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
            guard transcript.lowercased().contains("resume") else { throw JarvisError.message("Speech round-trip did not recognize the fixture phrase.") }
            let report: [String: Any] = ["model": model, "date": ISO8601DateFormatter().string(from: Date()), "results": results,
                "voice": ["syntheticInput": phrase, "transcript": transcript, "synthesisSeconds": synthesisSeconds, "transcriptionSeconds": transcriptionSeconds],
                "failedChecks": failedChecks,
                "note": "Synthetic fixtures only; not a live microphone test. Normal desktop applications left running. Task checks are a small smoke suite, not a general model-quality benchmark."]
            let output = repo.appendingPathComponent(".runtime/benchmark-\(model.replacingOccurrences(of: ":", with: "-" )).json")
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
            print("Report: \(output.path)")
            guard failedChecks.isEmpty else { throw JarvisError.message("\(failedChecks.count)/\(prompts.count) task checks failed for \(model). Inspect the report.") }
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
            throw JarvisError.message("Quit Jarvis and stop the diagnostic server before the lifecycle test; it will not stop a server it doesn't own.")
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
                guard await !client.isReachable() else { throw JarvisError.message("Owned engine remained reachable after shutdown.") }
                print("PASS runtime shutdown, cycle \(cycle)")
            }
        } catch { await runtime.shutdown(); throw error }
    }
}
