# RoadVision — module contracts

This file fixes the names and signatures that modules use from each other.
Each module may add private helpers, but **public names listed here must exist exactly as written**.

General rules
- Swift 5 language mode, iOS 17.0 deployment target, built with Xcode 26 (must also compile with Xcode 16.4 — CI uses it).
  Anything newer than iOS 17 must be guarded with `if #available(iOS 18/26, *)` / `@available`, and FoundationModels
  code additionally with `#if canImport(FoundationModels)`.
- UI language: Russian. Strings may be hard-coded Russian literals.
- `RoadVisionCore` (folder `Packages/RoadVisionCore/Sources/RoadVisionCore`) is compiled **into the app target** — app code
  must never write `import RoadVisionCore`. Core files import only `Foundation`, must build on Linux (swift-corelibs-foundation),
  and must not use `URLSession` (networking lives in the app layer).
- File names must be unique across the app folder and the core folder (one Xcode target).
- Services are `@Observable @MainActor final class`. Views get the graph through `@Environment(AppState.self) private var app`.
- Never claim accuracy: detector scores are "уверенность" (confidence). Estimated values are prefixed with "≈" and labelled "оценка".

---------------------------------------------------------------------------------------------------
## 1. RoadVisionCore (Foundation only)

Already written & tested (do not change signatures): `Geo.swift` (GeoPoint, Geo.*, Double.kmh/.mps), `VisionModels.swift`
(VehicleKind, BBox, TrafficLightColor, Detection), `RoadAttributes.swift` (LaneTurn, Lane, LaneInfo(+ .unknown), SpeedLimit),
`Tracking.swift`, `MonocularSpeedEstimator.swift`, `YOLODecoder.swift`, `TrafficLightColorClassifier.swift`, `ExperimentLog.swift`,
`Maneuver.swift`, `RouteProgress.swift`, `Formatting.swift`, `ChatProtocol.swift`, `AssistantPrompt.swift`
(the last two are leftovers of the removed AI assistant: still compiled and tested, but unused by the app).

### 1.1 Vision logic
```swift
// Tracking.swift
public struct TrackedObject: Identifiable, Hashable, Sendable {
    public let id: Int
    public var kind: VehicleKind
    public var label: String
    public var box: BBox                     // smoothed latest box
    public var confidence: Double            // latest detector confidence
    public var hits: Int
    public var missed: Int                   // consecutive unmatched frames
    public var firstSeen: TimeInterval
    public var lastSeen: TimeInterval
    public var isConfirmed: Bool             // hits >= minHits
    public var make: String?                 // majority vote of make observations
    public var makeConfidence: Double?       // mean confidence of the winning make
    public var lightColor: TrafficLightColor?   // majority of recent colour observations
    public var distanceMeters: Double?       // set by MonocularSpeedEstimator
    public var relativeSpeedKmh: Double?     // + = moving away from camera
    public var estimatedSpeedKmh: Double?    // own speed + relative speed (only when plausible)
}
public final class ObjectTracker {
    public struct Config: Sendable {
        public var iouThreshold: Double = 0.3
        public var maxMissed: Int = 8
        public var minHits: Int = 3
        public var boxSmoothing: Double = 0.6        // weight of the new box
        public init(iouThreshold: Double = 0.3, maxMissed: Int = 8, minHits: Int = 3, boxSmoothing: Double = 0.6)
    }
    public init(config: Config = Config())
    /// Returns currently visible tracks (missed == 0), confirmed or not. Unique counting uses confirmed tracks only.
    public func update(detections: [Detection], timestamp: TimeInterval) -> [TrackedObject]
    public func addMakeObservation(trackID: Int, make: String, confidence: Double)
    public private(set) var uniqueCounts: [VehicleKind: Int]   // confirmed unique objects since reset
    public var totalUniqueVehicles: Int { get }                // sum over kinds where isVehicle
    public private(set) var frameDetectionCount: Int           // total per-frame detections fed (not unique)
    public func reset()
}

// MonocularSpeedEstimator.swift
public struct CameraGeometry: Hashable, Sendable {
    public var horizontalFOVDegrees: Double  // AVCaptureDevice.activeFormat.videoFieldOfView (sensor long side)
    public var imageWidth: Double            // in display orientation, pixels
    public var imageHeight: Double
    public init(horizontalFOVDegrees: Double, imageWidth: Double, imageHeight: Double)
    public var focalLengthPixels: Double { get }   // (max(w,h)/2) / tan(fov/2)
    public static let defaultPortrait: CameraGeometry   // 65°, 1080 x 1920
}
public enum MonocularDistance {
    /// Z = f_px * realHeight / (normalizedBoxHeight * imageHeight). nil if box too small/large.
    public static func distance(realHeight: Double, normalizedBoxHeight: Double, geometry: CameraGeometry) -> Double?
}
public final class MonocularSpeedEstimator {
    public init(windowSeconds: Double = 1.5, maxDistance: Double = 120)
    /// Fills distanceMeters / relativeSpeedKmh / estimatedSpeedKmh (linear regression of distance over the window).
    public func update(tracks: [TrackedObject], ownSpeedKmh: Double?, geometry: CameraGeometry, timestamp: TimeInterval) -> [TrackedObject]
    public func reset()
}

// YOLODecoder.swift
public struct RawDetection: Hashable, Sendable { public var box: BBox; public var score: Double; public var classIndex: Int }
public enum YOLODecoder {
    /// Decodes a raw YOLO output tensor (row-major Float values with the given shape):
    ///  - [1, 4+nc, N] (YOLOv8/YOLO11, boxes cx,cy,w,h in input pixels) → runs NMS
    ///  - [1, N, 6]    (end-to-end YOLO26/YOLOv10: x1,y1,x2,y2,score,class in input pixels) → no NMS needed
    /// Coordinates are normalized by inputWidth/inputHeight into top-left-origin BBox.
    public static func decode(values: [Float], shape: [Int], inputWidth: Double, inputHeight: Double,
                              confidenceThreshold: Double, iouThreshold: Double, maxDetections: Int = 100,
                              sourceWidth: Double? = nil, sourceHeight: Double? = nil) -> [RawDetection]
    // sourceWidth/Height: pass the camera frame size when Vision used .scaleFit (letterbox) so it is undone.
    public static func nonMaxSuppression(_ detections: [RawDetection], iouThreshold: Double,
                                         classAware: Bool = true, maxDetections: Int = 100) -> [RawDetection]
}
public enum COCOLabels { public static let names: [String] }   // 80 COCO class names, index = class id

// TrafficLightColorClassifier.swift
public struct RGBPixel: Hashable, Sendable { public var r: UInt8; public var g: UInt8; public var b: UInt8; public init(r:g:b:) }
public enum TrafficLightColorClassifier {
    public static func classify(pixels: [RGBPixel]) -> TrafficLightColor
    /// Samples a BGRA (kCVPixelFormatType_32BGRA) buffer inside the pixel rect (x, y, width, height) with a stride.
    public static func classifyBGRA(base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int,
                                    rectX: Int, rectY: Int, rectWidth: Int, rectHeight: Int, step: Int = 2) -> TrafficLightColor
}

// ExperimentLog.swift — research export (per-frame detections vs unique tracked vehicles)
public struct ExperimentRecord: Codable, Hashable, Sendable {
    public var timestamp: Date; public var frameIndex: Int; public var trackID: Int?
    public var kind: VehicleKind; public var label: String; public var confidence: Double; public var box: BBox
    public var make: String?; public var makeConfidence: Double?; public var distanceMeters: Double?
    public var estimatedSpeedKmh: Double?; public var lightColor: TrafficLightColor?
    public var latitude: Double?; public var longitude: Double?; public var ownSpeedKmh: Double?
    public init(...all fields, optionals default nil...)
}
public final class ExperimentLog {
    public init(modelName: String, startedAt: Date = Date())
    public let modelName: String; public let startedAt: Date
    public private(set) var records: [ExperimentRecord]
    public private(set) var frameCount: Int
    public func markFrame()                  // call once per processed frame
    public func append(_ record: ExperimentRecord)
    public func detectionsCSV() -> String    // header + one row per record (ISO-8601 timestamps, '.' decimals)
    public func summaryCSV(uniqueCounts: [VehicleKind: Int], endedAt: Date) -> String  // per class: frame detections vs unique vehicles
    public func writeFiles(to directory: URL, uniqueCounts: [VehicleKind: Int], endedAt: Date) throws -> [URL]
}
```

