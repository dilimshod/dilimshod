import CoreLocation
import SwiftUI
import UIKit

/// Navigator map: the default dark layer is drawn by MapLibre Native over free OpenFreeMap vector tiles
/// (`MapLibreNavigationMapView`, CARTO raster fallback); Apple «Спутник / Гибрид» imagery stays on MapKit
/// (`AppleNavigationMapView`). Both take the same content and camera inputs.
///
/// The view keeps one map per layer family: switching between the camera and navigator screens (`isActive`) never
/// re-creates the map; only changing the map layer between the dark map and the Apple imagery swaps the engine.
struct NavigationMapView: View {
    /// Camera behaviour requested by the navigator.
    enum CameraMode: Equatable {
        /// No route: optionally follow the user (north up).
        case idle
        /// Route preview: show all routes.
        case overview
        /// Turn-by-turn guidance: pitched follow camera.
        case navigating
    }

    var routes: [RouteOption]
    var selectedRouteID: Int?
    var destination: GeoPoint?
    var destinationTitle: String?
    /// Timeline events of the selected / active route (map markers).
    var events: [RouteTimelineEvent]
    /// Speed-limit stretches of the selected route (route colouring); empty → plain blue.
    var speedLimitSegments: [SpeedLimitSegment] = []
    var incidents: [RoadIncident]
    var mapStyle: NavigatorMapStyle = .default
    var is3D: Bool = true
    var cameraMode: CameraMode
    var showsTraffic: Bool
    var trafficTileTemplate: String
    var allowsRouteSelection: Bool
    /// Heights of the SwiftUI overlays above (top) and below (bottom) the map, measured inside the safe area.
    var mapInsets: UIEdgeInsets = .zero
    /// False while the navigator screen is hidden (camera mode): no camera animations.
    var isActive: Bool = true
    @Binding var isFollowing: Bool
    var onSelectRoute: (Int) -> Void
    var onLongPress: (CLLocationCoordinate2D) -> Void
    /// Base map actually shown by the MapLibre layer (OpenFreeMap, or the CARTO fallback) — for the attribution.
    var onBaseMapChange: (BaseMapSource) -> Void = { _ in }

    var body: some View {
        if mapStyle.usesAppleImagery {
            AppleNavigationMapView(
                routes: routes,
                selectedRouteID: selectedRouteID,
                destination: destination,
                destinationTitle: destinationTitle,
                events: events,
                speedLimitSegments: speedLimitSegments,
                incidents: incidents,
                mapStyle: mapStyle,
                is3D: is3D,
                cameraMode: cameraMode,
                showsTraffic: showsTraffic,
                trafficTileTemplate: trafficTileTemplate,
                allowsRouteSelection: allowsRouteSelection,
                mapInsets: mapInsets,
                isActive: isActive,
                isFollowing: $isFollowing,
                onSelectRoute: onSelectRoute,
                onLongPress: onLongPress
            )
        } else {
            MapLibreNavigationMapView(
                routes: routes,
                selectedRouteID: selectedRouteID,
                destination: destination,
                destinationTitle: destinationTitle,
                events: events,
                speedLimitSegments: speedLimitSegments,
                incidents: incidents,
                is3D: is3D,
                cameraMode: cameraMode,
                trafficTileTemplate: trafficTileTemplate,
                allowsRouteSelection: allowsRouteSelection,
                mapInsets: mapInsets,
                isActive: isActive,
                isFollowing: $isFollowing,
                onSelectRoute: onSelectRoute,
                onLongPress: onLongPress,
                onBaseMapChange: onBaseMapChange
            )
        }
    }
}
