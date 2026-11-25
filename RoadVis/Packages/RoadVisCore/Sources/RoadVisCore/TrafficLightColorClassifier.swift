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

/// Heuristic colour classification of a traffic-light crop: votes over bright, saturated pixels by hue.
/// Works for standard round red/yellow/green signals; arrows, LED matrices and back-lit glare can fool it,
/// so the result is shown as an estimate and smoothed over several frames by the tracker.
public enum TrafficLightColorClassifier {
    /// Minimum share of "lit" pixels (of all sampled pixels) needed for a decision.
    static let minLitShare = 0.015
    /// The winning colour must have at least this share of the lit pixels.
    static let minWinnerShare = 0.5

    public static func classify(pixels: [RGBPixel]) -> TrafficLightColor {
        guard !pixels.isEmpty else { return .unknown }
        var red = 0, yellow = 0, green = 0
        for p in pixels {
            switch hueClass(p) {
            case .red: red += 1
            case .yellow: yellow += 1
            case .green: green += 1
            case .unknown: break
            }
        }
        return decide(red: red, yellow: yellow, green: green, total: pixels.count)
    }

    /// Samples a BGRA buffer (kCVPixelFormatType_32BGRA) inside the given pixel rectangle.
    public static func classifyBGRA(base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int,
                                    rectX: Int, rectY: Int, rectWidth: Int, rectHeight: Int,
                                    step: Int = 2) -> TrafficLightColor {
        let x0 = max(0, min(width - 1, rectX))
        let y0 = max(0, min(height - 1, rectY))
        let x1 = max(x0, min(width, rectX + rectWidth))
        let y1 = max(y0, min(height, rectY + rectHeight))
        guard x1 > x0, y1 > y0, bytesPerRow >= width * 4 else { return .unknown }
        let s = max(1, step)
        var red = 0, yellow = 0, green = 0, total = 0
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var y = y0
        while y < y1 {
            let row = bytes + y * bytesPerRow
            var x = x0
            while x < x1 {
                let px = row + x * 4
                let p = RGBPixel(r: px[2], g: px[1], b: px[0])
                switch hueClass(p) {
                case .red: red += 1
                case .yellow: yellow += 1
                case .green: green += 1
                case .unknown: break
                }
                total += 1
                x += s
            }
            y += s
        }
        return decide(red: red, yellow: yellow, green: green, total: total)
    }

    static func decide(red: Int, yellow: Int, green: Int, total: Int) -> TrafficLightColor {
        let lit = red + yellow + green
        guard total > 0, Double(lit) / Double(total) >= minLitShare, lit >= 3 else { return .unknown }
        let best = max(red, yellow, green)
        guard Double(best) / Double(lit) >= minWinnerShare else { return .unknown }
        if best == red { return .red }
        if best == green { return .green }
        return .yellow
    }

    /// Hue class of a single pixel; only bright and saturated pixels count as "lit".
    static func hueClass(_ p: RGBPixel) -> TrafficLightColor {
        let r = Double(p.r) / 255, g = Double(p.g) / 255, b = Double(p.b) / 255
        let maxC = max(r, g, b), minC = min(r, g, b)
        let delta = maxC - minC
        let value = maxC
        let saturation = maxC > 0 ? delta / maxC : 0
        guard value >= 0.55, saturation >= 0.35, delta > 0 else { return .unknown }
        var hue: Double
        if maxC == r {
            hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxC == g {
            hue = 60 * ((b - r) / delta + 2)
        } else {
            hue = 60 * ((r - g) / delta + 4)
        }
        if hue < 0 { hue += 360 }
        switch hue {
        case 0..<20, 330...360: return .red
        case 20..<70: return .yellow
        case 90..<200: return .green      // signal greens are often cyan-ish
        default: return .unknown
        }
    }
}