### 1.2 Road / OSM logic
```swift
// OSMModels.swift
public struct OSMElement: Decodable, Hashable, Sendable {
    public enum ElementType: String, Decodable, Sendable { case node, way, relation }
    public let type: ElementType; public let id: Int64
    public let lat: Double?; public let lon: Double?
    public let center: GeoPoint?             // from {"center":{"lat","lon"}}
    public let geometry: [GeoPoint]?         // from [{"lat","lon"}]
    public let nodes: [Int64]?
    public let tags: [String: String]        // empty if absent
    public var coordinate: GeoPoint? { get } // lat/lon, else center, else geometry midpoint
    public var key: String { get }           // "node/123"
}
public struct OverpassResponse: Decodable, Sendable { public let elements: [OSMElement] }
public enum OverpassQuery {
    public static let maxPolylinePoints: Int      // max vertices per featuresAlong query (≈ 100)
    /// Ways with highway=* within radius (out tags geom) + traffic_signals nodes within signalRadius.
    public static func roadsAround(_ p: GeoPoint, radius: Double = 30, signalRadius: Double = 80, timeout: Int = 15) -> String
    /// Nodes/ways along a polyline (around:R,lat1,lon1,...): traffic_signals, crossing, speed_camera, traffic_calming,
    /// stop, give_way, railway=level_crossing, amenity=school|kindergarten (out center), highway=construction.
    public static func featuresAlong(_ polyline: [GeoPoint], radius: Double = 35, timeout: Int = 25) -> String
    public static func formBody(_ query: String) -> Data      // "data=<percent-encoded>"
    public static func decode(_ data: Data) throws -> [OSMElement]
}

// RoadAttributes.swift
public enum LaneTurn: String, Codable, Hashable, Sendable, CaseIterable {
    case left, slightLeft = "slight_left", sharpLeft = "sharp_left", through, right,
         slightRight = "slight_right", sharpRight = "sharp_right", reverse,
         mergeToLeft = "merge_to_left", mergeToRight = "merge_to_right", none
    public var symbolName: String { get }    // SF Symbol for a lane arrow
}
public struct Lane: Hashable, Codable, Sendable { public var turns: [LaneTurn]; public init(turns: [LaneTurn]) }
public struct LaneInfo: Hashable, Codable, Sendable {
    public var totalLanes: Int?; public var lanesInDirection: Int?; public var lanesOpposite: Int?
    public var lanes: [Lane]          // our direction, left→right; may be empty when no turn:lanes
    public var isOneway: Bool
    public var isEstimated: Bool      // true when count is inferred (no lanes tag)
    public init(totalLanes: Int?, lanesInDirection: Int?, lanesOpposite: Int?, lanes: [Lane], isOneway: Bool, isEstimated: Bool)
}
public struct SpeedLimit: Hashable, Codable, Sendable {
    public var kmh: Int; public var raw: String; public var isImplicit: Bool   // implicit = zone code like "RU:urban"
    public init(kmh: Int, raw: String, isImplicit: Bool)
}
public enum MaxSpeedParser {
    public static func parse(_ value: String?) -> SpeedLimit?                 // "60", "50 mph", "RU:urban", "UZ:rural", "none", "walk"
    public static func limit(tags: [String: String], travelingForward: Bool) -> SpeedLimit?   // maxspeed:forward/backward first
}
public enum OSMRoadParser {
    public static func parseTurnLanes(_ value: String) -> [Lane]             // "left|through;right|right"
    public static func onewayDirection(tags: [String: String]) -> Int          // 0 = two-way, 1 = forward only, -1 = backward only
    public static func laneInfo(tags: [String: String], travelingForward: Bool) -> LaneInfo
    public static func defaultLaneCount(highway: String, oneway: Bool) -> Int?
    public static func highwayDisplayName(_ highway: String) -> String        // Russian ("Магистраль", "Улица" …)
}
public struct RoadSegmentInfo: Hashable, Sendable {
    public var wayID: Int64; public var name: String?; public var ref: String?; public var highway: String
    public var laneInfo: LaneInfo; public var speedLimit: SpeedLimit?; public var surface: String?; public var lit: Bool?
    public var travelingForward: Bool; public var distanceToRoad: Double; public var tags: [String: String]
    public var displayName: String { get }   // name ?? ref ?? highwayDisplayName
}
public enum RoadMatcher {
    /// Picks the way best matching the position and travel heading (distance + heading penalty). heading nil → nearest.
    public static func bestMatch(elements: [OSMElement], position: GeoPoint, heading: Double?, maxDistance: Double = 35) -> RoadSegmentInfo?
}

// RouteFeatures.swift
public enum RouteFeatureKind: String, Codable, Hashable, Sendable, CaseIterable {
    case trafficSignals, pedestrianCrossing, speedCamera, trafficCalming, railwayCrossing,
         school, kindergarten, construction, stopSign, giveWay
    public var displayName: String { get }   // Russian
    public var symbolName: String { get }    // SF Symbol
    public var alertDistance: Double { get } // metres before which to warn
}
public struct RouteFeature: Identifiable, Hashable, Sendable {
    public let id: String                    // "node/123" (first element of a merged cluster)
    public let kind: RouteFeatureKind
    public let coordinate: GeoPoint
    public let distanceAlongRoute: Double
    public let offsetFromRoute: Double
    public let name: String?
    public let tags: [String: String]
    public init(id: String, kind: RouteFeatureKind, coordinate: GeoPoint, distanceAlongRoute: Double, offsetFromRoute: Double, name: String?, tags: [String: String])
}
public struct SignalLocation: Hashable, Codable, Sendable { public var id: String; public var coordinate: GeoPoint; public init(id: String, coordinate: GeoPoint) }
public enum RouteFeatureExtractor {
    public static func kind(for tags: [String: String]) -> RouteFeatureKind?
    /// Projects elements onto the route, drops those farther than maxOffset (schools: 150 m), merges same-kind
    /// features closer than mergeRadius along the route (traffic signals: 60 m → one signalised intersection).
    public static func extract(elements: [OSMElement], route: [GeoPoint], cumulative: [Double]? = nil,
                               maxOffset: Double = 40) -> [RouteFeature]      // sorted by distanceAlongRoute
    public static func signals(from elements: [OSMElement]) -> [SignalLocation] // highway=traffic_signals nodes, clustered 40 m
}

// SignalTiming.swift
public struct SignalTimingAssumptions: Codable, Hashable, Sendable {
    public var cycleSeconds: Double; public var greenRatio: Double
    public init(cycleSeconds: Double = 90, greenRatio: Double = 0.45)
}
public struct SignalObservation: Codable, Hashable, Sendable {
    public var signalID: String; public var date: Date; public var stopped: Bool; public var waitSeconds: Double
    public init(signalID: String, date: Date, stopped: Bool, waitSeconds: Double)
}
public struct SignalWaitEstimate: Hashable, Sendable {
    public enum Source: String, Sendable { case model, learned, blended }
    public var expectedWaitSeconds: Double; public var stopProbability: Double; public var meanWaitIfStopped: Double
    public var observationCount: Int; public var source: Source
}
public enum SignalWaitModel {
    /// Random arrival, fixed-time signal: P(stop)=r/C, E[wait|stop]=r/2, E[wait]=r²/(2C), r = C·(1−g).
    public static func estimate(_ a: SignalTimingAssumptions) -> SignalWaitEstimate
}
public final class SignalStatistics: Codable {
    public init()
    public func record(_ observation: SignalObservation)
    /// Blends the model with learned observations (same peak/off-peak bucket preferred). ≥ 5 obs → learned.
    public func estimate(for signalID: String, at date: Date, assumptions: SignalTimingAssumptions, calendar: Calendar = .current) -> SignalWaitEstimate
    public func observations(for signalID: String) -> [SignalObservation]
    public var totalObservations: Int { get }
    public func removeAll()
}
public final class StopDetector {
    public init(stopSpeedKmh: Double = 3, resumeSpeedKmh: Double = 10, minStopSeconds: Double = 2, signalRadius: Double = 45)
    /// Feed every GPS fix. Returns an observation once the vehicle leaves a signal area
    /// (stopped=true with the stop duration, or stopped=false when it passed without stopping).
    public func update(position: GeoPoint, speedKmh: Double, timestamp: Date, nearbySignals: [SignalLocation]) -> SignalObservation?
    public func reset()
}

// WeatherModels.swift (Open-Meteo)
public struct WeatherSnapshot: Hashable, Sendable {
    public var temperatureC: Double?; public var apparentTemperatureC: Double?; public var precipitationMm: Double?
    public var rainMm: Double?; public var snowfallCm: Double?; public var weatherCode: Int?; public var cloudCover: Double?
    public var windSpeedKmh: Double?; public var windGustsKmh: Double?; public var visibilityMeters: Double?; public var isDay: Bool
    public var time: String?
    public var conditionDescription: String { get }   // Russian, from WMO code
    public var symbolName: String { get }             // SF Symbol
    public var summary: String { get }                // "+12°, дождь, ветер 18 км/ч"
    public var roadWarnings: [String] { get }         // Russian warnings: гололёд, туман, сильный ветер, ливень, снег
}
public enum OpenMeteo {
    public static func url(for point: GeoPoint) -> URL
    public static func parse(_ data: Data) throws -> WeatherSnapshot
    public static func conditionDescription(code: Int) -> String
}

// TrafficDelay.swift
public enum CongestionLevel: String, Codable, Sendable, CaseIterable {
    case free, light, moderate, heavy, severe
    public var displayName: String { get }   // Russian
}
public struct TrafficAssessment: Hashable, Sendable {
    public var currentSeconds: Double; public var freeFlowSeconds: Double
    public var delaySeconds: Double { get }   // max(0, current − freeFlow)
    public var ratio: Double { get }          // current / freeFlow
    public var level: CongestionLevel { get } // <1.1 free, <1.25 light, <1.5 moderate, <2 heavy, else severe
    public init(currentSeconds: Double, freeFlowSeconds: Double)
}
public enum TrafficDelay {
    /// Next 03:00 local time strictly after `date` (used as a low-traffic departure for the free-flow ETA).
    public static func nextOffPeakDate(after date: Date, calendar: Calendar = .current, hour: Int = 3) -> Date
}

// Incidents.swift — user-reported road events (stored locally on the phone)
public enum RoadIncidentKind: String, Codable, Hashable, Sendable, CaseIterable {
    case accident, roadWork, jam, police, pothole, hazard, closure
    public var displayName: String { get }; public var symbolName: String { get }
}
public struct RoadIncident: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID; public var kind: RoadIncidentKind; public var coordinate: GeoPoint; public var date: Date; public var note: String?
    public init(id: UUID = UUID(), kind: RoadIncidentKind, coordinate: GeoPoint, date: Date = Date(), note: String? = nil)
}
public struct IncidentOnRoute: Identifiable, Hashable, Sendable { public var incident: RoadIncident; public var distanceAlongRoute: Double; public var id: UUID { get } }
public enum IncidentFilter {
    public static func active(_ incidents: [RoadIncident], now: Date, lifetime: TimeInterval) -> [RoadIncident]
    public static func along(route: [GeoPoint], cumulative: [Double]?, incidents: [RoadIncident], maxOffset: Double = 50) -> [IncidentOnRoute]
}
```

