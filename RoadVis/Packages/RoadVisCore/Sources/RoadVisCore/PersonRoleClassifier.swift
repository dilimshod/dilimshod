import Foundation

// On-device HEURISTIC distinction of a traffic police officer (YHXX xodimi) and a road worker (yo‘l ishchisi) among the
// detector's "person" boxes. The COCO detector has no such classes, so the role is guessed from the colour of the
// high-visibility vest on the torso:
//  - fluorescent yellow-green / lime vest (hue ≈ 55–95°, S ≥ 0.5, V ≥ 0.6) over a dark uniform → traffic officer
//    (Uzbekistan's YHXX officers wear lime / yellow reflective vests over a dark uniform);
//  - fluorescent orange / red-orange vest (hue ≈ 10–35°, S ≥ 0.6, V ≥ 0.55) → road worker
//    (a lime vest without any dark clothing is also treated as a road worker);
//  - otherwise → pedestrian.
// A yellow jacket, an orange T-shirt, a reflective school vest or a cyclist's jersey fool it; night, back light and
// motion blur weaken it. The tracker therefore votes over several frames, and the app marks the role as "≈" (colour
// heuristic). Reliable results need a trained model (a labelled dataset of YHXX officers and road workers, e.g. in
// Roboflow, added as extra YOLO classes).

/// Role of a detected person (colour heuristic, see `PersonRoleClassifier`).
public enum PersonRole: String, Codable, Hashable, Sendable, CaseIterable {
    case pedestrian
    /// Traffic police officer (YHXX xodimi / сотрудник ГАИ) — lime / yellow hi-vis vest over a dark uniform.
    case trafficOfficer
    /// Road worker (yo‘l ishchisi / дорожный рабочий) — orange hi-vis vest.
    case roadWorker

    /// Officers and workers are on the road deliberately: they are never reported as "yield to the pedestrian".
    public var isRoadStaff: Bool { self != .pedestrian }
}

/// Colour shares measured in a person box.
public struct PersonRoleSample: Hashable, Sendable {
    /// Lime / yellow-green vest pixels / sampled torso pixels.
    public var limeShare: Double
    /// Orange vest pixels / sampled torso pixels.
    public var orangeShare: Double
    /// Dark pixels (uniform) / sampled pixels of the whole box.
    public var darkShare: Double
    public var torsoPixels: Int

    public init(limeShare: Double, orangeShare: Double, darkShare: Double, torsoPixels: Int) {
        self.limeShare = limeShare
        self.orangeShare = orangeShare
        self.darkShare = darkShare
        self.torsoPixels = torsoPixels
    }
}

public enum PersonRoleClassifier {
    /// Torso band of the box: rows from 22 % to 62 % of the box height…
    public static let torsoTop = 0.22
    public static let torsoBottom = 0.62
    /// …and the central 60 % of its width.
    public static let torsoWidth = 0.6
    /// Minimum vest share of the torso pixels.
    public static let minVestShare = 0.12
    /// Minimum share of dark pixels in the box for an officer (dark uniform).
    public static let minDarkShare = 0.08
    /// Minimum number of sampled torso pixels for a decision.
    public static let minTorsoPixels = 12
    /// Boxes smaller than this (pixels of height) are not classified (too far, colours unreliable).
    public static let minBoxHeightPixels = 40

    enum PixelClass { case lime, orange, dark, other }

