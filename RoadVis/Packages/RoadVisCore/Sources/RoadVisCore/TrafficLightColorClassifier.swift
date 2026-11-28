import Foundation

public struct RGBPixel: Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }
}

/// Heuristic colour classification of a traffic-light crop ("v2": relative brightness + red halo + position prior).
/// Faithful port of the Python prototype `tl/code/v5.py` (function `v3`), which was evaluated in this project on a
/// sample of the public LISA Traffic Light dataset (US footage, CC BY-NC-SA, evaluation only; 3550 annotated lights):
/// on ground-truth boxes by day the share of correct answers went 76.1 % → 91.7 % (the old classifier mostly answered
/// "unknown": 23.1 % → ≈ 7.9 %; wrong colour 0.8 % → 0.4 %), at night 98.2 % → 99.0 %; on YOLO11n boxes 83.0 % → 95.7 %
/// (wrong 0.1 % → 0.4 %). The classifier was designed while looking at failures from that same sample, so these
/// numbers are optimistic to an unknown degree; nothing was measured on Uzbek roads or on a phone.
///
/// Algorithm, on a grid of ≈ 24 samples along the short side of the box:
///  1. candidate pixel = hue red / orange / yellow (330…360, 0…70) or green (90…200), S ≥ 0.40, V ≥ 0.30;
///  2. `vref` = 90th percentile of V over the candidates; lit = candidate with V ≥ max(0.30, 0.5 · vref)
///     (relative brightness: a dim lamp in daylight still counts, the old absolute V ≥ 0.55 rejected it);
///  3. every lit pixel weighs S·V; masses R (hue < 10 or ≥ 330), A (10…40), Y (40…70), G (90…200);
///  4. warm = R + A + Y: if R ≥ 0.3 · (A + Y) all warm mass is RED (red halo around a bloomed yellow / white core);
///     else if the box is vertical (h ≥ 1.6 w), the weighted centroid of the warm pixels is in the top 42 % and
///     R + A ≥ 0.3 · warm → RED (lamp in the top section; red + amber phase reads red); else A joins YELLOW;
///  5. the winner needs ≥ 60 % of the mass, ≥ 3 lit pixels and a lit share ≥ 0.4 %;
///  6. guards: for GREEN only, > 60 % of its mass in the outer 15 % border ring of the box (grid ≥ 8 × 6) → unknown
///     (sky / foliage beside the housing); for any colour the weighted mean V of the winning pixels must exceed the
///     25th percentile of V in the crop by ≥ 0.10 (a lamp is clearly brighter than its dark housing).
/// Rejected by measurement (do not add): a ring guard for red / yellow, a hard position prior, a "lamp compactness"
/// check. Arrows, LED matrices and horizontal housings (no position prior) remain weaker; the result is an estimate
/// and is voted over time by the tracker.
public enum TrafficLightColorClassifier {
    /// Candidate pixel: minimum saturation / value.
    static let minSaturation = 0.40
    static let minValue = 0.30
    /// Lit = candidate at least this share of the 90th-percentile candidate brightness.
    static let relativeValue = 0.5
    static let referencePercentile = 0.90
    /// Hue bounds, degrees.
    static let amberLow = 10.0
    static let amberHigh = 40.0
    static let warmHigh = 70.0
    static let redWrap = 330.0
    static let greenLow = 90.0
    static let greenHigh = 200.0
    /// Red halo: red mass ≥ this × (amber + yellow mass) → the whole warm mass is red.
    static let haloRatio = 0.3
    /// Position prior for vertical housings: warm centroid above this share of the box height → red.
    static let topSectionY = 0.42
    /// The box counts as a vertical housing when height ≥ this × width.
    static let verticalAspect = 1.6
    /// Winner share of the total colour mass.
    static let minWinnerShare = 0.6
    /// Minimum lit pixels and lit share of the sampled pixels (was 1.5 %, which rejected arrows / small lamps).
    static let minLitPixels = 3
    static let minLitShare = 0.004
    /// Green border-ring guard.
    static let ringWidth = 0.15
    static let maxRingShare = 0.6
    static let ringMinRows = 8
    static let ringMinColumns = 6
    /// Lamp-vs-housing contrast: weighted mean V of the winner minus the 25th percentile of V.
    static let minContrast = 0.10
    static let housingPercentile = 0.25
    /// Samples along the short side of the box.
    public static let samplesAlongShortSide = 24

    /// Sampling step used for a box of the given pixel size (≈ 24 samples along the short side).
    public static func samplingStep(rectWidth: Int, rectHeight: Int) -> Int {
        max(1, min(rectWidth, rectHeight) / samplesAlongShortSide)
    }

