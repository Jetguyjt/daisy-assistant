import AVFoundation
import Foundation

/// Channel 0 of whatever the input node delivers, resampled to 16 kHz mono Int16 for Whisper and
/// the endpointer. AVAudioConverter does not downmix when the channel count shrinks: it writes
/// silence. The built-in mic delivers three channels and voice processing delivers seven, with
/// the processed voice in channel 0, so the channel is copied out before resampling.
public final class MicDownsampler: @unchecked Sendable {
    public static let sampleRate = 16000.0
    private let mono: AVAudioFormat
    private let target: AVAudioFormat
    private let converter: AVAudioConverter

    public init?(inputFormat: AVAudioFormat) {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              inputFormat.commonFormat == .pcmFormatFloat32,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate, channels: 1, interleaved: false),
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.sampleRate, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: mono, to: target) else { return nil }
        self.mono = mono; self.target = target; self.converter = converter
    }

    /// Returns the resampled samples and their power in dBFS, or nil for an empty buffer.
    public func convert(_ buffer: AVAudioPCMBuffer) -> (samples: [Int16], power: Float)? {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let source = buffer.floatChannelData,
              let channel = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
              let destination = channel.floatChannelData?[0] else { return nil }
        channel.frameLength = buffer.frameLength
        let stride = buffer.stride
        if stride == 1 { destination.update(from: source[0], count: frames) }
        else { for i in 0..<frames { destination[i] = source[0][i * stride] } }
        let capacity = AVAudioFrameCount(Double(frames) * Self.sampleRate / mono.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true; outStatus.pointee = .haveData; return channel
        }
        guard status != .error, out.frameLength > 0, let data = out.int16ChannelData else { return nil }
        let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
        var sum = 0.0
        for sample in samples { let value = Double(sample) / 32768; sum += value * value }
        let rms = (sum / Double(samples.count)).squareRoot()
        return (samples, Float(20 * log10(max(rms, 1e-7))))
    }
}

/// A started engine with an input tap and a player node wired to the speakers.
public struct MicrophoneSession {
    public let engine: AVAudioEngine
    public let player: AVAudioPlayerNode
    public let voiceProcessing: Bool
    public let inputFormat: AVAudioFormat
    public func stop() {
        player.stop()
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }
}

public enum MicrophoneEngine {
    /// Builds a fresh engine and starts it. Apple voice processing (echo cancellation) is tried
    /// first; if Core Audio refuses it, a plain engine is used so the microphone still works.
    ///
    /// The mixer is wired to the output explicitly after voice processing is on. Letting
    /// AVAudioEngine create that connection lazily picks up a stale 44.1 kHz format while the
    /// voice-processing unit runs at the device's 48 kHz, and start fails with -10875.
    public static func start(preferVoiceProcessing: Bool, tap: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws -> MicrophoneSession {
        var failure: Error?
        for useVoiceProcessing in preferVoiceProcessing ? [true, false] : [false] {
            let engine = AVAudioEngine(), player = AVAudioPlayerNode()
            engine.attach(player)
            let input = engine.inputNode
            if useVoiceProcessing {
                do { try input.setVoiceProcessingEnabled(true) } catch { failure = error; continue }
            }
            let output = engine.outputNode.inputFormat(forBus: 0)
            engine.connect(engine.mainMixerNode, to: engine.outputNode,
                           format: output.channelCount > 0 && output.sampleRate > 0 ? output : nil)
            engine.prepare()
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                failure = DaisyError.message("No audio input device is available."); continue
            }
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in tap(buffer) }
            do {
                try engine.start()
                return MicrophoneSession(engine: engine, player: player, voiceProcessing: useVoiceProcessing, inputFormat: format)
            } catch {
                input.removeTap(onBus: 0)
                engine.stop()
                failure = error
            }
        }
        let reason = (failure as NSError?)?.localizedDescription ?? "unknown error"
        throw DaisyError.message("The audio engine could not start: \(reason)")
    }
}
