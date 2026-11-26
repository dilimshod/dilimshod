import Foundation

/// One turn-by-turn step (from MKRoute.Step).
public struct RouteStepInfo: Hashable, Sendable {
    public var instruction: String
    public var distance: Double
    public var notice: String?
    /// Explicit maneuver type from the routing engine (Valhalla); nil → classified from `instruction`.
    public var maneuver: ManeuverType?
    /// Lanes at the maneuver point (left → right), empty when unknown.
    public var lanes: [Lane]
    /// Lanes recommended by the routing engine for this maneuver (same count as `lanes`), empty when unknown.
    public var activeLanes: [Bool]
    /// Street name(s) after the maneuver.
    public var streetNames: [String]

    public init(instruction: String, distance: Double, notice: String? = nil, maneuver: ManeuverType? = nil,
                lanes: [Lane] = [], activeLanes: [Bool] = [], streetNames: [String] = []) {
        self.instruction = instruction
        self.distance = distance
        self.notice = notice
        self.maneuver = maneuver
        self.lanes = lanes
        self.activeLanes = activeLanes
        self.streetNames = streetNames
    }

    /// Engine maneuver if present, otherwise keyword classification of the instruction.
    public var resolvedManeuver: ManeuverType {
        maneuver ?? ManeuverClassifier.classify(instruction)
    }
}

/// Position of the vehicle relative to the active route.
public struct RouteProgress: Hashable, Sendable {
    public var distanceAlong: Double
    public var remainingDistance: Double
    public var remainingTimeSeconds: Double
    public var fractionCompleted: Double
    /// Index of the step whose maneuver comes next.
    public var nextStepIndex: Int?
    public var distanceToNextManeuver: Double?
    public var nextInstruction: String?
    public var nextManeuver: ManeuverType
    /// The maneuver after the next one (for "затем …").
    public var followingInstruction: String?
    public var crossTrackDistance: Double
    public var isOffRoute: Bool
    public var hasArrived: Bool
    public var snappedPosition: GeoPoint
    /// Lanes at the next maneuver (from the routing engine), empty when unknown.
    public var nextLanes: [Lane] = []
    /// Recommended lanes for the next maneuver (same count as `nextLanes`).
    public var nextActiveLanes: [Bool] = []

    public init(distanceAlong: Double, remainingDistance: Double, remainingTimeSeconds: Double,
                fractionCompleted: Double, nextStepIndex: Int?, distanceToNextManeuver: Double?,
                nextInstruction: String?, nextManeuver: ManeuverType, followingInstruction: String?,
                crossTrackDistance: Double, isOffRoute: Bool, hasArrived: Bool, snappedPosition: GeoPoint) {
        self.distanceAlong = distanceAlong
        self.remainingDistance = remainingDistance
        self.remainingTimeSeconds = remainingTimeSeconds
        self.fractionCompleted = fractionCompleted
        self.nextStepIndex = nextStepIndex
        self.distanceToNextManeuver = distanceToNextManeuver
        self.nextInstruction = nextInstruction
        self.nextManeuver = nextManeuver
        self.followingInstruction = followingInstruction
        self.crossTrackDistance = crossTrackDistance
        self.isOffRoute = isOffRoute
        self.hasArrived = hasArrived
        self.snappedPosition = snappedPosition
    }
}

/// Map-matches GPS fixes onto the route polyline and derives next maneuver, remaining distance/time and off-route state.
public final class RouteProgressTracker {
    public let polyline: [GeoPoint]
    public let cumulative: [Double]
    public let steps: [RouteStepInfo]
    public let expectedTravelTime: Double
    public let offRouteThreshold: Double
    public let offRouteConfirmations: Int
    public let arrivalThreshold: Double
    /// Start distance (along the polyline) of each step = where its maneuver happens.
    public let maneuverDistances: [Double]

    /// Language of the fallback "destination" instruction (default Russian).
    public var language: RVLang = .ru