### 1.3 Navigation logic (+ unused chat helpers)
```swift
// Maneuver.swift
public enum ManeuverType: String, Codable, Hashable, Sendable, CaseIterable {
    case depart, straight, slightLeft, left, sharpLeft, slightRight, right, sharpRight,
         uTurn, roundabout, merge, keepLeft, keepRight, exitLeft, exitRight, arrive, unknown
    public var symbolName: String { get }          // SF Symbol, e.g. "arrow.turn.up.left"
    public var compatibleLaneTurns: Set<LaneTurn> { get }
}
public enum ManeuverClassifier {
    /// Keyword classification of MapKit step instructions in Russian, English and Uzbek (Latin).
    public static func classify(_ instruction: String) -> ManeuverType
}
public enum LaneGuidance {
    /// For each lane (left→right) whether it is recommended for the maneuver. Empty input → empty output.
    public static func recommendedLanes(_ lanes: [Lane], for maneuver: ManeuverType) -> [Bool]
}

// RouteProgress.swift
public struct RouteStepInfo: Hashable, Sendable {
    public var instruction: String; public var distance: Double; public var notice: String?
    public init(instruction: String, distance: Double, notice: String? = nil)
}
public struct RouteProgress: Hashable, Sendable {
    public var distanceAlong: Double; public var remainingDistance: Double; public var remainingTimeSeconds: Double
    public var fractionCompleted: Double
    public var nextStepIndex: Int?                 // step whose maneuver comes next
    public var distanceToNextManeuver: Double?
    public var nextInstruction: String?
    public var nextManeuver: ManeuverType
    public var followingInstruction: String?       // the maneuver after next ("затем …")
    public var crossTrackDistance: Double
    public var isOffRoute: Bool
    public var hasArrived: Bool
    public var snappedPosition: GeoPoint
}
public final class RouteProgressTracker {
    /// steps = MKRoute.steps in order. Maneuver of step i happens at the START of step i, i.e. at
    /// sum(distance[0..<i]) (scaled so that the sum of step distances equals the polyline length).
    /// Step 0 (departure, usually empty instruction) is never announced.
    public init(polyline: [GeoPoint], steps: [RouteStepInfo], expectedTravelTime: Double,
                offRouteThreshold: Double = 50, offRouteConfirmations: Int = 3, arrivalThreshold: Double = 30)
    public let polyline: [GeoPoint]; public let cumulative: [Double]; public var totalDistance: Double { get }
    public let steps: [RouteStepInfo]
    public var maneuverDistances: [Double] { get }    // scaled start distance of each step
    public func update(position: GeoPoint, horizontalAccuracy: Double? = nil) -> RouteProgress
}
public struct VoicePromptScheduler: Sendable {
    public init(thresholds: [Double] = [1000, 400, 100])
    /// Returns text to speak when a threshold for this step is crossed for the first time, else nil.
    /// Uses the largest crossed threshold only (never repeats), adapts 1000 → skipped when speed < 30 km/h.
    public mutating func prompt(stepIndex: Int, distance: Double, instruction: String, speedKmh: Double?) -> String?
    public mutating func reset()
}
public enum RVFormat {
    public static func distance(_ meters: Double) -> String        // "350 м", "1,2 км", "12 км"
    public static func spokenDistance(_ meters: Double) -> String  // "через 400 метров", "через 1,5 километра"
    public static func duration(_ seconds: Double) -> String       // "45 с", "12 мин", "1 ч 05 мин"
    public static func speed(_ kmh: Double) -> String              // "54"
    public static func clock(_ date: Date, calendar: Calendar = .current) -> String   // "14:35"
}

// ChatProtocol.swift + AssistantPrompt.swift — NOT used by the app (the AI assistant was removed); kept with their tests.
public struct ChatMessage: Codable, Hashable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable { case system, user, assistant }
    public var id: UUID; public var role: Role; public var content: String; public var date: Date
    public init(id: UUID = UUID(), role: Role, content: String, date: Date = Date())
}
public enum ChatStreamEvent: Equatable, Sendable { case delta(String), done, ignore, error(String) }
public enum OpenAIChat {
    public static func requestBody(model: String, messages: [ChatMessage], stream: Bool,
                                   temperature: Double? = 0.7, maxTokens: Int? = nil, extra: [String: String] = [:]) throws -> Data
    public static func parseStreamLine(_ line: String) -> ChatStreamEvent   // SSE "data: {...}" → delta.content only (ignore delta.reasoning)
    public static func parseCompletion(_ data: Data) throws -> String       // choices[0].message.content
    public static func parseError(_ data: Data) -> String?                  // {"error":{"message"}} or {"error":"..."}
    public static func parseModelList(_ data: Data) -> [String]             // GET /models → data[].id
}
public struct ChatProviderPreset: Codable, Hashable, Identifiable, Sendable {
    public var id: String; public var name: String; public var baseURL: String   // ends with /v1 or /openai, no trailing slash
    public var chatPath: String                     // usually "/chat/completions"
    public var defaultModel: String; public var requiresAPIKey: Bool
    public var keyURL: String?; public var notes: String; public var extraHeaders: [String: String]
    public var extraBody: [String: String]          // extra JSON string fields, e.g. ["reasoning_effort": "low"]
    public var chatURL: URL? { get }; public var modelsURL: URL? { get }
    public func withBaseURL(_ url: String) -> ChatProviderPreset
}
public enum ChatPresets {
    public static let all: [ChatProviderPreset]     // ids: "pollinations", "gemini", "groq", "openrouter", "ollama", "lmstudio", "custom"
    public static func preset(id: String) -> ChatProviderPreset?
    public static let appleOnDeviceID: String        // "apple" (FoundationModels; handled in app layer)
    public static let autoID: String                 // "auto"
    public static let autoOrder: [String]            // ["gemini","groq","openrouter","apple","pollinations"] (keyed ones only if a key is saved)
}
public struct DrivingContext: Sendable, Hashable {
    public var localTime: Date?; public var speedKmh: Double?; public var roadName: String?; public var speedLimitKmh: Int?
    public var lanesInDirection: Int?; public var totalLanes: Int?; public var destinationName: String?
    public var remainingDistanceMeters: Double?; public var remainingTimeSeconds: Double?; public var nextInstruction: String?
    public var trafficDelaySeconds: Double?; public var signalsAhead: Int?; public var expectedSignalWaitSeconds: Double?
    public var weatherSummary: String?; public var vehiclesInView: [VehicleKind: Int]; public var uniqueVehiclesCounted: Int?
    public init()   // all nil / empty
    public var summaryLines: [String] { get }        // Russian bullet lines of the known facts only
}
public enum AssistantPrompt {
    /// System prompt: friendly in-car companion; short spoken-style answers (≤ 3 sentences unless asked);
    /// answer in the user's language (languageCode "ru" | "uz" | "en"); never encourage looking at the phone;
    /// facts about the trip only from the context block; includeContext=false → no context block.
    public static func systemPrompt(languageCode: String, context: DrivingContext?, includeContext: Bool) -> String
}
public enum ChatHistory {
    /// Keeps the newest messages whose total content length ≤ maxCharacters (always keeps the last user message).
    public static func trimmed(_ messages: [ChatMessage], maxCharacters: Int) -> [ChatMessage]
}
```

