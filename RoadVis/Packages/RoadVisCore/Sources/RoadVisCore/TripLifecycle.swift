import Foundation

public extension Trip {
    /// Unfinished trip without a usable track: the placeholder written when a recording starts and never replaced
    /// by an autosave or a finished trip (the app was killed early). Such a trip is not shown in the history.
    var isEmptyPlaceholder: Bool { endedAt == nil && points.count < 2 }

    /// Age after which an empty placeholder cannot belong to a recording that has just started in this launch.
    static let stalePlaceholderAge: TimeInterval = 300

    /// True when the file of this empty placeholder may be deleted.
    func isStalePlaceholder(now: Date) -> Bool {
        isEmptyPlaceholder && now.timeIntervalSince(startedAt) > Trip.stalePlaceholderAge
    }
}

/// Decides when an automatically recorded trip ends because the car stands still.
///
/// Standing time is counted only from a valid GPS speed. A GPS outage (tunnel, underground road: no fresh fix or a
/// fix without speed, `speedKmh == nil`) is not "standing"; the trip then ends only after the much longer
/// `noSpeedSeconds` without any valid speed (car left in an underground garage with the app open).
public struct TripStandstillTimer: Sendable, Equatable {
    public var stationarySpeedKmh: Double
    public var stopSeconds: TimeInterval
    public var noSpeedSeconds: TimeInterval
    public private(set) var stationarySince: Date?
    public private(set) var noSpeedSince: Date?

    public init(stationarySpeedKmh: Double = 3, stopSeconds: TimeInterval = 180, noSpeedSeconds: TimeInterval = 900) {
        self.stationarySpeedKmh = stationarySpeedKmh
        self.stopSeconds = stopSeconds
        self.noSpeedSeconds = noSpeedSeconds
    }

    public mutating func reset() {
        stationarySince = nil
        noSpeedSince = nil
    }

    /// Feeds the current speed (nil = no usable GPS speed). Returns true when the trip should be stopped.
    public mutating func update(now: Date, speedKmh: Double?) -> Bool {
        guard let speedKmh, speedKmh.isFinite, speedKmh >= 0 else {
            stationarySince = nil
            let since = noSpeedSince ?? now
            noSpeedSince = since
            return now.timeIntervalSince(since) >= noSpeedSeconds
        }
        noSpeedSince = nil
        guard speedKmh <= stationarySpeedKmh else {
            stationarySince = nil
            return false
        }
        let since = stationarySince ?? now
        stationarySince = since
        return now.timeIntervalSince(since) >= stopSeconds
    }
}