    private var lastSegment = 0
    private var lastAlong = 0.0
    private var offRouteCount = 0
    /// False until a fix has matched this route (start in a yard / parking lot, or a reroute that still begins at the
    /// road-snapped point): until then only moving AWAY from the line counts as off-route.
    private var hasBeenOnRoute = false
    private var minOffRouteDistance = Double.infinity
    /// First fix that did not match while the route had never been matched: position and distance from the line.
    private var firstUnmatched: (position: GeoPoint, distance: Double)?
    /// Metres the car must travel without approaching the line before a never-matched route counts as off-route.
    static let unmatchedTravelLimit: Double = 150
    /// …"approaching" = the cross-track distance shrank by at least this share of the distance travelled.
    static let unmatchedClosingShare: Double = 0.3
    /// Match threshold used by the latest `update` (`offRouteThreshold` widened by the accuracy of that fix).
    public private(set) var lastMatchThreshold: Double = 50

    public var totalDistance: Double { cumulative.last ?? 0 }

    public init(polyline: [GeoPoint], steps: [RouteStepInfo], expectedTravelTime: Double,
                offRouteThreshold: Double = 50, offRouteConfirmations: Int = 3, arrivalThreshold: Double = 30) {
        self.polyline = polyline
        self.cumulative = Geo.cumulativeDistances(polyline)
        self.steps = steps
        self.expectedTravelTime = max(0, expectedTravelTime)
        self.offRouteThreshold = offRouteThreshold
        self.lastMatchThreshold = offRouteThreshold
        self.offRouteConfirmations = max(1, offRouteConfirmations)
        self.arrivalThreshold = arrivalThreshold

        let total = cumulative.last ?? 0
        let stepSum = steps.reduce(0) { $0 + max(0, $1.distance) }
        let scale = stepSum > 0 ? total / stepSum : 1
        var acc = 0.0
        var starts: [Double] = []
        for s in steps {
            starts.append(min(total, acc * scale))
            acc += max(0, s.distance)
        }
        self.maneuverDistances = starts
    }

