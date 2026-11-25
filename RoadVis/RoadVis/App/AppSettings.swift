import Foundation
import Observation

/// User preferences, persisted in UserDefaults.
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    // MARK: Recognition
    /// Minimum detector confidence (model score, not accuracy).
    var detectionConfidence: Double { didSet { defaults.set(detectionConfidence, forKey: Keys.detectionConfidence) } }
    /// IoU threshold for non-maximum suppression (used only when the model has no built-in NMS).
    var nmsIoUThreshold: Double { didSet { defaults.set(nmsIoUThreshold, forKey: Keys.nmsIoUThreshold) } }
    var makeRecognitionEnabled: Bool { didSet { defaults.set(makeRecognitionEnabled, forKey: Keys.makeRecognitionEnabled) } }
    var showDistanceEstimates: Bool { didSet { defaults.set(showDistanceEstimates, forKey: Keys.showDistanceEstimates) } }
    var showSpeedEstimates: Bool { didSet { defaults.set(showSpeedEstimates, forKey: Keys.showSpeedEstimates) } }
    var trackPedestrians: Bool { didSet { defaults.set(trackPedestrians, forKey: Keys.trackPedestrians) } }
    var detectTrafficLights: Bool { didSet { defaults.set(detectTrafficLights, forKey: Keys.detectTrafficLights) } }
    /// Save per-frame detections and unique-vehicle summary to CSV for research.
    var recordExperimentLog: Bool { didSet { defaults.set(recordExperimentLog, forKey: Keys.recordExperimentLog) } }

    // MARK: Following distance (lead vehicle)
    var followingDistanceEnabled: Bool { didSet { defaults.set(followingDistanceEnabled, forKey: Keys.followingDistanceEnabled) } }
    /// Recommended time gap on a dry road, seconds (wet/snow/ice are derived ×2/×3/×5).
    var followingTimeGapDry: Double { didSet { defaults.set(followingTimeGapDry, forKey: Keys.followingTimeGapDry) } }
    /// Recommended gap when standing in a queue / at a light, metres.
    var stoppedGapMeters: Double { didSet { defaults.set(stoppedGapMeters, forKey: Keys.stoppedGapMeters) } }
    /// Driver reaction time for the stopping-distance estimate, seconds.
    var reactionTimeSeconds: Double { didSet { defaults.set(reactionTimeSeconds, forKey: Keys.reactionTimeSeconds) } }
    /// "auto" (from weather) or a RoadSurfaceCondition raw value.
    var roadSurfaceMode: String { didSet { defaults.set(roadSurfaceMode, forKey: Keys.roadSurfaceMode) } }
    /// Haptic + sound + voice warnings for unsafe distance / forward collision.
    var distanceWarningsEnabled: Bool { didSet { defaults.set(distanceWarningsEnabled, forKey: Keys.distanceWarningsEnabled) } }
    /// Draw the own-lane corridor used to pick the lead vehicle.
    var showEgoCorridor: Bool { didSet { defaults.set(showEgoCorridor, forKey: Keys.showEgoCorridor) } }
    /// Horizon line for the lane corridor (fraction of the frame height) — depends on how the phone is mounted.
    var corridorHorizon: Double { didSet { defaults.set(corridorHorizon, forKey: Keys.corridorHorizon) } }

    // MARK: Navigation
    var voiceGuidanceEnabled: Bool { didSet { defaults.set(voiceGuidanceEnabled, forKey: Keys.voiceGuidanceEnabled) } }
    var avoidTolls: Bool { didSet { defaults.set(avoidTolls, forKey: Keys.avoidTolls) } }
    var avoidHighways: Bool { didSet { defaults.set(avoidHighways, forKey: Keys.avoidHighways) } }
    /// Keep a small live camera window (with recognition) on top of the navigator.
    var showCameraPiP: Bool { didSet { defaults.set(showCameraPiP, forKey: Keys.showCameraPiP) } }
    var showTrafficOnMap: Bool { didSet { defaults.set(showTrafficOnMap, forKey: Keys.showTrafficOnMap) } }
    /// Load road attributes (lanes, speed limits, signals, hazards) from OpenStreetMap via Overpass API.
    var roadDataEnabled: Bool { didSet { defaults.set(roadDataEnabled, forKey: Keys.roadDataEnabled) } }
    var overpassEndpoint: String { didSet { defaults.set(overpassEndpoint, forKey: Keys.overpassEndpoint) } }
    var speedWarningEnabled: Bool { didSet { defaults.set(speedWarningEnabled, forKey: Keys.speedWarningEnabled) } }
    /// km/h above the limit before the speed warning fires.
    var speedWarningTolerance: Double { didSet { defaults.set(speedWarningTolerance, forKey: Keys.speedWarningTolerance) } }
    /// Lifetime of user-reported incidents, minutes.
    var incidentLifetimeMinutes: Double { didSet { defaults.set(incidentLifetimeMinutes, forKey: Keys.incidentLifetimeMinutes) } }
    /// Routing engine: "auto" (Apple Maps, falls back to Valhalla/OSM on error), "apple" or "valhalla".
    var routingEngine: String { didSet { defaults.set(routingEngine, forKey: Keys.routingEngine) } }
    /// Valhalla server base URL (public FOSSGIS instance by default — light use only).
    var valhallaEndpoint: String { didSet { defaults.set(valhallaEndpoint, forKey: Keys.valhallaEndpoint) } }
    /// Load speed limits / lane counts / signals along the route from Valhalla trace_attributes.
    var routeAttributesEnabled: Bool { didSet { defaults.set(routeAttributesEnabled, forKey: Keys.routeAttributesEnabled) } }
    /// Optional raster traffic tile URL template with {z}/{x}/{y} (e.g. a provider you have a key for). Empty = off.
    var trafficTileTemplate: String { didSet { defaults.set(trafficTileTemplate, forKey: Keys.trafficTileTemplate) } }

    // MARK: Traffic signals (model assumptions when no learned data exists)
    var signalCycleSeconds: Double { didSet { defaults.set(signalCycleSeconds, forKey: Keys.signalCycleSeconds) } }
    var signalGreenRatio: Double { didSet { defaults.set(signalGreenRatio, forKey: Keys.signalGreenRatio) } }
    var learnSignalTimings: Bool { didSet { defaults.set(learnSignalTimings, forKey: Keys.learnSignalTimings) } }

    // MARK: Trips (recording + report)
    /// Start a trip recording automatically when «Поехали» is pressed.
    var tripAutoRecord: Bool { didSet { defaults.set(tripAutoRecord, forKey: Keys.tripAutoRecord) } }
    /// Also record the camera research CSV (`RecognitionPipeline.startRecording()`) during a trip.
    var tripRecordCameraCSV: Bool { didSet { defaults.set(tripRecordCameraCSV, forKey: Keys.tripRecordCameraCSV) } }
    /// km/h above the limit that still counts as within the limit (trip report).
    var tripSpeedToleranceKmh: Double { didSet { defaults.set(tripSpeedToleranceKmh, forKey: Keys.tripSpeedToleranceKmh) } }
    /// Minimum duration of a speeding episode, seconds (≥ 5).
    var tripSpeedingMinSeconds: Double { didSet { defaults.set(tripSpeedingMinSeconds, forKey: Keys.tripSpeedingMinSeconds) } }
    /// Harsh braking threshold, m/s² (stored as a positive deceleration).
    var tripHarshBrakingMps2: Double { didSet { defaults.set(tripHarshBrakingMps2, forKey: Keys.tripHarshBrakingMps2) } }
    /// Harsh acceleration threshold, m/s².
    var tripHarshAccelerationMps2: Double { didSet { defaults.set(tripHarshAccelerationMps2, forKey: Keys.tripHarshAccelerationMps2) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func double(_ key: String, _ fallback: Double) -> Double {
            defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
        }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        func string(_ key: String, _ fallback: String) -> String {
            defaults.string(forKey: key) ?? fallback
        }
        detectionConfidence = double(Keys.detectionConfidence, 0.35)
        nmsIoUThreshold = double(Keys.nmsIoUThreshold, 0.45)
        makeRecognitionEnabled = bool(Keys.makeRecognitionEnabled, true)
        showDistanceEstimates = bool(Keys.showDistanceEstimates, true)
        showSpeedEstimates = bool(Keys.showSpeedEstimates, true)
        trackPedestrians = bool(Keys.trackPedestrians, true)
        detectTrafficLights = bool(Keys.detectTrafficLights, true)
        recordExperimentLog = bool(Keys.recordExperimentLog, false)
        followingDistanceEnabled = bool(Keys.followingDistanceEnabled, true)
        followingTimeGapDry = double(Keys.followingTimeGapDry, 2)
        stoppedGapMeters = double(Keys.stoppedGapMeters, 2)
        reactionTimeSeconds = double(Keys.reactionTimeSeconds, 1)
        roadSurfaceMode = string(Keys.roadSurfaceMode, "auto")
        distanceWarningsEnabled = bool(Keys.distanceWarningsEnabled, true)
        showEgoCorridor = bool(Keys.showEgoCorridor, false)
        corridorHorizon = double(Keys.corridorHorizon, 0.42)

        voiceGuidanceEnabled = bool(Keys.voiceGuidanceEnabled, true)
        avoidTolls = bool(Keys.avoidTolls, false)
        avoidHighways = bool(Keys.avoidHighways, false)
        showCameraPiP = bool(Keys.showCameraPiP, true)
        showTrafficOnMap = bool(Keys.showTrafficOnMap, true)
        roadDataEnabled = bool(Keys.roadDataEnabled, true)
        overpassEndpoint = string(Keys.overpassEndpoint, AppSettings.defaultOverpassEndpoint)
        speedWarningEnabled = bool(Keys.speedWarningEnabled, true)
        speedWarningTolerance = double(Keys.speedWarningTolerance, 5)
        incidentLifetimeMinutes = double(Keys.incidentLifetimeMinutes, 120)
        routingEngine = string(Keys.routingEngine, "auto")
        valhallaEndpoint = string(Keys.valhallaEndpoint, Valhalla.defaultEndpoint)
        routeAttributesEnabled = bool(Keys.routeAttributesEnabled, true)
        trafficTileTemplate = string(Keys.trafficTileTemplate, "")

        signalCycleSeconds = double(Keys.signalCycleSeconds, 90)
        signalGreenRatio = double(Keys.signalGreenRatio, 0.45)
        learnSignalTimings = bool(Keys.learnSignalTimings, true)

        tripAutoRecord = bool(Keys.tripAutoRecord, true)
        tripRecordCameraCSV = bool(Keys.tripRecordCameraCSV, false)
        tripSpeedToleranceKmh = double(Keys.tripSpeedToleranceKmh, 5)
        tripSpeedingMinSeconds = max(5, double(Keys.tripSpeedingMinSeconds, 5))
        tripHarshBrakingMps2 = double(Keys.tripHarshBrakingMps2, 3.5)
        tripHarshAccelerationMps2 = double(Keys.tripHarshAccelerationMps2, 3.0)
    }

    static let defaultOverpassEndpoint = "https://overpass-api.de/api/interpreter"

    /// Public Overpass instances that can be chosen in Settings (and used as fallbacks).
    static let overpassEndpoints = [
        "https://overpass-api.de/api/interpreter",
        "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
        "https://overpass.private.coffee/api/interpreter",
    ]

    /// Following-distance policy from the settings (wet ×2, snow ×3, ice ×5 of the dry time gap — UK Highway Code 126: ×2 wet, up to ×10 ice).
    var followingDistancePolicy: FollowingDistancePolicy {
        FollowingDistancePolicy(timeGapDry: followingTimeGapDry, timeGapWet: followingTimeGapDry * 2,
                                timeGapSnow: followingTimeGapDry * 3, timeGapIce: followingTimeGapDry * 5,
                                stoppedGapMeters: stoppedGapMeters, reactionTimeSeconds: reactionTimeSeconds)
    }

    /// Thresholds for trip events (stored with every trip).
    var tripThresholds: TripThresholds {
        TripThresholds(speedToleranceKmh: tripSpeedToleranceKmh, speedingMinSeconds: tripSpeedingMinSeconds,
                       harshBrakingMps2: -tripHarshBrakingMps2, harshAccelerationMps2: tripHarshAccelerationMps2)
    }

    var signalAssumptions: SignalTimingAssumptions {
        SignalTimingAssumptions(cycleSeconds: signalCycleSeconds, greenRatio: signalGreenRatio)
    }

    private enum Keys {
        static let detectionConfidence = "rv.detectionConfidence"
        static let nmsIoUThreshold = "rv.nmsIoUThreshold"
        static let makeRecognitionEnabled = "rv.makeRecognitionEnabled"
        static let showDistanceEstimates = "rv.showDistanceEstimates"
        static let showSpeedEstimates = "rv.showSpeedEstimates"
        static let trackPedestrians = "rv.trackPedestrians"
        static let detectTrafficLights = "rv.detectTrafficLights"
        static let recordExperimentLog = "rv.recordExperimentLog"
        static let followingDistanceEnabled = "rv.followingDistanceEnabled"
        static let followingTimeGapDry = "rv.followingTimeGapDry"
        static let stoppedGapMeters = "rv.stoppedGapMeters"
        static let reactionTimeSeconds = "rv.reactionTimeSeconds"
        static let roadSurfaceMode = "rv.roadSurfaceMode"
        static let distanceWarningsEnabled = "rv.distanceWarningsEnabled"
        static let showEgoCorridor = "rv.showEgoCorridor"
        static let corridorHorizon = "rv.corridorHorizon"
        static let voiceGuidanceEnabled = "rv.voiceGuidanceEnabled"
        static let avoidTolls = "rv.avoidTolls"
        static let avoidHighways = "rv.avoidHighways"
        static let showCameraPiP = "rv.showCameraPiP"
        static let showTrafficOnMap = "rv.showTrafficOnMap"
        static let roadDataEnabled = "rv.roadDataEnabled"
        static let overpassEndpoint = "rv.overpassEndpoint"
        static let speedWarningEnabled = "rv.speedWarningEnabled"
        static let speedWarningTolerance = "rv.speedWarningTolerance"
        static let incidentLifetimeMinutes = "rv.incidentLifetimeMinutes"
        static let routingEngine = "rv.routingEngine"
        static let valhallaEndpoint = "rv.valhallaEndpoint"
        static let routeAttributesEnabled = "rv.routeAttributesEnabled"
        static let trafficTileTemplate = "rv.trafficTileTemplate"
        static let signalCycleSeconds = "rv.signalCycleSeconds"
        static let signalGreenRatio = "rv.signalGreenRatio"
        static let learnSignalTimings = "rv.learnSignalTimings"
        static let tripAutoRecord = "rv.tripAutoRecord"
        static let tripRecordCameraCSV = "rv.tripRecordCameraCSV"
        static let tripSpeedToleranceKmh = "rv.tripSpeedToleranceKmh"
        static let tripSpeedingMinSeconds = "rv.tripSpeedingMinSeconds"
        static let tripHarshBrakingMps2 = "rv.tripHarshBrakingMps2"
        static let tripHarshAccelerationMps2 = "rv.tripHarshAccelerationMps2"
    }
}
