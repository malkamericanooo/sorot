import AppKit
import QuartzCore

/// Draws the light: a band of colour along each edge of the main screen,
/// in a window that sits above everything and ignores the mouse.
final class GlowController {
    private let window: NSWindow
    private let left = CAGradientLayer()
    private let right = CAGradientLayer()
    private let top = CAGradientLayer()
    private let bottom = CAGradientLayer()
    private var observer: NSObjectProtocol?

    /// Band width in points at full glow, for the smallest and largest Reach setting.
    private static let reachWidths: ClosedRange<CGFloat> = 60...320

    init() {
        window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false

        let view = NSView()
        view.wantsLayer = true
        window.contentView = view

        // Each band is solid near the screen edge and fades out toward the middle.
        left.startPoint = CGPoint(x: 0, y: 0.5); left.endPoint = CGPoint(x: 1, y: 0.5)
        right.startPoint = CGPoint(x: 1, y: 0.5); right.endPoint = CGPoint(x: 0, y: 0.5)
        bottom.startPoint = CGPoint(x: 0.5, y: 0); bottom.endPoint = CGPoint(x: 0.5, y: 1)
        top.startPoint = CGPoint(x: 0.5, y: 1); top.endPoint = CGPoint(x: 0.5, y: 0)
        for band in [left, right, top, bottom] {
            band.locations = [0, 0.55, 1]
            view.layer?.addSublayer(band)
        }

        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.fitToScreen() }
        fitToScreen()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func fitToScreen() {
        guard let screen = NSScreen.screens.first else { return }
        window.setFrame(screen.frame, display: true)
    }

    func update(level: Double, kelvin: Double, leftGain: Double, rightGain: Double, reach: Double) {
        guard level > 0.004 else {
            window.orderOut(nil)
            return
        }
        let width = maxWidth(reach: reach) * CGFloat(0.35 + 0.65 * level)
        let alpha = min(1, level * 1.6)
        let rgb = ColorScience.rgb(kelvin: kelvin)
        func colors(_ gain: Double) -> [CGColor] { Self.band(rgb.r, rgb.g, rgb.b, alpha: alpha * gain) }
        let both = (leftGain + rightGain) / 2
        draw(width: width, left: colors(leftGain), right: colors(rightGain), top: colors(both), bottom: colors(both),
             animated: true)
    }

    /// The probe's two phases: the bands at full width, solid black and then solid white.
    /// Black first, so the only thing that changes between the phases is the pulse itself.
    func showProbe(lit: Bool, reach: Double) {
        let v: CGFloat = lit ? 1 : 0
        let colors = Self.band(v, v, v, alpha: 1)
        draw(width: maxWidth(reach: reach), left: colors, right: colors, top: colors, bottom: colors, animated: false)
    }

    private func maxWidth(reach: Double) -> CGFloat {
        Self.reachWidths.lowerBound + (Self.reachWidths.upperBound - Self.reachWidths.lowerBound) * CGFloat(reach)
    }

    private static func band(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, alpha: CGFloat) -> [CGColor] {
        let solid = CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
        let clear = CGColor(srgbRed: r, green: g, blue: b, alpha: 0)
        return [solid, solid, clear]
    }

    private func draw(width requested: CGFloat, left l: [CGColor], right r: [CGColor], top t: [CGColor],
                      bottom b: [CGColor], animated: Bool) {
        if !window.isVisible {
            fitToScreen()
            window.orderFrontRegardless()
        }
        let size = window.frame.size
        let width = min(requested, min(size.width, size.height) / 2)

        CATransaction.begin()
        if animated { CATransaction.setAnimationDuration(0.5) } else { CATransaction.setDisableActions(true) }
        left.frame = CGRect(x: 0, y: 0, width: width, height: size.height)
        right.frame = CGRect(x: size.width - width, y: 0, width: width, height: size.height)
        bottom.frame = CGRect(x: 0, y: 0, width: size.width, height: width)
        top.frame = CGRect(x: 0, y: size.height - width, width: size.width, height: width)
        left.colors = l
        right.colors = r
        top.colors = t
        bottom.colors = b
        CATransaction.commit()
    }
}
