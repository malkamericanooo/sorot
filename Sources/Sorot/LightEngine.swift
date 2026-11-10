import AVFoundation
import Combine
import Foundation
import QuartzCore

/// Owns the settings, the camera, the control loop, the probe and the glow.
/// Everything here runs on the main thread.
final class LightEngine: ObservableObject {
    enum CameraState { case idle, starting, live, denied, missing }

    /// A finished probe and when it ran.
    struct ProbeOutcome {
        var date: Date
        var result: ProbeResult
    }

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
        var probe: ProbeOutcome?
    }

    // Settings, saved between launches.
    @Published var isOn: Bool { didSet { save(isOn, "isOn"); refresh() } }
    @Published var isAutomatic: Bool { didSet { save(isAutomatic, "isAutomatic"); refresh() } }
    @Published var target: Double { didSet { save(target, "target") } }
    @Published var manualLevel: Double { didSet { save(manualLevel, "manualLevel"); refresh() } }
    @Published var manualKelvin: Double { didSet { save(manualKelvin, "manualKelvin"); refresh() } }
    @Published var reach: Double { didSet { save(reach, "reach"); pushGlow() } }
    @Published var probesAutomatically: Bool { didSet { save(probesAutomatically, "probesAutomatically") } }
    @Published var savesProbes: Bool { didSet { save(savesProbes, "savesProbes") } }

    // Live state.
    @Published private(set) var camera: CameraState = .idle
    @Published private(set) var faceFound = false
    @Published private(set) var faceLuma: Double?
    /// The room's colour temperature: the picture-based estimate, corrected by the last probe.
    @Published private(set) var roomKelvin: Double?
    @Published private(set) var level = 0.0
    @Published private(set) var kelvin = 5000.0
    @Published private(set) var isProbing = false
    @Published private(set) var lastProbe: ProbeOutcome?

    /// Half-width of the band around the target in which the glow is left alone.
    static let deadband = 0.03
    static let targetRange = 0.30...0.65
    static let kelvinRange = 2700.0...6500.0
    static let automaticProbeInterval = 300.0

    private let isPreview: Bool
    private let defaults = UserDefaults.standard
    private let sampler = CameraSampler()
    private var glow: GlowController?
    private let probeLog = ProbeLog()
    private var lastReadingTime = 0.0
    private var lastReading: Reading?
    private var leftGain = 1.0
    private var rightGain = 1.0

    /// The estimate read from the picture alone, before the probe's correction.
    private var pictureKelvin: Double?
    /// Probe minus picture estimate, in mireds (1e6 / kelvin), where such shifts add up.
    private var miredCorrection = 0.0

    // Probe timing: wait for the screen and camera to settle, then average a few frames.
    private static let probeSettle = 0.35
    private static let probeSamples = 5
    private static let probeTimeout = 4.0
    private enum ProbeStage {
        case idle
        case dark(since: Double, samples: [Reading])
        case lit(since: Double, dark: ProbePhase, samples: [Reading])
    }
    private var probeStage = ProbeStage.idle
    private var probeStart = 0.0
    private var lastProbeAttempt = 0.0
    private var probeContext: (reading: Reading, pictureKelvin: Double?, level: Double, kelvin: Double)?

    init(preview: Preview? = nil) {
        isPreview = preview != nil
        let d = UserDefaults.standard
        isOn = preview?.isOn ?? d.bool(forKey: "isOn")
        isAutomatic = preview?.isAutomatic ?? (d.object(forKey: "isAutomatic") as? Bool ?? true)
        target = d.object(forKey: "target") as? Double ?? 0.45
        manualLevel = d.object(forKey: "manualLevel") as? Double ?? 0.6
        manualKelvin = d.object(forKey: "manualKelvin") as? Double ?? 4500
        reach = d.object(forKey: "reach") as? Double ?? 0.5
        probesAutomatically = preview == nil && d.bool(forKey: "probesAutomatically")
        savesProbes = preview == nil && d.bool(forKey: "savesProbes")

        if let preview {
            camera = preview.camera
            faceFound = preview.faceFound
            faceLuma = preview.faceLuma
            roomKelvin = preview.roomKelvin
            level = preview.level
            kelvin = preview.kelvin
            lastProbe = preview.probe
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
        if isProbing { return "Probing room light…" }
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

    /// Says where the Room reading comes from.
    var roomSource: String {
        guard isOn, isAutomatic else { return "Camera is off in this mode." }
        if isProbing { return "Measuring…" }
        guard let lastProbe else { return "Estimated from the picture. Probe to measure it." }
        if let failure = lastProbe.result.failure { return failure.message }
        let minutes = Int(Date().timeIntervalSince(lastProbe.date) / 60)
        let when = minutes < 1 ? "just now" : "\(minutes) min ago"
        let gain = Int((lastProbe.result.screenGain * 100).rounded())
        return "Measured by probe \(when). Full glow adds \(gain)% light."
    }

    var canProbe: Bool { isOn && isAutomatic && camera == .live && faceFound && !isProbing }

    // MARK: - Mode changes

    private func refresh() {
        guard !isPreview else { return }
        if !isOn || !isAutomatic { cancelProbe() }
        if !isOn {
            sampler.stop()
            camera = .idle
            faceFound = false
            faceLuma = nil
            level = 0
            lastProbe = nil
            miredCorrection = 0
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

        if isProbing {
            advanceProbe(with: reading, now: now)
            return
        }

        let dt = lastReadingTime == 0 ? 0.2 : min(now - lastReadingTime, 1)
        lastReadingTime = now
        lastReading = reading

        if let measured = reading.roomKelvin {
            let previous = pictureKelvin ?? measured
            pictureKelvin = previous + (measured - previous) * 0.08
            applyRoomKelvin()
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

        pushGlow()

        if probesAutomatically, reading.faceFound, now - lastProbeAttempt >= Self.automaticProbeInterval {
            startProbe()
        }
    }

    /// Publishes the room reading (picture estimate plus probe correction) and aims the glow at it.
    private func applyRoomKelvin() {
        guard let pictureKelvin else { return }
        let mired = 1e6 / pictureKelvin + miredCorrection
        let corrected = mired > 0 ? min(max(1e6 / mired, 1500), 12000) : 12000
        roomKelvin = corrected
        kelvin = min(max(corrected, Self.kelvinRange.lowerBound), Self.kelvinRange.upperBound)
    }

    private func pushGlow() {
        guard !isProbing else { return }
        glow?.update(level: isOn ? level : 0, kelvin: kelvin, leftGain: leftGain, rightGain: rightGain, reach: reach)
    }

    // MARK: - Probe

    /// Flashes the screen edges black, then white, to measure the room's true light colour.
    func startProbe() {
        guard canProbe, let reading = lastReading else { return }
        let now = CACurrentMediaTime()
        probeContext = (reading, pictureKelvin, level, kelvin)
        probeStart = now
        lastProbeAttempt = now
        isProbing = true
        sampler.setSampleInterval(0.07)
        glow?.showProbe(lit: false, reach: reach)
        probeStage = .dark(since: now, samples: [])
    }

    private func advanceProbe(with reading: Reading, now: Double) {
        if now - probeStart > Self.probeTimeout {
            finishProbe(ProbeResult(failure: .faceLost))
            return
        }
        switch probeStage {
        case .idle:
            break
        case .dark(let since, var samples):
            guard now - since >= Self.probeSettle, reading.faceFound else { return }
            samples.append(reading)
            if samples.count >= Self.probeSamples {
                glow?.showProbe(lit: true, reach: reach)
                probeStage = .lit(since: now, dark: Self.phase(samples), samples: [])
            } else {
                probeStage = .dark(since: since, samples: samples)
            }
        case .lit(let since, let dark, var samples):
            guard now - since >= Self.probeSettle, reading.faceFound else { return }
            samples.append(reading)
            if samples.count >= Self.probeSamples {
                finishProbe(ProbeMath.solve(dark: dark, lit: Self.phase(samples)), dark: dark, lit: Self.phase(samples))
            } else {
                probeStage = .lit(since: since, dark: dark, samples: samples)
            }
        }
    }

    private static func phase(_ samples: [Reading]) -> ProbePhase {
        let rooms = samples.compactMap(\.roomLinear)
        return ProbePhase(
            face: RGB.mean(samples.map(\.faceLinear)),
            // Only trust the background when every frame of the phase had one.
            room: rooms.count == samples.count ? RGB.mean(rooms) : nil,
            faceClipped: samples.map(\.faceClipped).reduce(0, +) / Double(max(samples.count, 1))
        )
    }

    private func finishProbe(_ result: ProbeResult, dark: ProbePhase? = nil, lit: ProbePhase? = nil) {
        let context = probeContext
        endProbe()
        lastProbe = ProbeOutcome(date: Date(), result: result)

        if let measured = result.kelvin, let picture = context?.pictureKelvin {
            miredCorrection = 1e6 / measured - 1e6 / picture
            applyRoomKelvin()
        }
        if savesProbes, let context {
            probeLog.append(Self.record(result, context: context, dark: dark, lit: lit))
        }
        pushGlow()
    }

    private func cancelProbe() {
        guard isProbing else { return }
        endProbe()
    }

    private func endProbe() {
        probeStage = .idle
        probeContext = nil
        isProbing = false
        lastReadingTime = 0
        sampler.setSampleInterval(0.2)
    }

    /// One training example: what the camera saw in normal use, and what the probe then measured.
    private static func record(_ result: ProbeResult,
                               context: (reading: Reading, pictureKelvin: Double?, level: Double, kelvin: Double),
                               dark: ProbePhase?, lit: ProbePhase?) -> [String: Any] {
        var record: [String: Any] = [
            "version": 1,
            "time": Date().timeIntervalSince1970,
            "valid": result.kelvin != nil,
            "failure": result.failure?.rawValue ?? "",
            "screen_gain": result.screenGain,
            "camera_gain": result.cameraGain.list,
            "ambient": result.ambient.list,
            "glow_level": context.level,
            "glow_kelvin": context.kelvin,
            "face_luma": context.reading.faceLuma,
            "frame_luma": context.reading.frameLuma,
            "face_linear": context.reading.faceLinear.list,
            "room_histogram": context.reading.roomHistogram,
            "face_histogram": context.reading.faceHistogram,
            "histogram_bins": ChromaHistogram.bins,
            "histogram_range": ChromaHistogram.range,
        ]
        if let kelvin = result.kelvin { record["probe_kelvin"] = kelvin }
        if let picture = context.pictureKelvin { record["picture_kelvin"] = picture }
        if let room = context.reading.roomLinear { record["room_linear"] = room.list }
        if let dark {
            record["dark_face"] = dark.face.list
            if let room = dark.room { record["dark_room"] = room.list }
        }
        if let lit {
            record["lit_face"] = lit.face.list
            record["lit_clipped"] = lit.faceClipped
            if let room = lit.room { record["lit_room"] = room.list }
        }
        return record
    }

    private func save(_ value: Any, _ key: String) {
        guard !isPreview else { return }
        defaults.set(value, forKey: key)
    }
}
