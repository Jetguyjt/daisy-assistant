import Accelerate
import Foundation

/// Where the downloaded speech models live: `Runtime/speech` in Daisy's data folder, filled by
/// scripts/setup-speech.sh. Nothing here is downloaded at runtime.
public enum SpeechAssets {
    public static var folder: URL { Configuration.dataDirectory.appendingPathComponent("Runtime/speech", isDirectory: true) }
    /// Silero VAD v6.2, 16 kHz only, from github.com/snakers4/silero-vad.
    public static var sileroVAD: URL { folder.appendingPathComponent("silero_vad_16k_op15.onnx") }
    /// The "hey daisy" openWakeWord model Josh trains on Colab. See docs/wake-word.md.
    public static var wakeWord: URL { folder.appendingPathComponent("hey_daisy.onnx") }
    /// openWakeWord's shared feature models, from its GitHub release.
    public static var melSpectrogram: URL { folder.appendingPathComponent("melspectrogram.onnx") }
    public static var speechEmbedding: URL { folder.appendingPathComponent("embedding_model.onnx") }
    /// The worker that runs the wake word model, copied here from scripts/speech/wakeword.py.
    public static var wakeWordWorker: URL { folder.appendingPathComponent("wakeword.py") }
}

/// Silero VAD v6 at 16 kHz, run here with Accelerate from the weights in the project's ONNX file,
/// so there is no ONNX Runtime and no extra process. It is the model graph's own maths: a 256-point
/// STFT done as a convolution, four convolutions with ReLU, one LSTM cell and a sigmoid, over 512 new
/// samples plus the previous 64 each step (32 ms). The LSTM state carries over between steps.
///
/// Not thread-safe: feed it from one thread (the audio tap does).
public final class SileroVAD: @unchecked Sendable {
    public static let frame = 512
    static let context = 64
    static let padded = 640          // context + frame, reflect-padded by 64 on the right
    static let bins = 129            // STFT: 258 rows are 129 real and 129 imaginary
    static let steps = 4             // STFT frames of 256 at hop 128 over 640 samples
    static let hidden = 128

    public struct Weights: Sendable {
        public struct Conv: Sendable {
            public let weight: [Float]   // [outputs, inputs, 3], row-major
            public let bias: [Float]
            public let inputs: Int, outputs: Int, stride: Int
        }
        public let stft: [Float]         // [258, 256]
        public let convs: [Conv]
        public let inputHidden: [Float]  // [512, 128], gates in PyTorch order: input, forget, cell, output
        public let hiddenHidden: [Float] // [512, 128]
        public let gateBias: [Float]     // bias_ih + bias_hh
        public let output: [Float]       // [128]
        public let outputBias: Float

        /// Tensors by their names in silero_vad_16k_op15.onnx. Shapes are checked.
        public init(tensors: [String: (shape: [Int], values: [Float])]) throws {
            func tensor(_ name: String, _ shape: [Int]) throws -> [Float] {
                guard let found = tensors[name] else { throw DaisyError.message("The Silero VAD model is missing \(name).") }
                guard found.shape == shape, found.values.count == shape.reduce(1, *) else {
                    throw DaisyError.message("The Silero VAD model has an unexpected shape for \(name).")
                }
                return found.values
            }
            stft = try tensor("model.stft.forward_basis_buffer", [258, 1, 256])
            let layers = [(129, 128, 1), (128, 64, 2), (64, 64, 2), (64, 128, 1)]
            convs = try layers.enumerated().map { index, layer in
                let (inputs, outputs, stride) = layer
                return Conv(weight: try tensor("model.encoder.\(index).reparam_conv.weight", [outputs, inputs, 3]),
                            bias: try tensor("model.encoder.\(index).reparam_conv.bias", [outputs]),
                            inputs: inputs, outputs: outputs, stride: stride)
            }
            inputHidden = try tensor("model.decoder.rnn.weight_ih", [512, 128])
            hiddenHidden = try tensor("model.decoder.rnn.weight_hh", [512, 128])
            let ih = try tensor("model.decoder.rnn.bias_ih", [512]), hh = try tensor("model.decoder.rnn.bias_hh", [512])
            gateBias = zip(ih, hh).map { $0 + $1 }
            output = try tensor("model.decoder.decoder.2.weight", [1, 128, 1])
            outputBias = try tensor("model.decoder.decoder.2.bias", [1])[0]
        }
    }

    private let weights: Weights
    private var pending: [Float] = []
    private var consumed = 0
    private var input = [Float](repeating: 0, count: SileroVAD.context + SileroVAD.frame)
    private var h = [Float](repeating: 0, count: SileroVAD.hidden)
    private var c = [Float](repeating: 0, count: SileroVAD.hidden)
    public private(set) var lastProbability: Float = 0

