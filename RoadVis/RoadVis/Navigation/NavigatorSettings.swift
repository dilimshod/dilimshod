import Foundation

/// Navigator-only preferences stored directly in `UserDefaults` (keys "rv.osrmEndpoint", "rv.mapStyle",
/// "rv.map3D"). They live in an extension so `App/AppSettings.swift` stays untouched; views bind to them with
/// `@AppStorage(NavigatorSettingsKeys.…)`, services read them through these accessors.
enum NavigatorSettingsKeys {
    static let osrmEndpoint = "rv.osrmEndpoint"
    static let mapStyle = "rv.mapStyle"
    static let map3D = "rv.map3D"
}

extension AppSettings {
    /// OSRM server base URL (public FOSSGIS instance by default — light use only).
    var osrmEndpoint: String {
        get {
            let value = UserDefaults.standard.string(forKey: NavigatorSettingsKeys.osrmEndpoint)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? OSRM.defaultEndpoint : value
        }
        set { UserDefaults.standard.set(newValue, forKey: NavigatorSettingsKeys.osrmEndpoint) }
    }

    /// Map layer of the navigator.
    var navigatorMapStyle: NavigatorMapStyle {
        get { NavigatorMapStyle.resolve(UserDefaults.standard.string(forKey: NavigatorSettingsKeys.mapStyle)) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: NavigatorSettingsKeys.mapStyle) }
    }
}

/// Map layer of the navigator: free OpenStreetMap raster tiles (default) or Apple imagery.
///
/// OSM-based layers replace the Apple base map with an `OSMTileOverlay` (`canReplaceMapContent`); the satellite /
/// hybrid layers use Apple's `MKImageryMapConfiguration` / `MKHybridMapConfiguration`. Unknown stored values (e.g.
/// the former Apple "standard" scheme) fall back to `.default` (OpenStreetMap).
enum NavigatorMapStyle: String, CaseIterable, Identifiable {
    /// CARTO "Dark Matter" raster tiles (OpenStreetMap data). The standard OSM and CARTO Voyager layers were
    /// removed after on-device testing (tiles did not load reliably).
    case cartoDark
    /// Apple satellite imagery.
    case satellite
    /// Apple satellite imagery with Apple roads and labels.
    case hybrid

    static let `default`: NavigatorMapStyle = .cartoDark

    var id: String { rawValue }

    /// Stored raw value → style (`.default` when missing or unknown).
    static func resolve(_ raw: String?) -> NavigatorMapStyle {
        raw.flatMap(NavigatorMapStyle.init(rawValue:)) ?? .default
    }

    var displayName: String {
        switch self {
        case .cartoDark: return "OpenStreetMap (CARTO Dark)"
        case .satellite: return L("mapStyle.satellite")
        case .hybrid: return L("mapStyle.hybrid")
        }
    }

    var symbolName: String {
        switch self {
        case .cartoDark: return "map.fill"
        case .satellite: return "globe.asia.australia"
        case .hybrid: return "square.2.layers.3d"
        }
    }

    /// Raster tile source when the layer is drawn from OpenStreetMap-based tiles; nil for the Apple imagery layers.
    var tileSource: OSMTileSource? {
        switch self {
        case .cartoDark: return .cartoDark
        case .satellite, .hybrid: return nil
        }
    }

    /// True when the layer is drawn from OSM raster tiles (Apple base map, POIs and traffic are not shown).
    var usesOSMTiles: Bool { tileSource != nil }
}

/// Values of `AppSettings.routingEngine`.
enum RoutingEngineOption: String, CaseIterable, Identifiable {
    /// Apple (where available), Valhalla and OSRM queried together; distinct routes compared, fastest selected.
    case auto
    /// MKDirections only.
    case apple
    /// Valhalla (OpenStreetMap) only.
    case valhalla
    /// OSRM (OpenStreetMap) only.
    case osrm

    var id: String { rawValue }

    /// Russian label for Settings.
    var displayName: String {
        switch self {
        case .auto: return L("engine.option.auto")
        case .apple: return L("engine.option.apple")
        case .valhalla: return L("engine.option.valhalla")
        case .osrm: return L("engine.option.osrm")
        }
    }

    /// Engines queried for this option.
    var sources: [RouteSource] {
        switch self {
        case .auto: return [.apple, .valhalla, .osrm]
        case .apple: return [.apple]
        case .valhalla: return [.valhalla]
        case .osrm: return [.osrm]
        }
    }
}
