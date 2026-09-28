import AppKit
import DaisyCore
import SwiftUI

/// Settings section: pick one accent and the whole HUD, the core and the Dock icon follow it.
struct AppearanceSection: View {
    private let theme = ThemeStore.shared
    @State private var hex = ""
    @State private var hexInvalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("APPEARANCE").hudCaption(HUD.accent)
            HStack(spacing: 12) {
                Text("Accent").font(.system(size: 12)).foregroundStyle(HUD.steel).frame(width: 110, alignment: .leading)
                ColorPicker("Accent", selection: accentBinding, supportsOpacity: false).labelsHidden()
                TextField("#FAEAB7", text: $hex)
                    .hudField().frame(width: 110)
                    .onSubmit(applyHex)
                    .help("Six hex digits, like #FAEAB7")
                Button("Reset") { theme.reset() }
                    .buttonStyle(HUDButtonStyle(kind: .ghost, compact: true))
                    .disabled(theme.accent == ThemePalette.defaultAccent)
            }
            HStack(spacing: 12) {
                Text("Presets").font(.system(size: 12)).foregroundStyle(HUD.steel).frame(width: 110, alignment: .leading)
                ForEach(ThemePalette.presets, id: \.name) { preset in
                    Button { theme.set(preset.color) } label: {
                        Rectangle().fill(Color(preset.color)).frame(width: 22, height: 22)
                            .overlay(Rectangle().strokeBorder(theme.accent == preset.color ? HUD.ice : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .help(preset.name)
                    .accessibilityLabel(preset.name)
                }
            }
            HStack(spacing: 12) {
                Text("Derived").font(.system(size: 12)).foregroundStyle(HUD.steel).frame(width: 110, alignment: .leading)
                swatch("Accent", HUD.accent)
                swatch("Deep", HUD.ember)
                swatch("Working", HUD.thinking)
                swatch("Panel", HUD.panel)
                swatch("Approve", HUD.amber)
                swatch("Stop", HUD.crimson)
            }
            Text(hexInvalid ? "That isn't a hex color. Use six digits, like #FAEAB7."
                 : "Backgrounds, text and the core take this hue. Approve and stop colors change on their own if the accent gets too close to them.")
                .font(.system(size: 11)).foregroundStyle(hexInvalid ? HUD.amber : HUD.dim)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Rectangle().fill(HUD.line.opacity(0.09)).frame(height: 1) }
        .onAppear { hex = theme.accent.hex }
        .onChange(of: theme.accent) { hex = theme.accent.hex; hexInvalid = false }
    }

    private var accentBinding: Binding<Color> {
        Binding(get: { Color(theme.accent) }, set: { color in
            guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
            theme.set(RGB(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)))
        })
    }

    private func applyHex() {
        if let color = RGB(hex: hex) { theme.set(color); hex = color.hex; hexInvalid = false } else { hexInvalid = true }
    }

    private func swatch(_ name: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Rectangle().fill(color).frame(width: 34, height: 14)
                .overlay(Rectangle().strokeBorder(HUD.line.opacity(0.25), lineWidth: 1))
            Text(name.uppercased()).font(HUD.label(8)).tracking(1).foregroundStyle(HUD.dim)
        }
    }
}
