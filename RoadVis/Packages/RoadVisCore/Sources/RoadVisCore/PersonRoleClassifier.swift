import Foundation

// On-device HEURISTIC distinction of a traffic police officer (YHXX xodimi) and a road worker (yo‘l ishchisi) among the
// detector's "person" boxes. The COCO detector has no such classes, so the role is guessed from the colour of the
// high-visibility vest on the torso:
//  - fluorescent yellow-green / lime vest (hue 55–100°, S ≥ 0.30, V ≥ 0.40) over a dark / navy lower body and without
//    orange → traffic officer (the current YPX jacket seen on a Sept 2026 news photo: navy with a fluorescent
//    yellow-green yoke; ONE photo — officer vs worker stays a guess);
//  - fluorescent orange / red-orange vest (hue 3–38°, S ≥ 0.70, V ≥ 0.50) → road worker
//    (a lime vest without a dark lower body is also treated as a road worker);
//  - otherwise → pedestrian.
// Measured in this project on YOLO11n person crops of Roboflow-100 construction-safety (CC BY 4.0; construction-site
// photos, NOT road scenes; 1171 vest / 828 no-vest): the previous gates (lime S ≥ 0.5, V ≥ 0.6; orange 10–35°,
// S ≥ 0.6; share ≥ 0.12) found 52.4 % of vest wearers with 6.2 % false positives on the held-out part; the gates
// below, chosen on the train part, 62.1 % at the same 6.2 % — per single frame, before the vote. Misses of the old
// gates were ordinary lime vests in shade. A learned vest classifier reached 87.7 % at that false-positive rate in a
// 4-epoch experiment but was not shipped (under-trained snapshot, wrong domain, no device timing).
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
    /// Dark or navy pixels / sampled pixels of the lower body (rows 62–95 % of the box); nil when not measured
    /// (then the whole-box `darkShare` decides officer vs worker, as before).
    public var lowerDarkShare: Double?

    public init(limeShare: Double, orangeShare: Double, darkShare: Double, torsoPixels: Int,
                lowerDarkShare: Double? = nil) {
        self.limeShare = limeShare
        self.orangeShare = orangeShare
        self.darkShare = darkShare
        self.torsoPixels = torsoPixels
        self.lowerDarkShare = lowerDarkShare
    }
}

public enum PersonRoleClassifier {
    /// Torso band of the box: rows from 22 % to 62 % of the box height…
    public static let torsoTop = 0.22
    public static let torsoBottom = 0.62
    /// …and the central 60 % of its width.
    public static let torsoWidth = 0.6
    /// Minimum vest share of the torso pixels (0.12 before; raised together with the wider colour gates).
    public static let minVestShare = 0.15
    /// Lower body band: rows from 62 % to 95 % of the box height.
    public static let lowerBodyBottom = 0.95
    /// Officer: at least this share of the lower body is dark / navy (uniform trousers)…
    public static let minLowerDarkShare = 0.5
    /// …and (almost) no orange on the torso.
    public static let maxOfficerOrangeShare = 0.05
    /// Hi-vis colour gates (hue in degrees), see the measurement in the file header.
    static let limeHue: ClosedRange<Double> = 55...100
    static let limeMinSaturation = 0.30
    static let limeMinValue = 0.40
    static let orangeHue: ClosedRange<Double> = 3...38
    static let orangeMinSaturation = 0.70
    static let orangeMinValue = 0.50
    /// Navy (uniform) pixel: hue 200–260° and V below this (brighter blue is ordinary clothing).
    static let navyHue: ClosedRange<Double> = 200...260
    static let navyMaxValue = 0.45
    /// Minimum share of dark pixels in the box for an officer (dark uniform).
    public static let minDarkShare = 0.08
    /// Minimum number of sampled torso pixels for a decision.
    public static let minTorsoPixels = 12
    /// Boxes smaller than this (pixels of height) are not classified (too far, colours unreliable).
    public static let minBoxHeightPixels = 40

