import Foundation
import DaisyCore

/// Silero VAD run natively. The model isn't in the repo (scripts/setup-speech.sh fetches it), so the
/// maths is pinned against onnxruntime only when DAISY_SILERO_MODEL points at the file; the rest runs
/// on made-up weights and a made-up ONNX file.
final class SileroTests {
    /// A made-up voice: a buzz with a gliding pitch, three formants and a syllable rhythm, between
    /// silence and faint noise. 2 s, 62 steps of 512 samples.
    static func syntheticVoice() -> [Int16] {
        let rate = 16000.0
        var samples = [Int16](repeating: 0, count: Int(0.3 * rate))
        var phase = 0.0
        for i in 0..<Int(1.2 * rate) {
            let t = Double(i) / rate
            let pitch = 120 + 60 * t / 1.2
            phase += 2 * Double.pi * pitch / rate
            var value = 0.0
            for k in 1...20 {
                let f = Double(k) * pitch
                let formants = exp(-pow((f - 700) / 300, 2)) + 0.6 * exp(-pow((f - 1200) / 400, 2)) + 0.3 * exp(-pow((f - 2500) / 500, 2))
                value += formants / Double(k) * sin(Double(k) * phase)
            }
            let syllables = 0.5 - 0.5 * cos(2 * Double.pi * 4 * t)
            samples.append(Int16(max(-32767, min(32767, (value * syllables * 6000).rounded()))))
        }
        var seed: UInt32 = 12345
        for _ in 0..<Int(0.5 * rate) {
            seed = seed &* 1664525 &+ 1013904223
            samples.append(Int16(Double(Int32(bitPattern: seed)) / Double(Int32.max) * 300))
        }
        return samples
    }
    /// onnxruntime 1.30 on silero_vad_16k_op15.onnx (v6.2.3) for `syntheticVoice()`, with the context
    /// handling of silero-vad's own Python wrapper.
    static let reference: [Float] = [
        0.0017, 0.0069, 0.0089, 0.0079, 0.0059, 0.0060, 0.0059, 0.0056, 0.0054, 0.0677, 0.6307, 0.5144, 0.1181, 0.0223, 0.0130, 0.0090,
        0.0180, 0.0468, 0.0767, 0.0210, 0.0074, 0.0033, 0.0028, 0.0030, 0.0065, 0.0146, 0.0170, 0.0091, 0.0045, 0.0020, 0.0014, 0.0022,
        0.0059, 0.0145, 0.0072, 0.0078, 0.0027, 0.0013, 0.0017, 0.0021, 0.0044, 0.0110, 0.0036, 0.0034, 0.0017, 0.0015, 0.0292, 0.7856,
        0.8969, 0.8007, 0.7244, 0.5851, 0.4068, 0.2888, 0.1940, 0.1260, 0.0889, 0.0859, 0.0643, 0.0551, 0.0517, 0.0483
    ]

    // A few lines of protobuf, enough to write an ONNX file by hand.
    private func varint(_ value: UInt64) -> [UInt8] {
        var value = value, bytes: [UInt8] = []
        repeat { var byte = UInt8(value & 0x7F); value >>= 7; if value != 0 { byte |= 0x80 }; bytes.append(byte) } while value != 0
        return bytes
    }
    private func field(_ number: Int, _ bytes: [UInt8]) -> [UInt8] { varint(UInt64(number << 3 | 2)) + varint(UInt64(bytes.count)) + bytes }
    private func field(_ number: Int, varint value: UInt64) -> [UInt8] { varint(UInt64(number << 3)) + varint(value) }
    private func floatBytes(_ values: [Float]) -> [UInt8] {
        values.flatMap { value -> [UInt8] in let bits = value.bitPattern; return (0..<4).map { UInt8((bits >> (8 * $0)) & 0xFF) } }
    }
    private func tensor(_ name: String, dims: [Int], floats: [Float], raw: Bool, type: UInt64 = 1) -> [UInt8] {
        // Dims unpacked for the raw one and packed for the other, so both encodings get read.
        let shape = raw ? dims.flatMap { field(1, varint: UInt64($0)) } : field(1, dims.flatMap { varint(UInt64($0)) })
        return shape + field(2, varint: type) + field(8, Array(name.utf8)) + (raw ? field(9, floatBytes(floats)) : field(4, floatBytes(floats)))
    }

