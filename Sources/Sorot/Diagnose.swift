import AppKit
import AVFoundation

/// Measures what the camera really reports with the glow off, at a small Reach and at
/// full Reach, and writes the numbers to a text file. No image is saved: the only
/// picture-like output is a 32×24 grid of brightness digits.
/// Usage: Sorot --diagnose <file>
final class Diagnosis {
    private struct Phase {
        let name: String
        let level: Double
        let reach: Double
        var readings: [Reading] = []
    }

    private let sampler = CameraSampler()
    private let glow = GlowController()
    private var phases = [
        Phase(name: "glow off", level: 0, reach: 0),
        Phase(name: "full glow, Reach 20%", level: 1, reach: 0.2),
        Phase(name: "full glow, Reach 100%", level: 1, reach: 1),
        Phase(name: "glow off again", level: 0, reach: 0),
    ]
    private var index = 0
    private var phaseStart = 0.0
    private var lines: [String] = []
    private var grid: String?
    private let output: URL
    /// The camera's own exposure needs time to settle after the light changes.
    private static let settle = 2.0
    private static let length = 3.5

    init(output: URL) {
        self.output = output
        glow.followsPointer = false
    }

    func run() {
        lines.append("Sorot diagnosis, \(Date())")
        lines.append("camera permission: \(AVCaptureDevice.authorizationStatus(for: .video).rawValue) (3 = allowed)")
        sampler.onFailure = { [weak self] failure in
            DispatchQueue.main.async { self?.finish("camera failed: \(failure)") }
        }
        sampler.onFrame = { [weak self] frame, face in
            let text = Self.brightnessGrid(frame: frame, face: face)
            DispatchQueue.main.async { self?.grid = text }
        }
        sampler.onReading = { [weak self] reading in
            DispatchQueue.main.async { self?.ingest(reading) }
        }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self else { return }
                guard allowed else { return self.finish("camera access was not allowed") }
                self.sampler.start()
                DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in self?.finish("timed out") }
            }
        }
    }

    private func ingest(_ reading: Reading) {
        let now = CACurrentMediaTime()
        if phaseStart == 0 {
            phaseStart = now
            show()
        }
        if now - phaseStart >= Self.settle { phases[index].readings.append(reading) }
        guard now - phaseStart >= Self.length else { return }

        if index == 0, let grid {
            lines.append("")
            lines.append("brightness with the glow off, 0 = black … 9 = white, # = where the face is measured:")
            lines.append(grid)
        }
        index += 1
        phaseStart = now
        if index >= phases.count { finish(nil) } else { show() }
    }

    private func show() {
        let phase = phases[index]
        glow.update(level: phase.level, kelvin: 6500, leftGain: 1, rightGain: 1, reach: phase.reach)
    }

    private func finish(_ problem: String?) {
        sampler.stop()
        glow.update(level: 0, kelvin: 6500, leftGain: 1, rightGain: 1, reach: 0)
        if let problem { lines.append("PROBLEM: \(problem)") }
        lines.append("")
        lines.append("phase                      frames  face seen  face%  left%  right%  frame%  face linear  room linear  clipped")
        for phase in phases {
            let all = phase.readings, seen = all.filter(\.faceFound)
            func mean(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
            let rooms = all.compactMap(\.roomLinear).map(\.luma)
            lines.append(String(format: "%-26@ %6d  %9d  %5.1f  %5.1f  %6.1f  %6.1f  %11.4f  %11.4f  %7.3f",
                                phase.name as NSString, all.count, seen.count,
                                mean(seen.map(\.faceLuma)) * 100, mean(seen.map(\.imageLeftLuma)) * 100,
                                mean(seen.map(\.imageRightLuma)) * 100, mean(all.map(\.frameLuma)) * 100,
                                mean(seen.map { $0.faceLinear.luma }), mean(rooms), mean(seen.map(\.faceClipped))))
        }
        try? lines.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
        exit(problem == nil ? 0 : 1)
    }

    /// A 32×24 grid of mean brightness, one digit per cell.
    private static func brightnessGrid(frame: CVPixelBuffer, face: CGRect?) -> String {
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(frame) else { return "" }
        let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
        let rowBytes = CVPixelBufferGetBytesPerRow(frame)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var core: CGRect?
        if let face {
            let flipped = CGRect(x: face.minX, y: 1 - face.maxY, width: face.width, height: face.height)
            core = flipped.insetBy(dx: flipped.width * 0.2, dy: flipped.height * 0.2)
        }
        let columns = 32, rows = 24
        var text = ""
        for row in 0..<rows {
            for column in 0..<columns {
                var sum = 0, count = 0
                var y = row * height / rows
                while y < (row + 1) * height / rows {
                    var x = column * width / columns
                    while x < (column + 1) * width / columns {
                        let p = pixels + y * rowBytes + x * 4
                        sum += (Int(p[0]) * 7 + Int(p[1]) * 72 + Int(p[2]) * 21) / 100
                        count += 1
                        x += 4
                    }
                    y += 4
                }
                let centre = CGPoint(x: (Double(column) + 0.5) / Double(columns), y: (Double(row) + 0.5) / Double(rows))
                let digit = min(9, sum / max(count, 1) * 10 / 256)
                text += core?.contains(centre) == true ? "#" : String(digit)
            }
            text += "\n"
        }
        if let core {
            text += String(format: "face core: x %.2f…%.2f, y %.2f…%.2f (0,0 = top left of the camera image)",
                           core.minX, core.maxX, core.minY, core.maxY)
        } else {
            text += "no face detected in this frame"
        }
        return text
    }
}
