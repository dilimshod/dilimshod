import Foundation

// Classical (non-ML) lane-marking detection for the beginner-driver coach.
//
// HONEST SCOPE: a heuristic. It works on clearly painted white / yellow markings in daylight on a reasonably
// straight road. Worn markings, night, rain, glare, tight curves, shadows of trees, zebra crossings and cars covering
// the markings reduce the confidence (the detector then reports low confidence instead of guessing).
//
// Pipeline (all on a small downsampled single-channel image, ≤ 200 px wide):
//  1. `LaneImage.fromBGRA` builds a "marking brightness" channel: luma, with yellow pixels lifted to white level.
//  2. ROI = rows between `EgoCorridor.horizonY` (+ margin) and `roiBottom`.
//  3. Per row: a pixel is a marking candidate when it is a bright ridge ("dark–light–dark", width expected from
//     perspective) — brighter than both neighbours at ± d by `ridgeContrast` — and brighter than the local road
//     brightness (box mean over ±W/8) by `localContrast`, and above `minBrightness`. This is the edge/gradient filter.
//  4. Hough voting separately for the left and the right half with slope constraints (angle to the horizontal between
//     `minAngleDegrees` and `maxAngleDegrees`, line must reach the centre area at the horizon), then least-squares refit
//     of the inliers.
//     The three thresholds adapt per frame to the measured pixel noise and road brightness (`adaptiveThresholds`),
//     and the marking image is the pixel-wise maximum of the last `accumulateFrames` lane frames (dashed lines).
//  5. Temporal smoothing (EMA of the line end points, outlier rejection, confidence decay when missed).
//  6. The intersection of the two raw fits (vanishing point) is published per frame for `LaneHorizonEstimator`.

/// Single-channel 8-bit image (row-major, top-left origin).
public struct LaneImage: Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height, "pixel count must be width × height")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: UInt8 = 0) {
        self.width = width
        self.height = height
        self.pixels = [UInt8](repeating: fill, count: max(0, width * height))
    }

    @inline(__always) public subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// "Marking brightness" of one BGR(A) pixel: luma, but saturated yellow (road-marking yellow) counts as bright.
    @inline(__always) public static func markingValue(r: Int, g: Int, b: Int) -> UInt8 {
        let luma = (77 * r + 150 * g + 29 * b) >> 8
        let rg = (r + g) / 2
        var value = luma
        if r > 110, g > 85, rg - b > 45 {
            value = max(value, min(255, rg + (rg - b) / 2))
        }
        return UInt8(clamping: value)
    }

    /// Downsamples a locked 32BGRA buffer to `targetWidth` (aspect kept) and converts it to marking brightness.
    /// Rows above `roiTop` (fraction of the height) are left black to save time.
    ///
    /// Each output pixel covers a `scale × scale` cell of the source. Horizontally the cell is scanned in steps of
    /// 2 source pixels and the BRIGHTEST 2×2-averaged sample is kept (max-pooling): a marking that is thinner than the
    /// cell (far markings, landscape 1920-px frames with a 12× reduction) is not lost between sparse sample points,
    /// as it was with plain point sampling. Max-pooling lifts the road level a little too, which the relative
    /// (ridge / local-contrast) tests ignore.
    public static func fromBGRA(base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int,
                                targetWidth: Int = 160, roiTop: Double = 0) -> LaneImage {
        guard width > 1, height > 1, targetWidth > 1 else { return LaneImage(width: 0, height: 0) }
        let outW = min(targetWidth, width)
        let scale = Double(width) / Double(outW)
        let outH = max(1, Int(Double(height) / scale))
        var image = LaneImage(width: outW, height: outH)
        let firstRow = max(0, min(outH, Int(Double(outH) * max(0, min(1, roiTop)))))
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        image.pixels.withUnsafeMutableBufferPointer { out in
            for oy in firstRow..<outH {
                let sy = min(height - 2, Int((Double(oy) + 0.5) * scale))
                let row0 = bytes + sy * bytesPerRow
                let row1 = row0 + bytesPerRow
                for ox in 0..<outW {
                    let x0 = min(width - 2, Int(Double(ox) * scale))
                    let x1 = max(x0 + 1, min(width - 1, Int(Double(ox + 1) * scale)))
                    var best: UInt8 = 0
                    var sx = x0
                    while sx < x1 {
                        let p = min(sx, width - 2) * 4
                        let b = (Int(row0[p]) + Int(row0[p + 4]) + Int(row1[p]) + Int(row1[p + 4])) >> 2
                        let g = (Int(row0[p + 1]) + Int(row0[p + 5]) + Int(row1[p + 1]) + Int(row1[p + 5])) >> 2
                        let r = (Int(row0[p + 2]) + Int(row0[p + 6]) + Int(row1[p + 2]) + Int(row1[p + 6])) >> 2
                        best = max(best, markingValue(r: r, g: g, b: b))
                        sx += 2
                    }
                    out[oy * outW + ox] = best
                }
            }
        }
        return image
    }
}