    enum PixelClass { case lime, orange, dark, navy, other }

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
        if limeHue.contains(hue), saturation >= limeMinSaturation, value >= limeMinValue { return .lime }
        if orangeHue.contains(hue), saturation >= orangeMinSaturation, value >= orangeMinValue { return .orange }
        if navyHue.contains(hue), value < navyMaxValue { return .navy }
        return .other
    }

    /// Decision from the measured shares.
    public static func classify(_ sample: PersonRoleSample) -> PersonRole {
        guard sample.torsoPixels >= minTorsoPixels else { return .pedestrian }
        let lime = sample.limeShare, orange = sample.orangeShare
        guard max(lime, orange) >= minVestShare else { return .pedestrian }
        if lime >= orange {
            if let lower = sample.lowerDarkShare {
                // Structure rule: lime top over dark / navy trousers and no orange → officer; else worker.
                return lower >= minLowerDarkShare && orange < maxOfficerOrangeShare ? .trafficOfficer : .roadWorker
            }
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
        let lowerY1 = rectY + Int(Double(rectHeight) * lowerBodyBottom)
        var lime = 0, orange = 0, dark = 0, torsoCount = 0, total = 0, lowerCount = 0, lowerDark = 0
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var y = y0
        while y < y1 {
            let row = bytes + y * bytesPerRow
            let inTorsoRow = y >= torsoY0 && y < torsoY1
            let inLowerRow = y >= torsoY1 && y < lowerY1
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
                if inLowerRow, x >= torsoX0, x < torsoX1 {
                    lowerCount += 1
                    if cls == .dark || cls == .navy { lowerDark += 1 }
                }
                x += s
            }
            y += s
        }
        guard total > 0 else { return nil }
        let t = Double(max(1, torsoCount))
        return PersonRoleSample(limeShare: Double(lime) / t, orangeShare: Double(orange) / t,
                                darkShare: Double(dark) / Double(total), torsoPixels: torsoCount,
                                lowerDarkShare: lowerCount > 0 ? Double(lowerDark) / Double(lowerCount) : nil)
    }

    public static func classifyBGRA(base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int,
                                    rectX: Int, rectY: Int, rectWidth: Int, rectHeight: Int,
                                    step: Int = 2) -> PersonRole? {
        sampleBGRA(base: base, width: width, height: height, bytesPerRow: bytesPerRow, rectX: rectX, rectY: rectY,
                   rectWidth: rectWidth, rectHeight: rectHeight, step: step).map(classify)
    }

    // MARK: - Voting

    /// Observations kept per track (≈ 1 s at 15 fps; 9 with a strict majority before).
    public static let voteWindow = 15
    /// Observations needed before a role is reported.
    public static let minVotes = 5
    /// Staff (officer + worker together) is reported from this share of the window…
    public static let staffEnterShare = 0.6
    /// …and kept until its share drops below this (hysteresis, no flicker). Reasoning, not measured on video; with a
    /// per-frame false-positive rate of 6–7 % a 60 % vote makes a false staff label unlikely.
    public static let staffKeepShare = 0.3

    /// Role of a track from its recent per-frame observations: nil / `previous` with fewer than `minObservations`.
    /// Officer and worker votes are pooled ("wears hi-vis"): staff is entered at `staffEnterShare` and kept down to
    /// `staffKeepShare`; the more frequent of the two names the role (ties keep the previous one).
    public static func majority(_ history: [PersonRole], previous: PersonRole? = nil,
                                minObservations: Int = minVotes) -> PersonRole? {
        guard history.count >= max(1, minObservations) else { return previous }
        var officer = 0, worker = 0
        for role in history {
            if role == .trafficOfficer { officer += 1 } else if role == .roadWorker { worker += 1 }
        }
        let share = Double(officer + worker) / Double(history.count)
        let wasStaff = previous?.isRoadStaff == true
        guard share >= (wasStaff ? staffKeepShare : staffEnterShare) else { return .pedestrian }
        if officer == worker, let previous, previous.isRoadStaff { return previous }
        return officer >= worker ? .trafficOfficer : .roadWorker
    }
}
