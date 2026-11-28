import CoreLocation
import CoreMotion
import Foundation
import Observation

/// Records a trip in the background: ≈ 1 track point per second (time, position, GPS speed, speed limit, ≈ lead
/// gap), A and B, the route polyline and driving events.
///
/// Events: speeding (GPS speed > limit + tolerance for ≥ 5 s, `SpeedingDetector`), harsh braking / acceleration
/// (GPS speed derivative, confirmed by `CMDeviceMotion.userAcceleration` — no permission needed,
/// `HarshMotionDetector`), plus camera events delivered through `ingest(_:)` (wired by `AppState` to
/// `RecognitionPipeline.onDrivingEvent`). Everything goes through `DrivingEventDebouncer`.
/// Optionally starts the camera research CSV (`RecognitionPipeline.startRecording()`) for the trip (setting
/// «CSV камеры во время поездки» or «Журнал для исследования»). Recording has no on-screen controls: `AppState`
/// starts / stops it automatically (setting «Фоновая запись поездок»), Settings → Поездки offers manual control.
/// The in-progress trip is autosaved every 60 s, so a killed app still leaves its trip in the history.
@Observable
@MainActor
final class TripRecorder {
    private(set) var isRecording = false
    /// True while `stop` finalises (geocoding B, writing the CSV files).
    private(set) var isFinishing = false
    private(set) var startedAt: Date?
    private(set) var liveDistanceMeters: Double = 0
    private(set) var liveEventCount = 0
    private(set) var lastEvent: DrivingEvent?
    /// True when the current recording was started by «Поехали».
    private(set) var startedWithNavigation = false

    /// Minimum interval between stored track points.
    static let pointInterval: TimeInterval = 0.9
    /// Fixes with a worse horizontal accuracy are ignored.
    static let maxAccuracy: Double = 65
    static let autosaveInterval: TimeInterval = 60
    /// Simplified route polyline size.
    static let maxRoutePoints = 600

    @ObservationIgnored private let location: LocationService
    @ObservationIgnored private let roadInfo: RoadInfoService
    @ObservationIgnored private let navigation: NavigationService
    @ObservationIgnored private let recognition: RecognitionPipeline
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let store: TripStore

    @ObservationIgnored private var trip: Trip?
    @ObservationIgnored private var debouncer = DrivingEventDebouncer()
    @ObservationIgnored private var speeding = SpeedingDetector()
    @ObservationIgnored private var harsh = HarshMotionDetector()
    @ObservationIgnored private var listenerID: UUID?
    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private var smoothedMotion: Double?
    @ObservationIgnored private var lastAcceptedPoint: TripPoint?
    @ObservationIgnored private var lastAutosave = Date.distantPast
    @ObservationIgnored private var startedCameraCSV = false
    @ObservationIgnored private var routeSignature: (count: Int, first: GeoPoint?)?

    init(location: LocationService, roadInfo: RoadInfoService, navigation: NavigationService,
         recognition: RecognitionPipeline, settings: AppSettings, store: TripStore) {
        self.location = location
        self.roadInfo = roadInfo
        self.navigation = navigation
        self.recognition = recognition
        self.settings = settings
        self.store = store
    }

    /// Called on the main actor right after a recording started (e.g. the continuous-learning per-trip counter).
    @ObservationIgnored var onStarted: (() -> Void)?
    /// Called on the main actor when a recording was finalised and saved to the history (driver-cabinet upload).
    @ObservationIgnored var onFinished: ((Trip) -> Void)?

    /// Id of the trip being recorded.
    var currentTripID: UUID? { trip?.id }

    // MARK: - Start / stop

    /// Starts a recording (no-op while one is running). `withNavigation` = started by «Поехали».
    func start(withNavigation: Bool) {
        guard !isRecording, !isFinishing else { return }
        let thresholds = settings.tripThresholds
        let now = Date()
        var newTrip = Trip(startedAt: now, origin: TripEndpoint(coordinate: location.coordinate),
                           thresholds: thresholds, startedWithNavigation: withNavigation)
        if navigation.state == .navigating || navigation.state == .previewing {
            if let destination = navigation.destination {
                newTrip.destination = TripEndpoint(name: navigation.destinationName,
                                                   coordinate: GeoPoint(destination.placemark.coordinate))
            }
        }
        trip = newTrip
        debouncer = DrivingEventDebouncer()
        speeding = SpeedingDetector(thresholds: thresholds)
        harsh = HarshMotionDetector(thresholds: thresholds)
        smoothedMotion = nil
        lastAcceptedPoint = nil
        routeSignature = nil
        lastAutosave = now
        captureRoute()

        isRecording = true
        startedWithNavigation = withNavigation
        startedAt = now
        onStarted?()
        liveDistanceMeters = 0
        liveEventCount = 0
        lastEvent = nil

        location.start()
        location.setBackgroundUpdates(true)
        listenerID = location.addListener { [weak self] fix in
            self?.handleFix(fix)
        }
        startMotion()

        // The research CSV («Журнал для исследования» / «CSV камеры во время поездки») follows the trip recording.
        startedCameraCSV = false
        syncCameraCSV()
        if let fix = location.location, Date().timeIntervalSince(fix.timestamp) < 5 {
            handleFix(fix)
        }
        let id = newTrip.id
        if let origin = location.location {
            Task { [weak self] in
                let name = await TripRecorder.placeName(for: origin)
                guard let self, var current = self.trip, current.id == id, current.origin.name == nil else { return }
                current.origin.name = name
                self.trip = current
            }
        }
        store.persist(newTrip)
    }

