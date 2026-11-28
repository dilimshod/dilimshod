import CoreLocation
import Foundation
import Observation

/// Current weather at the user's position from Open-Meteo (free, no API key; data CC BY 4.0).
///
/// Refreshes every 15 minutes or after moving more than 10 km. On errors the last successful value is kept and
/// `lastError` explains the problem; retries use an exponential back-off (15 min after a daily-limit response).
@Observable
@MainActor
final class WeatherService {
    /// Latest successfully loaded weather; kept when later refreshes fail.
    private(set) var current: WeatherSnapshot?
    /// Time of the last successful refresh.
    private(set) var lastUpdate: Date?
    /// Russian description of the last failed refresh; nil after a success.
    private(set) var lastError: String?
    /// True while a request is in flight.
    private(set) var isLoading = false

    /// Attribution required by the Open-Meteo licence; show it wherever weather data is displayed.
    static var attribution: String { L("weather.attribution") }
    /// Refresh period, seconds.
    static let refreshInterval: TimeInterval = 15 * 60
    /// Distance from the last refresh position that triggers a new refresh, metres.
    static let refreshDistance: Double = 10_000
    /// Data older than this is reported as stale by `isStale`, seconds.
    static let staleAge: TimeInterval = 45 * 60
    /// Request timeout, seconds.
    static let requestTimeout: TimeInterval = 20

    @ObservationIgnored private let location: LocationService
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var listenerID: UUID?
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var lastFetchPosition: GeoPoint?
    @ObservationIgnored private var nextAttemptAllowed: Date = .distantPast
    @ObservationIgnored private var consecutiveFailures = 0

    init(location: LocationService) {
        self.location = location
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.requestTimeout + 10
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    /// True when the shown weather is older than `staleAge` (e.g. after a long offline period).
    var isStale: Bool {
        guard let lastUpdate else { return false }
        return Date().timeIntervalSince(lastUpdate) > Self.staleAge
    }

    /// Starts refreshing automatically on location updates. Safe to call repeatedly.
    func start() {
        guard listenerID == nil else { return }
        listenerID = location.addListener { [weak self] fix in
            self?.handleLocation(fix)
        }
        if let fix = location.location {
            handleLocation(fix)
        }
    }

    /// Stops automatic refreshes (the last value stays available).
    func stop() {
        if let listenerID {
            location.removeListener(listenerID)
        }
        listenerID = nil
    }

    /// Loads the weather for the current position now. Concurrent calls share one request. While the position is
    /// unknown nothing is requested (and, if no weather was loaded yet, `lastError` says why).
    func refresh() async {
        if let inFlight {
            await inFlight.value
            return
        }
        guard let point = location.coordinate, point.isValid else {
            if current == nil {
                lastError = L("weather.noLocation")
            }
            return
        }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.fetch(at: point)
        }
        inFlight = task
        await task.value
        inFlight = nil
    }

    // MARK: - Private

    private func handleLocation(_ fix: CLLocation) {
        guard inFlight == nil else { return }
        let now = Date()
        guard now >= nextAttemptAllowed else { return }
        let position = GeoPoint(fix.coordinate)
        guard position.isValid, isRefreshDue(at: position, now: now) else { return }
        Task { [weak self] in
            await self?.refresh()
        }
    }

    private func isRefreshDue(at position: GeoPoint, now: Date) -> Bool {
        guard let lastUpdate, let lastFetchPosition else { return true }
        if now.timeIntervalSince(lastUpdate) >= Self.refreshInterval { return true }
        return Geo.distance(position, lastFetchPosition) > Self.refreshDistance
    }

    private func fetch(at point: GeoPoint) async {
        isLoading = true
        defer { isLoading = false }

        var request = URLRequest(url: OpenMeteo.url(for: point), cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: Self.requestTimeout)
        request.httpMethod = "GET"
        request.setValue(OverpassClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw WeatherServiceError.invalidResponse
            }
            guard http.statusCode == 200 else {
                throw WeatherServiceError.http(status: http.statusCode, reason: Self.errorReason(in: data))
            }
            let snapshot: WeatherSnapshot
            do {
                snapshot = try OpenMeteo.parse(data)
            } catch {
                throw WeatherServiceError.invalidResponse
            }
            current = snapshot
            lastUpdate = Date()
            lastFetchPosition = point
            lastError = nil
            consecutiveFailures = 0
            nextAttemptAllowed = .distantPast
        } catch {
            if Task.isCancelled { return }
            if let urlError = error as? URLError, urlError.code == .cancelled { return }
            consecutiveFailures += 1
            nextAttemptAllowed = Date().addingTimeInterval(retryDelay(after: error))
            lastError = L("weather.updateFailed", Self.describe(error))
        }
    }

    /// 1, 2, 4, 8 … minutes, at most 15; 15 minutes after HTTP 429 (daily per-IP limit).
    private func retryDelay(after error: Error) -> TimeInterval {
        if case WeatherServiceError.http(status: 429, reason: _) = error {
            return Self.refreshInterval
        }
        let exponent = Double(min(max(consecutiveFailures - 1, 0), 4))
        return min(Self.refreshInterval, 60 * pow(2, exponent))
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
                return L("net.noInternet")
            case .timedOut:
                return L("net.timedOut")
            default:
                return urlError.localizedDescription
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// `reason` from an Open-Meteo error body `{"error": true, "reason": "…"}`.
    private static func errorReason(in data: Data) -> String? {
        struct ErrorBody: Decodable { let reason: String? }
        guard let reason = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.reason?
            .trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else { return nil }
        return reason.count > 160 ? String(reason.prefix(160)) + "…" : reason
    }
}

/// Failures of `WeatherService` requests (localized descriptions).
enum WeatherServiceError: LocalizedError, Equatable {
    case invalidResponse
    case http(status: Int, reason: String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return L("net.invalidResponse")
        case .http(429, _):
            return L("weather.dailyLimit")
        case .http(let status, let reason):
            if let reason { return "HTTP \(status): \(reason)" }
            return "HTTP \(status)"
        }
    }
}