    /// Classifies a flat list of pixels (no geometry: no position prior and no border-ring guard).
    public static func classify(pixels: [RGBPixel]) -> TrafficLightColor {
        classify(pixels: pixels, width: pixels.count, height: pixels.isEmpty ? 0 : 1, vertical: false)
    }

    /// Classifies a row-major grid of `width × height` sampled pixels of a traffic-light box.
    /// - Parameter vertical: whether the BOX (in image pixels) is a vertical housing; nil → from the grid shape.
    public static func classify(pixels: [RGBPixel], width: Int, height: Int, vertical: Bool? = nil) -> TrafficLightColor {
        guard width > 0, height > 0, pixels.count >= width * height else { return .unknown }
        var grid = Grid(width: width, height: height)
        for p in pixels.prefix(width * height) { grid.append(r: p.r, g: p.g, b: p.b) }
        return decide(grid, vertical: vertical ?? (Double(height) >= verticalAspect * Double(width)))
    }

    /// Samples a BGRA buffer (kCVPixelFormatType_32BGRA) inside the given pixel rectangle.
    /// - Parameter step: sampling step in pixels; nil → `samplingStep(rectWidth:rectHeight:)`.
    public static func classifyBGRA(base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int,
                                    rectX: Int, rectY: Int, rectWidth: Int, rectHeight: Int,
                                    step: Int? = nil) -> TrafficLightColor {
        let x0 = max(0, min(width - 1, rectX))
        let y0 = max(0, min(height - 1, rectY))
        let x1 = max(x0, min(width, rectX + rectWidth))
        let y1 = max(y0, min(height, rectY + rectHeight))
        guard x1 > x0, y1 > y0, bytesPerRow >= width * 4 else { return .unknown }
        let s = max(1, step ?? samplingStep(rectWidth: x1 - x0, rectHeight: y1 - y0))
        let columns = (x1 - x0 + s - 1) / s
        let rows = (y1 - y0 + s - 1) / s
        var grid = Grid(width: columns, height: rows)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var y = y0
        while y < y1 {
            let row = bytes + y * bytesPerRow
            var x = x0
            while x < x1 {
                let px = row + x * 4
                grid.append(r: px[2], g: px[1], b: px[0])
                x += s
            }
            y += s
        }
        return decide(grid, vertical: Double(y1 - y0) >= verticalAspect * Double(x1 - x0))
    }

    // MARK: - Implementation

    /// Hue (degrees 0..<360), saturation and value of the sampled pixels, row-major.
    struct Grid {
        let width: Int
        let height: Int
        var hue: [Double] = []
        var saturation: [Double] = []
        var value: [Double] = []
        /// Histogram of the 8-bit value channel (V = max(r, g, b) / 255 takes 256 levels → exact percentiles).
        var valueLevels: [UInt8] = []

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
            let n = max(0, width * height)
            hue.reserveCapacity(n)
            saturation.reserveCapacity(n)
            value.reserveCapacity(n)
            valueLevels.reserveCapacity(n)
        }

