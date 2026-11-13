import Foundation

// The probe measures the room's true light colour, which a single frame cannot
// show because the camera white-balances every frame before the app sees it.
//
// It takes two short measurements with the screen edges first black, then white:
//
//     dark face  =  gains₁ × skin × ambient
//     lit face   =  gains₂ × skin × (ambient + pulse)
//
// The background is too far away for the pulse to reach, so any change there is
// the camera changing its own gains: gains₂ / gains₁ = lit room / dark room.
// Dividing the lit face by that ratio puts both frames on the same gains, and then
//
//     dark face / (lit face − dark face)  =  ambient / pulse
//
// per colour channel. Skin colour and camera gains cancel. The pulse is the
// display's white, so the three ratios are the ambient light's colour.

/// Averages over one phase of the probe.
struct ProbePhase {
    var face: RGB
    var room: RGB?
    var faceClipped: Double
}

struct ProbeResult {
    enum Failure: String {
        case faceLost, noBackground, tooBright, clipped, implausible

        var message: String {
            switch self {
            case .faceLost: return "Probe stopped: your face left the view."
            case .noBackground: return "Probe needs some background in view."
            case .tooBright: return "The pulse barely changed your face. Sit closer or dim the room."
            case .clipped: return "Face overexposed during the pulse. Sit back a little."
            case .implausible: return "Probe gave an implausible reading. Try again."
            }
        }
    }

    /// The room's colour temperature, or nil when the probe failed.
    var kelvin: Double?
    var failure: Failure?
    /// Ambient light colour relative to display white, scaled so green is 1.
    var ambient = RGB.zero
    /// How much light the full pulse added to the face, as a share of the ambient light.
    var screenGain = 0.0
    /// How much the camera changed its gains between the two phases.
    var cameraGain = RGB(r: 1, g: 1, b: 1)
}

enum ProbeMath {
    /// The pulse must add at least this share of light to the face to be measurable.
    static let minimumGain = 0.06
    static let plausibleKelvin = 1500.0...15000.0

    static func solve(dark: ProbePhase, lit: ProbePhase) -> ProbeResult {
        guard let roomDark = dark.room, let roomLit = lit.room,
              min(roomDark.r, roomDark.g, roomDark.b) > 1e-5 else {
            return ProbeResult(failure: .noBackground)
        }
        func ratio(_ a: Double, _ b: Double) -> Double { min(max(a / b, 0.4), 2.5) }
        let gain = RGB(r: ratio(roomLit.r, roomDark.r), g: ratio(roomLit.g, roomDark.g), b: ratio(roomLit.b, roomDark.b))
        var result = ProbeResult(cameraGain: gain)

        guard lit.faceClipped <= 0.05 else {
            result.failure = .clipped
            return result
        }

        let delta = RGB(r: lit.face.r / gain.r - dark.face.r,
                        g: lit.face.g / gain.g - dark.face.g,
                        b: lit.face.b / gain.b - dark.face.b)
        result.screenGain = dark.face.luma > 0 ? delta.luma / dark.face.luma : 0
        guard min(delta.r, delta.g, delta.b) > 0, result.screenGain >= minimumGain else {
            result.failure = .tooBright
            return result
        }

        let green = dark.face.g / delta.g
        let ambient = RGB(r: dark.face.r / delta.r / green, g: 1, b: dark.face.b / delta.b / green)
        result.ambient = ambient
        guard let kelvin = ColorScience.kelvin(linearR: ambient.r, g: ambient.g, b: ambient.b),
              plausibleKelvin.contains(kelvin) else {
            result.failure = .implausible
            return result
        }
        result.kelvin = kelvin
        return result
    }

    /// Checks the maths against simulated cameras. Usage: Sorot --selftest
    static func selfTest() -> Bool {
        var passed = true
        func check(_ name: String, _ ok: Bool, _ detail: String) {
            print("\(ok ? "PASS" : "FAIL")  \(name): \(detail)")
            if !ok { passed = false }
        }
        func times(_ a: RGB, _ b: RGB) -> RGB { RGB(r: a.r * b.r, g: a.g * b.g, b: a.b * b.b) }
        func plus(_ a: RGB, _ b: RGB) -> RGB { RGB(r: a.r + b.r, g: a.g + b.g, b: a.b + b.b) }
        func scaled(_ a: RGB, _ k: Double) -> RGB { RGB(r: a.r * k, g: a.g * k, b: a.b * k) }

        let skin = RGB(r: 0.6, g: 0.4, b: 0.3), wall = RGB(r: 0.5, g: 0.5, b: 0.45)
        // White balance plus exposure, then a different exposure and a white balance drift.
        let gainsDark = RGB(r: 1.5, g: 1.8, b: 3.0)
        let gainsLit = times(gainsDark, RGB(r: 0.80, g: 0.82, b: 0.78))
        let white = RGB(r: 1, g: 1, b: 1)

        /// Simulates both phases. `leak` is the share of the pulse that reaches the wall.
        func simulate(kelvin: Double, pulse: Double, leak: Double = 0) -> (truth: Double, result: ProbeResult) {
            let c = ColorScience.rgb(kelvin: kelvin)
            let ambient = scaled(RGB(r: ColorScience.linear(c.r), g: ColorScience.linear(c.g), b: ColorScience.linear(c.b)), 0.3)
            let truth = ColorScience.kelvin(linearR: ambient.r, g: ambient.g, b: ambient.b) ?? 0
            let dark = ProbePhase(face: times(gainsDark, times(skin, ambient)),
                                  room: times(gainsDark, times(wall, ambient)), faceClipped: 0)
            let lit = ProbePhase(face: times(gainsLit, times(skin, plus(ambient, scaled(white, pulse)))),
                                 room: times(gainsLit, times(wall, plus(ambient, scaled(white, pulse * leak)))), faceClipped: 0)
            return (truth, solve(dark: dark, lit: lit))
        }

        for kelvin in [2700.0, 4000, 6500] {
            let (truth, result) = simulate(kelvin: kelvin, pulse: 0.15)
            let error = abs((result.kelvin ?? 0) - truth)
            check("recovers \(Int(kelvin)) K lamp through changing camera gains", error < 1,
                  String(format: "truth %.0f K, probe %.0f K", truth, result.kelvin ?? 0))
        }

        let faint = simulate(kelvin: 4000, pulse: 0.001).result
        check("rejects a pulse too weak to measure", faint.failure == .tooBright,
              "failure = \(faint.failure?.rawValue ?? "none")")

        let (truth, leaky) = simulate(kelvin: 3000, pulse: 0.15, leak: 0.1)
        print(String(format: "INFO  10%% of the pulse reaching the wall: truth %.0f K, probe %.0f K", truth, leaky.kelvin ?? 0))
        return passed
    }
}

/// Appends one line of JSON per probe, as training data for the colour model.
/// It stores numbers and colour histograms. No image is ever written.
final class ProbeLog {
    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sorot", isDirectory: true)
            .appendingPathComponent("probes.jsonl")
    }

    func append(_ record: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        let url = Self.fileURL
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) { manager.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        handle.write(json + Data("\n".utf8))
    }
}
