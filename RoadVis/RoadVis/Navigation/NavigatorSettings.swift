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
        get { NavigatorMapStyle(rawValue: UserDefaults.standard.string(forKey: NavigatorSettingsKeys.mapStyle) ?? "") ?? .standard }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: NavigatorSettingsKeys.mapStyle) }
    }
}

/// Map layer of the navigator (MKMapView `preferredConfiguration`).
enum NavigatorMapStyle: String, CaseIterable, Identifiable {
    case standard, satellite, hybrid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return L("mapStyle.standard")
        case .satellite: return L("mapStyle.satellite")
        case .hybrid: return L("mapStyle.hybrid")
        }
    }

    var symbolName: String {
        switch self {
        case .standard: return "map"
        case .satellite: return "globe.asia.australia"
        case .hybrid: return "square.2.layers.3d"
        }
    }
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
