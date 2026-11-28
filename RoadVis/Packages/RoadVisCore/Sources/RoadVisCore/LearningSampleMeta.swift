import Foundation

/// Metadata of one training sample — the `meta` part of `POST /api/v1/samples` and the `<uuid>.json` file next to
/// `<uuid>.jpg` (`docs/TRAINING_API.md` §2–3). Field names are the contract: do not rename.
/// Boxes are normalized `[x, y, w, h]` with the origin top-left. Nil optionals (`speedKmh`, `lat`, `lon`) are
/// omitted from the JSON.
public struct LearningSampleMeta: Codable, Equatable, Sendable {
    public struct Model: Codable, Equatable, Sendable {
        public var name: String
        public var version: String

        public init(name: String, version: String) {
            self.name = name
            self.version = version
        }
    }

    public struct ImageInfo: Codable, Equatable, Sendable {
        public var width: Int
        public var height: Int
        /// "landscape" or "portrait".
        public var orientation: String

        public init(width: Int, height: Int, orientation: String) {
            self.width = width
            self.height = height
            self.orientation = orientation
        }

        public init(width: Int, height: Int) {
            self.init(width: width, height: height, orientation: width >= height ? "landscape" : "portrait")
        }
    }

    public struct DetectionInfo: Codable, Equatable, Sendable {
        public var label: String
        public var kind: String
        public var confidence: Double
        public var box: [Double]

        public init(label: String, kind: String, confidence: Double, box: [Double]) {
            self.label = label
            self.kind = kind
            self.confidence = confidence
            self.box = box
        }

        public init(_ detection: Detection) {
            self.init(label: detection.label, kind: detection.kind.rawValue,
                      confidence: LearningSampleMeta.round(detection.confidence, 3),
                      box: LearningSampleMeta.boxArray(detection.box))
        }
    }

    public struct TrackInfo: Codable, Equatable, Sendable {
        public var id: Int
        public var kind: String
        public var confidence: Double
        public var hits: Int
        public var missed: Int
        public var confirmed: Bool
        public var box: [Double]

        public init(id: Int, kind: String, confidence: Double, hits: Int, missed: Int, confirmed: Bool, box: [Double]) {
            self.id = id
            self.kind = kind
            self.confidence = confidence
            self.hits = hits
            self.missed = missed
            self.confirmed = confirmed
            self.box = box
        }

        public init(_ track: TrackedObject) {
            self.init(id: track.id, kind: track.kind.rawValue, confidence: LearningSampleMeta.round(track.confidence, 3),
                      hits: track.hits, missed: track.missed, confirmed: track.isConfirmed,
                      box: LearningSampleMeta.boxArray(track.box))
        }
    }

    public struct Quality: Codable, Equatable, Sendable {
        public var sharpness: Double
        public var brightness: Double
        /// 16 lowercase hex digits (`FrameQuality.hexString`).
        public var dhash: String

        public init(sharpness: Double, brightness: Double, dhash: String) {
            self.sharpness = sharpness
            self.brightness = brightness
            self.dhash = dhash
        }

        public init(_ metrics: FrameQualityMetrics) {
            self.init(sharpness: LearningSampleMeta.round(metrics.sharpness, 1),
                      brightness: LearningSampleMeta.round(metrics.brightness, 1), dhash: metrics.dhashHex)
        }
    }

    public var id: String
    /// ISO 8601 UTC, e.g. "2026-11-26T10:00:00Z" (`LearningSampleMeta.timestamp(_:)`).
    public var capturedAt: String
    /// "ios" or "android".
    public var platform: String
    public var appVersion: String
    public var model: Model
    public var image: ImageInfo
    public var reasons: [String]
    public var speedKmh: Double?
    public var lat: Double?
    public var lon: Double?
    public var detections: [DetectionInfo]
    public var tracks: [TrackInfo]
    public var quality: Quality

    public init(id: String, capturedAt: String, platform: String, appVersion: String, model: Model, image: ImageInfo,
                reasons: [String], speedKmh: Double?, lat: Double?, lon: Double?, detections: [DetectionInfo],
                tracks: [TrackInfo], quality: Quality) {
        self.id = id
        self.capturedAt = capturedAt
        self.platform = platform
        self.appVersion = appVersion
        self.model = model
        self.image = image
        self.reasons = reasons
        self.speedKmh = speedKmh
        self.lat = lat
        self.lon = lon
        self.detections = detections
        self.tracks = tracks
        self.quality = quality
    }

    /// Builds the metadata of a kept frame. `latitude` / `longitude` are passed only when the user allowed
    /// "send location"; a non-finite or negative speed is omitted.
    public static func make(id: String, capturedAt: Date, platform: String, appVersion: String, modelName: String,
                            modelVersion: String, imageWidth: Int, imageHeight: Int, reasons: [String],
                            speedKmh: Double?, latitude: Double?, longitude: Double?, detections: [Detection],
                            tracks: [TrackedObject], quality: FrameQualityMetrics) -> LearningSampleMeta {
        var speed: Double?
        if let speedKmh, speedKmh.isFinite, speedKmh >= 0 { speed = round(speedKmh, 1) }
        var lat: Double?
        var lon: Double?
        if let latitude, let longitude, latitude.isFinite, longitude.isFinite,
           abs(latitude) <= 90, abs(longitude) <= 180 {
            lat = round(latitude, 5)
            lon = round(longitude, 5)
        }
        return LearningSampleMeta(
            id: id, capturedAt: timestamp(capturedAt), platform: platform, appVersion: appVersion,
            model: Model(name: modelName, version: modelVersion),
            image: ImageInfo(width: imageWidth, height: imageHeight), reasons: reasons, speedKmh: speed,
            lat: lat, lon: lon, detections: detections.map(DetectionInfo.init),
            tracks: tracks.map(TrackInfo.init), quality: Quality(quality))
    }

    /// "2026-11-26T10:00:00Z" (UTC, whole seconds).
    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Parses `timestamp(_:)` output (also accepts fractional seconds).
    public static func date(fromTimestamp text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    /// Encoder for the `meta` part / json file (sorted keys, no escaped slashes).
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public func encoded() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> LearningSampleMeta {
        try JSONDecoder().decode(LearningSampleMeta.self, from: data)
    }

    static func boxArray(_ box: BBox) -> [Double] {
        let clamped = box.clamped
        return [round(clamped.x, 4), round(clamped.y, 4), round(clamped.width, 4), round(clamped.height, 4)]
    }

    static func round(_ value: Double, _ digits: Int) -> Double {
        guard value.isFinite else { return 0 }
        let scale = pow(10, Double(digits))
        return (value * scale).rounded() / scale
    }
}