    public convenience init(model: URL) throws {
        try self.init(weights: Weights(tensors: ONNXTensors.read(Data(contentsOf: model))))
    }
    public init(weights: Weights) { self.weights = weights }

    /// Forget the audio so far, as if the stream started again.
    public func reset() {
        pending = []; consumed = 0
        for i in input.indices { input[i] = 0 }
        for i in 0..<Self.hidden { h[i] = 0; c[i] = 0 }
        lastProbability = 0
    }

    /// Loads the installed model, or nil when it's turned off, missing or unreadable (then the
    /// endpointer goes by energy alone).
    public static func installed(_ settings: SpeechInputSettings = SpeechInputSettings(), model: URL = SpeechAssets.sileroVAD) -> SileroVAD? {
        guard settings.usesVoiceActivity, FileManager.default.fileExists(atPath: model.path) else { return nil }
        return try? SileroVAD(model: model)
    }

    /// The probability for one audio chunk of any length: the highest of the steps it completed,
    /// or the last one when it was too short to complete a step.
    public func probability(for samples: [Int16]) -> Float {
        process(samples).max() ?? lastProbability
    }

    /// 16 kHz mono samples in any chunk size. Returns one speech probability per completed 32 ms step.
    public func process(_ samples: [Int16]) -> [Float] {
        process(floats: samples.map { Float($0) / 32768 })
    }
    public func process(floats samples: [Float]) -> [Float] {
        pending.append(contentsOf: samples)
        var results: [Float] = []
        while pending.count - consumed >= Self.frame {
            // The window is the last 64 samples of the previous step followed by 512 new ones.
            for i in 0..<Self.context { input[i] = input[Self.frame + i] }
            for i in 0..<Self.frame { input[Self.context + i] = pending[consumed + i] }
            consumed += Self.frame
            lastProbability = step()
            results.append(lastProbability)
        }
        if consumed > 8 * Self.frame { pending.removeFirst(consumed); consumed = 0 }
        return results
    }

    private func step() -> Float {
        // Reflect padding on the right: 576 samples become 640, mirroring without repeating the edge.
        let n = input.count
        var padded = input
        padded.reserveCapacity(Self.padded)
        for j in 0..<(Self.padded - n) { padded.append(input[n - 2 - j]) }
        // STFT as a matrix product: 258 filters of 256 taps over 4 frames at hop 128.
        var frames = [Float](repeating: 0, count: 256 * Self.steps)
        for k in 0..<256 { for t in 0..<Self.steps { frames[k * Self.steps + t] = padded[128 * t + k] } }
        var spectrum = [Float](repeating: 0, count: 258 * Self.steps)
        vDSP_mmul(weights.stft, 1, frames, 1, &spectrum, 1, 258, vDSP_Length(Self.steps), 256)
        var features = [Float](repeating: 0, count: Self.bins * Self.steps)
        for i in 0..<(Self.bins * Self.steps) {
            let re = spectrum[i], im = spectrum[Self.bins * Self.steps + i]
            features[i] = (re * re + im * im).squareRoot()
        }
        var length = Self.steps
        for conv in weights.convs { (features, length) = Self.convolve(features, length: length, conv) }
        // LSTM cell over the single remaining time step.
        var fromInput = [Float](repeating: 0, count: 512), fromHidden = [Float](repeating: 0, count: 512)
        vDSP_mmul(weights.inputHidden, 1, features, 1, &fromInput, 1, 512, 1, vDSP_Length(Self.hidden))
        vDSP_mmul(weights.hiddenHidden, 1, h, 1, &fromHidden, 1, 512, 1, vDSP_Length(Self.hidden))
        var gates = weights.gateBias
        for i in 0..<512 { gates[i] += fromInput[i] + fromHidden[i] }
        var logit = weights.outputBias
        for j in 0..<Self.hidden {
            let i = Self.sigmoid(gates[j]), f = Self.sigmoid(gates[128 + j])
            let g = tanhf(gates[256 + j]), o = Self.sigmoid(gates[384 + j])
            c[j] = f * c[j] + i * g
            h[j] = o * tanhf(c[j])
            logit += weights.output[j] * max(h[j], 0)
        }
        return Self.sigmoid(logit)
    }

