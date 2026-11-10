import AVFoundation
import Combine
import Foundation
import QuartzCore

/// Owns the settings, the camera, the control loop and the glow.
/// Everything here runs on the main thread.
final class LightEngine: ObservableObject {
    enum CameraState { case idle, starting, live, denied, missing }

    /// What the panel needs to draw a state without a camera, for snapshots.
    struct Preview {
        var isOn = true
        var isAutomatic = true
        var camera: CameraState = .live
        var faceFound = true
        var faceLuma: Double? = 0.34
        var roomKelvin: Double? = 3400
        var level = 0.62
        var kelvin = 3400.0
    }

    // Settings, saved between launches.
    @Published var isOn: Bool { didSet { save(isOn, "isOn"); refresh() } }
    @Published var isAutomatic: Bool { didSet { save(isAutomatic, "isAutomatic"); refresh() } }
    @Published var target: Double { didSet { save(target, "target") } }
    @Published var manualLevel: Double { didSet { save(manualLevel, "manualLevel"); refresh() } }
    @Published var manualKelvin: Double { didSet { save(manualKelvin, "manualKelvin"); refresh() } }
    @Published var reach: Double { didSet { save(reach, "reach"); pushGlow() } }
    @Published var logsReadings: Bool { didSet { save(logsReadings, "logsReadings") } }

    // Live state.
    @Published private(set) var camera: CameraState = .idle
    @Published private(set) var faceFound = false
    @Published private(set) var faceLuma: Double?
    @Published private(set) var roomKelvin: Double?
    @Published private(set) var level = 0.0
    @Published private(set) var kelvin = 5000.0

    /// Half-width of the band around the target in which the glow is left alone.
    static let deadband = 0.03
    static let targetRange = 0.30...0.65
    static let kelvinRange = 2700.0...6500.0

    private let isPreview: Bool
    private let defaults = UserDefaults.standard
    private let sampler = CameraSampler()
    private var glow: GlowController?
    private let log = ReadingLog()
    private var lastReadingTime = 0.0
    private var leftGain = 1.0
    private var rightGain = 1.0

    init(preview: Preview? = nil) {
        isPreview = preview != nil
        let d = UserDefaults.standard
        isOn = preview?.isOn ?? d.bool(forKey: "isOn")
        isAutomatic = preview?.isAutomatic ?? (d.object(forKey: "isAutomatic") as? Bool ?? true)
        target = d.object(forKey: "target") as? Double ?? 0.45
        manualLevel = d.object(forKey: "manualLevel") as? Double ?? 0.6
        manualKelvin = d.object(forKey: "manualKelvin") as? Double ?? 4500
        reach = d.object(forKey: "reach") as? Double ?? 0.5
        logsReadings = preview == nil && d.bool(forKey: "logsReadings")

        if let preview {
            camera = preview.camera
            faceFound = preview.faceFound
            faceLuma = preview.faceLuma
            roomKelvin = preview.roomKelvin
            level = preview.level
            kelvin = preview.kelvin
            return
        }

        glow = GlowController()
        sampler.onReading = { [weak self] reading in
            DispatchQueue.main.async { self?.ingest(reading) }
        }
        sampler.onFailure = { [weak self] _ in
            DispatchQueue.main.async { self?.camera = .missing }
        }
        refresh()
    }

    /// One line describing what the light is doing right now.
    var status: String {
        guard isOn else { return "Off" }
        guard isAutomatic else { return "Manual light" }
        switch camera {
        case .idle, .starting: return "Starting camera…"
        case .denied: return "Camera access is off"
        case .missing: return "No camera found"
        case .live:
            guard faceFound, let faceLuma else { return "No face in view. Holding this level." }
            let error = target - faceLuma
            if abs(error) <= Self.deadband { return "Face is on target" }
            if error > 0 { return level >= 0.999 ? "At full glow. The room is too dark for the screen alone." : "Brightening" }
            return level <= 0.001 ? "Room light is enough" : "Dimming"
        }
    }

    // MARK: - Mode changes