/// A lane line in normalized image coordinates (top-left origin), as a segment from the bottom of the ROI up toward
/// the horizon.
public struct LaneLine: Hashable, Codable, Sendable {
    public var bottomX: Double
    public var bottomY: Double
    public var topX: Double
    public var topY: Double

    public init(bottomX: Double, bottomY: Double, topX: Double, topY: Double) {
        self.bottomX = bottomX
        self.bottomY = bottomY
        self.topX = topX
        self.topY = topY
    }

    /// x of the (infinite) line at image row y.
    public func x(atY y: Double) -> Double {
        let dy = bottomY - topY
        guard abs(dy) > 1e-9 else { return bottomX }
        return bottomX + (topX - bottomX) * (bottomY - y) / dy
    }
}

/// Result of the lane detector for one frame (smoothed).
public struct LaneEstimate: Hashable, Codable, Sendable {
    /// Left marking of the own lane (nil when not found / confidence decayed).
    public var left: LaneLine?
    /// Right marking of the own lane.
    public var right: LaneLine?
    public var leftConfidence: Double
    public var rightConfidence: Double
    /// Lane centre at the reference row (bottom of the ROI), normalized x.
    public var laneCenterX: Double?
    /// Ego position inside the lane: −1 = on the left line, 0 = centre, +1 = on the right line (beyond ±1 = crossed).
    public var egoOffset: Double?
    /// Overall confidence 0…1 (heuristic, not a probability).
    public var confidence: Double
    /// Row (normalized y) where `laneCenterX` / `egoOffset` are evaluated.
    public var referenceY: Double
    public var timestamp: TimeInterval

    public init(left: LaneLine?, right: LaneLine?, leftConfidence: Double, rightConfidence: Double,
                laneCenterX: Double?, egoOffset: Double?, confidence: Double, referenceY: Double,
                timestamp: TimeInterval) {
        self.left = left
        self.right = right
        self.leftConfidence = leftConfidence
        self.rightConfidence = rightConfidence
        self.laneCenterX = laneCenterX
        self.egoOffset = egoOffset
        self.confidence = confidence
        self.referenceY = referenceY
        self.timestamp = timestamp
    }

    public static func empty(timestamp: TimeInterval = 0, referenceY: Double = 0.95) -> LaneEstimate {
        LaneEstimate(left: nil, right: nil, leftConfidence: 0, rightConfidence: 0, laneCenterX: nil,
                     egoOffset: nil, confidence: 0, referenceY: referenceY, timestamp: timestamp)
    }

    public func line(_ side: LaneSide) -> LaneLine? { side == .left ? left : right }
    public func confidence(_ side: LaneSide) -> Double { side == .left ? leftConfidence : rightConfidence }
}

public enum LaneSide: String, Codable, Hashable, Sendable, CaseIterable {
    case left, right
}

/// Raw per-frame line fit (before smoothing), pixel coordinates of the analysed image.
public struct LaneLineFit: Hashable, Sendable {
    /// x at the bottom ROI row and at the horizon row, pixels.
    public var bottomX: Double
    public var horizonX: Double
    /// Number of inlier pixels and distinct inlier rows.
    public var inliers: Int
    public var rows: Int
    /// Raw confidence 0…1 (row coverage, residual).
    public var confidence: Double
}

/// Detects the own-lane markings in `LaneImage`s and smooths them over time. Not thread-safe: use from one queue.
public final class LaneDetector {
    public struct Config: Sendable {
        /// Horizon row (fraction of the height); the ROI starts a little below it.
        public var horizonY: Double
        /// Extra margin below the horizon where the ROI starts (fraction of the height).
        public var roiTopMargin: Double
        /// Bottom of the ROI (excludes the bonnet / phone mount edge).
        public var roiBottom: Double
        /// Horizontal ego reference (camera centre), normalized x.
        public var egoX: Double
        /// Minimum brightness of a marking pixel (0…255).
        public var minBrightness: Int
        /// Required brightness above the ± d neighbours (ridge test).
        public var ridgeContrast: Int
        /// Required brightness above the local road brightness (box mean ±W/8).
        public var localContrast: Int
        /// Expected marking width at the bottom row, fraction of the image width (sets the ridge offset d).
        public var markingWidthAtBottom: Double
        /// Allowed line angle to the horizontal, degrees.
        public var minAngleDegrees: Double
        public var maxAngleDegrees: Double
        /// Distinct inlier rows needed (fraction of ROI rows) for a line to count.
        public var minRowCoverage: Double
        /// Row coverage at which the raw confidence saturates at 1.
        public var fullRowCoverage: Double
        /// EMA weight of a new observation (1 = no smoothing).
        public var smoothing: Double
        /// Confidence multiplier per frame without a detection.
        public var missDecay: Double
        /// Typical lane width at the reference row (normalized) used when only one line is visible; refined online.
        /// The value (and the 0.25…2.2 plausibility limits of `process`) is for a 16:9 LANDSCAPE frame; for other
        /// frame shapes they are multiplied by `LaneDetector.aspectScale` (≈ 3.16 for 9:16 portrait).
        public var defaultLaneWidth: Double
        /// Derive `minBrightness` / `ridgeContrast` / `localContrast` per frame from the pixel noise and the road
        /// brightness of the ROI (`LaneDetector.adaptiveThresholds`). The three configured values then act as the
        /// upper bound of the brightness floor and as the fallback when the ROI is too small to sample.
        public var adaptiveThresholds: Bool
        /// The detector analyses the pixel-wise maximum of the last this-many lane frames (1 = single frame).
        public var accumulateFrames: Int

