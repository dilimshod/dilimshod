import Foundation

/// Hand-off of the destination to other navigation apps.
public enum ExternalNavigation {
    /// Waze universal link `https://waze.com/ul?ll=<lat>,<lon>&navigate=yes`: opens the Waze app when installed
    /// (it builds its own route to the point), otherwise the Waze website / App Store. Nil for an invalid point.
    public static func wazeURL(destination: GeoPoint) -> URL? {
        guard destination.isValid else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "waze.com"
        components.path = "/ul"
        components.queryItems = [
            URLQueryItem(name: "ll", value: coordinateText(destination.latitude) + "," + coordinateText(destination.longitude)),
            URLQueryItem(name: "navigate", value: "yes"),
        ]
        return components.url
    }

    /// Locale-independent decimal degrees with up to 6 fractional digits ("41.311081").
    static func coordinateText(_ degrees: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), degrees)
    }
}
