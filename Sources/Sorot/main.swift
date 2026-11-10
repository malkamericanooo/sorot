import AppKit
import SwiftUI

struct SorotApp: App {
    @StateObject private var engine = LightEngine()

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(engine)
        } label: {
            Image(systemName: Self.symbol)
                .accessibilityLabel("Sorot")
        }
        .menuBarExtraStyle(.window)
    }

    /// `light.panel` is not in every SF Symbols version; fall back to one that is.
    private static let symbol: String =
        NSImage(systemSymbolName: "light.panel", accessibilityDescription: nil) != nil ? "light.panel" : "sun.max"
}

// MARK: - Snapshots (development only)

/// Renders the panel off screen, without a camera.
func renderPanel(_ preview: LightEngine.Preview, appearance: NSAppearance.Name,
                 fonts: PanelFonts = .standard) -> NSBitmapImageRep? {
    let engine = LightEngine(preview: preview)
    let host = NSHostingView(rootView: PanelView()
        .environmentObject(engine)
        .environment(\.panelFonts, fonts)
        .background(Color(nsColor: .windowBackgroundColor)))
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -5000, y: -5000), size: host.fittingSize),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: appearance)
    window.contentView = host
    window.orderFrontRegardless()
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    defer { window.orderOut(nil) }

    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) {
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
}

/// Usage: Sorot --snapshot <folder>. One PNG per panel state and appearance.
func writeStateSnapshots(to folder: URL) {
    let states: [(String, LightEngine.Preview)] = [
        ("auto-live", .init()),
        ("auto-no-face", .init(faceFound: false, faceLuma: nil, level: 0.4)),
        ("manual", .init(isAutomatic: false, camera: .idle, faceFound: false, faceLuma: nil, roomKelvin: nil, level: 0.6, kelvin: 4500)),
        ("denied", .init(camera: .denied, faceFound: false, faceLuma: nil, roomKelvin: nil, level: 0)),
        ("off", .init(isOn: false, camera: .idle, faceFound: false, faceLuma: nil, roomKelvin: nil, level: 0)),
    ]
    for (name, preview) in states {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            guard let rep = renderPanel(preview, appearance: appearance) else { continue }
            let suffix = appearance == .aqua ? "light" : "dark"
            writePNG(rep, to: folder.appendingPathComponent("\(name)-\(suffix).png"))
        }
    }
}

/// Usage: Sorot --fonts <folder> [light|dark]. Contact sheets of the panel in each font option.
func writeFontSheets(to folder: URL, appearance: NSAppearance.Name) {
    let options = PanelFonts.options.filter { option in
        if !option.isAvailable { print("Skipped, not installed: \(option.name)") }
        return option.isAvailable
    }
    let dark = appearance == .darkAqua
    let perSheet = 6, columns = 3
    let gap: CGFloat = 24, labelHeight: CGFloat = 28

    for (sheetIndex, start) in stride(from: 0, to: options.count, by: perSheet).enumerated() {
        let chunk = Array(options[start..<min(start + perSheet, options.count)])
        let panels = chunk.compactMap { renderPanel(.init(), appearance: appearance, fonts: $0) }
        guard panels.count == chunk.count, let first = panels.first else { continue }
        let cell = first.size
        let rows = Int(ceil(Double(chunk.count) / Double(columns)))
        let tallest = panels.map(\.size.height).max() ?? cell.height
        let size = NSSize(width: gap + CGFloat(columns) * (cell.width + gap),
                          height: gap + CGFloat(rows) * (tallest + labelHeight + gap))

        let scale = 2
        guard let sheet = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { continue }
        sheet.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
        (dark ? NSColor(white: 0.06, alpha: 1) : NSColor(white: 0.86, alpha: 1)).setFill()
        NSRect(origin: .zero, size: size).fill()
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: dark ? NSColor.white : NSColor.black,
        ]
        for (index, panel) in panels.enumerated() {
            let column = index % columns, row = index / columns
            let x = gap + CGFloat(column) * (cell.width + gap)
            let top = size.height - gap - CGFloat(row) * (tallest + labelHeight + gap)
            ("\(start + index + 1).  \(chunk[index].name)" as NSString)
                .draw(at: NSPoint(x: x, y: top - 20), withAttributes: labelAttributes)
            panel.draw(in: NSRect(x: x, y: top - labelHeight - panel.size.height,
                                  width: panel.size.width, height: panel.size.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        writePNG(sheet, to: folder.appendingPathComponent("fonts-\(sheetIndex + 1).png"))
    }
}

let arguments = CommandLine.arguments
func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.count > index + 1 else { return nil }
    return arguments[index + 1]
}

if let path = value(after: "--snapshot") ?? value(after: "--fonts") {
    _ = NSApplication.shared
    let folder = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    if arguments.contains("--fonts") {
        writeFontSheets(to: folder, appearance: arguments.contains("light") ? .aqua : .darkAqua)
    } else {
        writeStateSnapshots(to: folder)
    }
} else {
    SorotApp.main()
}