        /// Frames accumulated by default. Measured on synthetic images only (both lines dashed with 25 % duty,
        /// 50 km/h at 5 Hz, no lateral motion): both lines reached confidence 0.45 on 23 of 55 single frames
        /// (mean 0.45), on 55 of 55 with the maximum of 2 frames (mean 0.73) and of 3 frames (mean 0.81).
        public static let defaultAccumulateFrames: Int = 3

        public init(horizonY: Double = EgoCorridor.default.horizonY, roiTopMargin: Double = 0.04,
                    roiBottom: Double = 0.96, egoX: Double = 0.5, minBrightness: Int = 85,
                    ridgeContrast: Int = 14, localContrast: Int = 18, markingWidthAtBottom: Double = 0.035,
                    minAngleDegrees: Double = 18, maxAngleDegrees: Double = 86, minRowCoverage: Double = 0.12,
                    fullRowCoverage: Double = 0.45, smoothing: Double = 0.4, missDecay: Double = 0.8,
                    defaultLaneWidth: Double = 0.9, adaptiveThresholds: Bool = true,
                    accumulateFrames: Int = Config.defaultAccumulateFrames) {
            self.horizonY = horizonY
            self.roiTopMargin = roiTopMargin
            self.roiBottom = roiBottom
            self.egoX = egoX
            self.minBrightness = minBrightness
            self.ridgeContrast = ridgeContrast
            self.localContrast = localContrast
            self.markingWidthAtBottom = markingWidthAtBottom
            self.minAngleDegrees = minAngleDegrees
            self.maxAngleDegrees = maxAngleDegrees
            self.minRowCoverage = minRowCoverage
            self.fullRowCoverage = fullRowCoverage
            self.smoothing = smoothing
            self.missDecay = missDecay
            self.defaultLaneWidth = defaultLaneWidth
            self.adaptiveThresholds = adaptiveThresholds
            self.accumulateFrames = max(1, accumulateFrames)
        }
    }

    private struct SideState {
        var bottomX: Double   // normalized, at roiBottom
        var topX: Double      // normalized, at the horizon
        var confidence: Double
        var outliers = 0
    }

    public var config: Config
    private var left: SideState?
    private var right: SideState?
    private var laneWidth: Double
    /// Aspect factor of the frames seen so far (1 until the first frame); a change (rotation) restarts the state.
    private var aspect: Double = 1
    /// Previous lane frames (newest last) for the pixel-wise maximum, with the horizon they were analysed with.
    private var previousImages: [(image: LaneImage, time: TimeInterval)] = []
    private var accumulationHorizon: Double = -1
    /// Vanishing point of the two RAW fits of the last processed frame (nil unless both lines were fitted).
    public private(set) var lastVanishingPoint: LaneVanishingPoint?

    /// Lane frames further apart than this are not accumulated, seconds (the lane detector runs at ≈ 5 Hz; at
    /// 0.5 s the car has moved too far for the dashes of two frames to belong to one picture).
    static let accumulateMaxGap: TimeInterval = 0.5
    /// The two lines may cross by this much (fraction of the width) at the middle row of the ROI before the weaker
    /// side is distrusted.
    static let crossingTolerance: Double = 0.05

    /// Plausible lane width at the ROI bottom for a 16:9 landscape frame, fractions of the image width. A 3.5 m lane
    /// seen from 1.2 m is (3.5 / 1.2) × (0.96 − 0.42) × H / W ≈ 0.89 there (flat-ground geometry, independent of the
    /// field of view) — and ≈ 2.8 in 9:16 portrait, which is why the limits are scaled by `aspectScale`.
    static let minLaneWidth: Double = 0.25
    static let maxLaneWidthLandscape: Double = 2.2
    /// Bottom-x jump (fraction of the width, landscape) above which a new fit is treated as a stray line.
    static let bottomJumpLandscape: Double = 0.15

    /// Lane-width factor of a frame relative to 16:9 landscape: (H / W) ÷ (9 / 16). 1 for 16:9 landscape,
    /// ≈ 3.16 for 9:16 portrait, 1.33 for 4:3 landscape. Clamped to 0.75…4.
    public static func aspectScale(width: Int, height: Int) -> Double {
        guard width > 0, height > 0 else { return 1 }
        return min(4, max(0.75, (Double(height) / Double(width)) / (9.0 / 16.0)))
    }

