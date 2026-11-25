import Foundation
import Observation

/// Current weather (Open-Meteo, free, no key) at points of the route other than the user's position:
/// the destination and, for routes longer than 30 km, the midpoint. The weather at the current position comes
/// from `WeatherService`. Responses are cached for 15 minutes per ≈ 1 km cell; requests are sequential.
@Observable
@MainActor
final class RouteWeatherService {
    struct Point: Identifiable, Hashable {
        /// "Середина маршрута", "Пункт назначения".
        let label: String
        let coordinate: GeoPoint
        let distanceAlongRoute: Double
        var snapshot: WeatherSnapshot?
        var error: String?
        var id: String { label }
    }

    private(set) var points: [Point] = []
    private(set) var isLoading = false

    static let midpointMinimumRouteLength: Double = 30_000
    static let cacheLifetime: TimeInterval = 15 * 60

    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cache: [String: (snapshot: WeatherSnapshot, date: Date)] = [:]
    @ObservationIgnored private var routeKey = ""

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    /// Loads the weather for the route's destination (+ midpoint). Repeated calls for the same route are ignored.
    func load(route: NavRoute) {
        guard let last = route.polyline.last, last.isValid else { clear(); return }
        let key = String(format: "%.3f,%.3f|%d", last.latitude, last.longitude, Int(route.distance / 1000))
        guard key != routeKey else { return }
        routeKey = key
        task?.cancel()
        let cumulative = Geo.cumulativeDistances(route.polyline)
        let total = cumulative.last ?? route.distance
        var targets: [Point] = []
        if total >= Self.midpointMinimumRouteLength,
           let mid = Geo.point(atDistance: total / 2, along: route.polyline, cumulative: cumulative) {
            targets.append(Point(label: L("weather.midRoute"), coordinate: mid, distanceAlongRoute: total / 2))
        }
        targets.append(Point(label: L("weather.destination"), coordinate: last, distanceAlongRoute: total))
        points = targets
        isLoading = true
        task = Task { [weak self] in
            for index in targets.indices {
                guard let self, !Task.isCancelled else { return }
                let result = await self.fetch(targets[index].coordinate)
                guard !Task.isCancelled, self.routeKey == key, self.points.indices.contains(index) else { return }
                switch result {
                case .success(let snapshot): self.points[index].snapshot = snapshot
                case .failure(let error): self.points[index].error = Self.describe(error)
                }
            }
            self?.isLoading = false
        }
    }

    func clear() {
        task?.cancel()
        task = nil
        routeKey = ""
        points = []
        isLoading = false
    }

    private func fetch(_ point: GeoPoint) async -> Result<WeatherSnapshot, Error> {
        let cell = String(format: "%.2f,%.2f", point.latitude, point.longitude)
        if let cached = cache[cell], Date().timeIntervalSince(cached.date) < Self.cacheLifetime {
            return .success(cached.snapshot)
        }
        var request = URLRequest(url: OpenMeteo.url(for: point), cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 20)
        request.setValue(OverpassClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw WeatherServiceError.http(status: (response as? HTTPURLResponse)?.statusCode ?? 0, reason: nil)
            }
            let snapshot = try OpenMeteo.parse(data)
            cache[cell] = (snapshot, Date())
            return .success(snapshot)
        } catch {
            return .failure(error)
        }
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed: return L("net.noInternet")
            case .timedOut: return L("net.timeout")
            default: return urlError.localizedDescription
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? L("net.loadError")
    }
}