    /// Stops the recording, finalises B and saves the trip. Returns nil when nothing was recorded
    /// (fewer than 2 track points); such a trip is discarded.
    func stop(arrived: Bool = false) async -> Trip? {
        guard isRecording, var finished = trip else { return nil }
        isRecording = false
        isFinishing = true
        defer { isFinishing = false }
        if let listenerID { location.removeListener(listenerID) }
        listenerID = nil
        motion.stopDeviceMotionUpdates()
        if navigation.state != .navigating {
            location.setBackgroundUpdates(false)
        }
        captureRoute()
        finished = trip ?? finished
        finished.endedAt = Date()
        finished.arrived = arrived
        finished.events = debouncer.events
        if finished.destination == nil, let last = finished.points.last {
            finished.destination = TripEndpoint(coordinate: last.coordinate)
        }
        if finished.origin.coordinate == nil {
            finished.origin.coordinate = finished.points.first?.coordinate
        }
        // The finished state goes to disk before anything is awaited: stopping usually happens when the app goes to
        // the background, and it may be suspended / killed during the slow steps below.
        trip = finished
        let hasTrack = finished.points.count >= 2
        if hasTrack { store.persist(finished) }
        // The research log lives in memory until it is finished, so it comes before the (up to 8 s) geocoding.
        if startedCameraCSV {
            startedCameraCSV = false
            let urls = await recognition.finishRecording()
            finished.cameraCSVFiles = urls.map(\.lastPathComponent)
            // The address of A may have arrived during the await (geocoding task of `start`): keep it before the
            // local copy overwrites `trip`.
            if finished.origin.name == nil { finished.origin.name = trip?.origin.name }
            trip = finished
            if hasTrack { store.persist(finished) }
        }
        if hasTrack {
            // The address of A may have arrived meanwhile (geocoding task of `start`).
            if finished.origin.name == nil { finished.origin.name = trip?.origin.name }
            // B gets an address only when it has no name (manual trips); the geocoder is given ≤ 4 s.
            if finished.destination?.name == nil, let coordinate = finished.destination?.coordinate {
                finished.destination?.name = await TripRecorder.placeName(for: coordinate.clLocation, timeout: 4)
                // …or during this await.
                if finished.origin.name == nil { finished.origin.name = trip?.origin.name }
            }
            if finished.origin.name == nil, let coordinate = finished.origin.coordinate {
                finished.origin.name = await TripRecorder.placeName(for: coordinate.clLocation, timeout: 4)
            }
        }
        trip = nil
        startedAt = nil
        guard hasTrack else {
            store.delete(finished.id)
            return nil
        }
        store.save(finished)
        onFinished?(finished)
        return finished
    }

    /// Adds an event from another source (camera). Missing position / speed are filled from GPS.
    func ingest(_ event: DrivingEvent) {
        guard isRecording, trip != nil else { return }
        var event = event
        if event.coordinate == nil { event.coordinate = location.coordinate }
        if event.speedKmh == nil { event.speedKmh = location.speedKmh }
        add(event)
    }

    /// Re-asserts background location while recording (navigation turns it off on arrival / stop).
    func keepBackgroundUpdatesIfNeeded() {
        if isRecording { location.setBackgroundUpdates(true) }
    }

    /// «Поехали» pressed while an automatically started recording is running: the trip becomes a navigation trip
    /// (arrival / cancelled guidance end it) and takes the route and destination of the navigator.
    func adoptNavigation() {
        guard isRecording, trip != nil else { return }
        startedWithNavigation = true
        trip?.startedWithNavigation = true
        if let destination = navigation.destination {
            trip?.destination = TripEndpoint(name: navigation.destinationName,
                                             coordinate: GeoPoint(destination.placemark.coordinate))
        }
        captureRoute()
    }

    /// Applies «Журнал для исследования» / «CSV камеры во время поездки» to a trip that is already being recorded.
    /// Only starts the log: a running one goes on to the end of the trip, so the trip's file list stays complete.
    func syncCameraCSV() {
        guard isRecording, !isFinishing, !startedCameraCSV, !recognition.isRecording,
              settings.tripRecordCameraCSV || settings.recordExperimentLog else { return }
        recognition.startRecording()
        startedCameraCSV = true
    }

