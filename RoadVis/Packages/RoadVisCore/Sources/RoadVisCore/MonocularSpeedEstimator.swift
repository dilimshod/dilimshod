import Foundation

/// Pinhole-camera parameters needed for rough monocular distance estimation.
public struct CameraGeometry: Hashable, Sendable {
    /// Horizontal field of view of the sensor's long side, degrees (AVCaptureDevice.activeFormat.videoFieldOfView).
    public var horizontalFOVDegrees: Double
    /// Image width in the display orientation, pixels.
    public var imageWidth: Double
    /// Image height in the display orientation, pixels.
    public var imageHeight: Double

    public init(horizontalFOVDegrees: Double, imageWidth: Double, imageHeight: Double) {
        self.horizontalFOVDegrees = horizontalFOVDegrees
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }

    /// Focal length in pixels. The FOV refers to the long side of the sensor, whatever the orientation.
    public var focalLengthPixels: Double {
        let longSide = max(imageWidth, imageHeight)
        let half = horizontalFOVDegrees * .pi / 360
        guard half > 0, half < .pi / 2 else { return longSide }
        return (longSide / 2) / tan(half)
    }

    /// Typical iPhone wide camera, portrait 1080×1920.
    public static let defaultPortrait = CameraGeometry(horizontalFOVDegrees: 65, imageWidth: 1080, imageHeight: 1920)
}

public enum MonocularDistance {
    /// Distance along the optical axis: Z = f_px · H_real / h_px.
    /// Returns nil for boxes that are too small (< 1.5 % of the frame) or too large (> 95 %).
    /// This is an approximation: it assumes a typical object height and a level camera.
    public static func distance(realHeight: Double, normalizedBoxHeight: Double, geometry: CameraGeometry) -> Double? {
        guard realHeight > 0, normalizedBoxHeight >= 0.015, normalizedBoxHeight <= 0.95,
              geometry.imageHeight > 0 else { return nil }
        let pixelHeight = normalizedBoxHeight * geometry.imageHeight
        let z = geometry.focalLengthPixels * realHeight / pixelHeight
        return z.isFinite ? z : nil
    }
}

/// Estimates distance and speed of tracked vehicles from the change of their apparent size.
/// Results are rough estimates (single camera, assumed vehicle height) and are shown with "≈".
public final class MonocularSpeedEstimator {
    private struct Sample { let t: TimeInterval; let z: Double }

    public let windowSeconds: Double
    public let maxDistance: Double
    private var history: [Int: [Sample]] = [:]
    /// Smoothed ground speed per track (EMA), km/h.
    private var smoothedSpeed: [Int: Double] = [:]

    /// Ground speed needs more evidence than the distance: ≥ 5 samples over ≥ 0.8 s.
    static let minSpeedSamples = 5
    static let minSpeedWindow: TimeInterval = 0.8
    /// Farther than this the height-based distance is too noisy for a speed (a 1 px box change is metres).
    static let maxSpeedDistance: Double = 80
    /// Below this the vehicle is shown as standing (noise of the distance slope).
    static let standstillKmh: Double = 4
    /// EMA factor of the displayed ground speed (≈ 0.5 s time constant at 15 fps).
    static let speedSmoothing: Double = 0.3
    private var lastSeen: [Int: TimeInterval] = [:]

    public init(windowSeconds: Double = 1.5, maxDistance: Double = 120) {
        self.windowSeconds = windowSeconds
        self.maxDistance = maxDistance
    }

    public func reset() {
        history.removeAll()
        lastSeen.removeAll()
        smoothedSpeed.removeAll()
    }

    public func update(tracks: [TrackedObject], ownSpeedKmh: Double?, geometry: CameraGeometry,
                       timestamp: TimeInterval) -> [TrackedObject] {
        var result = tracks
        for i in result.indices {
            var t = result[i]
            if t.missed > 0 {
                // Coasted track (predicted box, see `ObjectTracker.Config.coastFrames`): no new sample — a predicted
                // box height is not a measurement. The last measured distance stays on screen; speeds are withheld.
                let recent = (history[t.id] ?? []).suffix(3).map(\.z).sorted()
                t.distanceMeters = recent.isEmpty ? nil : recent[recent.count / 2]
                t.relativeSpeedKmh = nil
                t.estimatedSpeedKmh = nil
                t.isOncoming = false
                if !recent.isEmpty { lastSeen[t.id] = timestamp }
                result[i] = t
                continue
            }
            guard let realH = t.kind.typicalHeightMeters,
                  t.box.maxY < 0.985, t.box.minY > 0.005, // truncated boxes give wrong heights
                  let z = MonocularDistance.distance(realHeight: realH, normalizedBoxHeight: t.box.height, geometry: geometry),
                  z <= maxDistance else {
                t.distanceMeters = nil
                t.relativeSpeedKmh = nil
                t.estimatedSpeedKmh = nil
                t.isOncoming = false
                result[i] = t
                continue
            }
            var samples = history[t.id] ?? []
            samples.append(Sample(t: timestamp, z: z))
            samples.removeAll { timestamp - $0.t > windowSeconds }
            history[t.id] = samples
            lastSeen[t.id] = timestamp

            // Median of the last three samples for a steadier displayed distance.
            let recent = samples.suffix(3).map(\.z).sorted()
            t.distanceMeters = recent[recent.count / 2]

            t.relativeSpeedKmh = nil
            t.estimatedSpeedKmh = nil
            t.isOncoming = false
            if samples.count >= 4, let first = samples.first, timestamp - first.t >= 0.5,
               let slope = Self.slope(samples) {
                let rel = slope * 3.6
                if abs(rel) <= 150 {
                    t.relativeSpeedKmh = rel
                    // Ground speed of every vehicle (same direction OR oncoming): the gap changes at
                    // rel = v_other - own (same direction) or rel = -(v_other + own) (oncoming), so
                    // v_other = |own + rel| in both cases and the sign tells the direction. Monocular distance is
                    // noisy, so the speed needs a longer window, a nearer object and is smoothed per track.
                    if t.kind.isVehicle, let own = ownSpeedKmh, own >= 0,
                       samples.count >= Self.minSpeedSamples, timestamp - first.t >= Self.minSpeedWindow,
                       z <= Self.maxSpeedDistance {
                        let signed = own + rel
                        var absolute = abs(signed)
                        if absolute < Self.standstillKmh { absolute = 0 }
                        if absolute <= 250 {
                            let previous = smoothedSpeed[t.id]
                            let value = previous.map { $0 + Self.speedSmoothing * (absolute - $0) } ?? absolute
                            smoothedSpeed[t.id] = value
                            t.estimatedSpeedKmh = value
                            t.isOncoming = signed < -Self.standstillKmh
                        }
                    }
                }
            }
            result[i] = t
        }
        // Forget tracks not seen for a while.
        for (id, seen) in lastSeen where timestamp - seen > 2 {
            lastSeen[id] = nil
            history[id] = nil
            smoothedSpeed[id] = nil
        }
        return result
    }

    /// Least-squares slope dz/dt in m/s.
    private static func slope(_ s: [Sample]) -> Double? {
        let n = Double(s.count)
        let meanT = s.reduce(0) { $0 + $1.t } / n
        let meanZ = s.reduce(0) { $0 + $1.z } / n
        var num = 0.0, den = 0.0
        for p in s {
            num += (p.t - meanT) * (p.z - meanZ)
            den += (p.t - meanT) * (p.t - meanT)
        }
        guard den > 1e-9 else { return nil }
        return num / den
    }
}
