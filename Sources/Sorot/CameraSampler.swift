import AVFoundation
import QuartzCore
import Vision

/// One measurement taken from a single webcam frame.
struct Reading: Sendable {
    var faceFound: Bool
    /// Mean brightness of the middle of the face, sRGB-encoded, 0…1.
    var faceLuma: Double
    /// The same, for the left and right halves of the face as they appear in the image.
    var imageLeftLuma: Double
    var imageRightLuma: Double
    /// Mean brightness of the whole frame, 0…1.
    var frameLuma: Double
    /// Colour temperature of the background, or nil when too little of it is usable.
    var roomKelvin: Double?

    // Colour data for the probe and for training. All values are linear light.
    /// Mean colour of the middle of the face.
    var faceLinear = RGB.zero
    /// Mean colour of the background, or nil when too little of it is usable.
    var roomLinear: RGB?
    /// Share of face pixels at the sensor's ceiling, where colour is lost.
    var faceClipped = 0.0
    /// Where the background's and the face's colours fall, as histograms over
    /// log(G/R) and log(G/B). They hold no positions, so no picture can be rebuilt.
    var roomHistogram: [Float] = []
    var faceHistogram: [Float] = []
}

/// A colour in linear light.
struct RGB: Sendable {
    var r: Double, g: Double, b: Double
    static let zero = RGB(r: 0, g: 0, b: 0)
    var luma: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    var list: [Double] { [r, g, b] }

    static func mean(_ colors: [RGB]) -> RGB {
        let n = Double(max(colors.count, 1))
        return RGB(r: colors.reduce(0) { $0 + $1.r } / n,
                   g: colors.reduce(0) { $0 + $1.g } / n,
                   b: colors.reduce(0) { $0 + $1.b } / n)
    }
}

/// A 2-D histogram of colour, independent of brightness.
struct ChromaHistogram {
    static let bins = 12
    static let range = 1.2
    private var counts = [Float](repeating: 0, count: bins * bins)
    private var total: Float = 0

    mutating func add(r: Double, g: Double, b: Double) {
        let u = log((g + 1e-4) / (r + 1e-4)), v = log((g + 1e-4) / (b + 1e-4))
        counts[Self.bin(v) * Self.bins + Self.bin(u)] += 1
        total += 1
    }

    private static func bin(_ x: Double) -> Int {
        min(bins - 1, max(0, Int((x + range) / (2 * range) * Double(bins))))
    }

    /// Counts scaled to sum to 1, or all zeros when empty.
    var normalized: [Float] { total > 0 ? counts.map { $0 / total } : counts }
}

