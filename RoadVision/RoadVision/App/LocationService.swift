import CoreLocation
import Foundation
import Observation

/// GPS position, speed and heading. Shared by recognition (own speed), navigator and road-data services.
@Observable
@MainActor
final class LocationService: NSObject {
    private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var location: CLLocation?
    /// Own speed from GPS, km/h; nil while the fix has no valid speed.
    private(set) var speedKmh: Double?
    /// GPS course over ground, degrees; nil when invalid (e.g. standing still).
    private(set) var course: Double?
    /// Compass heading (true north when available), degrees.
    private(set) var heading: Double?
    private(set) var isRunning = false

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var listeners: [UUID: (CLLocation) -> Void] = [:]

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.headingFilter = 2
        manager.pausesLocationUpdatesAutomatically = false
    }

    var coordinate: GeoPoint? { location.map { GeoPoint($0.coordinate) } }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    /// Best travel direction: GPS course while moving, otherwise compass heading.
    var travelDirection: Double? {
        if let course, (speedKmh ?? 0) >= 5 { return course }
        return heading ?? course
    }

    func requestPermission() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    /// Keeps GPS running while the app is in background (active navigation only).
    /// Requires `UIBackgroundModes = location` in Info.plist (present in this project).
    func setBackgroundUpdates(_ enabled: Bool) {
        manager.allowsBackgroundLocationUpdates = enabled
        manager.showsBackgroundLocationIndicator = enabled
    }

    /// Registers a callback invoked on the main actor for every new location fix.
    @discardableResult
    func addListener(_ handler: @escaping (CLLocation) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = handler
        return id
    }

    func removeListener(_ id: UUID) {
        listeners[id] = nil
    }

    private func handle(_ newLocation: CLLocation) {
        // Ignore stale or very inaccurate fixes.
        guard newLocation.horizontalAccuracy >= 0, newLocation.horizontalAccuracy < 200,
              abs(newLocation.timestamp.timeIntervalSinceNow) < 15 else { return }
        location = newLocation
        speedKmh = newLocation.speed >= 0 ? newLocation.speed * 3.6 : nil
        if newLocation.course >= 0, newLocation.courseAccuracy >= 0 || newLocation.speed > 1.5 {
            course = newLocation.course
        } else if (speedKmh ?? 0) < 3 {
            course = nil
        }
        for handler in listeners.values {
            handler(newLocation)
        }
    }
}

extension LocationService: CLLocationManagerDelegate {
    // CLLocationManager calls its delegate on the thread it was created on (the main thread here).
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        MainActor.assumeIsolated {
            self.handle(last)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let value = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        guard newHeading.headingAccuracy >= 0 else { return }
        MainActor.assumeIsolated {
            self.heading = value
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            self.authorizationStatus = status
            if self.isRunning, status == .authorizedWhenInUse || status == .authorizedAlways {
                manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient errors (kCLErrorLocationUnknown) are expected; the manager keeps trying.
    }
}
