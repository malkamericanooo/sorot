import Foundation

/// Colour maths shared by the camera measurement and the glow.
enum ColorScience {
    /// sRGB-encoded channel (0…1) to linear light.
    static func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Lookup table for 8-bit channels, so the per-pixel loop avoids `pow`.
    static let linearLUT: [Double] = (0..<256).map { linear(Double($0) / 255) }

    /// Correlated colour temperature of a linear sRGB colour, using McCamy's
    /// approximation on CIE xy chromaticity. Returns nil for black.
    static func kelvin(linearR r: Double, g: Double, b: Double) -> Double? {
        let X = 0.4124 * r + 0.3576 * g + 0.1805 * b
        let Y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let Z = 0.0193 * r + 0.1192 * g + 0.9505 * b
        let sum = X + Y + Z
        guard sum > 1e-6 else { return nil }
        let x = X / sum, y = Y / sum
        let n = (x - 0.3320) / (0.1858 - y)
        let t = 449 * n * n * n + 3525 * n * n + 6823.3 * n + 5520.33
        return t.isFinite ? t : nil
    }

    /// Display colour (sRGB, 0…1) of a black-body light at the given temperature.
    /// Tanner Helland's curve fit, good from about 1000 K to 12000 K.
    static func rgb(kelvin: Double) -> (r: Double, g: Double, b: Double) {
        let t = min(max(kelvin, 1000), 12000) / 100
        var r: Double, g: Double, b: Double
        if t <= 66 {
            r = 255
            g = 99.4708025861 * log(t) - 161.1195681661
            b = t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307
        } else {
            r = 329.698727446 * pow(t - 60, -0.1332047592)
            g = 288.1221695283 * pow(t - 60, -0.0755148492)
            b = 255
        }
        func unit(_ v: Double) -> Double { min(max(v, 0), 255) / 255 }
        return (unit(r), unit(g), unit(b))
    }
}
