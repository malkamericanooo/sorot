import AppKit
import SwiftUI

/// The typefaces the panel uses: one for the title, one for words, one for numbers.
/// A nil family means the system font in the given design.
struct PanelFonts {
    var name = "SF Pro + SF Mono"
    /// Falls back to `textFamily` when nil.
    var titleFamily: String?
    var textFamily: String?
    var textDesign: Font.Design = .default
    var numberFamily: String?
    var numberDesign: Font.Design = .monospaced

    func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if let textFamily { return Font.custom(textFamily, fixedSize: size).weight(weight) }
        return .system(size: size, weight: weight, design: textDesign)
    }

    func title(_ size: CGFloat) -> Font {
        if let family = titleFamily ?? textFamily { return Font.custom(family, fixedSize: size).weight(.bold) }
        return .system(size: size, weight: .bold, design: textDesign)
    }

    func number(_ size: CGFloat) -> Font {
        if let numberFamily { return Font.custom(numberFamily, fixedSize: size).monospacedDigit() }
        return Font.system(size: size, design: numberDesign).monospacedDigit()
    }

    /// True when every named family is installed on this Mac.
    var isAvailable: Bool {
        [titleFamily, textFamily, numberFamily].compactMap { $0 }.allSatisfy { NSFont(name: $0, size: 12) != nil }
    }

    /// What the app ships with: Futura for the title and the readings, Optima for words.
    static let standard = PanelFonts(name: "Futura + Optima", titleFamily: "Futura",
                                     textFamily: "Optima", numberFamily: "Futura")

    /// Candidates for the panel. All ship with macOS, so nothing has to be bundled.
    static let options: [PanelFonts] = [
        standard,
        PanelFonts(),
        PanelFonts(name: "SF Mono only", textDesign: .monospaced),
        PanelFonts(name: "SF Rounded", textDesign: .rounded, numberDesign: .rounded),
        PanelFonts(name: "New York + SF Mono", textDesign: .serif),
        PanelFonts(name: "Avenir Next + Menlo", textFamily: "Avenir Next", numberFamily: "Menlo"),
        PanelFonts(name: "Helvetica Neue + DIN Alternate", textFamily: "Helvetica Neue", numberFamily: "DIN Alternate"),
        PanelFonts(name: "Futura", textFamily: "Futura", numberFamily: "Futura"),
        PanelFonts(name: "Gill Sans", textFamily: "Gill Sans", numberFamily: "Gill Sans"),
        PanelFonts(name: "Optima + Menlo", textFamily: "Optima", numberFamily: "Menlo"),
        PanelFonts(name: "Charter + SF Mono", textFamily: "Charter"),
        PanelFonts(name: "American Typewriter", textFamily: "American Typewriter", numberFamily: "American Typewriter"),
        PanelFonts(name: "Monaco only", textFamily: "Monaco", numberFamily: "Monaco"),
    ]
}

private struct PanelFontsKey: EnvironmentKey {
    static let defaultValue = PanelFonts.standard
}

extension EnvironmentValues {
    var panelFonts: PanelFonts {
        get { self[PanelFontsKey.self] }
        set { self[PanelFontsKey.self] = newValue }
    }
}