    public init(config: Config = Config()) {
        self.config = config
        self.laneWidth = config.defaultLaneWidth
    }

    public func reset() {
        left = nil
        right = nil
        laneWidth = config.defaultLaneWidth * aspect
        previousImages.removeAll()
        lastVanishingPoint = nil
    }

    /// Changes the horizon row and keeps the smoothed lines where they are in the image (their stored top x is the
    /// x AT the horizon row, so it is re-evaluated at the new row). Use this instead of assigning
    /// `config.horizonY` while the detector is running.
    public func setHorizon(_ horizonY: Double) {
        let old = config.horizonY
        guard horizonY.isFinite, abs(horizonY - old) > 1e-9 else { return }
        let span = config.roiBottom - old
        if abs(span) > 1e-6 {
            let factor = (config.roiBottom - horizonY) / span
            if var l = left {
                l.topX = l.bottomX + (l.topX - l.bottomX) * factor
                left = l
            }
            if var r = right {
                r.topX = r.bottomX + (r.topX - r.bottomX) * factor
                right = r
            }
        }
        config.horizonY = horizonY
    }

    /// Pixel-wise maximum of `image` and the recent frames (same size, same horizon, close in time). Dashed lines
    /// show only part of their strokes on one frame; the car's forward motion moves them along the same image line.
    /// Lateral motion smears the accumulated line, which lowers the fit confidence rather than inventing a line.
    private func accumulated(_ image: LaneImage, timestamp: TimeInterval) -> LaneImage {
        let frames = max(1, config.accumulateFrames)
        if abs(accumulationHorizon - config.horizonY) > 1e-9 {
            // Rows above the horizon are blanked by the caller; frames made for another horizon do not mix.
            previousImages.removeAll()
            accumulationHorizon = config.horizonY
        }
        previousImages.removeAll {
            $0.image.width != image.width || $0.image.height != image.height
                || timestamp - $0.time > Self.accumulateMaxGap * Double(frames - 1) || timestamp < $0.time
        }
        if let newest = previousImages.last, timestamp - newest.time > Self.accumulateMaxGap {
            previousImages.removeAll()
        }
        var result = image
        if frames > 1, !previousImages.isEmpty {
            result.pixels.withUnsafeMutableBufferPointer { out in
                for entry in previousImages {
                    entry.image.pixels.withUnsafeBufferPointer { other in
                        let n = min(out.count, other.count)
                        for i in 0..<n where other[i] > out[i] { out[i] = other[i] }
                    }
                }
            }
        }
        if frames > 1 {
            previousImages.append((image, timestamp))
            if previousImages.count > frames - 1 { previousImages.removeFirst(previousImages.count - (frames - 1)) }
        } else {
            previousImages.removeAll()
        }
        return result
    }

    /// Analyses one frame and returns the smoothed estimate.
    @discardableResult
    public func process(_ image: LaneImage, timestamp: TimeInterval) -> LaneEstimate {
        let k = Self.aspectScale(width: image.width, height: image.height)
        if abs(k - aspect) > 0.01 {
            // Frame shape changed (rotation, first frame): normalized x of the old state means something else.
            aspect = k
            left = nil
            right = nil
            laneWidth = config.defaultLaneWidth * k
        }
        let analysed = accumulated(image, timestamp: timestamp)
        let fits = Self.detectLines(in: analysed, config: config)
        let w = Double(max(1, image.width))
        lastVanishingPoint = Self.vanishingPoint(left: fits.left, right: fits.right, width: w,
                                                 height: Double(max(1, image.height)), config: config)
        left = Self.smooth(left, fit: fits.left, width: w, aspect: k, config: config)
        right = Self.smooth(right, fit: fits.right, width: w, aspect: k, config: config)
        // Plausibility: lane width at the bottom must be sensible, otherwise trust the weaker side less.
        if let l = left, let r = right {
            let width = r.bottomX - l.bottomX
            // Crossing check at the MIDDLE row of the ROI, not at the configured horizon. Two correct lines meet at
            // the REAL horizon and are crossed above it, so with a configured horizon above the real one the old
            // check (at the configured horizon) halved the weaker side on every frame (measured, synthetic:
            // configured 0.42 / true 0.48–0.60 left one side at 0.20–0.23, below the 0.45 that lane departure and
            // the roadway zone need). Lines that are crossed half-way down the road picture are implausible for
            // any horizon the estimator accepts (≤ 0.70 with the ROI bottom at 0.96).
            let span = config.roiBottom - config.horizonY
            let roiTop = config.horizonY + config.roiTopMargin
            let middle = (roiTop + config.roiBottom) / 2
            let f = abs(span) > 1e-6 ? (config.roiBottom - middle) / span : 1
            let leftTop = l.bottomX + (l.topX - l.bottomX) * f
            let rightTop = r.bottomX + (r.topX - r.bottomX) * f
            // Only the upper limit scales with the aspect (the lower one is a sanity bound for any frame shape).
            if width < Self.minLaneWidth || width > Self.maxLaneWidthLandscape * k
                || rightTop < leftTop - Self.crossingTolerance {
                if l.confidence < r.confidence { left?.confidence *= 0.5 } else { right?.confidence *= 0.5 }
            } else if l.confidence >= 0.5, r.confidence >= 0.5 {
                laneWidth += 0.1 * (width - laneWidth)
            }
        }
        if (left?.confidence ?? 0) < 0.08 { left = nil }
        if (right?.confidence ?? 0) < 0.08 { right = nil }
        return makeEstimate(timestamp: timestamp)
    }