---------------------------------------------------------------------------------------------------
## 2. App layer (iOS) — shell already written

`App/RoadVisionApp.swift`, `App/RootView.swift`, `App/AppState.swift`, `App/AppSettings.swift`, `App/LocationService.swift`,
`App/SpeechService.swift`, `Shared/AppBridges.swift`. Read them; do not rename anything they reference.

Key shell APIs:
- `AppState`: `mode`, `showSettings`, `switchTo(_:)`, `toggleMode()`, `updateCameraForMode()`, `handleScenePhase(_:)`,
  services `settings, location, speech, roadInfo, weather, signals, incidents, navigation, recognition`.
  App-wide lifecycle (camera, GPS, idle timer) is driven by `RootView` from `UIApplication.didBecomeActive /
  willEnterForeground / didEnterBackground` notifications (not per-scene `scenePhase`); `handleScenePhase` ignores
  `.inactive` and repeated phases, so several scenes act only once per app state change.
- `LocationService`: `location: CLLocation?`, `speedKmh: Double?`, `course`, `heading`, `travelDirection`, `coordinate: GeoPoint?`,
  `isAuthorized`, `authorizationStatus`, `start()`, `stop()`, `setBackgroundUpdates(_:)`, `addListener(_:) -> UUID`, `removeListener(_:)`.
- `SpeechService`: `speak(_:priority:)`, `stop()`, `isSpeaking`, `isMuted`, `static voiceLanguage` (= "ru-RU", fixed —
  every prompt is Russian; no setting changes it), `russianVoice()`, `static voice(for:)` (system default voice for the
  language, else an enhanced/premium `com.apple.voice.*` / `com.apple.ttsbundle.*` voice; never novelty/Eloquence).
  The `.playback`/`.voicePrompt` session ducks other audio only while speaking and is deactivated with
  `.notifyOthersOnDeactivation` after the last utterance. No microphone / recording.
- `AppSettings`: see file (all user preferences, `signalAssumptions`, `overpassEndpoints`).
- `AppBridges.swift`: `GeoPoint(CLLocationCoordinate2D)`, `.coordinate`, `MKPolyline.coordinates/.geoPoints`,
  `BBox(visionRect:)`, `.visionRect`, `.cgRect`, `.rect(in:)`.

