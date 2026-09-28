import SwiftUI
import DaisyCore

/// Settings → Voice: which Kokoro voice, how fast, and a preview. It keeps no state; the caller
/// passes the saved setting in and says what preview and stop do:
///
///     VoiceSettingsView(voice: …, speed: …, busy: model.busy, preview: { model.previewVoice() }, stop: { model.interrupt() })
struct VoiceSettingsView: View {
    @Binding var voice: String
    @Binding var speed: Double
    var busy = false
    var preview: () -> Void
    var stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("Voice") {
                Picker("", selection: $voice) {
                    ForEach(Self.groups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.voices) { option in Text(Self.label(for: option)).tag(option.id) }
                        }
                    }
                    // A setting typed into config.json by hand still shows, rather than a blank picker.
                    if !NaturalSpeech.voices.contains(where: { $0.id == voice }) {
                        Section("Current setting") { Text(NaturalSpeech.shortName(for: voice)).tag(voice) }
                    }
                }
                .labelsHidden().fixedSize()
                .accessibilityLabel("Voice")
            }
            Text(detail)
                .font(.system(size: 11)).foregroundStyle(problem == nil ? HUD.dim : HUD.amber)
                .textSelection(.enabled)
                .padding(.leading, 122)
            row("Speed") {
                HStack(spacing: 10) {
                    Slider(value: $speed, in: NaturalSpeech.speeds, step: 0.05)
                        .tint(HUD.accent).frame(maxWidth: 220)
                        .accessibilityLabel("Speaking speed")
                        .accessibilityValue(String(format: "%.2f times", speed))
                    Text(String(format: "%.2f×", speed)).font(HUD.readout(11)).foregroundStyle(HUD.steel)
                }
            }
            HStack {
                Button("Preview voice", action: preview).buttonStyle(HUDButtonStyle(kind: .ghost, compact: true)).disabled(busy)
                if busy { Button("Stop", action: stop).buttonStyle(HUDButtonStyle(kind: .danger, compact: true)) }
            }
        }
    }

    /// The blend first, then American and British voices, women first.
    private static let groups: [(title: String, voices: [LocalVoice])] = [
        ("Blend", NaturalSpeech.voices.filter(\.isBlend)),
        ("American · female", NaturalSpeech.voices.filter { !$0.isBlend && $0.accent == .american && $0.female }),
        ("American · male", NaturalSpeech.voices.filter { !$0.isBlend && $0.accent == .american && !$0.female }),
        ("British · female", NaturalSpeech.voices.filter { !$0.isBlend && $0.accent == .british && $0.female }),
        ("British · male", NaturalSpeech.voices.filter { !$0.isBlend && $0.accent == .british && !$0.female }),
    ]

    private static func label(for option: LocalVoice) -> String {
        if option.isBlend { return option.name }
        return NaturalSpeech.shortName(for: option.id) + (option.id == NaturalSpeech.defaultVoice ? " · default" : "")
    }

    private var problem: String? {
        do { _ = try NaturalSpeech.blend(voice); return nil } catch { return error.localizedDescription }
    }

    /// "af_heart · American female", or the mix for a blend, or what's wrong with a bad setting.
    private var detail: String {
        if let problem { return problem }
        guard let parts = try? NaturalSpeech.blend(voice) else { return voice }
        if parts.count > 1 {
            let mix = parts.map { "\(Int(($0.weight * 100).rounded()))% \(NaturalSpeech.shortName(for: $0.voice))" }
            return mix.joined(separator: ", ") + " · " + voice
        }
        guard let option = NaturalSpeech.voices.first(where: { $0.id == parts[0].voice }) else { return voice }
        return "\(option.id) · \(option.accent.rawValue) \(option.female ? "female" : "male")"
            + (option.id == NaturalSpeech.defaultVoice ? " · Kokoro's best-rated voice" : "")
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 12)).foregroundStyle(HUD.steel).frame(width: 110, alignment: .leading)
            content()
        }
    }
}