    /// Colour class of one pixel.
    static func pixelClass(_ p: RGBPixel) -> PixelClass {
        let r = Double(p.r) / 255, g = Double(p.g) / 255, b = Double(p.b) / 255
        let maxC = max(r, g, b), minC = min(r, g, b)
        let delta = maxC - minC
        let value = maxC
        if value < 0.3 { return .dark }
        let saturation = maxC > 0 ? delta / maxC : 0
        guard delta > 0 else { return .other }
        var hue: Double
        if maxC == r {
            hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxC == g {
            hue = 60 * ((b - r) / delta + 2)
        } else {
            hue = 60 * ((r - g) / delta + 4)
        }
        if hue < 0 { hue += 360 }
        if hue >= 55, hue <= 95, saturation >= 0.5, value >= 0.6 { return .lime }
        if hue >= 10, hue <= 35, saturation >= 0.6, value >= 0.55 { return .orange }
        return .other
    }

    /// Decision from the measured shares.
    public static func classify(_ sample: PersonRoleSample) -> PersonRole {
        guard sample.torsoPixels >= minTorsoPixels else { return .pedestrian }
        let lime = sample.limeShare, orange = sample.orangeShare
        guard max(lime, orange) >= minVestShare else { return .pedestrian }
        if lime >= orange {
            return sample.darkShare >= minDarkShare ? .trafficOfficer : .roadWorker
        }
        return .roadWorker
    }

    /// Measures the shares from the pixels of the torso band and of the whole box.
    public static func sample(torso: [RGBPixel], box: [RGBPixel]) -> PersonRoleSample {
        var lime = 0, orange = 0, dark = 0
        for p in torso {
            switch pixelClass(p) {
            case .lime: lime += 1
            case .orange: orange += 1
            default: break
            }
        }
        for p in box where pixelClass(p) == .dark { dark += 1 }
        let t = Double(max(1, torso.count)), b = Double(max(1, box.count))
        return PersonRoleSample(limeShare: Double(lime) / t, orangeShare: Double(orange) / t,
                                darkShare: box.isEmpty ? 0 : Double(dark) / b, torsoPixels: torso.count)
    }

    public static func classify(torso: [RGBPixel], box: [RGBPixel]) -> PersonRole {
        classify(sample(torso: torso, box: box))
    }

    /// Samples a BGRA buffer (kCVPixelFormatType_32BGRA) inside the person box given in pixels.
    /// Returns nil when the box is too small to judge.
    public static func sampleBGRA(base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int,
                                  rectX: Int, rectY: Int, rectWidth: Int, rectHeight: Int,
                                  step: Int = 2) -> PersonRoleSample? {
        let x0 = max(0, min(width - 1, rectX))
        let y0 = max(0, min(height - 1, rectY))
        let x1 = max(x0, min(width, rectX + rectWidth))
        let y1 = max(y0, min(height, rectY + rectHeight))
        guard x1 > x0, y1 > y0, bytesPerRow >= width * 4, rectHeight >= minBoxHeightPixels else { return nil }
        let s = max(1, step)
        let torsoY0 = rectY + Int(Double(rectHeight) * torsoTop)
        let torsoY1 = rectY + Int(Double(rectHeight) * torsoBottom)
        let margin = Double(rectWidth) * (1 - torsoWidth) / 2
        let torsoX0 = rectX + Int(margin)
        let torsoX1 = rectX + rectWidth - Int(margin)
        var lime = 0, orange = 0, dark = 0, torsoCount = 0, total = 0
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var y = y0
        while y < y1 {
            let row = bytes + y * bytesPerRow
            let inTorsoRow = y >= torsoY0 && y < torsoY1
            var x = x0
            while x < x1 {
                let px = row + x * 4
                let cls = pixelClass(RGBPixel(r: px[2], g: px[1], b: px[0]))
                if cls == .dark { dark += 1 }
                total += 1
                if inTorsoRow, x >= torsoX0, x < torsoX1 {
                    torsoCount += 1
                    if cls == .lime { lime += 1 } else if cls == .orange { orange += 1 }
                }
                x += s
            }
            y += s
        }
        guard total > 0 else { return nil }
        let t = Double(max(1, torsoCount))
        return PersonRoleSample(limeShare: Double(lime) / t, orangeShare: Double(orange) / t,
                                darkShare: Double(dark) / Double(total), torsoPixels: torsoCount)
    }

    public static func classifyBGRA(base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int,
                                    rectX: Int, rectY: Int, rectWidth: Int, rectHeight: Int,
                                    step: Int = 2) -> PersonRole? {
        sampleBGRA(base: base, width: width, height: height, bytesPerRow: bytesPerRow, rectX: rectX, rectY: rectY,
                   rectWidth: rectWidth, rectHeight: rectHeight, step: step).map(classify)
    }

    // MARK: - Voting

    /// Observations kept per track.
    public static let voteWindow = 9
    /// Observations needed before a role is reported.
    public static let minVotes = 5

    /// Role of a track from its recent per-frame observations: nil with fewer than `minObservations`; a role with a
    /// strict majority wins; without one the previous role is kept (no flicker), or `.pedestrian` when there is none.
    public static func majority(_ history: [PersonRole], previous: PersonRole? = nil,
                                minObservations: Int = minVotes) -> PersonRole? {
        guard history.count >= max(1, minObservations) else { return previous }
        var counts: [PersonRole: Int] = [:]
        for role in history { counts[role, default: 0] += 1 }
        if let best = counts.max(by: { $0.value < $1.value }), best.value * 2 > history.count {
            return best.key
        }
        return previous ?? .pedestrian
    }
}
