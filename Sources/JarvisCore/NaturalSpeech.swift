import Foundation

public struct LocalVoice: Identifiable, Sendable {
    public let id: String
    public let name: String
}

public enum NaturalSpeech {
    public static let voices: [LocalVoice] = [
        .init(id: "bm_george", name: "George · British"),
        .init(id: "bm_fable", name: "Fable · British"),
        .init(id: "am_michael", name: "Michael · American"),
        .init(id: "af_heart", name: "Heart · American"),
        .init(id: "bf_emma", name: "Emma · British")
    ]
    public static var runtime: URL { Configuration.dataDirectory.appendingPathComponent("Runtime/voice") }
    public static func synthesize(text: String, voice: String, speed: Double, input: URL, output: URL) async throws {
        guard voices.contains(where: { $0.id == voice }), (0.75...1.3).contains(speed) else {
            throw JarvisError.message("Choose a supported local voice and speaking speed in Settings.")
        }
        let python = runtime.appendingPathComponent("venv/bin/python")
        let script = runtime.appendingPathComponent("synthesize.py")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              [script, runtime.appendingPathComponent("kokoro-v1.0.onnx"), runtime.appendingPathComponent("voices-v1.0.bin")]
                .allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw JarvisError.message("The natural voice is not installed. Run scripts/setup-voice.sh. Your answer is still available as text.")
        }
        try Task.checkCancellation()
        try String(text.prefix(2200)).write(to: input, atomically: true, encoding: .utf8)
        try await LocalProcess.run(executable: python, arguments: [script.path, "--input", input.path, "--output", output.path,
            "--voice", voice, "--speed", String(speed)], timeout: 90)
        try Task.checkCancellation()
    }
}