### 2.1 Camera & recognition (folders Camera/, Detection/, Shared/)
```swift
enum ModelStatus: Equatable, Sendable {                // Detection/VehicleDetector.swift
    case loading, ready(String), missing, failed(String)
    var isReady: Bool { get }; var modelName: String? { get }; var displayText: String { get }   // Russian
}
@Observable @MainActor final class RecognitionPipeline {
    init(location: LocationService, settings: AppSettings, signals: TrafficSignalService)
    let camera: CameraService
    private(set) var tracks: [TrackedObject]           // visible tracks for overlay (+ confirmed tracks missed ≤ trackHoldSeconds = 0.3 s, missed ≥ 1)
    private(set) var visibleCounts: [VehicleKind: Int] // currently visible confirmed objects by kind
    private(set) var uniqueCounts: [VehicleKind: Int]  // unique confirmed objects since reset
    var totalUniqueVehicles: Int { get }
    var totalVisibleVehicles: Int { get }               // added: visible confirmed road vehicles
    private(set) var fps: Double
    private(set) var inferenceMs: Double
    private(set) var detectorStatus: ModelStatus
    private(set) var makeClassifierStatus: ModelStatus
    private(set) var currentLightColor: TrafficLightColor?   // largest confirmed traffic light (.unknown = colour not determined); nil = none
    private(set) var isRunning: Bool                    // capture session running
    private(set) var cameraPermissionDenied: Bool
    private(set) var frameSize: CGSize                  // added: upright buffer size in pixels (for aspect-fill box mapping)
    private(set) var cameraError: String?               // added: configuration error (e.g. no camera in the simulator)
    private(set) var isCameraInterrupted: Bool          // added: system interruption (other app, Split View, call…)
    private(set) var recordingStartedAt: Date?          // added
    private(set) var lastRecordingFiles: [URL]          // added
    private(set) var recordingError: String?            // added
    private(set) var processedFrames: Int               // added
    var isRecording: Bool { get }                       // stays true until the CSV files of finishRecording() are on disk
    func start(); func stop()                           // start() is idempotent; asks for camera permission on first use
    func resetCounters()
    func startRecording(); @discardableResult func stopRecording() -> [URL]    // CSV files written to Documents/Experiments/
    func finishRecording() async -> [URL]               // added: same as stopRecording(), writes off the main actor
    nonisolated static var experimentsDirectory: URL { get }   // added: Documents/Experiments/
}
final class CameraService: NSObject, @unchecked Sendable {     // not MainActor
    let session: AVCaptureSession
    var frameHandler: ((CVPixelBuffer, CMTime) -> Void)?       // called on the serial "camera.frames" queue, frames upright BGRA
    var stateHandler: (@Sendable (_ isRunning: Bool, _ isInterrupted: Bool) -> Void)?   // any queue
    var horizontalFieldOfView: Double { get }                  // activeFormat.videoFieldOfView, fallback 65
    var isRunning: Bool { get }; var isInterrupted: Bool { get }; var videoRotationAngle: Double { get }
    static var authorizationStatus: AVAuthorizationStatus { get }; static func requestAccess() async -> Bool
    func start(completion: (@Sendable (Error?) -> Void)? = nil); func stop()   // on the serial "camera.session" queue
}
extension Notification.Name { static let cameraPreviewLayerDidChange: Notification.Name }   // object: AVCaptureSession
struct CameraPreviewView: UIViewRepresentable { init(session: AVCaptureSession, videoGravity: AVLayerVideoGravity = .resizeAspectFill) }
// CHANGED: imageSize (the pipeline's frameSize) is required to map boxes with aspect-fill geometry.
// CHANGED (section 3): optional lead highlight + selection; draw-only (never takes touches, see TrackHitLayer).
struct DetectionOverlayView: View {
    init(tracks: [TrackedObject], imageSize: CGSize, showDistance: Bool, showSpeed: Bool, showLabels: Bool = true,
         lead: LeadVehicle? = nil, leadStatus: DistanceStatus = .unknown, selectedTrackID: Int? = nil)
    static func color(for kind: VehicleKind) -> Color          // = RVTheme.kindColor
    static func titleText(for:) -> String; static func primaryText(for:) -> String; static func makeText(for:) -> String?
    static func confidencePercent(for:) -> Int; static func estimateText(for:showDistance:showSpeed:) -> String?
}
struct RecognitionView: View          // full-screen camera UI; has the corner map button (→ app.switchTo(.navigator))
struct RecognitionStatusView: View { init(pipeline: RecognitionPipeline) }   // status sheet (models, fps, counters, disclaimers)
struct CameraPiPView: View { init(pipeline: RecognitionPipeline) }   // small live camera + boxes, tap → app.switchTo(.camera)
final class VehicleDetector; final class MakeClassifier; enum VehicleMakeNormalizer; final class RecognitionWorker   // internal
// Shared/ components also used by the navigator:
struct SpeedometerView: View {
    init(speedKmh: Double?, limitKmh: Int?, warningTolerance: Double = 5, compact: Bool = false, warningEnabled: Bool = true)
    static func isOverLimit(speedKmh: Double?, limitKmh: Int?, tolerance: Double) -> Bool
}
struct SpeedLimitSignView: View { init(kmh: Int, size: CGFloat = 44) }
struct GlassIconButton: View { init(systemName: String, label: String, size: CGFloat = 52, tint: Color = .white, action: @escaping () -> Void) }
struct RVPressableButtonStyle: ButtonStyle            // added: press feedback (scale/opacity), any background
struct TrafficLightIndicatorView: View { init(color: TrafficLightColor, lampSize: CGFloat = 16, showsCaption: Bool = true)
    static func displayColor(for color: TrafficLightColor) -> Color   // added
    static func estimateCaption(for:) -> String                       // "≈ Красный" (unknown → "Не определён")
    static func estimateAccessibilityLabel(for:) -> String }          // "Светофор: ≈ Красный (оценка камеры)"
struct TrafficLightDotView: View { init(color: TrafficLightColor, size: CGFloat = 14) }   // added
```
The detector model is looked up in the bundle by name, first found wins: `RoadVisionDetector`, `yolo26n`, `yolo11n`,
`yolov8n` (`.mlmodelc`). The make classifier: `VehicleMakeClassifier.mlmodelc`. Missing model → `.missing`, the UI shows
an explanatory banner, the app keeps working (speed, navigator).
Frames are rotated upright by the capture connection (`AVCaptureDevice.RotationCoordinator`; while a preview layer is
attached, the coordinator's *preview* angle is used for the frames too), so Vision always runs with orientation `.up` and
normalized boxes map onto the buffer; the overlay maps them onto the aspect-fill preview with `frameSize`.

### 2.2 Road data services (folder RoadData/)
```swift
@Observable @MainActor final class RoadInfoService {
    init(location: LocationService, settings: AppSettings)
    private(set) var currentRoad: RoadSegmentInfo?
    private(set) var nearbySignals: [SignalLocation]      // from the same roadsAround query
    private(set) var lastUpdate: Date?
    private(set) var isLoading: Bool
    private(set) var lastError: String?
    private(set) var routeFeatures: [RouteFeature]        // for the active route
    private(set) var isLoadingRouteFeatures: Bool
    private(set) var routeFeaturesIncomplete: Bool; private(set) var routeFeaturesCoverageNote: String?   // added
    var onRouteFeaturesChanged: (() -> Void)?             // added (NavigationService rebuilds its timeline)
    var travelHeading: Double? { get }                    // added: GPS course ≥ 5 km/h, else last course ≤ 60 s, else compass
    func start(); func stop()                             // refresh ≈ every 10 s or 60 m, max 1 request in flight;
                                                          // roadsAround radius 40 m (= matcher maxDistance), signals 80 m
    func loadRouteFeatures(polyline: [GeoPoint]) async    // RouteQueryPlanner chunks (≤ 60 pts, ≤ 3 km), sequential, 45 s timeout
    func clearRouteFeatures()
}
actor OverpassClient {                                     // endpoint fallback, 429/504 back-off, User-Agent
    init(primaryEndpoint: String, fallbacks: [String])
    func run(_ query: String, timeout: TimeInterval = 25) async throws -> [OSMElement]   // route queries: routeQueryTimeout = 45
}
@Observable @MainActor final class WeatherService {
    init(location: LocationService)
    private(set) var current: WeatherSnapshot?; private(set) var lastUpdate: Date?; private(set) var lastError: String?
    func start(); func refresh() async                     // every 15 min or 10 km
}
@Observable @MainActor final class TrafficSignalService {
    init(location: LocationService, roadInfo: RoadInfoService, settings: AppSettings)
    struct UpcomingSignal: Identifiable, Hashable { let id: String; let feature: RouteFeature; let distanceAhead: Double; let estimate: SignalWaitEstimate }
    private(set) var routeSignals: [RouteFeature]
    private(set) var observationCount: Int
    var cameraLightColor: TrafficLightColor?               // written by RecognitionPipeline
    func start()                                           // listens to location → StopDetector → SignalStatistics (persisted JSON)
    func setRouteSignals(_ features: [RouteFeature])       // filters kind == .trafficSignals
    func upcoming(fromDistance distanceAlong: Double, limit: Int = 3) -> [UpcomingSignal]
    func totalExpectedWait(fromDistance distanceAlong: Double) -> (count: Int, seconds: Double)
    func estimate(for signalID: String) -> SignalWaitEstimate
    func resetLearnedData()
}
@Observable @MainActor final class IncidentStore {
    init(settings: AppSettings)
    private(set) var incidents: [RoadIncident]            // active only (expired removed), persisted JSON in Application Support
    func report(_ kind: RoadIncidentKind, at coordinate: GeoPoint, note: String? = nil)
    func remove(_ id: UUID)
    func along(route: [GeoPoint], cumulative: [Double]?) -> [IncidentOnRoute]
}
```

### 2.3 Navigator (folder Navigation/) — navigator v2 (multi-source)
Routing facts: Apple's feature-availability page lists Uzbekistan only for "Maps: Satellite" (no Turn-by-Turn/Traffic/Lane
Guidance/Speed Limits); MKDirections may fail there (MKError .placemarkNotFound=4 / .directionsNotFound=5).
`settings.routingEngine`: "auto" (Apple + Valhalla + OSRM queried CONCURRENTLY, each client ≤ 1 req/s; routes merged and
ranked, fastest auto-selected), "apple", "valhalla", "osrm". All sources are free and keyless: Valhalla FOSSGIS
(`Valhalla.defaultEndpoint`: Russian instructions, lanes, alternates, `/trace_attributes`), OSRM FOSSGIS (`OSRM.defaultEndpoint`
= https://routing.openstreetmap.de/routed-car; no text instructions → Russian ones built in core), Overpass (OSM features),
Open-Meteo (weather). FOSSGIS policy: ≤ 1 request/s, identifying User-Agent, OSM attribution + link
https://www.openstreetmap.org/fixthemap, URLs configurable. No free real-time traffic exists for Tashkent — never faked
(MapKit traffic layer where Apple has data; optional user tile template, **https only**; live "congestion on current segment"
= CongestionEstimator(own GPS speed vs typical speed)).

Core additions (Foundation only, tested in `NavigatorV2Tests`):
```swift
// Valhalla.swift (changed, compatible)
public enum RouteSource: String, Codable, Hashable, Sendable, CaseIterable { case apple, valhalla, osrm
    var displayName   // "Apple Maps", "OpenStreetMap (Valhalla)", "OpenStreetMap (OSRM)"
    var badge         // "Apple", "Valhalla", "OSRM"
    var mayIncludeTraffic: Bool; var usesOpenStreetMap: Bool }
RouteEdgeAttributes += surface: String?, use: String?, isToll, isTunnel, isBridge (init params defaulted), length, isPrimaryRoad,
    static roadClassDisplayName(_:), static surfaceDisplayName(_:)      // trace filters += edge.surface/use/toll/tunnel/bridge
Valhalla.arrivalInstruction(instruction:alert:)   // .arrive: verbal_transition_alert_instruction, else "Вы прибыли"→"Вы прибудете"
// OSRM.swift
public struct OSRMError: Error { code: String?; message; russianDescription }
public enum OSRM { defaultEndpoint; routeURL(endpoint:from:to:alternatives:) -> URL?   // polyline6, steps, alternatives, annotations
    parseRoutes(_ data: Data) throws -> [NavRoute]       // source .osrm; step 0 instruction blanked; lanes = intersections[0].lanes
    maneuverType(type:modifier:) -> ManeuverType; instruction(type:modifier:name:exit:rotaryName:) -> String   // Russian
    laneTurn(_ indication:) -> LaneTurn; lanes(from: [OSRMLane]) -> (lanes, valid) }                          // recommended = valid
// RouteComparison.swift
public struct RouteEstimate { source; expectedTravelTime; distance }
public struct RouteChoice { route: NavRoute; duplicates: [RouteEstimate]; sources; timeRange }
public struct RouteFacts { distance, expectedTravelTime, averageSpeedKmh, signalCount, maxSpeedLimitKmh, averageSpeedLimitKmh,
    speedLimitCoverage, primaryRoadShare, unpavedShare, hasTolls, hasHighways, maneuverCount, tunnelCount, bridgeCount }
public enum RouteComparison { samples(_:spacing:); overlap(_:_:spacing:tolerance:); similarity(_:_:tolerance:)
    merge(_ routes:threshold: 0.85, tolerance: 30) -> [RouteChoice]   // fastest first; duplicates folded into the faster one
    facts(for:edges:signalCount:) -> RouteFacts; delayText(_:comparedTo:) -> String?; notes(for:) -> [String] }
// RouteTimeline.swift
public enum RouteTimelineKind { maneuver(ManeuverType), speedLimit(Int?), lanes(from:to:), trafficSignal,
    feature(RouteFeatureKind), incident(RoadIncidentKind), destination; var category: String }
public struct RouteTimelineEvent: Identifiable { id; distanceAlongRoute; kind; title; detail; symbolName; source; coordinate }
public struct SpeedLimitSegment { start; end; limitKmh: Int? }
public enum RouteTimeline { maneuverDistances(steps:totalLength:); build(route:edges:features:incidents:) -> [RouteTimelineEvent]
    upcoming(_:from:limit:); speedLimitSegments(edges:totalDistance:); timeOffset(to:from:remainingTime:totalDistance:edges:) }
// RouteQueryPlanner.swift — Overpass chunks: 10 m simplification, ≤ 60 points AND ≤ 3 km per chunk; maxChunks → droppedChunks
public enum RouteQueryPlanner { plan(route:maxPointsPerChunk:maxChunkLength:tolerance:maxChunks:) -> Plan; chunks(_:maxPoints:maxLength:) }
// RouteFeatures.swift: RouteFeatureKind += .fuel ("АЗС"), .parking ("Парковка"); isPointOfInterest (never announced as hazards)
// OverpassQuery.featuresAlong += nwr[amenity=fuel] (100 m), nwr[amenity=parking][access!~private|no|customers] (60 m)
// RoadMatcher.scoredMatch(elements:position:heading:maxDistance:) -> (road, score)   // stickiness compares scores
```

App layer:
```swift
actor ValhallaClient { init(endpoint:); setEndpoint(_:); static url(endpoint:path:); static userAgent
    func routes(from:to:heading:avoidTolls:avoidHighways:) async throws -> [NavRoute]
    func traceAttributes(polyline:edgeWalk:) async throws -> [RouteEdgeAttributes] }
actor OSRMClient { init(endpoint:); setEndpoint(_:); func routes(from:to:) async throws -> [NavRoute] }   // ≥ 1.1 s spacing, UA
enum OSRMClientError: LocalizedError                                                                        // Russian
struct RouteOption: Identifiable, Hashable {
    let id: Int; var route: NavRoute; var mkRoute: MKRoute?
    var traffic: TrafficAssessment?   // Apple only: calculateETA() now vs next 03:00 (two MKDirections), both distances within 3 %
    var signalCount: Int?; var alsoFoundBy: [RouteEstimate]
    var name, distance, expectedTravelTime, source: RouteSource, sources: [RouteSource] { get }
}
struct RoutingEngineReport: Identifiable { source; status: .success(routes:) | .failed(String) | .notAttempted(String); summary; isSuccess }
enum RoutingEngineOption: String { auto, apple, valhalla, osrm; displayName; sources }
enum NavigatorMapStyle: String { standard, satellite, hybrid; displayName ("Схема"/"Спутник"/"Гибрид"); symbolName }
enum NavigatorSettingsKeys { osrmEndpoint = "rv.osrmEndpoint", mapStyle = "rv.mapStyle", map3D = "rv.map3D" }
extension AppSettings { var osrmEndpoint: String; var navigatorMapStyle: NavigatorMapStyle }   // UserDefaults (NavigatorSettings.swift)
@Observable @MainActor final class NavigationService {
    enum State: Equatable { case idle, planning, previewing, navigating, arrived }
    init(location:speech:roadInfo:signals:incidents:settings:)
    private(set) var state, destination, routeOptions, progress, errorMessage, routeEdges, currentEdge, congestion,
                     upcomingFeatures, incidentsOnRoute, edgeSignalDistances, isLoadingRouteAttributes, routeAttributesError,
                     isRecalculating, averageSpeedKmh, isWaitingAtSignal, distanceToNextSignal
    var destinationName: String? { get }; var selectedRouteID: Int?; var selectedRouteOption: RouteOption? { get }
    private(set) var routingNotice: String?   // actual reason per failed engine, e.g. "Apple: ошибка — … (MKError 5, «…»)"
    private(set) var engineReports: [RoutingEngineReport]; private(set) var comparisonNotes: [String]
    private(set) var optionEdges: [Int: [RouteEdgeAttributes]]   // trace_attributes per option (selected first, then others)
    private(set) var timeline: [RouteTimelineEvent]; private(set) var speedLimitSegments: [SpeedLimitSegment]
    let placeSearch: PlaceSearchService; let routeWeather: RouteWeatherService
    var activeRoute: NavRoute? { get }; var distanceAlong: Double { get }; var routeLength: Double { get }
    func facts(for: RouteOption) -> RouteFacts; func upcomingEvents(limit: Int? = nil) -> [RouteTimelineEvent]
    func timeUntil(_ event: RouteTimelineEvent) -> Double
    func planRoutes(to item: MKMapItem) async; func startNavigation(); func stopNavigation()
    func recalculate() async      // generation-checked: a stale run never clears the newer rerouteTask / isRecalculating
    func refreshIncidents(); func dismissError()
}
@Observable @MainActor final class RouteWeatherService { struct Point { label; coordinate; distanceAlongRoute; snapshot; error }
    private(set) var points: [Point]; private(set) var isLoading: Bool; func load(route: NavRoute); func clear() }   // destination (+ midpoint > 30 km)
@Observable @MainActor final class PlaceSearchService   // unchanged: query, completions, resolve, search, recents API
struct NavigatorView: View; struct NavigationMapView: UIViewRepresentable   // + events, speedLimitSegments, mapStyle, is3D
struct ManeuverBannerView: View { init(progress:isRerouting:lanes:recommendedLanes:laneSource:) }
struct CurrentRoadCard: View { init(nextManeuver: ManeuverType?) }        // collapsible, every value with its source
struct RouteStripView: View { init(totalDistance:distanceAlong:segments:events:showsPosition:height:) }
struct TripInfoPanel: View; struct RouteOptionsView: View; struct RouteComparisonSheet: View; struct TimelineRow: View
struct LaneGuidanceView: View { init(lanes:recommended:); init(laneInfo:maneuver:) }
struct NavigationSettingsSection: View   // «Маршрутизация» (engine, Valhalla + OSRM servers, attributes), «Пробки» (https tiles)
```
Behaviour notes: the selected route always gets Valhalla trace_attributes (edge_walk for Valhalla shapes, map_snap on ≤ 1000
simplified points otherwise); after a reroute the old route's OSM features / signals are cleared synchronously before the
first fix; the signal-wait source reads "по вашим поездкам" only for `.learned`, "частично по поездкам" for `.blended`,
else "модель"; the Overpass client timeout (45 s) exceeds the route query's `[timeout:25]`.
Settings used: routingEngine, valhallaEndpoint, rv.osrmEndpoint, rv.mapStyle, rv.map3D, routeAttributesEnabled,
trafficTileTemplate, showTrafficOnMap, voiceGuidanceEnabled, avoidTolls, avoidHighways, showCameraPiP, speedWarningEnabled,
speedWarningTolerance, signalAssumptions.

### 2.4 Settings (folder Settings/)
```swift
struct SettingsView: View                          // all settings sections (see AppSettings) + data-source disclaimers;
                                                   // embeds the navigator's `NavigationSettingsSection()` (Navigation/)
```

---------------------------------------------------------------------------------------------------
## 3. Following distance to the lead vehicle (camera mode, added after the first iteration)

Core (`FollowingDistance.swift`, written & tested): `RoadSurfaceCondition` (.dry/.wet/.snow/.ice, `from(weatherCode:temperatureC:precipitationMm:)`,
`frictionCoefficient`), `FollowingDistancePolicy` (time gaps per surface, `stoppedGapMeters`, `reactionTimeSeconds`,
`stoppedSpeedKmh`, `collisionWarningSeconds`), `DistanceStatus`, `FollowingDistanceAssessment`,
`FollowingDistanceCalculator.stoppingDistance/recommendedDistance/assess(distanceMeters:ownSpeedKmh:relativeSpeedKmh:policy:condition:)`,
`EgoCorridor` (own-lane trapezoid, `contains(_:)`, `polygon`, `halfWidth(atY:)`), `LeadVehicle`, `LeadVehicleTracker`
(`update(tracks:geometry:timestamp:) -> LeadVehicle?` — closest confirmed vehicle in the corridor, hysteresis, fused width+height
distance, EMA smoothing, relative speed by regression), `VehicleKind.typicalWidthMeters`.
`FollowingDistanceNorms.swift`: `rulesDocument`, `items` (status Норма / Рекомендация / Настройка приложения, source, url), `disclaimer`.
Settings: `followingDistanceEnabled`, `followingTimeGapDry` (wet ×2, snow ×3, ice ×5), `stoppedGapMeters`, `reactionTimeSeconds`,
`roadSurfaceMode` ("auto" | raw surface), `distanceWarningsEnabled`, `showEgoCorridor`, `corridorHorizon`, and
`AppSettings.followingDistancePolicy`.

Pipeline (Detection/). `RecognitionWorker` runs `LeadVehicleTracker` on its queue after tracking + `MonocularSpeedEstimator` every
processed frame (corridor horizon = `settings.corridorHorizon` clamped 0.1…0.8, `CameraGeometry` from the camera FOV + buffer size),
`Inputs.followingDistanceEnabled/corridorHorizon`, `Output.leadVehicle`. The main actor computes the assessment (frames ≤ 15 Hz;
GPS updates refresh it only when no frame arrived for 0.5 s):
```swift
// RecognitionPipeline additions (all nil / unchanged while settings.followingDistanceEnabled == false)
private(set) var leadVehicle: LeadVehicle?                        // bridged for leadHoldSeconds = 0.5 s when a frame misses it
private(set) var followingAssessment: FollowingDistanceAssessment?  // no lead → recommended gap for the current speed, status .unknown
private(set) var roadSurface: RoadSurfaceCondition                 // "auto" → RoadSurfaceCondition.from(weather), else the manual value
private(set) var roadSurfaceSource: RoadSurfaceSource              // .weather | .noWeather (auto, dry assumed) | .manual
private(set) var isForwardCollisionWarning: Bool                   // moving, .danger, TTC < policy.collisionWarningSeconds (unthrottled, visual)
var weatherProvider: (@MainActor () -> WeatherSnapshot?)?          // set by AppState: { [weak weather] in weather?.current }
var speech: SpeechService?                                         // set by AppState (voice warnings)
var egoCorridor: EgoCorridor { get }                               // corridor used by the worker (for drawing)
var followingDistancePolicy: FollowingDistancePolicy { get }       // = settings.followingDistancePolicy
enum RoadSurfaceSource: String, Sendable { case weather, noWeather, manual; var displayName: String }   // "авто", "авто · нет погоды", "вручную"

@MainActor final class DistanceWarningController {                // Detection/DistanceWarningController.swift, owned by the pipeline
    init(speech: SpeechService? = nil); weak var speech: SpeechService?
    static func isForwardCollision(_:policy:) -> Bool; static func isTooClose(_:policy:) -> Bool
    func evaluate(_ assessment: FollowingDistanceAssessment?, leadID: Int?, policy: FollowingDistancePolicy, enabled: Bool, now: Date = Date())
    func reset()
}
// Rules (settings.distanceWarningsEnabled): moving + collision (held ≥ 0.2 s) → error haptic + system sound 1005 +
// speak("Внимание! Опасное сближение", .high), ≤ every 5 s; moving + .danger without imminent TTC (held ≥ 1 s) → light haptic +
// speak("Держите дистанцию", .normal), ≤ every 12 s; standing → only one soft haptic when the gap drops below stoppedGapMeters
// (re-armed when it opens to > 1.3× + 0.3 m or another vehicle becomes the lead). No lead → nothing.
```

UI (Shared/, Detection/, Camera/):
```swift
enum RVTheme {                                     // Shared/RVTheme.swift — design tokens
    static let safe, caution, danger, neutral, accent, recording: Color
    static func statusColor(_: DistanceStatus) -> Color; static func statusGradient(_:) -> LinearGradient; static func statusSymbol(_:) -> String
    static func kindColor(_: VehicleKind) -> Color; static func normColor(_: FollowingDistanceNorms.Status) -> Color
    enum Radius { box, chip, control, panel, card }; enum Stroke { hairline, tentative, box, selected, lead }; enum Spacing { gutter, stack, tight }
    static let glass: Material; static let glassEdge: LinearGradient; static let shadow: Color
    static func font(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font      // .rounded
    static let trackMotion, springIn, snappy: Animation
}
extension View { func rvGlass(cornerRadius:tint:shadow:); func rvGlassCapsule(tint:shadow:); func rvNumeric(_:weight:); func rvPulse(_:minOpacity:period:) }
struct RVBadge: View { init(text: String, color: Color, systemImage: String? = nil) }
struct AspectFillMapping: Equatable {             // Shared/AspectFillMapping.swift — shared by every camera overlay
    init(imageSize: CGSize, viewSize: CGSize); func rect(for: BBox) -> CGRect; func point(x: Double, y: Double) -> CGPoint
    func normalizedPoint(_: CGPoint) -> (x: Double, y: Double)
}
extension RVFormat { static func gapMeters(_: Double?) -> String /* "1,6 м", "18 м", "125 м" */; static func gapSeconds(_: Double?) -> String
                     static func normMeters(_: Double) -> String /* "2 м", "33 м" */; static func compactNumber(_: Double) -> String
                     static func spokenQuantity(_:digits:one:few:many:) -> String }        // Shared/DistanceFormatting.swift
enum FollowingDistanceText { gap(_:), recommended(_:), lineCaption(_:) /* "1,4 с · норма ≥ 33 м" | "норма ≥ 2 м" */,
                             movingNorm(_:policy:) /* "≥ 2 с ≈ 33 м (сухо)" */, stoppedNorm(policy:) /* "≥ 2 м" */, compactNorms(_:policy:),
                             stoppingDistance(_:), timeToCollision(_:), relativeMotion(relativeSpeedKmh:), accessibilitySummary(_:policy:hasLead:) }

struct CornerBracketShape: Shape { var armFraction: CGFloat = 0.26; var cornerRadius: CGFloat = RVTheme.Radius.box }
struct TrackHitLayer: View { init(tracks: [TrackedObject], imageSize: CGSize, selectedTrackID: Binding<Int?>) }  // below the HUD
struct TrackDetailCard: View {                    // tap card: class, make + уверенность, ≈ distance, ≈ speed, age, lead badge, light colour
    init(track: TrackedObject, lead: LeadVehicle?, assessment: FollowingDistanceAssessment?, onClose: @escaping () -> Void)
    static let estimatedSize: CGSize; static func position(for rect: CGRect, in size: CGSize, safeArea: EdgeInsets) -> CGPoint
}
struct LeadDistanceOverlay: View {                // flowing dashed line + chevrons + ground marker + glass label (TimelineView + Canvas)
    init(lead: LeadVehicle, assessment: FollowingDistanceAssessment?, imageSize: CGSize, labelInsets: EdgeInsets = …)
}
struct LeadLineGeometry; final class LeadLineSmoother; enum LeadLineRenderer   // helpers of LeadDistanceOverlay
struct EgoCorridorOverlay: View { init(corridor: EgoCorridor, imageSize: CGSize, tint: Color = .white) }
struct FollowingDistanceHUD: View {               // .full (portrait, above the record button, tap = expand rows) | .mini (landscape, leading column)
    enum Style { case full, mini }
    init(assessment:lead:policy:surfaceSource:isForwardCollisionWarning:style: = .full, onShowNorms:)
    static let expandedKey: String                // "rv.distanceHUDExpanded" (@AppStorage)
}
struct GapProgressBar: View { init(fraction: Double?, color: Color) }   // 0…1.5× with zones and a tick at 1.0
struct DistanceNormsView: View { init(showsDoneButton: Bool = false) }  // rulesDocument, items (+ Link), current thresholds, example table, disclaimer
struct DistanceNormsSheet: View                   // NavigationStack + "Готово"; also pushed from Settings → «Дистанция» → «Требования к дистанции»
```
RecognitionView layers (all `.ignoresSafeArea()`, same mapping): corridor → boxes (lead = thick glowing status-coloured bracket, pulsing on
caution/danger) → distance line → TrackHitLayer; then the HUD; then the detail card; then a red edge glow while
`isForwardCollisionWarning && distanceWarningsEnabled`. CameraPiPView: lead bracket in status colour + "≈ 18 м" badge (bottom-left).
Honesty: distances "≈ … (оценка)", detector scores "уверенность"; norms labelled Норма / Рекомендация / Настройка приложения.

---------------------------------------------------------------------------------------------------
## 4. Project, resources and models (added by the project-files slice)
- `RoadVision.xcodeproj` (objectVersion 77): one app target `RoadVision`, two synchronized folders —
  `RoadVision/` (app) and `Packages/RoadVisionCore/Sources/RoadVisionCore` (core). Any file added there is built
  automatically; non-Swift files in `RoadVision/` are copied into the bundle as resources, so do NOT add extra
  README/markdown/JSON files there (duplicate resource names break the build). `RoadVision/Models/README.md` is
  excluded via a membership exception in the project.
- `Config/Info.plist` (outside the synced folder) holds UIBackgroundModes [location, audio], `UIFileSharingEnabled`,
  `LSSupportsOpeningDocumentsInPlace`. Usage descriptions (camera, location only — no microphone, speech recognition or
  local network) and the rest come from `INFOPLIST_KEY_*` build settings.
- Asset catalog: `AppIcon`, `AccentColor` (asset symbol generation is on → do not declare your own `Color.accent` /
  `ColorResource.accent`).
- Core ML model classes are NOT generated (`COREML_CODEGEN_LANGUAGE = None`): load models by bundle resource name
  (`Bundle.main.url(forResource: "RoadVisionDetector", withExtension: "mlmodelc")`). Still avoid naming Swift types
  `RoadVisionDetector*` / `VehicleMakeClassifier*` so the project keeps working if someone re-enables generation.
- `RoadVision/Models/RoadVisionDetector.mlpackage` (present): YOLO11n COCO-80, 640×640 RGB image input named `image`,
  pipeline mlProgram(FP16) → NonMaximumSuppression; optional Double inputs `iouThreshold` (default 0.45) and
  `confidenceThreshold` (default 0.25); outputs `confidence` [N×80] and `coordinates` [N×4] (normalized x,y,w,h) →
  Vision returns `VNRecognizedObjectObservation` with COCO labels ("car", "traffic light", …).
