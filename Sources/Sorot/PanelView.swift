import AppKit
import SwiftUI

/// The menu bar panel. It reads like a light meter: three live readings on top,
/// the few controls that change them underneath.
struct PanelView: View {
    @EnvironmentObject private var engine: LightEngine
    @Environment(\.panelFonts) private var fonts

    private static let kelvinScale = 2500.0...7500.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if engine.isOn, engine.isAutomatic, engine.camera == .denied {
                cameraDenied
            } else {
                readings
            }
            Divider()
            controls
            Divider()
            footer
        }
        .font(fonts.text(13))
        .frame(width: 300)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sorot").font(fonts.title(15))
                Text(engine.status)
                    .font(fonts.text(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("Light", isOn: $engine.isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(16)
    }

    private var readings: some View {
        VStack(alignment: .leading, spacing: 14) {
            ReadingRow(
                label: "Face",
                value: engine.faceLuma.map { percent($0) } ?? "–",
                spoken: engine.faceLuma.map { "\(percent($0)), target \(percent(engine.target))" } ?? "no reading"
            ) {
                LevelBar(value: engine.faceLuma, tick: showsTarget ? engine.target : nil, fill: .primary.opacity(0.7))
            }
            VStack(alignment: .leading, spacing: 9) {
                ReadingRow(
                    label: "Room",
                    value: engine.roomKelvin.map { kelvinText($0) } ?? "–",
                    spoken: (engine.roomKelvin.map { kelvinText($0) } ?? "no reading") + ". " + engine.roomSource
                ) {
                    KelvinStrip(value: engine.roomKelvin, scale: Self.kelvinScale)
                }
                Text(engine.roomSource)
                    .font(fonts.text(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
            ReadingRow(
                label: "Glow",
                value: engine.isOn ? "\(percent(engine.level)) · \(kelvinText(engine.kelvin))" : "–",
                spoken: engine.isOn ? "\(percent(engine.level)) at \(kelvinText(engine.kelvin))" : "off"
            ) {
                LevelBar(value: engine.isOn ? engine.level : nil, tick: nil, fill: glowColor)
            }
        }
        .padding(16)
    }

    private var cameraDenied: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sorot needs the camera to measure your face. Frames are analysed on this Mac and never saved or sent anywhere.")
                .font(fonts.text(12))
                .fixedSize(horizontal: false, vertical: true)
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("Open Camera Settings").font(fonts.text(13))
            }
            Text("Or switch Automatic off to set the light by hand.")
                .font(fonts.text(11))
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Automatic")
                Spacer()
                Toggle("Automatic", isOn: $engine.isAutomatic)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            if engine.isAutomatic {
                SliderRow(label: "Target brightness", value: $engine.target,
                          range: LightEngine.targetRange, text: percent(engine.target))
            } else {
                SliderRow(label: "Brightness", value: $engine.manualLevel, range: 0...1,
                          text: percent(engine.manualLevel))
                SliderRow(label: "Light colour", value: $engine.manualKelvin, range: LightEngine.kelvinRange,
                          text: kelvinText(engine.manualKelvin))
            }
            SliderRow(label: "Reach", value: $engine.reach, range: 0...1, text: percent(engine.reach))

            if engine.isAutomatic {
                Divider()
                HStack {
                    Text("Probe every 5 minutes")
                    Spacer()
                    Toggle("Probe every 5 minutes", isOn: $engine.probesAutomatically)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                Button { engine.startProbe() } label: {
                    Text("Probe Room Light Now").font(fonts.text(13))
                }
                .disabled(!engine.canProbe)
                Text("The screen edges go black, then white, for about a second.")
                    .font(fonts.text(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .disabled(!engine.isOn)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $engine.savesProbes) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Save probe data")
                    Text("Numbers and colour counts for training. Never images.")
                        .font(fonts.text(11))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)

            HStack {
                if engine.savesProbes {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([ProbeLog.fileURL])
                    } label: {
                        Text("Show File").font(fonts.text(13))
                    }
                }
                Spacer()
                Button { NSApplication.shared.terminate(nil) } label: {
                    Text("Quit Sorot").font(fonts.text(13))
                }
                .keyboardShortcut("q")
            }
        }
        .padding(16)
    }

    // MARK: - Helpers

    private var showsTarget: Bool { engine.isOn && engine.isAutomatic }

    private var glowColor: Color {
        let rgb = ColorScience.rgb(kelvin: engine.kelvin)
        return Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1)
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    private func kelvinText(_ value: Double) -> String { "\(Int((value / 50).rounded()) * 50) K" }
}

/// A label, a right-aligned number, and a bar that shows the same number.
private struct ReadingRow<Bar: View>: View {
    let label: String
    let value: String
    let spoken: String
    @ViewBuilder let bar: Bar
    @Environment(\.panelFonts) private var fonts

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(fonts.number(13))
            }
            bar
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(spoken)
    }
}

/// A flat bar from 0 to 1, with an optional tick for the target.
private struct LevelBar: View {
    let value: Double?
    let tick: Double?
    let fill: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(.primary.opacity(0.1))
                if let value {
                    Rectangle()
                        .fill(fill)
                        .overlay(Rectangle().strokeBorder(.primary.opacity(0.25), lineWidth: 0.5))
                        .frame(width: geo.size.width * min(max(value, 0), 1))
                }
                if let tick {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 2, height: geo.size.height + 6)
                        .offset(x: geo.size.width * tick - 1)
                }
            }
        }
        .frame(height: 6)
    }
}

/// The colour temperature scale, drawn in the colours it stands for,
/// with a marker at the measured value.
private struct KelvinStrip: View {
    let value: Double?
    let scale: ClosedRange<Double>

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing)
                    .overlay(Rectangle().strokeBorder(.primary.opacity(0.25), lineWidth: 0.5))
                    .opacity(value == nil ? 0.35 : 1)
                if let value {
                    let position = (min(max(value, scale.lowerBound), scale.upperBound) - scale.lowerBound)
                        / (scale.upperBound - scale.lowerBound)
                    Rectangle()
                        .fill(.primary)
                        .frame(width: 2, height: geo.size.height + 6)
                        .offset(x: geo.size.width * position - 1)
                }
            }
        }
        .frame(height: 6)
    }

    private var stops: [Color] {
        Swift.stride(from: scale.lowerBound, through: scale.upperBound, by: 500).map { kelvin in
            let rgb = ColorScience.rgb(kelvin: kelvin)
            return Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1)
        }
    }
}

/// A labelled slider with its current value on the right.
private struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let text: String
    @Environment(\.panelFonts) private var fonts

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                Spacer()
                Text(text)
                    .font(fonts.number(13))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .accessibilityLabel(label)
                .accessibilityValue(text)
        }
    }
}