        mutating func append(r: UInt8, g: UInt8, b: UInt8) {
            let rd = Double(r) / 255, gd = Double(g) / 255, bd = Double(b) / 255
            let maxC = max(rd, gd, bd), minC = min(rd, gd, bd)
            let delta = maxC - minC
            var h = 0.0
            if delta > 0 {
                if maxC == rd {
                    h = 60 * ((gd - bd) / delta).truncatingRemainder(dividingBy: 6)
                } else if maxC == gd {
                    h = 60 * ((bd - rd) / delta + 2)
                } else {
                    h = 60 * ((rd - gd) / delta + 4)
                }
                if h < 0 { h += 360 }
            }
            hue.append(h)
            saturation.append(maxC > 0 ? delta / maxC : 0)
            value.append(maxC)
            valueLevels.append(max(r, g, b))
        }
    }

    /// Linear-interpolated percentile (same definition as `numpy.percentile`) from a 256-level histogram.
    static func percentile(_ histogram: [Int], count: Int, fraction: Double) -> Double {
        guard count > 0 else { return 0 }
        let position = Double(count - 1) * fraction
        let lowIndex = Int(position.rounded(.down))
        let highIndex = min(count - 1, lowIndex + 1)
        let weight = position - Double(lowIndex)
        var low = 0.0, high = 0.0
        var seen = 0
        var haveLow = false
        for level in 0..<256 {
            let c = histogram[level]
            guard c > 0 else { continue }
            seen += c
            if !haveLow, seen > lowIndex {
                low = Double(level) / 255
                haveLow = true
            }
            if seen > highIndex {
                high = Double(level) / 255
                break
            }
        }
        return low + (high - low) * weight
    }

    private enum Band { case red, amber, yellow, green, none }

    private static func band(_ hue: Double) -> Band {
        if hue < amberLow || hue >= redWrap { return .red }
        if hue < amberHigh { return .amber }
        if hue < warmHigh { return .yellow }
        if hue >= greenLow && hue < greenHigh { return .green }
        return .none
    }

    static func decide(_ grid: Grid, vertical: Bool) -> TrafficLightColor {
        let n = grid.hue.count
        guard n > 0, grid.width > 0, grid.height > 0, n == grid.width * grid.height else { return .unknown }

        // 1. Candidates and their brightness histogram.
        var candidate = [Bool](repeating: false, count: n)
        var candidateHistogram = [Int](repeating: 0, count: 256)
        var allHistogram = [Int](repeating: 0, count: 256)
        var candidateCount = 0
        for i in 0..<n {
            allHistogram[Int(grid.valueLevels[i])] += 1
            guard band(grid.hue[i]) != .none, grid.saturation[i] >= minSaturation, grid.value[i] >= minValue else {
                continue
            }
            candidate[i] = true
            candidateCount += 1
            candidateHistogram[Int(grid.valueLevels[i])] += 1
        }
        guard candidateCount >= minLitPixels else { return .unknown }

        // 2. Lit pixels relative to the brightest candidates.
        let reference = percentile(candidateHistogram, count: candidateCount, fraction: referencePercentile)
        let litThreshold = max(minValue, relativeValue * reference)

        // 3. Colour masses (weight S·V) and the warm centroid.
        var weight = [Double](repeating: 0, count: n)
        var red = 0.0, amber = 0.0, yellow = 0.0, green = 0.0
        var warmY = 0.0
        var litCount = 0
        for row in 0..<grid.height {
            let rowCentre = (Double(row) + 0.5) / Double(grid.height)
            for column in 0..<grid.width {
                let i = row * grid.width + column
                guard candidate[i], grid.value[i] >= litThreshold else { continue }
                let w = grid.saturation[i] * grid.value[i]
                weight[i] = w
                litCount += 1
                switch band(grid.hue[i]) {
                case .red:
                    red += w
                    warmY += w * rowCentre
                case .amber:
                    amber += w
                    warmY += w * rowCentre
                case .yellow:
                    yellow += w
                    warmY += w * rowCentre
                case .green:
                    green += w
                case .none:
                    break
                }
            }
        }

        // 4. Red halo / position prior.
        let warm = red + amber + yellow
        var redScore = red, yellowScore = yellow
        if warm > 0 {
            let centroid = warmY / warm
            if red >= haloRatio * (amber + yellow) {
                redScore = warm
                yellowScore = 0
            } else if vertical, centroid < topSectionY, red + amber >= 0.3 * warm {
                redScore = warm
                yellowScore = 0
            } else {
                yellowScore = yellow + amber
            }
        }
        let total = redScore + yellowScore + green
        // Ties resolve red → yellow → green, as in the prototype.
        var best = TrafficLightColor.red
        var bestScore = redScore
        if yellowScore > bestScore {
            best = .yellow
            bestScore = yellowScore
        }
        if green > bestScore {
            best = .green
            bestScore = green
        }

        // 6. Guards on the winning colour's pixels.
        if total > 0 {
            let rows = grid.height, columns = grid.width
            let ringRows = max(1, Int((Double(rows) * ringWidth).rounded(.toNearestOrEven)))
            let ringColumns = max(1, Int((Double(columns) * ringWidth).rounded(.toNearestOrEven)))
            var winnerMass = 0.0, innerMass = 0.0, winnerValue = 0.0
            for row in 0..<rows {
                for column in 0..<columns {
                    let i = row * columns + column
                    let w = weight[i]
                    guard w > 0 else { continue }
                    let b = band(grid.hue[i])
                    let counts: Bool
                    switch best {
                    case .red: counts = b == .red || b == .amber || b == .yellow
                    case .yellow: counts = b == .amber || b == .yellow
                    default: counts = b == .green
                    }
                    guard counts else { continue }
                    winnerMass += w
                    winnerValue += w * grid.value[i]
                    if row >= ringRows, row < rows - ringRows, column >= ringColumns, column < columns - ringColumns {
                        innerMass += w
                    }
                }
            }
            let mass = max(winnerMass, 1e-9)
            if best == .green, rows >= ringMinRows, columns >= ringMinColumns, 1 - innerMass / mass > maxRingShare {
                return .unknown        // the colour sits on the box border: sky / foliage / neighbour, not the lamp
            }
            let housing = percentile(allHistogram, count: n, fraction: housingPercentile)
            if winnerValue / mass - housing < minContrast {
                return .unknown        // the lamp must be clearly brighter than the (dark) housing
            }
        }

        // 5. Enough lit pixels and a clear winner.
        guard litCount >= minLitPixels, Double(litCount) / Double(n) >= minLitShare, total > 0,
              bestScore / total >= minWinnerShare else { return .unknown }
        return best
    }
}
