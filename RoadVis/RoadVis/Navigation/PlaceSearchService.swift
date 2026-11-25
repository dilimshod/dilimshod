import CoreLocation
import Foundation
import MapKit
import Observation

/// Destination search for the navigator: live autocompletion (`MKLocalSearchCompleter`), resolving a completion or a
/// free-text query to `MKMapItem`s (`MKLocalSearch`), and the list of recent destinations.
///
/// Results are biased to a ≈ 60 km region around the user; the region is refreshed whenever the user has moved more
/// than 5 km since it was last set (checked on every query change and search, so no location listener is needed).
/// Recent destinations (last 8) are stored in `UserDefaults` as name + coordinates only.
@Observable
@MainActor
final class PlaceSearchService: NSObject {
    /// A destination the user navigated to recently.
    struct RecentDestination: Codable, Hashable, Identifiable, Sendable {
        var name: String
        var subtitle: String?
        var latitude: Double
        var longitude: Double
        var date: Date

        var id: String { String(format: "%.5f,%.5f|", latitude, longitude) + name }
        var coordinate: GeoPoint { GeoPoint(latitude, longitude) }
    }

    /// Text typed into the search field. Every change updates `completions` (debounced by MapKit).
    var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            queryDidChange()
        }
    }
    /// Autocompletion suggestions for `query`.
    private(set) var completions: [MKLocalSearchCompletion] = []
    /// True while a completion is being resolved or a free-text search runs ("Ищем…").
    private(set) var isSearching = false
    /// True while MapKit is computing completions for the current `query`.
    private(set) var isCompleting = false
    /// Russian description of the last search problem; nil when fine.
    private(set) var errorMessage: String?
    /// Recent destinations, newest first (at most `maxRecents`).
    private(set) var recents: [RecentDestination] = []

    /// Maximum number of remembered destinations.
    static let maxRecents = 8
    /// Size of the search bias region, metres.
    static let regionSpan: CLLocationDistance = 60_000
    /// Movement after which the bias region is re-centred, metres.
    static let regionRefreshDistance: Double = 5_000

    @ObservationIgnored private let location: LocationService
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let completer = MKLocalSearchCompleter()
    @ObservationIgnored private var regionCenter: GeoPoint?
    @ObservationIgnored private var activeSearch: MKLocalSearch?

    private static let recentsKey = "rv.recentDestinations"

    init(location: LocationService, defaults: UserDefaults = .standard) {
        self.location = location
        self.defaults = defaults
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest, .query]
        recents = Self.loadRecents(from: defaults)
        updateRegionIfNeeded()
    }

    // MARK: - Search

    /// Resolves an autocompletion suggestion to a map item (the first result of `MKLocalSearch`).
    func resolve(_ completion: MKLocalSearchCompletion) async throws -> MKMapItem {
        updateRegionIfNeeded()
        let request = MKLocalSearch.Request(completion: completion)
        request.resultTypes = [.address, .pointOfInterest]
        if let region = currentRegion() { request.region = region }
        let items = try await run(request)
        guard let first = items.first else {
            errorMessage = L("search.placeNotFound", completion.title)
            throw PlaceSearchError.notFound
        }
        if first.name?.isEmpty ?? true {
            first.name = completion.title
        }
        return first
    }

    /// Free-text (natural language) search, e.g. "заправка" or "ул. Амира Темура 1".
    func search(_ text: String) async throws -> [MKMapItem] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        updateRegionIfNeeded()
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        request.resultTypes = [.address, .pointOfInterest]
        if let region = currentRegion() { request.region = region }
        let items = try await run(request)
        if items.isEmpty {
            errorMessage = L("search.queryNotFound", trimmed)
        }
        return items
    }

    /// Cancels a running search and clears the query and suggestions.
    func reset() {
        activeSearch?.cancel()
        activeSearch = nil
        isSearching = false
        errorMessage = nil
        query = ""
        completions = []
        isCompleting = false
    }

    /// Clears the error message.
    func dismissError() {
        errorMessage = nil
    }

    private func run(_ request: MKLocalSearch.Request) async throws -> [MKMapItem] {
        activeSearch?.cancel()
        let search = MKLocalSearch(request: request)
        activeSearch = search
        isSearching = true
        errorMessage = nil
        defer {
            if activeSearch === search {
                activeSearch = nil
                isSearching = false
            }
        }
        do {
            let response = try await search.start()
            return response.mapItems
        } catch {
            if Task.isCancelled || (error as? CancellationError) != nil { throw CancellationError() }
            let message = Self.describe(error)
            if activeSearch === search { errorMessage = message }
            throw PlaceSearchError.failed(message)
        }
    }

    // MARK: - Recents

    /// Remembers `item` as the most recent destination (duplicates within 50 m with the same name are merged).
    func addRecent(_ item: MKMapItem) {
        let coordinate = item.placemark.coordinate
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        let point = GeoPoint(coordinate)
        let name = Self.displayName(for: item)
        let entry = RecentDestination(name: name, subtitle: Self.subtitle(for: item),
                                      latitude: point.latitude, longitude: point.longitude, date: Date())
        var list = recents.filter { !($0.name == name && Geo.distance($0.coordinate, point) < 50) }
        list.insert(entry, at: 0)
        recents = Array(list.prefix(Self.maxRecents))
        saveRecents()
    }

    /// Removes one recent destination.
    func removeRecent(_ recent: RecentDestination) {
        recents.removeAll { $0.id == recent.id }
        saveRecents()
    }

    /// Forgets all recent destinations.
    func clearRecents() {
        recents = []
        saveRecents()
    }

    /// A map item for a stored recent destination (name + coordinate).
    func mapItem(for recent: RecentDestination) -> MKMapItem {
        Self.mapItem(coordinate: recent.coordinate, name: recent.name)
    }

    /// A map item for an arbitrary coordinate (e.g. a long-press on the map).
    static func mapItem(coordinate: GeoPoint, name: String) -> MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate.coordinate))
        item.name = name
        return item
    }

    /// Best human-readable name of a map item.
    static func displayName(for item: MKMapItem) -> String {
        if let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        let placemark = item.placemark
        let parts = [placemark.thoroughfare, placemark.subThoroughfare].compactMap { $0 }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        return placemark.locality ?? L("nav.mapPoint")
    }

    /// Secondary line (street / city) of a map item, nil when it would repeat the name.
    static func subtitle(for item: MKMapItem) -> String? {
        let placemark = item.placemark
        var parts: [String] = []
        let street = [placemark.thoroughfare, placemark.subThoroughfare].compactMap { $0 }.joined(separator: " ")
        if !street.isEmpty { parts.append(street) }
        if let city = placemark.locality, !city.isEmpty { parts.append(city) }
        let text = parts.joined(separator: ", ")
        guard !text.isEmpty, text != item.name else { return nil }
        return text
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recents) {
            defaults.set(data, forKey: Self.recentsKey)
        }
    }

    private static func loadRecents(from defaults: UserDefaults) -> [RecentDestination] {
        guard let data = defaults.data(forKey: recentsKey),
              let list = try? JSONDecoder().decode([RecentDestination].self, from: data) else { return [] }
        return Array(list.filter { $0.coordinate.isValid }.prefix(maxRecents))
    }

    // MARK: - Completer

    private func queryDidChange() {
        updateRegionIfNeeded()
        errorMessage = nil
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            completer.cancel()
            completions = []
            isCompleting = false
        } else {
            isCompleting = true
            completer.queryFragment = trimmed
        }
    }

    /// Re-centres the bias region when the user moved more than 5 km (or when no region was set yet).
    private func updateRegionIfNeeded() {
        guard let here = location.coordinate, here.isValid else { return }
        if let center = regionCenter, Geo.distance(center, here) < Self.regionRefreshDistance { return }
        regionCenter = here
        completer.region = MKCoordinateRegion(center: here.coordinate,
                                              latitudinalMeters: Self.regionSpan,
                                              longitudinalMeters: Self.regionSpan)
    }

    private func currentRegion() -> MKCoordinateRegion? {
        guard let center = regionCenter else { return nil }
        return MKCoordinateRegion(center: center.coordinate,
                                  latitudinalMeters: Self.regionSpan, longitudinalMeters: Self.regionSpan)
    }

    fileprivate func completerUpdated(_ results: [MKLocalSearchCompletion]) {
        completions = results
        isCompleting = false
    }

    fileprivate func completerFailed(_ error: Error) {
        isCompleting = false
        let code = (error as NSError).code
        // MKError.placemarkNotFound (4) just means "no suggestions" for this fragment.
        if code == 4 {
            completions = []
            return
        }
        errorMessage = Self.describe(error)
    }

    // MARK: - Errors

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
                return L("search.err.offline")
            case .timedOut:
                return L("search.err.timeout")
            default:
                return L("search.err.network", urlError.localizedDescription)
            }
        }
        if let mkError = error as? MKError {
            switch mkError.code {
            case .placemarkNotFound:
                return L("search.err.nothing")
            case .loadingThrottled:
                return L("search.err.throttled")
            case .serverFailure:
                return L("search.err.server")
            default:
                break
            }
        }
        return L("search.err.failed", error.localizedDescription)
    }
}

/// Errors thrown by `PlaceSearchService`.
enum PlaceSearchError: LocalizedError {
    case notFound
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notFound: return L("search.err.notFound")
        case .failed(let message): return message
        }
    }
}

extension PlaceSearchService: MKLocalSearchCompleterDelegate {
    // MKLocalSearchCompleter calls its delegate on the main thread (it is created and used on the main actor).
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            self.completerUpdated(completer.results)
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            self.completerFailed(error)
        }
    }
}