    private func makeEstimate(timestamp: TimeInterval) -> LaneEstimate {
        let topY = min(config.roiBottom - 0.05, config.horizonY + 0.02)
        let refY = config.roiBottom
        func line(_ s: SideState?) -> LaneLine? {
            guard let s else { return nil }
            // topX is the x at horizonY; re-evaluate at the drawn top row.
            let full = LaneLine(bottomX: s.bottomX, bottomY: refY, topX: s.topX, topY: config.horizonY)
            return LaneLine(bottomX: s.bottomX, bottomY: refY, topX: full.x(atY: topY), topY: topY)
        }
        let lc = left?.confidence ?? 0, rc = right?.confidence ?? 0
        var center: Double?
        var half: Double?
        if let l = left, let r = right, r.bottomX > l.bottomX {
            center = (l.bottomX + r.bottomX) / 2
            half = (r.bottomX - l.bottomX) / 2
        } else if let l = left {
            center = l.bottomX + laneWidth / 2
            half = laneWidth / 2
        } else if let r = right {
            center = r.bottomX - laneWidth / 2
            half = laneWidth / 2
        }
        var offset: Double?
        if let c = center, let h = half, h > 0.01 {
            offset = max(-3, min(3, (config.egoX - c) / h))
        }
        let overall = (left != nil && right != nil) ? (lc + rc) / 2 : max(lc, rc) * 0.6
        return LaneEstimate(left: line(left), right: line(right), leftConfidence: lc, rightConfidence: rc,
                            laneCenterX: center, egoOffset: offset, confidence: overall, referenceY: refY,
                            timestamp: timestamp)
    }

    private static func smooth(_ state: SideState?, fit: LaneLineFit?, width: Double, aspect: Double,
                               config: Config) -> SideState? {
        guard let fit else {
            guard var s = state else { return nil }
            s.confidence *= config.missDecay
            return s
        }
        let bx = fit.bottomX / width, tx = fit.horizonX / width
        guard var s = state else {
            return SideState(bottomX: bx, topX: tx, confidence: fit.confidence * 0.6)
        }
        // The bottom x is extrapolated far outside a portrait frame, so only its threshold scales with the aspect.
        let jump = abs(bx - s.bottomX) > bottomJumpLandscape * aspect || abs(tx - s.topX) > 0.1
        if jump && s.confidence >= 0.3 && s.outliers < 2 {
            // Probably a stray line (crack, kerb, car edge): ignore it unless it persists.
            s.outliers += 1
            s.confidence *= config.missDecay
            return s
        }
        let a = jump ? 0.8 : min(1, max(0.05, config.smoothing))
        s.bottomX += a * (bx - s.bottomX)
        s.topX += a * (tx - s.topX)
        s.confidence += 0.4 * (fit.confidence - s.confidence)
        s.outliers = 0
        return s
    }

    // MARK: - Per-frame detection (stateless, testable)

    // Adaptive candidate thresholds. All numbers below were measured on SYNTHETIC 160×284 road images with uniform
    // pixel noise (scratchpad/lane/core/Tests/RoadVisCoreTests/ExpLane.swift) — real roads have structured clutter
    // (shadows, cracks, headlight glare on wet asphalt) that this noise model does not contain, and no night drive
    // was evaluated. With the fixed 85 / 14 / 18: a night road (road 30 / marking 70, or 20 / 50) gave no lines at
    // all, worn paint (95 / 108) gave none, and 20 of 200 raw side fits on EMPTY roads with noise up to ±20 were
    // false lines. With the factors below: night 0.80, worn 0.60, day unchanged at 0.80, 0 of 200 false fits.
    // Merely lowering the fixed thresholds (45 / 10 / 12) fixed night but gave 70 of 160 false fits.
    /// Ridge contrast = this × noise (median |p[x] − p[x+2]| of the ROI)…
    static let adaptiveRidgeFactor: Double = 3.0
    /// …clamped to this range.
    static let adaptiveRidgeRange: ClosedRange<Int> = 8...40
    /// Local contrast = this × noise…
    static let adaptiveLocalFactor: Double = 3.5
    static let adaptiveLocalRange: ClosedRange<Int> = 10...45
    /// Lowest brightness floor (the floor is road median + local contrast, at most `Config.minBrightness`).
    static let adaptiveMinBrightnessFloor: Int = 30
    /// Sampling of the ROI for the noise estimate: every 4th row, every 3rd pixel.
    static let adaptiveRowStep: Int = 4
    static let adaptivePixelStep: Int = 3