    private func refresh() {
        guard !isPreview else { return }
        if !isOn {
            sampler.stop()
            camera = .idle
            faceFound = false
            faceLuma = nil
            level = 0
        } else if isAutomatic {
            startCameraIfAllowed()
        } else {
            // Manual mode does not need the camera, so its light stays off.
            sampler.stop()
            camera = .idle
            faceFound = false
            faceLuma = nil
            level = manualLevel
            kelvin = manualKelvin
            leftGain = 1
            rightGain = 1
        }
        pushGlow()
    }

    private func startCameraIfAllowed() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            if camera != .live { camera = .starting }
            lastReadingTime = 0
            sampler.start()
        case .notDetermined:
            camera = .starting
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
        default:
            camera = .denied
            level = 0
        }
    }

    // MARK: - Control loop

    private func ingest(_ reading: Reading) {
        guard isOn, isAutomatic else { return }
        camera = .live

        let now = CACurrentMediaTime()
        let dt = lastReadingTime == 0 ? 0.2 : min(now - lastReadingTime, 1)
        lastReadingTime = now

        if let measured = reading.roomKelvin {
            let previous = roomKelvin ?? measured
            roomKelvin = previous + (measured - previous) * 0.08
            kelvin = min(max(roomKelvin ?? 5000, Self.kelvinRange.lowerBound), Self.kelvinRange.upperBound)
        }

        faceFound = reading.faceFound
        if reading.faceFound {
            let previous = faceLuma ?? reading.faceLuma
            let smoothed = previous + (reading.faceLuma - previous) * 0.4
            faceLuma = smoothed

            // Integral control: keep nudging the glow until the face sits in the deadband.
            let error = target - smoothed
            if abs(error) > Self.deadband {
                level = min(max(level + 1.5 * error * dt, 0), 1)
            }

            // Dim the screen edge on the side of the face that is already brighter.
            // The image is unmirrored, so image-left is the user's right, which the
            // right screen edge lights.
            let sum = max(reading.imageLeftLuma + reading.imageRightLuma, 0.01)
            let skew = (reading.imageLeftLuma - reading.imageRightLuma) / sum
            let cut = min(abs(skew) * 2, 0.5)
            let wantRight = skew > 0 ? 1 - cut : 1
            let wantLeft = skew < 0 ? 1 - cut : 1
            rightGain += (wantRight - rightGain) * 0.15
            leftGain += (wantLeft - leftGain) * 0.15
        }

        if logsReadings {
            log.append(reading, level: level, kelvin: kelvin, target: target)
        }
        pushGlow()
    }

    private func pushGlow() {
        glow?.update(level: isOn ? level : 0, kelvin: kelvin, leftGain: leftGain, rightGain: rightGain, reach: reach)
    }

    private func save(_ value: Any, _ key: String) {
        guard !isPreview else { return }
        defaults.set(value, forKey: key)
    }
}

/// Appends readings to a CSV file so a model can be trained on them later.
/// Numbers only: no image ever leaves the camera pipeline.
final class ReadingLog {
    static var fileURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sorot", isDirectory: true)
        return folder.appendingPathComponent("readings.csv")
    }

    private var handle: FileHandle?

    func append(_ r: Reading, level: Double, kelvin: Double, target: Double) {
        if handle == nil { open() }
        let room = r.roomKelvin.map { String(format: "%.0f", $0) } ?? ""
        let line = String(
            format: "%.2f,%d,%.4f,%.4f,%.4f,%.4f,%@,%.4f,%.0f,%.2f\n",
            Date().timeIntervalSince1970, r.faceFound ? 1 : 0, r.faceLuma, r.imageLeftLuma,
            r.imageRightLuma, r.frameLuma, room, level, kelvin, target
        )
        handle?.write(Data(line.utf8))
    }

    private func open() {
        let url = Self.fileURL
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) {
            let header = "time,face_found,face_luma,image_left_luma,image_right_luma,frame_luma,room_kelvin,glow_level,glow_kelvin,target\n"
            manager.createFile(atPath: url.path, contents: Data(header.utf8))
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }
}
