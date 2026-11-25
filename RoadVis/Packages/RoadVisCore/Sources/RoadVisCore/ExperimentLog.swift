import Foundation

/// One detection row of a research log.
public struct ExperimentRecord: Codable, Hashable, Sendable {
    public var timestamp: Date
    public var frameIndex: Int
    public var trackID: Int?
    public var kind: VehicleKind
    public var label: String
    /// Detector confidence (model score), not accuracy.
    public var confidence: Double
    public var box: BBox
    public var make: String?
    public var makeConfidence: Double?
    public var distanceMeters: Double?
    public var estimatedSpeedKmh: Double?
    public var lightColor: TrafficLightColor?
    public var latitude: Double?
    public var longitude: Double?
    public var ownSpeedKmh: Double?

    public init(timestamp: Date, frameIndex: Int, trackID: Int? = nil, kind: VehicleKind, label: String,
                confidence: Double, box: BBox, make: String? = nil, makeConfidence: Double? = nil,
                distanceMeters: Double? = nil, estimatedSpeedKmh: Double? = nil,
                lightColor: TrafficLightColor? = nil, latitude: Double? = nil, longitude: Double? = nil,
                ownSpeedKmh: Double? = nil) {
        self.timestamp = timestamp
        self.frameIndex = frameIndex
        self.trackID = trackID
        self.kind = kind
        self.label = label
        self.confidence = confidence
        self.box = box
        self.make = make
        self.makeConfidence = makeConfidence
        self.distanceMeters = distanceMeters
        self.estimatedSpeedKmh = estimatedSpeedKmh
        self.lightColor = lightColor
        self.latitude = latitude
        self.longitude = longitude
        self.ownSpeedKmh = ownSpeedKmh
    }
}

/// Research log of a recognition session.
///
/// Two different quantities are exported and must not be confused:
/// - per-frame detections (`detections.csv`, one row per object per processed frame), and
/// - unique tracked objects (`summary.csv`, counted once when a track is confirmed).
public final class ExperimentLog {
    public let modelName: String
    public let startedAt: Date
    public private(set) var records: [ExperimentRecord] = []
    public private(set) var frameCount = 0

    /// Hard cap to keep memory bounded on long sessions (≈ 200k rows).
    public var maxRecords = 200_000
    public private(set) var droppedRecords = 0

    public init(modelName: String, startedAt: Date = Date()) {
        self.modelName = modelName
        self.startedAt = startedAt
    }

    public func markFrame() {
        frameCount += 1
    }

    public func append(_ record: ExperimentRecord) {
        guard records.count < maxRecords else {
            droppedRecords += 1
            return
        }
        records.append(record)
    }

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    static func num(_ v: Double?, _ digits: Int = 3) -> String {
        guard let v, v.isFinite else { return "" }
        return String(format: "%.\(digits)f", v)
    }

    static func csvField(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "" }
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    public func detectionsCSV() -> String {
        var lines = ["timestamp,frame,track_id,class,label,confidence,x,y,width,height,make,make_confidence,distance_m_est,speed_kmh_est,light_color,lat,lon,own_speed_kmh"]
        lines.reserveCapacity(records.count + 1)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for r in records {
            let fields: [String] = [
                f.string(from: r.timestamp),
                String(r.frameIndex),
                r.trackID.map(String.init) ?? "",
                r.kind.rawValue,
                Self.csvField(r.label),
                Self.num(r.confidence),
                Self.num(r.box.x, 4), Self.num(r.box.y, 4), Self.num(r.box.width, 4), Self.num(r.box.height, 4),
                Self.csvField(r.make),
                Self.num(r.makeConfidence),
                Self.num(r.distanceMeters, 1),
                Self.num(r.estimatedSpeedKmh, 1),
                r.lightColor?.rawValue ?? "",
                Self.num(r.latitude, 6), Self.num(r.longitude, 6),
                Self.num(r.ownSpeedKmh, 1),
            ]
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Per-class comparison of raw per-frame detections and unique tracked objects.
    public func summaryCSV(uniqueCounts: [VehicleKind: Int], endedAt: Date) -> String {
        var frameDetections: [VehicleKind: Int] = [:]
        var confidenceSum: [VehicleKind: Double] = [:]
        for r in records {
            frameDetections[r.kind, default: 0] += 1
            confidenceSum[r.kind, default: 0] += r.confidence
        }
        let duration = max(0, endedAt.timeIntervalSince(startedAt))
        var lines = [
            "# RoadVis experiment summary",
            "# model,\(Self.csvField(modelName))",
            "# started,\(Self.iso(startedAt))",
            "# ended,\(Self.iso(endedAt))",
            "# duration_s,\(Self.num(duration, 1))",
            "# processed_frames,\(frameCount)",
            "# dropped_rows,\(droppedRecords)",
            "# note,frame_detections = rows in detections.csv (one object on one frame); unique_tracked = objects counted once per confirmed track; mean_confidence is model score, not accuracy",
            "class,frame_detections,unique_tracked,mean_confidence",
        ]
        for kind in VehicleKind.allCases {
            let det = frameDetections[kind] ?? 0
            let uniq = uniqueCounts[kind] ?? 0
            guard det > 0 || uniq > 0 else { continue }
            let mean = det > 0 ? (confidenceSum[kind] ?? 0) / Double(det) : nil
            lines.append("\(kind.rawValue),\(det),\(uniq),\(Self.num(mean))")
        }
        let totalUnique = uniqueCounts.filter { $0.key.isVehicle }.reduce(0) { $0 + $1.value }
        lines.append("vehicles_total,\(frameDetections.filter { $0.key.isVehicle }.reduce(0) { $0 + $1.value }),\(totalUnique),")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes `<prefix>_detections.csv` and `<prefix>_summary.csv` into `directory` and returns their URLs.
    public func writeFiles(to directory: URL, uniqueCounts: [VehicleKind: Int], endedAt: Date) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Self.iso(startedAt)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let prefix = "roadvis_\(stamp)"
        let detURL = directory.appendingPathComponent("\(prefix)_detections.csv")
        let sumURL = directory.appendingPathComponent("\(prefix)_summary.csv")
        try Data(detectionsCSV().utf8).write(to: detURL, options: .atomic)
        try Data(summaryCSV(uniqueCounts: uniqueCounts, endedAt: endedAt).utf8).write(to: sumURL, options: .atomic)
        return [detURL, sumURL]
    }
}