    func testONNXTensorsReadsRawAndPackedFloatInitializers() throws {
        let graph = field(5, tensor("a", dims: [2, 2], floats: [1, -2, 3.5, 0], raw: true))
            + field(5, tensor("b", dims: [3], floats: [0.25, 0.5, 0.75], raw: false))
            + field(5, tensor("ints", dims: [1], floats: [0], raw: true, type: 7))
            + field(1, Array("a node the reader skips".utf8))
        let model = field(1, varint: 8) + field(7, graph)
        let tensors = try ONNXTensors.read(Data(model))
        expectEqual(tensors["a"]?.shape, [2, 2]); expectEqual(tensors["a"]?.values, [1, -2, 3.5, 0])
        expectEqual(tensors["b"]?.shape, [3]); expectEqual(tensors["b"]?.values, [0.25, 0.5, 0.75])
        expectTrue(tensors["ints"] == nil)
        expectThrows(try ONNXTensors.read(Data([0x3A, 0x10, 0x01])))     // a length that runs past the end
        expectThrows(try ONNXTensors.read(Data(field(1, varint: 8))))    // no graph, no weights
        expectThrows(try SileroVAD.Weights(tensors: tensors))            // not Silero's names
    }

    private func madeUpWeights(seed: UInt64) throws -> SileroVAD.Weights {
        var state = seed
        func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int((state >> 33) % 2001) - 1000) / 10000
        }
        func tensor(_ shape: [Int]) -> (shape: [Int], values: [Float]) { (shape, (0..<shape.reduce(1, *)).map { _ in next() }) }
        var tensors: [String: (shape: [Int], values: [Float])] = ["model.stft.forward_basis_buffer": tensor([258, 1, 256])]
        for (index, (inputs, outputs)) in [(129, 128), (128, 64), (64, 64), (64, 128)].enumerated() {
            tensors["model.encoder.\(index).reparam_conv.weight"] = tensor([outputs, inputs, 3])
            tensors["model.encoder.\(index).reparam_conv.bias"] = tensor([outputs])
        }
        tensors["model.decoder.rnn.weight_ih"] = tensor([512, 128]); tensors["model.decoder.rnn.weight_hh"] = tensor([512, 128])
        tensors["model.decoder.rnn.bias_ih"] = tensor([512]); tensors["model.decoder.rnn.bias_hh"] = tensor([512])
        tensors["model.decoder.decoder.2.weight"] = tensor([1, 128, 1]); tensors["model.decoder.decoder.2.bias"] = tensor([1])
        return try SileroVAD.Weights(tensors: tensors)
    }

    func testSileroGivesTheSameAnswerForAnyChunking() throws {
        let weights = try madeUpWeights(seed: 7)
        let signal = Self.syntheticVoice()
        let whole = SileroVAD(weights: weights).process(signal)
        expectEqual(whole.count, signal.count / SileroVAD.frame)
        expectTrue(whole.allSatisfy { $0 > 0 && $0 < 1 })
        // The tap delivers chunks of any size; the 64-sample context and LSTM state must carry over.
        let chunked = SileroVAD(weights: weights)
        var pieces: [Float] = []
        var index = 0, size = 1
        while index < signal.count {
            let end = min(signal.count, index + size)
            pieces += chunked.process(Array(signal[index..<end]))
            index = end; size = size * 7 % 1500 + 1
        }
        expectEqual(pieces, whole)
        chunked.reset()
        expectEqual(chunked.process(signal), whole)
        // A chunk too short to finish a step repeats the last probability.
        expectEqual(chunked.probability(for: [0, 0, 0]), whole.last)
    }

    func testSileroMatchesOnnxRuntimeWhenTheModelIsInstalled() throws {
        guard let path = ProcessInfo.processInfo.environment["DAISY_SILERO_MODEL"] else {
            print("  skipped: set DAISY_SILERO_MODEL to silero_vad_16k_op15.onnx to check against onnxruntime")
            return
        }
        let model = URL(fileURLWithPath: path)
        let probabilities = try SileroVAD(model: model).process(Self.syntheticVoice())
        expectEqual(probabilities.count, Self.reference.count)
        let worst = zip(probabilities, Self.reference).map { abs($0 - $1) }.max() ?? 1
        expectTrue(worst < 1e-3)
        expectTrue(SileroVAD.installed(model: model) != nil)
        var off = SpeechInputSettings(); off.voiceActivity = false
        expectTrue(SileroVAD.installed(off, model: model) == nil)
        expectTrue(SileroVAD.installed(model: model.deletingLastPathComponent().appendingPathComponent("missing.onnx")) == nil)
    }
}
