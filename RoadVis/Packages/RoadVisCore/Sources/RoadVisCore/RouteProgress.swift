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

    private var lastSegment = 0
    private var lastAlong = 0.0
    private var offRouteCount = 0

    public var totalDistance: Double { cumulative.last ?? 0 }

    public init(polyline: [GeoPoint], steps: [RouteStepInfo], expectedTravelTime: Double,
                offRouteThreshold: Double = 50, offRouteConfirmations: Int = 3, arrivalThreshold: Double = 30) {
        self.polyline = polyline
        self.cumulative = Geo.cumulativeDistances(polyline)
        self.steps = steps
        self.expectedTravelTime = max(0, expectedTravelTime)
        self.offRouteThreshold = offRouteThreshold
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

    public func update(position: GeoPoint, horizontalAccuracy: Double? = nil) -> RouteProgress {
        let total = totalDistance
        let threshold = offRouteThreshold + min(50, max(0, (horizontalAccuracy ?? 0) - 10))

        // Incremental search near the last match first (avoids jumping to overlapping parts of the route).
        var projection: Geo.Projection?
        if polyline.count >= 2 {
            let lo = max(0, lastSegment - 5)
            let hi = min(polyline.count - 1, lastSegment + 80)
            if lo < hi {
                projection = Geo.project(position, onto: polyline, cumulative: cumulative, segmentRange: lo..<hi)
            }
            if projection == nil || projection!.distanceFromLine > threshold {
                if let full = Geo.project(position, onto: polyline, cumulative: cumulative),
                   full.distanceFromLine < (projection?.distanceFromLine ?? .infinity) {
                    projection = full
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
            offRouteCount += 1
        } else {
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
            nextInstruction = arrived ? "Вы прибыли" : "Пункт назначения"
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
        return "\(RVFormat.spokenDistance(distance)) \(Self.lowercasingFirst(text))"
    }

    static func lowercasingFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.lowercased() + s.dropFirst()
    }
}
