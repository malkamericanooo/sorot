import Foundation

// The learner is the part of Sorot that trains itself, on this Mac, from its own probes.
//
// The picture-based estimate of the room's light colour is wrong by some amount,
// because the camera white-balances every frame. A probe measures the true colour,
// so each probe gives one example: what the camera saw, and how wrong the picture
// estimate was. From those examples the learner fits a small model that predicts
// the error from what the camera sees, so the estimate stays right between probes
// and when the light changes.
//
// The model is ridge regression on eight numbers. It is refitted from scratch after
// every probe, which takes well under a millisecond, and it is only used once it
// predicts probes it has not seen better than a constant correction does.

/// One probe, as the learner remembers it: eight numbers and the answer.
struct LearnerExample: Codable {
    var features: [Double]
    /// Probe minus picture estimate, in mireds (1e6 / kelvin).
    var target: Double
    var time: Double
}

struct RoomLearner {
    /// Fewer examples than this cannot say anything about eight features.
    static let minimumExamples = 8
    /// Oldest examples are dropped beyond this, so the model follows a changed room or camera.
    static let capacity = 300
    /// The model must beat a constant correction by this factor to be used.
    static let requiredGain = 0.85
    static let featureCount = 8

    struct Fit {
        var mean: [Double]
        var scale: [Double]
        var weights: [Double]
        var intercept: Double
        /// Typical error on probes left out of the fit, in mireds.
        var error: Double
        /// The same for a constant correction, the thing the model has to beat.
        var baselineError: Double
        var targetRange: ClosedRange<Double>
    }

    private(set) var examples: [LearnerExample] = []
    private(set) var fit: Fit?

    var count: Int { examples.count }

    /// True when the model has earned its place: enough probes, and better than a constant.
    var isTrusted: Bool {
        guard let fit, examples.count >= Self.minimumExamples else { return false }
        return fit.error < fit.baselineError * Self.requiredGain
    }

    /// What the camera saw, reduced to eight numbers. Nil without a usable background.
    static func features(reading: Reading, pictureKelvin: Double, level: Double) -> [Double]? {
        guard reading.faceFound, let room = reading.roomLinear, pictureKelvin > 0 else { return nil }
        func chroma(_ c: RGB) -> (u: Double, v: Double) {
            (log((c.g + 1e-4) / (c.r + 1e-4)), log((c.g + 1e-4) / (c.b + 1e-4)))
        }
        let r = chroma(room), f = chroma(reading.faceLinear)
        return [1e6 / pictureKelvin, r.u, r.v, f.u, f.v, reading.faceLuma, reading.frameLuma, level]
    }

    mutating func add(features: [Double], target: Double, time: Double = Date().timeIntervalSince1970) {
        guard features.count == Self.featureCount, target.isFinite, features.allSatisfy(\.isFinite) else { return }
        examples.append(LearnerExample(features: features, target: target, time: time))
        if examples.count > Self.capacity { examples.removeFirst(examples.count - Self.capacity) }
        refit()
    }

    /// The predicted correction in mireds, or nil while the model is not trusted.
    func predict(_ features: [Double]) -> Double? {
        guard isTrusted, let fit, features.count == Self.featureCount else { return nil }
        var y = fit.intercept
        for j in 0..<Self.featureCount {
            y += fit.weights[j] * (features[j] - fit.mean[j]) / fit.scale[j]
        }
        // Stay near what probes have actually measured, so an unfamiliar scene cannot send it far off.
        return min(max(y, fit.targetRange.lowerBound - 20), fit.targetRange.upperBound + 20)
    }

    // MARK: - Fitting