    /// Per-frame candidate thresholds from the ROI's pixel noise and median brightness; `config`'s own values when
    /// `config.adaptiveThresholds` is off or the ROI is too small.
    public static func adaptiveThresholds(in image: LaneImage, config: Config)
        -> (minBrightness: Int, ridgeContrast: Int, localContrast: Int) {
        let fixed = (minBrightness: config.minBrightness, ridgeContrast: config.ridgeContrast,
                     localContrast: config.localContrast)
        guard config.adaptiveThresholds else { return fixed }
        let w = image.width, h = image.height
        guard w >= 16, h >= 16 else { return fixed }
        let yTop = max(1, Int(Double(h) * min(0.95, config.horizonY + config.roiTopMargin)))
        let yBottom = min(h - 1, Int(Double(h) * config.roiBottom))
        guard yBottom - yTop >= 6 else { return fixed }
        // Histograms instead of sorting (values are 0…255).
        var diffHistogram = [Int](repeating: 0, count: 256)
        var valueHistogram = [Int](repeating: 0, count: 256)
        var count = 0
        image.pixels.withUnsafeBufferPointer { px in
            var y = yTop
            while y <= yBottom {
                let row = y * w
                var x = 0
                while x + 2 < w {
                    let a = Int(px[row + x]), b = Int(px[row + x + 2])
                    diffHistogram[abs(a - b)] += 1
                    valueHistogram[a] += 1
                    count += 1
                    x += adaptivePixelStep
                }
                y += adaptiveRowStep
            }
        }
        guard count >= 32 else { return fixed }
        func median(_ histogram: [Int]) -> Int {
            // Element at index count / 2 of the sorted samples.
            var seen = 0
            for (value, n) in histogram.enumerated() {
                seen += n
                if seen > count / 2 { return value }
            }
            return 255
        }
        let noise = Double(median(diffHistogram))
        let road = median(valueHistogram)
        let ridge = min(adaptiveRidgeRange.upperBound,
                        max(adaptiveRidgeRange.lowerBound, Int((adaptiveRidgeFactor * noise).rounded())))
        let local = min(adaptiveLocalRange.upperBound,
                        max(adaptiveLocalRange.lowerBound, Int((adaptiveLocalFactor * noise).rounded())))
        let brightness = min(config.minBrightness, max(adaptiveMinBrightnessFloor, road + local))
        return (brightness, ridge, local)
    }

    /// Intersection of the two raw fits of one frame (nil unless both exist and are not parallel).
    public static func vanishingPoint(left: LaneLineFit?, right: LaneLineFit?, width: Double, height: Double,
                                      config: Config) -> LaneVanishingPoint? {
        guard let left, let right, width > 0, height > 0 else { return nil }
        // Same rows as `detectLines`: the fits give x at the ROI bottom row and at the configured horizon row.
        let yb = Double(min(Int(height) - 1, Int(height * config.roiBottom)))
        let yh = height * config.horizonY
        let dl = left.horizonX - left.bottomX, dr = right.horizonX - right.bottomX
        let denominator = dl - dr
        guard abs(denominator) > 1e-6 else { return nil }
        let u = (right.bottomX - left.bottomX) / denominator      // fraction of (yb − yh) above the bottom row
        let x = left.bottomX + dl * u
        let y = yb - u * (yb - yh)
        guard x.isFinite, y.isFinite else { return nil }
        return LaneVanishingPoint(x: x / width, y: y / height,
                                  confidence: min(left.confidence, right.confidence))
    }

