import AppKit
import AVFoundation
import JarvisCore

@MainActor final class AudioController: ObservableObject {
    @Published var level: Double = 0
    @Published var elapsed: TimeInterval = 0
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var meter: Timer?
    private var recordingFolder: URL?
    var onRecordingLimit: (() -> Void)?
    var microphoneStatus: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "Microphone permission granted"
        case .denied, .restricted: return "Microphone permission blocked in System Settings"
        case .notDetermined: return "Microphone permission will be requested on Record"
        @unknown default: return "Microphone permission unknown"
        }
    }
    var inputDeviceName: String { AVCaptureDevice.default(for: .audio)?.localizedName ?? "No default audio input device detected" }

    func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
    func startRecording() throws {
        stop()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        recordingFolder = folder
        let audio = folder.appendingPathComponent("input.wav")
        do {
            let capture = try AVAudioRecorder(url: audio, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
            ])
            capture.isMeteringEnabled = true
            guard capture.record() else { throw JarvisError.message("The microphone could not start recording.") }
            recorder = capture; elapsed = 0
            let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let recorder = self.recorder else { return }
                    recorder.updateMeters()
                    self.elapsed = recorder.currentTime
                    self.level = min(1, Double(pow(10, recorder.averagePower(forChannel: 0) / 30)))
                    if recorder.currentTime >= 60 { self.onRecordingLimit?() }
                }
            }
            meter = timer
            // Mouse tracking/modal loops must not freeze the recording meter or duration limit.
            RunLoop.main.add(timer, forMode: .common)
        } catch { stop(); throw error }
    }
    func finishRecording() throws -> URL {
        guard let recorder else { throw JarvisError.message("No recording is active.") }
        let duration = recorder.currentTime; let url = recorder.url
        recorder.stop(); self.recorder = nil; meter?.invalidate(); meter = nil; level = 0
        guard duration >= 0.35 else {
            stop(); throw JarvisError.message("Recording was too short. Click Record, speak, then click Finish.")
        }
        recordingFolder = nil // caller owns deletion after decoding
        return url
    }
    func speak(_ text: String, voice: String, speed: Double = 1, onReady: (() -> Void)? = nil) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("speech.txt")
        let output = folder.appendingPathComponent("speech.wav")
        try await NaturalSpeech.synthesize(text: text, voice: voice, speed: speed, input: input, output: output)
        try Task.checkCancellation()
        let playback = try AVAudioPlayer(contentsOf: output)
        playback.isMeteringEnabled = true; player = playback
        guard playback.play() else { throw JarvisError.message("Audio playback could not start.") }
        onReady?()
        defer { playback.stop(); if player === playback { player = nil; level = 0 } }
        while playback.isPlaying {
            try Task.checkCancellation()
            playback.updateMeters()
            level = min(1, Double(pow(10, playback.averagePower(forChannel: 0) / 30)))
            try await Task.sleep(nanoseconds: 40_000_000)
        }
    }
    func stop() {
        recorder?.stop(); recorder = nil; player?.stop(); player = nil
        meter?.invalidate(); meter = nil; level = 0; elapsed = 0
        if let recordingFolder { try? FileManager.default.removeItem(at: recordingFolder) }
        recordingFolder = nil
    }
}
