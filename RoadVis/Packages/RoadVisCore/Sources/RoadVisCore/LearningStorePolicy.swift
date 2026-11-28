import Foundation

/// One stored training sample (`<id>.jpg` + `<id>.json`) as seen by the retention policy.
public struct LearningStoredSample: Equatable, Sendable {
    public var id: String
    public var createdAt: Date
    /// Size of the jpg and json together, bytes.
    public var bytes: Int64

    public init(id: String, createdAt: Date, bytes: Int64) {
        self.id = id
        self.createdAt = createdAt
        self.bytes = bytes
    }
}

/// What the retention policy deletes, by cause.
public struct LearningRetentionPlan: Equatable, Sendable {
    /// Older than `maxAgeSeconds`.
    public var expired: [String]
    /// Oldest samples removed to get back under the size cap.
    public var overLimit: [String]

    public init(expired: [String] = [], overLimit: [String] = []) {
        self.expired = expired
        self.overLimit = overLimit
    }

    public var all: [String] { expired + overLimit }
    public var isEmpty: Bool { expired.isEmpty && overLimit.isEmpty }
}

/// Retention of the local sample folder (`docs/TRAINING_API.md` §2): size cap (oldest first), 14-day age limit,
/// delete after a successful upload. Pure decisions; the app does the file work.
public struct LearningStorePolicy: Equatable, Sendable {
    /// Storage limit choices in Settings, MB.
    public static let limitChoicesMB: [Int] = [100, 300, 1000]
    public static let defaultLimitMB: Int = 300
    /// Samples older than this are deleted, seconds (14 days).
    public static let defaultMaxAgeSeconds: TimeInterval = 14 * 24 * 3600

    public var limitBytes: Int64
    public var maxAgeSeconds: TimeInterval

    public init(limitMB: Int = LearningStorePolicy.defaultLimitMB,
                maxAgeSeconds: TimeInterval = LearningStorePolicy.defaultMaxAgeSeconds) {
        self.limitBytes = Int64(max(1, limitMB)) * 1024 * 1024
        self.maxAgeSeconds = maxAgeSeconds
    }

    /// A stored limit value mapped to one of `limitChoicesMB` (unknown values → the default).
    public static func normalizedLimitMB(_ value: Int) -> Int {
        limitChoicesMB.contains(value) ? value : defaultLimitMB
    }

    /// Samples to delete now: everything older than the age limit, then the oldest of the rest until the total
    /// size is within the cap. Samples with a creation date in the future count as new.
    public func plan(for samples: [LearningStoredSample], now: Date) -> LearningRetentionPlan {
        var plan = LearningRetentionPlan()
        var remaining: [LearningStoredSample] = []
        for sample in samples {
            if now.timeIntervalSince(sample.createdAt) > maxAgeSeconds {
                plan.expired.append(sample.id)
            } else {
                remaining.append(sample)
            }
        }
        var total: Int64 = remaining.reduce(0) { $0 + max(0, $1.bytes) }
        guard total > limitBytes else { return plan }
        // Oldest first; ties by id so the order is deterministic.
        remaining.sort { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        for sample in remaining where total > limitBytes {
            plan.overLimit.append(sample.id)
            total -= max(0, sample.bytes)
        }
        return plan
    }

    /// 201 (stored) and 409 (duplicate id: the server already has it) both mean "delete the local copy".
    public static func deleteAfterUpload(statusCode: Int) -> Bool {
        statusCode == 201 || statusCode == 409
    }
}

/// How the uploader reacts to one `POST /api/v1/samples` response (`docs/TRAINING_API.md` §3).
public enum LearningUploadOutcome: Equatable, Sendable {
    /// 201 / 409: uploaded (or already there) → delete the sample.
    case uploaded
    /// 413 (too large) / 422 (invalid meta): the server will never take this sample → delete it, go on.
    case rejected
    /// 401: bad token → stop this run (back-off), keep the sample.
    case unauthorized
    /// 429, 5xx, other codes, network errors: stop this run with back-off, keep the sample.
    case retryLater

    public init(statusCode: Int) {
        switch statusCode {
        case 201, 409: self = .uploaded
        case 413, 422: self = .rejected
        case 401, 403: self = .unauthorized
        default: self = .retryLater
        }
    }

    /// The local sample is deleted after this outcome.
    public var deletesSample: Bool { self == .uploaded || self == .rejected }
    /// The run stops (the rest waits for the back-off).
    public var stopsRun: Bool { self == .unauthorized || self == .retryLater }
}

/// Upload scheduling: batches of `batchSize`, exponential back-off 1, 2, 4 … 60 min after failed runs.
public struct LearningUploadSchedule: Equatable, Sendable {
    public static let batchSize = 20
    public static let maxBackoffMinutes: Double = 60

    /// Consecutive failed runs.
    public private(set) var failures: Int
    /// Earliest time of the next run (nil = any time).
    public private(set) var nextAllowed: Date?

    public init(failures: Int = 0, nextAllowed: Date? = nil) {
        self.failures = max(0, failures)
        self.nextAllowed = nextAllowed
    }

    /// Back-off after `failures` consecutive failed runs, seconds: 1, 2, 4, 8, 16, 32, 60, 60 … minutes.
    public static func backoffSeconds(failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let exponent = Double(min(failures - 1, 16))
        return min(maxBackoffMinutes, pow(2, exponent)) * 60
    }

    public func mayRun(now: Date) -> Bool {
        guard let nextAllowed else { return true }
        return now >= nextAllowed
    }

    public mutating func recordSuccess() {
        failures = 0
        nextAllowed = nil
    }

    public mutating func recordFailure(now: Date) {
        failures += 1
        nextAllowed = now.addingTimeInterval(Self.backoffSeconds(failures: failures))
    }
}