    /// Marking candidate pixels of the ROI (pixel coordinates).
    public static func candidatePoints(in image: LaneImage, config: Config) -> [(x: Int, y: Int)] {
        let w = image.width, h = image.height
        guard w >= 16, h >= 16 else { return [] }
        let yTop = max(1, Int(Double(h) * min(0.95, config.horizonY + config.roiTopMargin)))
        let yBottom = min(h - 1, Int(Double(h) * config.roiBottom))
        guard yBottom - yTop >= 6 else { return [] }
        let thresholds = adaptiveThresholds(in: image, config: config)
        let minBrightness = thresholds.minBrightness
        let ridgeContrast = thresholds.ridgeContrast
        let localContrast = thresholds.localContrast
        let window = max(4, w / 8)
        var points: [(x: Int, y: Int)] = []
        points.reserveCapacity(1024)
        var prefix = [Int](repeating: 0, count: w + 1)
        image.pixels.withUnsafeBufferPointer { px in
            for y in yTop...yBottom {
                let row = y * w
                for x in 0..<w { prefix[x + 1] = prefix[x] + Int(px[row + x]) }
                let t = Double(y - yTop) / Double(max(1, yBottom - yTop))
                // Perspective: the marking is ~0 px wide at the horizon and widest at the bottom.
                let d = max(2, Int((0.25 + 0.75 * t) * config.markingWidthAtBottom * Double(w) + 1))
                guard w > 2 * d + 2 else { continue }
                for x in d..<(w - d) {
                    let v = Int(px[row + x])
                    guard v >= minBrightness else { continue }
                    let l = Int(px[row + x - d]), r = Int(px[row + x + d])
                    guard v - max(l, r) >= ridgeContrast else { continue }
                    let a = max(0, x - window), b = min(w, x + window + 1)
                    let mean = (prefix[b] - prefix[a]) / max(1, b - a)
                    guard v - mean >= localContrast else { continue }
                    points.append((x, y))
                }
            }
        }
        return points
    }

    /// Hough + least-squares line fits for the left and the right half.
    public static func detectLines(in image: LaneImage, config: Config) -> (left: LaneLineFit?, right: LaneLineFit?) {
        let points = candidatePoints(in: image, config: config)
        guard points.count >= 6 else { return (nil, nil) }
        let w = Double(image.width), h = Double(image.height)
        let yb = Double(min(image.height - 1, Int(h * config.roiBottom)))
        let yh = h * config.horizonY
        let yTop = Double(max(1, Int(h * min(0.95, config.horizonY + config.roiTopMargin))))
        let roiRows = max(1, Int(yb - yTop) + 1)
        let egoPx = config.egoX * w
        var leftPts: [(x: Double, y: Double)] = []
        var rightPts: [(x: Double, y: Double)] = []
        for p in points {
            let pt = (x: Double(p.x), y: Double(p.y))
            if pt.x < egoPx { leftPts.append(pt) } else { rightPts.append(pt) }
        }
        let k = aspectScale(width: image.width, height: image.height)
        let leftFit = fitSide(leftPts, side: .left, width: w, yb: yb, yh: yh, roiRows: roiRows, aspect: k, config: config)
        let rightFit = fitSide(rightPts, side: .right, width: w, yb: yb, yh: yh, roiRows: roiRows, aspect: k,
                               config: config)
        return (leftFit, rightFit)
    }

    private static func fitSide(_ pts: [(x: Double, y: Double)], side: LaneSide, width w: Double, yb: Double, yh: Double,
                                roiRows: Int, aspect k: Double, config: Config) -> LaneLineFit? {
        guard pts.count >= 6 else { return nil }
        // Line model: x = xb + s · (yb − y); s = cot(angle) > 0 for the left line (it leans right going up), < 0 right.
        let sMin = 1 / tan(config.maxAngleDegrees * .pi / 180)
        let sMax = 1 / tan(config.minAngleDegrees * .pi / 180)
        let slopeBins = 48
        // Bottom-intercept range: one image width beyond the frame in 16:9 landscape, `k` widths for taller frames
        // (in portrait the own-lane lines reach the ROI bottom ≈ 0.9 widths outside the frame). Identical to the
        // previous range for k = 1; wider bins keep the accumulator bounded.
        let binWidth = max(1.0, w / 80 * max(1, k / 2))
        let xbMin = side == .left ? -w * k : 0.35 * w
        let xbMax = side == .left ? 0.65 * w : (1 + k) * w
        let xbBins = max(1, Int((xbMax - xbMin) / binWidth) + 1)
        // At the horizon the own-lane lines converge near the centre.
        let horizonMin = 0.12 * w, horizonMax = 0.88 * w
        var acc = [Int](repeating: 0, count: slopeBins * xbBins)
        var slopes = [Double](repeating: 0, count: slopeBins)
        for k in 0..<slopeBins {
            let mag = sMin + (sMax - sMin) * Double(k) / Double(slopeBins - 1)
            slopes[k] = side == .left ? mag : -mag
        }
        let dyh = yb - yh
        for p in pts {
            let up = yb - p.y
            for k in 0..<slopeBins {
                let s = slopes[k]
                let xb = p.x - s * up
                guard xb >= xbMin, xb < xbMax else { continue }
                let xh = xb + s * dyh
                guard xh >= horizonMin, xh <= horizonMax else { continue }
                acc[k * xbBins + Int((xb - xbMin) / binWidth)] += 1
            }
        }
        guard let best = acc.indices.max(by: { acc[$0] < acc[$1] }), acc[best] >= 6 else { return nil }
        var s = slopes[best / xbBins]
        var xb = xbMin + (Double(best % xbBins) + 0.5) * binWidth

        // Least-squares refit (two passes with a shrinking tolerance).
        var inliers: [(x: Double, y: Double)] = []
        for tolerance in [max(2.0, w / 60), max(1.5, w / 100)] {
            inliers = pts.filter { abs($0.x - (xb + s * (yb - $0.y))) <= tolerance }
            guard inliers.count >= 6 else { return nil }
            let n = Double(inliers.count)
            let mu = inliers.reduce(0) { $0 + (yb - $1.y) } / n
            let mx = inliers.reduce(0) { $0 + $1.x } / n
            var num = 0.0, den = 0.0
            for q in inliers {
                let u = yb - q.y - mu
                num += u * (q.x - mx)
                den += u * u
            }
            guard den > 1e-6 else { return nil }
            let fitted = num / den
            // Keep the slope constraint after the refit.
            guard (side == .left ? fitted : -fitted) >= sMin * 0.8, abs(fitted) <= sMax * 1.2 else { return nil }
            s = fitted
            xb = mx - s * mu
        }
        let rows = Set(inliers.map { Int($0.y) }).count
        let coverage = Double(rows) / Double(roiRows)
        guard coverage >= config.minRowCoverage else { return nil }
        // Residual (pixels) penalty.
        let residual = inliers.reduce(0) { $0 + abs($1.x - (xb + s * (yb - $1.y))) } / Double(inliers.count)
        let residualFactor = max(0.3, 1 - residual / max(2, w / 40))
        let confidence = min(1, coverage / config.fullRowCoverage) * residualFactor
        return LaneLineFit(bottomX: xb, horizonX: xb + s * (yb - yh), inliers: inliers.count, rows: rows,
                           confidence: confidence)
    }
}