    /// - Parameter countsTowardsOffRoute: pass false for a poor fix (low GPS accuracy): it still advances the progress
    ///   when it matches the route, but a far-off position neither counts towards nor clears the off-route state.
    /// - Parameter course: optional GPS course (degrees clockwise from north, only meaningful while moving): route
    ///   segments running against it by more than 100° are not matched while a continuous candidate exists.
    public func update(position: GeoPoint, horizontalAccuracy: Double? = nil,
                       countsTowardsOffRoute: Bool = true, course: Double? = nil) -> RouteProgress {
        let total = totalDistance
        let threshold = offRouteThreshold + min(50, max(0, (horizontalAccuracy ?? 0) - 10))
        lastMatchThreshold = threshold

        // Incremental search near the last match first (avoids jumping to overlapping parts of the route).
        var projection: Geo.Projection?
        if polyline.count >= 2 {
            let lo = max(0, lastSegment - 5)
            let hi = min(polyline.count - 1, lastSegment + 80)
            // 1) Continuity first: the nearest candidate that keeps the progress within [-30 m, +150 m] of the last
            //    match. Prevents snapping to the return leg of an out-and-back section (U-turn at a median break).
            let minAlong = lastAlong - 30
            let maxAlong = lastAlong + 150
            var i = lo
            while i < hi {
                if cumulative[i] > maxAlong { break }
                if cumulative[i + 1] >= minAlong,
                   let candidate = Geo.project(position, onto: polyline, cumulative: cumulative,
                                               segmentRange: i..<(i + 1)),
                   candidate.distanceAlong >= minAlong, candidate.distanceAlong <= maxAlong,
                   candidate.distanceFromLine <= threshold,
                   course.map({ Geo.angleDifference(candidate.segmentBearing, $0) <= 100 }) ?? true {
                    if let best = projection {
                        // A candidate much further along (the opposite carriageway just before the U-turn) must be
                        // clearly nearer, not merely within GPS noise of the current one.
                        let jumpsAhead = candidate.distanceAlong - best.distanceAlong > 40
                        if candidate.distanceFromLine + (jumpsAhead ? 10 : 0) < best.distanceFromLine {
                            projection = candidate
                        }
                    } else {
                        projection = candidate
                    }
                }
                i += 1
            }
            // 2) No continuous candidate on the route: the wide window, then the whole route.
            if projection == nil {
                if lo < hi {
                    projection = Geo.project(position, onto: polyline, cumulative: cumulative, segmentRange: lo..<hi)
                }
                if projection == nil || projection!.distanceFromLine > threshold {
                    if let full = Geo.project(position, onto: polyline, cumulative: cumulative),
                       full.distanceFromLine < (projection?.distanceFromLine ?? .infinity) {
                        projection = full
                    }
                }
            }
        } else {
            projection = Geo.project(position, onto: polyline, cumulative: cumulative)
        }

        guard let proj = projection else {
            return RouteProgress(distanceAlong: 0, remainingDistance: 0, remainingTimeSeconds: 0,
                                 fractionCompleted: 0, nextStepIndex: nil, distanceToNextManeuver: nil,
                                 nextInstruction: nil, nextManeuver: .unknown, followingInstruction: nil,
                                 crossTrackDistance: 0, isOffRoute: false, hasArrived: false,
                                 snappedPosition: position)
        }

        if proj.distanceFromLine > threshold {
            if !countsTowardsOffRoute {
                // Poor fix: the progress holds and the off-route state stays as it was.
            } else if hasBeenOnRoute {
                offRouteCount += 1
            } else {
                // Not on this route yet: off-route only when the car moves away from the line, or drives a real
                // distance without approaching it (a parallel street) — not while it stands still or approaches
                // (otherwise every reroute would start off-route again — a reroute storm).
                minOffRouteDistance = min(minOffRouteDistance, proj.distanceFromLine)
                if firstUnmatched == nil { firstUnmatched = (position, proj.distanceFromLine) }
                let startDistance: Double = firstUnmatched?.distance ?? proj.distanceFromLine
                let travelled: Double = firstUnmatched.map { Geo.distance($0.position, position) } ?? 0
                let closed: Double = startDistance - proj.distanceFromLine
                let drivingPast: Bool = travelled > Self.unmatchedTravelLimit
                    && closed < travelled * Self.unmatchedClosingShare
                if proj.distanceFromLine > minOffRouteDistance + offRouteThreshold || drivingPast {
                    offRouteCount += 1
                } else {
                    offRouteCount = 0
                }
            }
        } else {
            hasBeenOnRoute = true
            offRouteCount = 0
            lastSegment = proj.segmentIndex
            lastAlong = proj.distanceAlong
        }
        let isOffRoute = offRouteCount >= offRouteConfirmations
        let along = proj.distanceFromLine > threshold ? lastAlong : proj.distanceAlong
        let remaining = max(0, total - along)
        let remainingTime = total > 0 ? expectedTravelTime * remaining / total : 0

        // Next maneuver: first announced step (index ≥ 1, non-empty instruction) starting ahead of us.
        var nextIndex: Int?
        for i in steps.indices where i >= 1 {
            let text = steps[i].instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty && maneuverDistances[i] > along + 2 {
                nextIndex = i
                break
            }
        }
        var following: String?
        if let n = nextIndex {
            for j in steps.indices where j > n {
                let text = steps[j].instruction.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { following = text; break }
            }
        }

        let distanceToEnd = polyline.last.map { Geo.distance(position, $0) } ?? .infinity
        let arrived = total > 0 && (remaining <= arrivalThreshold || (distanceToEnd <= arrivalThreshold && along > total * 0.5))

        let nextInstruction: String?
        let nextManeuver: ManeuverType
        let distanceToNext: Double?
        if let n = nextIndex {
            nextInstruction = steps[n].instruction
            nextManeuver = steps[n].resolvedManeuver
            distanceToNext = max(0, maneuverDistances[n] - along)
        } else {
            nextInstruction = NavInstructionText.destination(arrived: arrived, language: language)
            nextManeuver = .arrive
            distanceToNext = remaining
        }

        var progress = RouteProgress(distanceAlong: along,
                             remainingDistance: remaining,
                             remainingTimeSeconds: remainingTime,
                             fractionCompleted: total > 0 ? min(1, along / total) : 0,
                             nextStepIndex: nextIndex,
                             distanceToNextManeuver: distanceToNext,
                             nextInstruction: nextInstruction,
                             nextManeuver: nextManeuver,
                             followingInstruction: following,
                             crossTrackDistance: proj.distanceFromLine,
                             isOffRoute: isOffRoute,
                             hasArrived: arrived,
                             snappedPosition: proj.point)
        if let n = nextIndex {
            progress.nextLanes = steps[n].lanes
            progress.nextActiveLanes = steps[n].activeLanes
        }
        return progress
    }
}