    /// The app is being terminated: writes the trip synchronously on the calling thread (a `Task` would never run —
    /// the process exits when the notification handler returns). The camera research log cannot be saved here.
    func flushOnTerminate() {
        guard var current = trip, current.points.count >= 2 else { return }
        if isRecording {
            current.events = debouncer.events
        }
        if current.endedAt == nil { current.endedAt = Date() }
        if current.destination == nil, let last = current.points.last {
            current.destination = TripEndpoint(coordinate: last.coordinate)
        }
        guard let data = try? JSONEncoder().encode(current), let url = try? TripStore.fileURL(for: current.id) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Samples

    private func handleFix(_ fix: CLLocation) {
        guard isRecording, var current = trip else { return }
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= Self.maxAccuracy else { return }
        let position = GeoPoint(fix.coordinate)
        guard position.isValid else { return }
        let speed: Double? = fix.speed >= 0 ? fix.speed * 3.6 : nil
        let limit = currentSpeedLimit()
        let lead = settings.followingDistanceEnabled ? recognition.leadVehicle?.distanceMeters : nil
        let recommended = settings.followingDistanceEnabled
            ? recognition.followingAssessment?.recommendedDistanceMeters : nil

        if let previous = lastAcceptedPoint, fix.timestamp.timeIntervalSince(previous.date) < Self.pointInterval {
            // Too soon for a new track point; detectors still see the fix below.
        } else {
            let point = TripPoint(date: fix.timestamp, coordinate: position, speedKmh: speed, speedLimitKmh: limit,
                                  leadDistanceMeters: lead, recommendedGapMeters: recommended,
                                  horizontalAccuracy: fix.horizontalAccuracy)
            if let previous = lastAcceptedPoint {
                let dt = point.date.timeIntervalSince(previous.date)
                let step = Geo.distance(previous.coordinate, position)
                if dt > 0, step / dt < 70 { liveDistanceMeters += step }
            }
            current.points.append(point)
            lastAcceptedPoint = point
            if current.origin.coordinate == nil { current.origin.coordinate = position }
        }
        trip = current

        if let event = speeding.update(date: fix.timestamp, speedKmh: speed, limitKmh: limit, coordinate: position) {
            add(event)
        }
        if let speed, let event = harsh.addSpeed(date: fix.timestamp, speedKmh: speed, coordinate: position) {
            add(event)
        }
        captureRoute()
        if fix.timestamp.timeIntervalSince(lastAutosave) >= Self.autosaveInterval, let snapshot = trip {
            lastAutosave = fix.timestamp
            var copy = snapshot
            copy.events = debouncer.events
            store.persist(copy)
        }
    }

    /// Limit of the route edge (Valhalla, during guidance), else of the OpenStreetMap road.
    private func currentSpeedLimit() -> Int? {
        if navigation.state == .navigating, let limit = navigation.currentEdge?.speedLimitKmh { return limit }
        return roadInfo.currentRoad?.speedLimit?.kmh
    }

    private func add(_ event: DrivingEvent) {
        let isNew = debouncer.add(event)
        trip?.events = debouncer.events
        liveEventCount = debouncer.events.count
        if isNew { lastEvent = event }
    }

    /// Keeps the latest non-empty route polyline of the navigator (simplified), with its engine badge.
    private func captureRoute() {
        guard trip != nil, navigation.state == .navigating || navigation.state == .previewing,
              let option = navigation.selectedRouteOption else { return }
        let polyline = option.route.polyline
        guard !polyline.isEmpty else { return }
        if let signature = routeSignature, signature.count == polyline.count, signature.first == polyline.first {
            return
        }
        routeSignature = (polyline.count, polyline.first)
        trip?.routePolyline = Geo.simplify(polyline, maxPoints: Self.maxRoutePoints)
        trip?.routeSource = option.source.badge
        if trip?.destination == nil, let destination = navigation.destination {
            trip?.destination = TripEndpoint(name: navigation.destinationName,
                                             coordinate: GeoPoint(destination.placemark.coordinate))
        }
    }

    // MARK: - Motion sensors

    private func startMotion() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            let a = data.userAcceleration
            let magnitude = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot() * 9.80665
            let date = Date()
            MainActor.assumeIsolated {
                self?.handleMotion(magnitude: magnitude, date: date)
            }
        }
    }

    private func handleMotion(magnitude: Double, date: Date) {
        guard isRecording else { return }
        // Short low-pass (≈ 0.25 s) against vibration spikes of the phone mount.
        let smoothed = (smoothedMotion ?? magnitude) * 0.6 + magnitude * 0.4
        smoothedMotion = smoothed
        harsh.addMotion(date: date, magnitude: smoothed)
    }

    // MARK: - Geocoding

    /// Street + house, else locality, else nil. Never throws; returns nil after `timeout` seconds.
    nonisolated static func placeName(for location: CLLocation, timeout: TimeInterval = 8) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                let geocoder = CLGeocoder()
                guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else { return nil }
                let street = [placemark.thoroughfare, placemark.subThoroughfare].compactMap { $0 }.joined(separator: " ")
                if !street.isEmpty { return street }
                return placemark.name ?? placemark.locality
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
