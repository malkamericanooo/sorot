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

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "sorot.camera")
    private var isConfigured = false
    private var lastSampleTime = 0.0
    private let sampleInterval = 0.2

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
                if let faceCore, faceCore.contains(point) {
                    if u < faceCore.midX { leftSum += luma; leftCount += 1 }
                    else { rightSum += luma; rightCount += 1 }
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
                    let peak = max(r, g, b)
                    if !isPerson, peak < 245, peak > 20 {
                        roomR += lut[r]; roomG += lut[g]; roomB += lut[b]
                        roomCount += 1
                    }
                }
                x += stride
            }
            y += stride
        }

        guard frameCount > 0 else { return nil }
        let faceCount = leftCount + rightCount
        let faceFound = faceCount >= 12 && leftCount > 0 && rightCount > 0
        let roomKelvin = roomCount >= 200
            ? ColorScience.kelvin(linearR: roomR / Double(roomCount), g: roomG / Double(roomCount), b: roomB / Double(roomCount))
            : nil

        return Reading(
            faceFound: faceFound,
            faceLuma: faceFound ? (leftSum + rightSum) / Double(faceCount) : 0,
            imageLeftLuma: faceFound ? leftSum / Double(leftCount) : 0,
            imageRightLuma: faceFound ? rightSum / Double(rightCount) : 0,
            frameLuma: frameSum / Double(frameCount),
            roomKelvin: roomKelvin
        )
    }
}
