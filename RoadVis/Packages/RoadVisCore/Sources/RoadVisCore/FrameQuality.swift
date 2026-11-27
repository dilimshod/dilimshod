import Foundation

/// 8-bit grayscale image, row-major, no padding (0 = black, 255 = white).
public struct GrayImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == max(0, width) * max(0, height), "GrayImage: pixel count must be width × height")
        self.width = max(0, width)
        self.height = max(0, height)
        self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: UInt8 = 0) {
        self.init(width: width, height: height, pixels: [UInt8](repeating: fill, count: max(0, width) * max(0, height)))
    }

    public subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// Horizontal mirror image (used by tests and diagnostics).
    public func mirroredHorizontally() -> GrayImage {
        var out = GrayImage(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                out[x, y] = self[width - 1 - x, y]
            }
        }
        return out
    }
}

/// Quality metrics of one frame, computed on the `FrameQuality.analysisWidth`-wide grayscale copy.
public struct FrameQualityMetrics: Equatable, Sendable {
    /// Variance of the 4-neighbour Laplacian (0–255 gray at 160 px wide).
    public var sharpness: Double
    /// Mean gray value 0–255.
    public var brightness: Double
    /// 64-bit difference hash (`FrameQuality.dHash`).
    public var dhash: UInt64

    public init(sharpness: Double, brightness: Double, dhash: UInt64) {
        self.sharpness = sharpness
        self.brightness = brightness
        self.dhash = dhash
    }

    /// 16 lowercase hex digits, e.g. "f0e1d2c3b4a59687".
    public var dhashHex: String { FrameQuality.hexString(dhash) }
}

/// Frame-quality measures of the continuous-learning collector (`docs/TRAINING_API.md` §1). Identical rules in the
/// Kotlin core (`uz.roadvis.core`) and on the RoadVis Trainer server, so the same frame gets the same verdict.
///
/// - sharpness: variance (population, ddof 0) of the 4-neighbour Laplacian `[[0,1,0],[1,-4,1],[0,1,0]]` with
///   reflect-101 borders — what `cv2.Laplacian(gray, cv2.CV_64F).var()` returns;
/// - brightness: mean gray value;
/// - dHash: the image is area-resized to 9×8, then per row bit = left cell > right cell (8 × 8 = 64 bits); the
///   first comparison (row 0, column 0) is the most significant bit.
public enum FrameQuality {
    /// Width of the analysed grayscale copy, pixels.
    public static let analysisWidth = 160

    /// All three metrics of an analysis image.
    public static func metrics(_ image: GrayImage) -> FrameQualityMetrics {
        FrameQualityMetrics(sharpness: sharpness(image), brightness: brightness(image), dhash: dHash(image))
    }

    /// Variance of the 4-neighbour Laplacian (reflect-101 borders). 0 for a flat image or one smaller than 2×2.
    public static func sharpness(_ image: GrayImage) -> Double {
        let w = image.width, h = image.height
        guard w >= 2, h >= 2 else { return 0 }
        var sum: Double = 0
        var sumSquares: Double = 0
        image.pixels.withUnsafeBufferPointer { p in
            for y in 0..<h {
                let yUp = y == 0 ? 1 : y - 1
                let yDown = y == h - 1 ? h - 2 : y + 1
                let row = y * w
                for x in 0..<w {
                    let xLeft = x == 0 ? 1 : x - 1
                    let xRight = x == w - 1 ? w - 2 : x + 1
                    let center = Int(p[row + x])
                    let lap = Int(p[yUp * w + x]) + Int(p[yDown * w + x]) + Int(p[row + xLeft]) + Int(p[row + xRight])
                        - 4 * center
                    let value = Double(lap)
                    sum += value
                    sumSquares += value * value
                }
            }
        }
        let count = Double(w * h)
        let mean = sum / count
        return max(0, sumSquares / count - mean * mean)
    }

    /// Mean gray value 0–255 (0 for an empty image).
    public static func brightness(_ image: GrayImage) -> Double {
        guard !image.pixels.isEmpty else { return 0 }
        var total = 0
        for value in image.pixels { total += Int(value) }
        return Double(total) / Double(image.pixels.count)
    }