/// Reads the webcam a few times per second and turns each frame into a `Reading`.
///
/// Two Vision models run on every sampled frame: a face detector, which says
/// where to measure brightness, and a person segmenter, which says which
/// pixels are the room and not the person.
final class CameraSampler: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Failure { case noCamera, cannotConfigure }

    var onReading: ((Reading) -> Void)?
    var onFailure: ((Failure) -> Void)?
    /// For diagnosis only: the raw frame and the face box Vision found in it.
    var onFrame: ((CVPixelBuffer, CGRect?) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "sorot.camera")
    private var isConfigured = false
    private var lastSampleTime = 0.0
    private var sampleInterval = 0.2

    /// How often a frame is measured. The probe asks for a faster rate while it runs.
    func setSampleInterval(_ seconds: Double) {
        queue.async { [self] in sampleInterval = seconds }
    }

    private let faceRequest = VNDetectFaceRectanglesRequest()
    private let personRequest: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .fast
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()

    func start() {
        queue.async { [self] in
            if !isConfigured {
                guard configure() else { return }
                isConfigured = true
            }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure() -> Bool {
        guard let device = AVCaptureDevice.default(for: .video) else {
            onFailure?(.noCamera)
            return false
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }

        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            onFailure?(.cannotConfigure)
            return false
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            onFailure?(.cannotConfigure)
            return false
        }
        session.addOutput(output)

        // Keep the image unmirrored so "image left" always means the same side.
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        return true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastSampleTime >= sampleInterval,
              let frame = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastSampleTime = now

        let handler = VNImageRequestHandler(cvPixelBuffer: frame, orientation: .up)
        try? handler.perform([faceRequest, personRequest])

        let face = faceRequest.results?.max { $0.boundingBox.width < $1.boundingBox.width }
        let mask = personRequest.results?.first?.pixelBuffer
        onFrame?(frame, face?.boundingBox)
        if let reading = Self.measure(frame: frame, face: face?.boundingBox, personMask: mask) {
            onReading?(reading)
        }
    }

    /// Walks a coarse grid over the frame and averages face and background pixels.
    static func measure(frame: CVPixelBuffer, face: CGRect?, personMask: CVPixelBuffer?) -> Reading? {
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(frame) else { return nil }
        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)
        let rowBytes = CVPixelBufferGetBytesPerRow(frame)
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        var maskPixels: UnsafeMutablePointer<UInt8>?
        var maskWidth = 0, maskHeight = 0, maskRowBytes = 0
        if let personMask {
            CVPixelBufferLockBaseAddress(personMask, .readOnly)
            maskPixels = CVPixelBufferGetBaseAddress(personMask)?.assumingMemoryBound(to: UInt8.self)
            maskWidth = CVPixelBufferGetWidth(personMask)
            maskHeight = CVPixelBufferGetHeight(personMask)
            maskRowBytes = CVPixelBufferGetBytesPerRow(personMask)
        }
        defer { if let personMask { CVPixelBufferUnlockBaseAddress(personMask, .readOnly) } }

        // Vision uses a bottom-left origin; pixel rows run top-down.
        var faceRect: CGRect?
        var faceCore: CGRect?
        if let face {
            let flipped = CGRect(x: face.minX, y: 1 - face.maxY, width: face.width, height: face.height)
            faceRect = flipped
            // The middle of the box, to keep hair and background out of the average.
            faceCore = flipped.insetBy(dx: flipped.width * 0.2, dy: flipped.height * 0.2)
        }

        var leftSum = 0.0, rightSum = 0.0, leftCount = 0, rightCount = 0
        var frameSum = 0.0, frameCount = 0
        var roomR = 0.0, roomG = 0.0, roomB = 0.0, roomCount = 0
        var faceR = 0.0, faceG = 0.0, faceB = 0.0, faceClippedCount = 0
        var roomHistogram = ChromaHistogram(), faceHistogram = ChromaHistogram()
        let lut = ColorScience.linearLUT
        let stride = 6

        var y = stride / 2
        while y < height {
            let v = Double(y) / Double(height)
            var x = stride / 2
            while x < width {
                let u = Double(x) / Double(width)
                let p = pixels + y * rowBytes + x * 4
                let b = Int(p[0]), g = Int(p[1]), r = Int(p[2])
                let luma = (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)) / 255
                frameSum += luma
                frameCount += 1

                let point = CGPoint(x: u, y: v)
                let peak = max(r, g, b)
                if let faceCore, faceCore.contains(point) {
                    if u < faceCore.midX { leftSum += luma; leftCount += 1 }
                    else { rightSum += luma; rightCount += 1 }
                    faceR += lut[r]; faceG += lut[g]; faceB += lut[b]
                    if peak >= 250 { faceClippedCount += 1 }
                    else if peak > 20 { faceHistogram.add(r: lut[r], g: lut[g], b: lut[b]) }
                } else {
                    let isPerson: Bool
                    if let maskPixels {
                        let mx = min(maskWidth - 1, Int(u * Double(maskWidth)))
                        let my = min(maskHeight - 1, Int(v * Double(maskHeight)))
                        isPerson = maskPixels[my * maskRowBytes + mx] > 64
                    } else if let faceRect {
                        isPerson = faceRect.insetBy(dx: -faceRect.width * 0.5, dy: -faceRect.height * 0.5).contains(point)
                    } else {
                        isPerson = false
                    }
                    // Clipped and near-black pixels carry no colour information.
                    if !isPerson, peak < 245, peak > 20 {
                        roomR += lut[r]; roomG += lut[g]; roomB += lut[b]
                        roomCount += 1
                        roomHistogram.add(r: lut[r], g: lut[g], b: lut[b])
                    }
                }
                x += stride
            }
            y += stride
        }

        guard frameCount > 0 else { return nil }
        let faceCount = leftCount + rightCount
        let faceFound = faceCount >= 12 && leftCount > 0 && rightCount > 0
        let roomLinear = roomCount >= 200
            ? RGB(r: roomR / Double(roomCount), g: roomG / Double(roomCount), b: roomB / Double(roomCount))
            : nil
        let roomKelvin = roomLinear.flatMap { ColorScience.kelvin(linearR: $0.r, g: $0.g, b: $0.b) }
        let n = Double(max(faceCount, 1))

        return Reading(
            faceFound: faceFound,
            faceLuma: faceFound ? (leftSum + rightSum) / Double(faceCount) : 0,
            imageLeftLuma: faceFound ? leftSum / Double(leftCount) : 0,
            imageRightLuma: faceFound ? rightSum / Double(rightCount) : 0,
            frameLuma: frameSum / Double(frameCount),
            roomKelvin: roomKelvin,
            faceLinear: faceFound ? RGB(r: faceR / n, g: faceG / n, b: faceB / n) : .zero,
            roomLinear: roomLinear,
            faceClipped: faceFound ? Double(faceClippedCount) / n : 0,
            roomHistogram: roomHistogram.normalized,
            faceHistogram: faceHistogram.normalized
        )
    }
}