/// Lane-departure warning logic: a departure is reported when the ego reference point (bottom centre of the frame)
/// comes within the margin of a confident lane line (|egoOffset| ≥ `triggerOffset`) for at least `minDuration`
/// seconds while driving at least `minSpeedKmh`, at most once per `cooldown` and re-armed only after returning toward
/// the lane centre. Heuristic: no turn-signal input, so a deliberate lane change is also reported once.
public struct LaneDepartureDetector: Sendable {
    public struct Config: Sendable {
        public var minSpeedKmh: Double
        public var minDuration: TimeInterval
        /// |egoOffset| at which the car is considered to touch the marking (the camera sits at the car's centre, the
        /// wheels ≈ 0.9 m to the side of a ≈ 1.75 m half lane → ≈ 0.55–0.65).
        public var triggerOffset: Double
        /// Back below this |offset| re-arms the warning.
        public var rearmOffset: Double
        /// Minimum confidence of the line on the departure side.
        public var minLineConfidence: Double
        public var cooldown: TimeInterval
        /// Estimates older than this are ignored.
        public var maxAge: TimeInterval

        public init(minSpeedKmh: Double = 40, minDuration: TimeInterval = 0.4, triggerOffset: Double = 0.6,
                    rearmOffset: Double = 0.4, minLineConfidence: Double = 0.45, cooldown: TimeInterval = 5,
                    maxAge: TimeInterval = 0.6) {
            self.minSpeedKmh = minSpeedKmh
            self.minDuration = minDuration
            self.triggerOffset = triggerOffset
            self.rearmOffset = rearmOffset
            self.minLineConfidence = minLineConfidence
            self.cooldown = cooldown
            self.maxAge = maxAge
        }
    }

    public var config: Config
    private var candidateSide: LaneSide?
    private var candidateSince: TimeInterval?
    private var armed = true
    private var lastWarning: TimeInterval = -.infinity
    /// Side the car is currently drifting over (for the overlay), nil when inside the lane.
    public private(set) var activeSide: LaneSide?

    public init(config: Config = Config()) {
        self.config = config
    }

    public mutating func reset() {
        candidateSide = nil
        candidateSince = nil
        armed = true
        activeSide = nil
    }

    /// Feeds one estimate; returns the side when a NEW departure warning should be given.
    public mutating func update(_ estimate: LaneEstimate?, speedKmh: Double?, timestamp: TimeInterval) -> LaneSide? {
        guard let estimate, timestamp - estimate.timestamp <= config.maxAge, let offset = estimate.egoOffset,
              (speedKmh ?? 0) >= config.minSpeedKmh else {
            candidateSide = nil
            candidateSince = nil
            activeSide = nil
            return nil
        }
        let side: LaneSide = offset < 0 ? .left : .right
        let confident = estimate.line(side) != nil && estimate.confidence(side) >= config.minLineConfidence
        if abs(offset) < config.rearmOffset { armed = true }
        guard confident, abs(offset) >= config.triggerOffset else {
            candidateSide = nil
            candidateSince = nil
            activeSide = nil
            return nil
        }
        if candidateSide != side {
            candidateSide = side
            candidateSince = timestamp
        }
        guard let since = candidateSince, timestamp - since >= config.minDuration else { return nil }
        activeSide = side
        guard armed, timestamp - lastWarning >= config.cooldown else { return nil }
        armed = false
        lastWarning = timestamp
        return side
    }
}