    private mutating func refit() {
        let n = examples.count, d = Self.featureCount
        guard n >= Self.minimumExamples else {
            fit = nil
            return
        }
        let nD = Double(n)
        let targets = examples.map(\.target)
        let targetMean = targets.reduce(0, +) / nD

        // Standardise each feature so one ridge strength suits all of them.
        var mean = [Double](repeating: 0, count: d), scale = [Double](repeating: 1, count: d)
        for j in 0..<d {
            let column = examples.map { $0.features[j] }
            mean[j] = column.reduce(0, +) / nD
            let variance = column.reduce(0) { $0 + ($1 - mean[j]) * ($1 - mean[j]) } / nD
            scale[j] = variance > 1e-12 ? variance.squareRoot() : 1
        }
        let x = examples.map { example in (0..<d).map { (example.features[$0] - mean[$0]) / scale[$0] } }
        let y = targets.map { $0 - targetMean }

        var gram = [[Double]](repeating: [Double](repeating: 0, count: d), count: d)
        var moment = [Double](repeating: 0, count: d)
        for i in 0..<n {
            for a in 0..<d {
                moment[a] += x[i][a] * y[i]
                for b in a..<d { gram[a][b] += x[i][a] * x[i][b] }
            }
        }
        for a in 0..<d { for b in 0..<a { gram[a][b] = gram[b][a] } }

        // A constant correction, judged the same way: each probe predicted from the others.
        let baseline = n > 1 ? (y.reduce(0) { $0 + $1 * $1 } / nD).squareRoot() * nD / (nD - 1) : .infinity

        // Try a few ridge strengths and keep the one that predicts left-out probes best.
        var best: (error: Double, weights: [Double])?
        for strength in [0.01, 0.1, 1.0] {
            var regularised = gram
            for a in 0..<d { regularised[a][a] += strength * nD }
            guard let inverse = Self.invert(regularised) else { continue }
            let weights = (0..<d).map { a in (0..<d).reduce(0) { $0 + inverse[a][$1] * moment[$1] } }

            // Leave-one-out error in closed form: residual / (1 − leverage).
            var sum = 0.0
            for i in 0..<n {
                var prediction = 0.0, leverage = 1 / nD
                for a in 0..<d {
                    prediction += weights[a] * x[i][a]
                    var row = 0.0
                    for b in 0..<d { row += inverse[a][b] * x[i][b] }
                    leverage += x[i][a] * row
                }
                let left = (y[i] - prediction) / max(1 - leverage, 0.05)
                sum += left * left
            }
            let error = (sum / nD).squareRoot()
            if best == nil || error < best!.error { best = (error, weights) }
        }
        guard let best else {
            fit = nil
            return
        }
        fit = Fit(mean: mean, scale: scale, weights: best.weights, intercept: targetMean,
                  error: best.error, baselineError: baseline,
                  targetRange: (targets.min() ?? 0)...(targets.max() ?? 0))
    }

    /// Gauss-Jordan inverse of a small symmetric positive-definite matrix.
    private static func invert(_ matrix: [[Double]]) -> [[Double]]? {
        let n = matrix.count
        var a = matrix
        var inverse = (0..<n).map { i in (0..<n).map { $0 == i ? 1.0 : 0.0 } }
        for column in 0..<n {
            guard let pivot = (column..<n).max(by: { abs(a[$0][column]) < abs(a[$1][column]) }),
                  abs(a[pivot][column]) > 1e-12 else { return nil }
            a.swapAt(column, pivot)
            inverse.swapAt(column, pivot)
            let divisor = a[column][column]
            for k in 0..<n {
                a[column][k] /= divisor
                inverse[column][k] /= divisor
            }
            for row in 0..<n where row != column {
                let factor = a[row][column]
                guard factor != 0 else { continue }
                for k in 0..<n {
                    a[row][k] -= factor * a[column][k]
                    inverse[row][k] -= factor * inverse[column][k]
                }
            }
        }
        return inverse
    }