/// Decides when to speak turn-by-turn prompts. Each threshold is spoken at most once per step.
public struct VoicePromptScheduler: Sendable {
    public let thresholds: [Double]
    private var announced: [Int: Set<Int>] = [:]
    /// Language of the spoken distance prefix (default Russian).
    public var language: RVLang = .ru

    public init(thresholds: [Double] = [1000, 400, 100]) {
        self.thresholds = thresholds.sorted(by: >)
    }

    public mutating func reset() {
        announced.removeAll()
    }

    public mutating func prompt(stepIndex: Int, distance: Double, instruction: String, speedKmh: Double?) -> String? {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, distance >= 0 else { return nil }
        // Smallest threshold already crossed (thresholds are sorted descending).
        guard let idx = thresholds.indices.last(where: { distance <= thresholds[$0] }) else { return nil }
        var done = announced[stepIndex] ?? []
        if done.contains(idx) { return nil }
        // Mark this and all larger thresholds as done so they are never spoken late.
        for i in 0...idx { done.insert(i) }
        announced[stepIndex] = done

        let threshold = thresholds[idx]
        if threshold >= 1000 && (speedKmh ?? 0) < 30 {
            return nil   // far announcements are noise in slow city traffic
        }
        if threshold <= 150 || distance < 60 {
            return text
        }
        return "\(RVFormat.spokenDistance(distance, language: language)) \(Self.lowercasingFirst(text))"
    }

    static func lowercasingFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.lowercased() + s.dropFirst()
    }
}

/// Reroute policy helpers (pure logic shared by the navigation service and its tests).
public enum ReroutePolicy {
    /// Bearing (degrees clockwise from north) from the first point of `polyline` to its first point at least
    /// `minDistance` metres away; nil for a polyline shorter than that.
    public static func initialBearing(of polyline: [GeoPoint], minDistance: Double = 15) -> Double? {
        guard let first = polyline.first else { return nil }
        for point in polyline.dropFirst() where Geo.distance(first, point) >= minDistance {
            return Geo.bearing(from: first, to: point)
        }
        return nil
    }

    /// Index of the route to follow after a reroute: the first one (routes are ordered fastest first) that starts
    /// within `tolerance` degrees of the travel `heading`, so the new route does not begin with a U-turn the driver
    /// is not making. Falls back to 0 when the heading is unknown or no route matches.
    ///
    /// `travelTimes` (seconds, parallel to `polylines`; index 0 = fastest) bounds the preference: a route that is
    /// slower than the fastest one by more than `max(minExtraSeconds, maxExtraShare × fastest)` is never preferred —
    /// a forward start must not buy an unbounded detour. Routes without a known time are not bounded.
    public static func preferredIndex(polylines: [[GeoPoint]], heading: Double?, tolerance: Double = 90,
                                      travelTimes: [Double] = [], minExtraSeconds: Double = 120,
                                      maxExtraShare: Double = 0.15) -> Int {
        guard let heading, heading.isFinite else { return 0 }
        let fastest: Double? = travelTimes.first.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        for (index, polyline) in polylines.enumerated() {
            if let fastest, index < travelTimes.count {
                let time: Double = travelTimes[index]
                let allowance: Double = max(minExtraSeconds, fastest * maxExtraShare)
                if !time.isFinite || time > fastest + allowance { continue }
            }
            if let bearing = initialBearing(of: polyline), Geo.angleDifference(bearing, heading) <= tolerance {
                return index
            }
        }
        return 0
    }

    /// Minimum pause before the next automatic reroute: `base` doubled per consecutive failure, capped at
    /// `maximum` (15, 30, 60, 120 s for the defaults).
    public static func retryInterval(base: Double = 15, failures: Int, maximum: Double = 120) -> Double {
        let exponent = Double(min(max(failures, 0), 3))
        return min(base * pow(2, exponent), maximum)
    }

    /// True for a newly listed incident that lies at or behind the car (within `margin` metres ahead): a mark the
    /// driver just made at the current position must not be voiced back as "ahead".
    public static func isIncidentAtOrBehind(distanceAlongRoute: Double, carDistanceAlong: Double,
                                            margin: Double = 30) -> Bool {
        distanceAlongRoute <= carDistanceAlong + margin
    }
}