    /// Kernel 3, padding 1, then ReLU. `features` is [inputs, length] row-major.
    private static func convolve(_ features: [Float], length: Int, _ conv: Weights.Conv) -> ([Float], Int) {
        let out = (length + 2 - 3) / conv.stride + 1
        var columns = [Float](repeating: 0, count: conv.inputs * 3 * out)
        for channel in 0..<conv.inputs {
            for k in 0..<3 {
                for t in 0..<out {
                    let source = t * conv.stride + k - 1
                    if source >= 0 && source < length { columns[(channel * 3 + k) * out + t] = features[channel * length + source] }
                }
            }
        }
        var result = [Float](repeating: 0, count: conv.outputs * out)
        vDSP_mmul(conv.weight, 1, columns, 1, &result, 1, vDSP_Length(conv.outputs), vDSP_Length(out), vDSP_Length(conv.inputs * 3))
        for o in 0..<conv.outputs {
            for t in 0..<out { result[o * out + t] = max(result[o * out + t] + conv.bias[o], 0) }
        }
        return (result, out)
    }

    private static func sigmoid(_ x: Float) -> Float { 1 / (1 + expf(-x)) }
}

/// Reads the float initializers out of an ONNX file: just enough protobuf for ModelProto.graph and
/// its TensorProtos (dims, data type, name, raw or packed float data). No graph execution.
public enum ONNXTensors {
    public static func read(_ data: Data) throws -> [String: (shape: [Int], values: [Float])] {
        let bytes = [UInt8](data)
        var tensors: [String: (shape: [Int], values: [Float])] = [:]
        for field in try fields(bytes[...]) where field.number == 7 {         // ModelProto.graph
            for item in try fields(field.bytes) where item.number == 5 {       // GraphProto.initializer
                if let tensor = try tensor(item.bytes) { tensors[tensor.name] = (tensor.shape, tensor.values) }
            }
        }
        guard !tensors.isEmpty else { throw DaisyError.message("The model file has no weights Daisy can read.") }
        return tensors
    }

    private struct Field { let number: Int; let wire: Int; let value: UInt64; let bytes: ArraySlice<UInt8> }

    private static func tensor(_ bytes: ArraySlice<UInt8>) throws -> (name: String, shape: [Int], values: [Float])? {
        var shape: [Int] = [], type = 0, name = "", values: [Float] = [], raw: ArraySlice<UInt8>?
        for field in try fields(bytes) {
            switch (field.number, field.wire) {
            case (1, 0): shape.append(Int(field.value))
            case (1, 2):
                var index = field.bytes.startIndex
                while index < field.bytes.endIndex { shape.append(Int(try varint(field.bytes, &index))) }
            case (2, 0): type = Int(field.value)
            case (4, 2): values += floats(field.bytes)
            case (4, 5): values.append(Float(bitPattern: UInt32(truncatingIfNeeded: field.value)))
            case (8, 2): name = String(decoding: field.bytes, as: UTF8.self)
            case (9, 2): raw = field.bytes
            default: break
            }
        }
        guard type == 1 else { return nil }                                   // FLOAT only
        if let raw { values = floats(raw) }
        return (name, shape, values)
    }

    private static func floats(_ bytes: ArraySlice<UInt8>) -> [Float] {
        var result: [Float] = []
        result.reserveCapacity(bytes.count / 4)
        var index = bytes.startIndex
        while index + 4 <= bytes.endIndex {
            let bits = UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
            result.append(Float(bitPattern: bits))
            index += 4
        }
        return result
    }

    private static func fields(_ bytes: ArraySlice<UInt8>) throws -> [Field] {
        var result: [Field] = []
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let key = try varint(bytes, &index)
            let number = Int(key >> 3), wire = Int(key & 7)
            switch wire {
            case 0: result.append(Field(number: number, wire: wire, value: try varint(bytes, &index), bytes: []))
            case 1:
                guard index + 8 <= bytes.endIndex else { throw malformed }
                var value: UInt64 = 0
                for i in 0..<8 { value |= UInt64(bytes[index + i]) << (8 * UInt64(i)) }
                result.append(Field(number: number, wire: wire, value: value, bytes: bytes[index..<(index + 8)])); index += 8
            case 2:
                let length = Int(try varint(bytes, &index))
                guard length >= 0, index + length <= bytes.endIndex else { throw malformed }
                result.append(Field(number: number, wire: wire, value: 0, bytes: bytes[index..<(index + length)])); index += length
            case 5:
                guard index + 4 <= bytes.endIndex else { throw malformed }
                var value: UInt64 = 0
                for i in 0..<4 { value |= UInt64(bytes[index + i]) << (8 * UInt64(i)) }
                result.append(Field(number: number, wire: wire, value: value, bytes: bytes[index..<(index + 4)])); index += 4
            default: throw malformed
            }
        }
        return result
    }

    private static func varint(_ bytes: ArraySlice<UInt8>, _ index: inout Int) throws -> UInt64 {
        var result: UInt64 = 0, shift: UInt64 = 0
        while index < bytes.endIndex, shift < 64 {
            let byte = bytes[index]; index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        throw malformed
    }
    private static var malformed: Error { DaisyError.message("The model file is damaged. Run scripts/setup-speech.sh again.") }
}