    /// 64-bit difference hash: 9×8 area resize, row-wise "left > right", row 0 / column 0 in the most significant bit.
    public static func dHash(_ image: GrayImage) -> UInt64 {
        let cells = resizeArea(image, width: 9, height: 8)
        var hash: UInt64 = 0
        for row in 0..<8 {
            for col in 0..<8 {
                let bit: UInt64 = cells[row * 9 + col] > cells[row * 9 + col + 1] ? 1 : 0
                hash = (hash << 1) | bit
            }
        }
        return hash
    }

    /// Number of differing bits.
    public static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    /// 16 lowercase hex digits (zero-padded).
    public static func hexString(_ hash: UInt64) -> String {
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }

    /// Parses `hexString` output (nil for anything else).
    public static func hash(fromHex text: String) -> UInt64? {
        guard text.count == 16 else { return nil }
        return UInt64(text, radix: 16)
    }

    /// Area-average resize to `width × height` cells (mean of the source pixels each cell covers, integer cell
    /// borders `i × W / width`). Returns the cell means row-major.
    static func resizeArea(_ image: GrayImage, width outW: Int, height outH: Int) -> [Double] {
        var cells = [Double](repeating: 0, count: outW * outH)
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return cells }
        for cy in 0..<outH {
            let y0 = min(h - 1, cy * h / outH)
            let y1 = max(y0 + 1, min(h, (cy + 1) * h / outH))
            for cx in 0..<outW {
                let x0 = min(w - 1, cx * w / outW)
                let x1 = max(x0 + 1, min(w, (cx + 1) * w / outW))
                var total = 0
                for y in y0..<y1 {
                    let row = y * w
                    for x in x0..<x1 { total += Int(image.pixels[row + x]) }
                }
                cells[cy * outW + cx] = Double(total) / Double((y1 - y0) * (x1 - x0))
            }
        }
        return cells
    }

    /// Gray value of a BGR(A) pixel: `0.299 R + 0.587 G + 0.114 B` in the fixed-point form OpenCV uses (14 bits).
    @inline(__always)
    public static func gray(r: Int, g: Int, b: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: min(255, (r * 4899 + g * 9617 + b * 1868 + 8192) >> 14))
    }

    /// Downsamples a BGRA buffer (8 bits per channel, `bytesPerRow` may include padding) to a `targetWidth`-wide
    /// grayscale image (height keeps the aspect ratio, rounded). Each output pixel is the mean of a grid of samples
    /// inside the source area it covers (at most ~4 × 4 per cell, so the cost stays small for a 1920-px frame).
    public static func grayFromBGRA(base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int,
                                    targetWidth: Int = analysisWidth) -> GrayImage {
        guard width > 0, height > 0, targetWidth > 0, bytesPerRow >= width * 4 else {
            return GrayImage(width: 0, height: 0)
        }
        let outW = min(targetWidth, width)
        let outH = max(1, Int((Double(height) * Double(outW) / Double(width)).rounded()))
        var image = GrayImage(width: outW, height: outH)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        image.pixels.withUnsafeMutableBufferPointer { out in
            for oy in 0..<outH {
                let y0 = min(height - 1, oy * height / outH)
                let y1 = max(y0 + 1, min(height, (oy + 1) * height / outH))
                let stepY = max(1, (y1 - y0) / 4)
                for ox in 0..<outW {
                    let x0 = min(width - 1, ox * width / outW)
                    let x1 = max(x0 + 1, min(width, (ox + 1) * width / outW))
                    let stepX = max(1, (x1 - x0) / 4)
                    var total = 0
                    var count = 0
                    var y = y0
                    while y < y1 {
                        let row = bytes + y * bytesPerRow
                        var x = x0
                        while x < x1 {
                            let p = x * 4
                            total += Int(gray(r: Int(row[p + 2]), g: Int(row[p + 1]), b: Int(row[p])))
                            count += 1
                            x += stepX
                        }
                        y += stepY
                    }
                    out[oy * outW + ox] = UInt8(truncatingIfNeeded: (total + count / 2) / max(1, count))
                }
            }
        }
        return image
    }
}