    // MARK: - Storage

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sorot", isDirectory: true)
            .appendingPathComponent("learner.json")
    }

    static func load() -> RoomLearner {
        var learner = RoomLearner()
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([LearnerExample].self, from: data) {
            learner.examples = saved.filter { $0.features.count == featureCount }.suffix(capacity).map { $0 }
            learner.refit()
        }
        return learner
    }

    func save() {
        guard let data = try? JSONEncoder().encode(examples) else { return }
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Self-test

    /// Checks the learner against made-up data with a known answer. Usage: Sorot --selftest
    static func selfTest() -> Bool {
        var passed = true
        func check(_ name: String, _ ok: Bool, _ detail: String) {
            print("\(ok ? "PASS" : "FAIL")  \(name): \(detail)")
            if !ok { passed = false }
        }
        // A fixed random sequence, so the test gives the same result every run.
        var seed: UInt64 = 0x5EED
        func uniform() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        func normal() -> Double { (-2 * log(max(uniform(), 1e-12))).squareRoot() * cos(2 * .pi * uniform()) }

        /// A made-up scene in realistic units, and the correction a made-up camera would need.
        func scene(noise: Double, learnable: Bool) -> (features: [Double], target: Double) {
            let features = [150 + 250 * uniform(), 0.6 * (uniform() - 0.5), 0.8 * (uniform() - 0.5),
                            0.6 * (uniform() - 0.5) - 0.3, 0.8 * (uniform() - 0.5) + 0.3,
                            0.2 + 0.4 * uniform(), 0.1 + 0.5 * uniform(), uniform()]
            let rule = 0.25 * (features[0] - 275) - 90 * features[2] + 60 * features[4] + 25 * features[7]
            return (features, (learnable ? rule : 0) + noise * normal())
        }
        func learner(examples: Int, noise: Double, learnable: Bool) -> RoomLearner {
            var learner = RoomLearner()
            for _ in 0..<examples {
                let s = scene(noise: noise, learnable: learnable)
                learner.add(features: s.features, target: s.target)
            }
            return learner
        }

        let few = learner(examples: 5, noise: 4, learnable: true)
        check("learner waits for \(minimumExamples) probes", !few.isTrusted && few.predict(scene(noise: 0, learnable: true).features) == nil,
              "5 probes, trusted = \(few.isTrusted)")

        for count in [12, 40] {
            let trained = learner(examples: count, noise: 4, learnable: true)
            var sum = 0.0, constant = 0.0
            let fresh = 500
            for _ in 0..<fresh {
                let s = scene(noise: 0, learnable: true)
                let predicted = trained.predict(s.features) ?? trained.fit?.intercept ?? 0
                sum += (predicted - s.target) * (predicted - s.target)
                constant += (s.target - (trained.fit?.intercept ?? 0)) * (s.target - (trained.fit?.intercept ?? 0))
            }
            let unseen = (sum / Double(fresh)).squareRoot(), plain = (constant / Double(fresh)).squareRoot()
            check("learns a camera's error from \(count) probes", trained.isTrusted && unseen < plain * 0.5,
                  String(format: "on 500 unseen scenes: model %.1f mired, constant %.1f mired; its own estimate was %.1f",
                         unseen, plain, trained.fit?.error ?? -1))
        }

        let noisy = learner(examples: 40, noise: 25, learnable: false)
        check("refuses to learn from noise", !noisy.isTrusted,
              String(format: "left-out error %.1f mired, constant %.1f mired", noisy.fit?.error ?? -1, noisy.fit?.baselineError ?? -1))

        var timed = learner(examples: capacity - 1, noise: 4, learnable: true)
        let s = scene(noise: 4, learnable: true)
        let before = Date()
        timed.add(features: s.features, target: s.target)
        let refitTime = Date().timeIntervalSince(before) * 1000
        let predictStart = Date()
        var total = 0.0
        for i in 0..<100_000 {
            var f = s.features
            f[7] = Double(i % 100) / 100
            total += timed.predict(f) ?? 0
        }
        let predictTime = Date().timeIntervalSince(predictStart) / 100_000 * 1e6
        print(String(format: "INFO  with %d probes: refit %.2f ms, one prediction %.2f µs (checksum %.0f)",
                     capacity, refitTime, predictTime, total))
        return passed
    }
}
