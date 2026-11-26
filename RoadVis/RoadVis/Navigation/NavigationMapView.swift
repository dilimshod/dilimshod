import MapKit
import SwiftUI
import UIKit

/// Full-screen `MKMapView` for the navigator (UIKit map instead of SwiftUI `Map` for tile overlays, custom renderers
/// and precise camera control).
///
/// - Layers: `mapStyle` — OpenStreetMap-based raster tiles (OpenStreetMap / CARTO Dark / CARTO Voyager, default
///   OpenStreetMap) drawn by an `OSMTileOverlay` that replaces the Apple base map (Apple POIs, labels and traffic
///   are off), or Apple Спутник / Гибрид (`MKImageryMapConfiguration` / `MKHybridMapConfiguration`); `is3D`
///   (pitched guidance camera; realistic elevation for the Apple imagery only). The base tiles sit at index 0 of
///   `.aboveRoads`, below the optional traffic tiles and the routes. Attribution is shown by `NavigatorView`.
/// - `isActive`: false while the navigator is hidden behind the camera screen (both stay mounted for instant
///   switching) — the follow camera is not animated then and is snapped back into place on activation.
/// - Routes: the selected route is drawn over a white casing, coloured by speed-limit segments when known
///   (`MKGradientPolylineRenderer`, palette `NavigatorStyle.speedLimitUIColor`), else blue; alternatives are gray.
///   Tapping near an alternative (≤ 30 pt) calls `onSelectRoute` when `allowsRouteSelection` is true.
/// - Optional raster traffic tiles from `trafficTileTemplate` (`https://…{z}/{x}/{y}` only — ATS), below the routes.
/// - Annotations: destination, every timeline event of the route (maneuvers, limit changes, signals, cameras, schools,
///   crossings, fuel, parking … clustered per category) and user-reported incidents.
/// - Camera: `.navigating` + following → a pitched camera that follows the user's course (distance scaled by speed);
///   `.overview` → fits all routes; `.idle` + following → MapKit's follow mode. Any pan / pinch / rotate gesture stops
///   following (`isFollowing = false`) so the navigator can show a "recenter" button.
/// - Long press → `onLongPress` with the coordinate.
///
/// Overlays and annotations are diffed by identity in the coordinator, so SwiftUI updates do not rebuild the map.
struct NavigationMapView: UIViewRepresentable {
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
    /// Applied as the map's layout margins (MapKit keeps its compass, scale and legal label inside them) and as
    /// padding when fitting the route overview.
    var mapInsets: UIEdgeInsets = .zero
    /// False while the navigator screen is hidden (camera mode): no camera animations.
    var isActive: Bool = true
    @Binding var isFollowing: Bool
    var onSelectRoute: (Int) -> Void
    var onLongPress: (CLLocationCoordinate2D) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = true
        map.showsScale = true
        map.isPitchEnabled = true
        map.isRotateEnabled = true
        let key = Coordinator.ConfigurationKey(style: mapStyle, is3D: is3D, showsTraffic: showsTraffic)
        map.preferredConfiguration = Coordinator.configuration(for: key)
        context.coordinator.appliedConfiguration = key
        context.coordinator.install(on: map)
        context.coordinator.updateBaseTiles(on: map, style: mapStyle)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.isFollowingBinding = $isFollowing
        coordinator.onSelectRoute = onSelectRoute
        coordinator.onLongPress = onLongPress
        coordinator.allowsRouteSelection = allowsRouteSelection
        if map.layoutMargins != mapInsets {
            map.layoutMargins = mapInsets
        }
        coordinator.mapInsets = mapInsets

        let configurationKey = Coordinator.ConfigurationKey(style: mapStyle, is3D: is3D, showsTraffic: showsTraffic)
        if coordinator.appliedConfiguration != configurationKey {
            coordinator.appliedConfiguration = configurationKey
            map.preferredConfiguration = Coordinator.configuration(for: configurationKey)
        }
        coordinator.is3D = is3D
        coordinator.updateBaseTiles(on: map, style: mapStyle)
        coordinator.updateTileOverlay(on: map, template: trafficTileTemplate)
        coordinator.updateRoutes(on: map, routes: routes, selectedID: selectedRouteID, segments: speedLimitSegments)
        coordinator.updateAnnotations(on: map, destination: destination, destinationTitle: destinationTitle,
                                      events: events, incidents: incidents)
        let becameActive = isActive && !coordinator.isActive
        coordinator.isActive = isActive
        guard isActive else { return }
        coordinator.updateCamera(on: map, mode: cameraMode, following: isFollowing, routes: routes)
        if becameActive {
            coordinator.snapCameraAfterActivation(on: map)
        }
    }

    static func dismantleUIView(_ map: MKMapView, coordinator: Coordinator) {
        map.delegate = nil
    }

    // MARK: - Overlay & annotation types

    /// Role of a route polyline overlay.
    enum RouteRole: String {
        case casing, main, alternative
    }

    /// Route polyline carrying its route id, drawing role and (main line) speed-limit colouring.
    final class RoutePolyline: MKPolyline {
        var routeID = 0
        var role: RouteRole = .main
        /// Gradient stops (colour, fraction of the route length); empty → plain colour.
        var colorStops: [(UIColor, CGFloat)] = []
    }

    /// Destination pin.
    final class DestinationAnnotation: NSObject, MKAnnotation {
        let coordinate: CLLocationCoordinate2D
        let title: String?

        init(coordinate: CLLocationCoordinate2D, title: String?) {
            self.coordinate = coordinate
            self.title = title
        }
    }

    /// Timeline event along the route (maneuver, limit change, signal, camera, school, fuel …).
    final class EventAnnotation: NSObject, MKAnnotation {
        let event: RouteTimelineEvent
        let coordinate: CLLocationCoordinate2D
        let title: String?
        let subtitle: String?

        init(event: RouteTimelineEvent, coordinate: GeoPoint) {
            self.event = event
            self.coordinate = coordinate.coordinate
            self.title = event.title
            self.subtitle = [event.detail, event.source].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// User-reported incident.
    final class IncidentAnnotation: NSObject, MKAnnotation {
        let incident: RoadIncident
        let coordinate: CLLocationCoordinate2D
        let title: String?
        let subtitle: String?

        init(incident: RoadIncident) {
            self.incident = incident
            self.coordinate = incident.coordinate.coordinate
            self.title = incident.kind.localizedName
            self.subtitle = L("map.yourMarker", RVFormat.clock(incident.date))
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var isFollowingBinding: Binding<Bool>?
        var onSelectRoute: ((Int) -> Void)?
        var onLongPress: ((CLLocationCoordinate2D) -> Void)?
        var allowsRouteSelection = false
        var mapInsets: UIEdgeInsets = .zero
        var appliedConfiguration: ConfigurationKey?
        var is3D = true
        /// Mirrors `NavigationMapView.isActive` (false while the navigator is hidden).
        var isActive = true

        /// Effective MapKit configuration: with OSM tiles the Apple base map is hidden, so 3D elevation and the Apple
        /// traffic layer do not apply (normalized away so toggling them does not reload the map).
        struct ConfigurationKey: Equatable {
            let style: NavigatorMapStyle
            let is3D: Bool
            let showsTraffic: Bool

            init(style: NavigatorMapStyle, is3D: Bool, showsTraffic: Bool) {
                self.style = style
                self.is3D = style.usesOSMTiles ? false : is3D
                self.showsTraffic = style.usesOSMTiles || style == .satellite ? false : showsTraffic
            }
        }

        private var routeOverlays: [String: RoutePolyline] = [:]
        private var routeSignature: [String] = []
        private var tileOverlay: MKTileOverlay?
        private var appliedTileTemplate = ""
        private var baseTileOverlay: OSMTileOverlay?
        private var annotationsByKey: [String: MKAnnotation] = [:]
        private var lastMode: NavigationMapView.CameraMode?
        private var lastFollowing = false
        private var fittedRouteSignature: [String] = []
        private var fittedInsets: UIEdgeInsets = .zero
        private var lastCameraHeading: CLLocationDirection = 0
        private var isProgrammaticCameraChange = false

        private static let featureReuseID = "rv.feature"
        private static let incidentReuseID = "rv.incident"
        private static let destinationReuseID = "rv.destination"
        private static let clusterReuseID = "rv.cluster"

        // MARK: Setup

        /// MapKit configuration for the layer. OSM layers: a flat standard map with every Apple POI and the traffic
        /// layer off (the `OSMTileOverlay` replaces its content). Спутник / Гибрид: Apple imagery, 3D = realistic
        /// elevation; Гибрид shows the Apple traffic layer on request and only fuel / parking / EV charging Apple POIs
        /// (OSM POIs come as timeline markers).
        static func configuration(for key: ConfigurationKey) -> MKMapConfiguration {
            let elevation: MKMapConfiguration.ElevationStyle = key.is3D ? .realistic : .flat
            switch key.style {
            case .osm, .cartoDark, .voyager:
                let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
                configuration.showsTraffic = false
                configuration.pointOfInterestFilter = .excludingAll
                return configuration
            case .satellite:
                return MKImageryMapConfiguration(elevationStyle: elevation)
            case .hybrid:
                let configuration = MKHybridMapConfiguration(elevationStyle: elevation)
                configuration.showsTraffic = key.showsTraffic
                configuration.pointOfInterestFilter = MKPointOfInterestFilter(including: [.gasStation, .parking, .evCharger])
                return configuration
            }
        }

        func install(on map: MKMapView) {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.delegate = self
            map.addGestureRecognizer(tap)

            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            longPress.minimumPressDuration = 0.6
            longPress.delegate = self
            map.addGestureRecognizer(longPress)

            // Detect user camera gestures to stop following.
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleUserCameraGesture(_:)))
            pan.delegate = self
            map.addGestureRecognizer(pan)
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handleUserCameraGesture(_:)))
            pinch.delegate = self
            map.addGestureRecognizer(pinch)
            let rotate = UIRotationGestureRecognizer(target: self, action: #selector(handleUserCameraGesture(_:)))
            rotate.delegate = self
            map.addGestureRecognizer(rotate)
        }

        // MARK: Base tiles (OpenStreetMap)

        /// Installs / swaps / removes the OSM base-map overlay for `style` (index 0 of `.aboveRoads`, i.e. below the
        /// traffic tiles and the routes). Also limits zooming to the tiles' maximum zoom and matches the interface
        /// style to the tiles (dark CARTO → dark compass / scale / user-location styling).
        func updateBaseTiles(on map: MKMapView, style: NavigatorMapStyle) {
            let source = style.tileSource
            guard baseTileOverlay?.source != source else { return }
            if let baseTileOverlay {
                map.removeOverlay(baseTileOverlay)
                self.baseTileOverlay = nil
            }
            if let source {
                let overlay = OSMTileOverlay(source: source)
                baseTileOverlay = overlay
                map.insertOverlay(overlay, at: 0, level: .aboveRoads)
                // About z19 on a phone; closer would only upscale the z19 tiles.
                map.setCameraZoomRange(MKMapView.CameraZoomRange(minCenterCoordinateDistance: 150), animated: false)
                map.overrideUserInterfaceStyle = source.isDark ? .dark : .light
            } else {
                map.setCameraZoomRange(nil, animated: false)
                map.overrideUserInterfaceStyle = .unspecified
            }
        }

        // MARK: Tile overlay

        func updateTileOverlay(on map: MKMapView, template rawTemplate: String) {
            let template = rawTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
            let valid = Self.isValidTileTemplate(template) ? template : ""
            guard valid != appliedTileTemplate else { return }
            appliedTileTemplate = valid
            if let tileOverlay {
                map.removeOverlay(tileOverlay)
                self.tileOverlay = nil
            }
            guard !valid.isEmpty else { return }
            let overlay = MKTileOverlay(urlTemplate: valid)
            overlay.canReplaceMapContent = false
            overlay.minimumZ = 3
            overlay.maximumZ = 19
            tileOverlay = overlay
            // Right above the OSM base tiles (if any) and below the route lines.
            map.insertOverlay(overlay, at: baseTileOverlay == nil ? 0 : 1, level: .aboveRoads)
        }

        /// https URL template containing `{z}`, `{x}` and `{y}` (plain http is blocked by App Transport Security).
        static func isValidTileTemplate(_ template: String) -> Bool {
            guard template.lowercased().hasPrefix("https://") else { return false }
            return template.contains("{z}") && template.contains("{x}") && template.contains("{y}")
        }

        // MARK: Routes

        private static func routeKey(_ option: RouteOption) -> String {
            let first = option.route.polyline.first ?? GeoPoint(0, 0)
            let last = option.route.polyline.last ?? GeoPoint(0, 0)
            return "\(option.id)|\(option.source.rawValue)|\(option.route.polyline.count)|\(Int(option.distance))|"
                + String(format: "%.5f,%.5f>%.5f,%.5f", first.latitude, first.longitude, last.latitude, last.longitude)
        }

        /// Gradient stops for the speed-limit segments: two stops at every boundary give sharp colour changes.
        private static func colorStops(_ segments: [SpeedLimitSegment], length: Double) -> [(UIColor, CGFloat)] {
            guard length > 0, !segments.isEmpty else { return [] }
            var stops: [(UIColor, CGFloat)] = []
            for segment in segments {
                let color = NavigatorStyle.speedLimitUIColor(segment.limitKmh)
                let start = CGFloat(max(0, min(1, segment.start / length)))
                let end = CGFloat(max(0, min(1, segment.end / length)))
                stops.append((color, start))
                stops.append((color, max(start, end - 0.0001)))
            }
            return stops
        }

        func updateRoutes(on map: MKMapView, routes: [RouteOption], selectedID: Int?, segments: [SpeedLimitSegment]) {
            let effectiveSelected = selectedID ?? routes.first?.id
            var desired: [(key: String, option: RouteOption, role: RouteRole)] = []
            // Alternatives first (bottom), then the selected casing and line (top).
            for option in routes where option.id != effectiveSelected {
                desired.append((Self.routeKey(option) + "#alt", option, .alternative))
            }
            let segmentKey = segments.isEmpty ? "" : "|sl\(segments.count)|\(Int(segments.last?.end ?? 0))|"
                + segments.map { "\($0.limitKmh ?? 0)" }.joined(separator: ",")
            if let selected = routes.first(where: { $0.id == effectiveSelected }) {
                let key = Self.routeKey(selected)
                desired.append((key + "#casing", selected, .casing))
                desired.append((key + "#main" + segmentKey, selected, .main))
            }
            let signature = desired.map(\.key)
            guard signature != routeSignature else { return }
            routeSignature = signature

            // Re-adding in order is required to keep the z-order (selected on top) correct.
            map.removeOverlays(Array(routeOverlays.values))
            var reusable = routeOverlays
            routeOverlays = [:]
            for entry in desired {
                let overlay: RoutePolyline
                if let existing = reusable.removeValue(forKey: entry.key) {
                    overlay = existing
                } else {
                    let coordinates = entry.option.route.polyline.map(\.coordinate)
                    overlay = RoutePolyline(coordinates: coordinates, count: coordinates.count)
                    overlay.routeID = entry.option.id
                    overlay.role = entry.role
                    if entry.role == .main {
                        overlay.colorStops = Self.colorStops(segments, length: Geo.polylineLength(entry.option.route.polyline))
                    }
                }
                routeOverlays[entry.key] = overlay
                map.addOverlay(overlay, level: .aboveRoads)
            }
        }

        // MARK: Annotations

        func updateAnnotations(on map: MKMapView, destination: GeoPoint?, destinationTitle: String?,
                               events: [RouteTimelineEvent], incidents: [RoadIncident]) {
            var desired: [String: () -> MKAnnotation] = [:]
            if let destination, destination.isValid {
                let key = "dest|" + destination.description + "|" + (destinationTitle ?? "")
                desired[key] = { DestinationAnnotation(coordinate: destination.coordinate, title: destinationTitle) }
            }
            for event in events where event.kind != .destination {
                guard let coordinate = event.coordinate, coordinate.isValid else { continue }
                desired["e|\(event.id)|\(event.kind.category)|\(Int(event.distanceAlongRoute))|\(event.title)"] = {
                    EventAnnotation(event: event, coordinate: coordinate)
                }
            }
            for incident in incidents where incident.coordinate.isValid {
                let key = "i|\(incident.id.uuidString)|\(incident.coordinate.description)|\(incident.date.timeIntervalSince1970)"
                desired[key] = { IncidentAnnotation(incident: incident) }
            }

            let currentKeys = Set(annotationsByKey.keys)
            let desiredKeys = Set(desired.keys)
            guard currentKeys != desiredKeys else { return }

            let removedKeys = currentKeys.subtracting(desiredKeys)
            if !removedKeys.isEmpty {
                map.removeAnnotations(removedKeys.compactMap { annotationsByKey[$0] })
                for key in removedKeys { annotationsByKey[key] = nil }
            }
            var added: [MKAnnotation] = []
            for key in desiredKeys.subtracting(currentKeys) {
                guard let make = desired[key] else { continue }
                let annotation = make()
                annotationsByKey[key] = annotation
                added.append(annotation)
            }
            if !added.isEmpty {
                map.addAnnotations(added)
            }
        }

        // MARK: Camera

        func updateCamera(on map: MKMapView, mode: NavigationMapView.CameraMode, following: Bool, routes: [RouteOption]) {
            let modeChanged = mode != lastMode
            let followingChanged = following != lastFollowing
            lastMode = mode
            lastFollowing = following

            switch mode {
            case .idle:
                if following {
                    if map.userTrackingMode != .follow {
                        flattenCamera(map)
                        setProgrammatic { map.setUserTrackingMode(.follow, animated: !modeChanged) }
                    }
                } else if map.userTrackingMode != .none {
                    map.setUserTrackingMode(.none, animated: false)
                }
                if modeChanged { fittedRouteSignature = [] }

            case .overview:
                if map.userTrackingMode != .none {
                    map.setUserTrackingMode(.none, animated: false)
                }
                let signature = routes.map(Self.routeKey)
                // The overlays are measured after they appear, so refit once their height settles (while the
                // user has not moved the map).
                let insetsChanged = abs(mapInsets.top - fittedInsets.top) > 20
                    || abs(mapInsets.bottom - fittedInsets.bottom) > 20
                let needsFit = modeChanged || signature != fittedRouteSignature
                    || (followingChanged && following) || (following && insetsChanged)
                if needsFit, !routes.isEmpty {
                    fittedRouteSignature = signature
                    fittedInsets = mapInsets
                    fitRoutes(on: map, routes: routes, animated: true)
                }

            case .navigating:
                if map.userTrackingMode != .none {
                    map.setUserTrackingMode(.none, animated: false)
                }
                if following, modeChanged || followingChanged, let userLocation = map.userLocation.location {
                    followCamera(on: map, location: userLocation, animated: true)
                }
                if modeChanged { fittedRouteSignature = [] }
            }
        }

        /// The navigator became visible again: put the guidance camera behind the car at once (its updates were
        /// skipped while hidden), so the map does not fly in from a stale position.
        func snapCameraAfterActivation(on map: MKMapView) {
            guard lastMode == .navigating, lastFollowing, let location = map.userLocation.location else { return }
            followCamera(on: map, location: location, animated: false)
        }

        private func fitRoutes(on map: MKMapView, routes: [RouteOption], animated: Bool) {
            var rect = MKMapRect.null
            for option in routes {
                for point in option.route.polyline where point.isValid {
                    let mapPoint = MKMapPoint(point.coordinate)
                    rect = rect.union(MKMapRect(x: mapPoint.x, y: mapPoint.y, width: 0, height: 0))
                }
            }
            guard !rect.isNull else { return }
            flattenCamera(map)
            let safe = map.safeAreaInsets
            var top = safe.top + mapInsets.top + 24
            var bottom = safe.bottom + mapInsets.bottom + 24
            // Keep at least 120 pt of map visible even with tall overlays.
            let available = map.bounds.height - top - bottom
            if map.bounds.height > 0, available < 120 {
                let excess = 120 - available
                let share = top + bottom > 0 ? top / (top + bottom) : 0.5
                top = max(safe.top, top - excess * share)
                bottom = max(safe.bottom, bottom - excess * (1 - share))
            }
            let padding = UIEdgeInsets(top: top, left: 40, bottom: bottom, right: 84)
            setProgrammatic {
                map.setVisibleMapRect(rect, edgePadding: padding, animated: animated)
            }
        }

        /// Removes pitch and rotation (before fitting or following north-up).
        private func flattenCamera(_ map: MKMapView) {
            guard map.camera.pitch > 0.5 || abs(map.camera.heading) > 0.5 else { return }
            let flat = MKMapCamera(lookingAtCenter: map.centerCoordinate,
                                   fromDistance: map.camera.centerCoordinateDistance,
                                   pitch: 0, heading: 0)
            setProgrammatic { map.setCamera(flat, animated: false) }
        }

        /// Pitched camera behind the car: 50° pitch, 600–900 m distance growing with speed, heading = GPS course.
        private func followCamera(on map: MKMapView, location: CLLocation, animated: Bool) {
            let speedKmh = location.speed >= 0 ? location.speed * 3.6 : 0
            if location.course >= 0, speedKmh >= 5 {
                lastCameraHeading = location.course
            }
            let distance = min(900, max(600, 600 + speedKmh * 4))
            let pitch: CGFloat = is3D ? (speedKmh > 60 ? 45 : 52) : 0
            let camera = MKMapCamera(lookingAtCenter: location.coordinate, fromDistance: distance,
                                     pitch: pitch, heading: lastCameraHeading)
            setProgrammatic { map.setCamera(camera, animated: animated) }
        }

        private func setProgrammatic(_ change: () -> Void) {
            isProgrammaticCameraChange = true
            change()
            isProgrammaticCameraChange = false
        }

        private func stopFollowing() {
            guard let binding = isFollowingBinding, binding.wrappedValue else { return }
            binding.wrappedValue = false
        }

        // MARK: Gestures

        @objc private func handleUserCameraGesture(_ recognizer: UIGestureRecognizer) {
            if recognizer.state == .began {
                stopFollowing()
            }
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, allowsRouteSelection,
                  let map = recognizer.view as? MKMapView else { return }
            let point = recognizer.location(in: map)
            var bestID: Int?
            var bestDistance: CGFloat = 30
            for overlay in routeOverlays.values where overlay.role == .alternative {
                let distance = Self.distance(from: point, to: overlay, in: map)
                if distance < bestDistance {
                    bestDistance = distance
                    bestID = overlay.routeID
                }
            }
            if let bestID {
                onSelectRoute?(bestID)
            }
        }

        @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let map = recognizer.view as? MKMapView else { return }
            let point = recognizer.location(in: map)
            let coordinate = map.convert(point, toCoordinateFrom: map)
            guard CLLocationCoordinate2DIsValid(coordinate) else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onLongPress?(coordinate)
        }

        /// Smallest screen distance (points) from `point` to the polyline.
        private static func distance(from point: CGPoint, to polyline: MKPolyline, in map: MKMapView) -> CGFloat {
            let count = polyline.pointCount
            guard count > 0 else { return .infinity }
            let points = polyline.points()
            let visible = map.visibleMapRect.insetBy(dx: -map.visibleMapRect.width * 0.1,
                                                     dy: -map.visibleMapRect.height * 0.1)
            var best = CGFloat.infinity
            var previous: CGPoint?
            var previousVisible = false
            for index in 0..<count {
                let mapPoint = points[index]
                let isVisible = visible.contains(mapPoint)
                let screen = map.convert(mapPoint.coordinate, toPointTo: map)
                if let previous, isVisible || previousVisible {
                    best = min(best, segmentDistance(point, previous, screen))
                } else if count == 1 {
                    best = hypot(point.x - screen.x, point.y - screen.y)
                }
                previous = screen
                previousVisible = isVisible
            }
            return best
        }

        private static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
            let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
            return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let base = overlay as? OSMTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: base)
            }
            if let tiles = overlay as? MKTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tiles)
                renderer.alpha = 0.85
                return renderer
            }
            if let route = overlay as? RoutePolyline {
                let renderer = MKPolylineRenderer(polyline: route)
                renderer.lineCap = .round
                renderer.lineJoin = .round
                switch route.role {
                case .casing:
                    renderer.strokeColor = .white
                    renderer.lineWidth = 11
                case .main:
                    if !route.colorStops.isEmpty {
                        let gradient = MKGradientPolylineRenderer(polyline: route)
                        gradient.setColors(route.colorStops.map { $0.0 }, locations: route.colorStops.map { $0.1 })
                        gradient.lineCap = .round
                        gradient.lineJoin = .round
                        gradient.lineWidth = 8
                        return gradient
                    }
                    renderer.strokeColor = UIColor.systemBlue
                    renderer.lineWidth = 8
                case .alternative:
                    renderer.strokeColor = UIColor.systemGray.withAlphaComponent(0.9)
                    renderer.lineWidth = 7
                }
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }

            if let cluster = annotation as? MKClusterAnnotation {
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: Self.clusterReuseID) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: cluster, reuseIdentifier: Self.clusterReuseID)
                view.annotation = cluster
                let kind = (cluster.memberAnnotations.first as? EventAnnotation)?.event.kind
                view.markerTintColor = kind.map(NavigatorStyle.eventUIColor) ?? .systemGray
                view.glyphImage = nil
                view.glyphText = "\(cluster.memberAnnotations.count)"
                view.displayPriority = .defaultLow
                return view
            }

            if let destination = annotation as? DestinationAnnotation {
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: Self.destinationReuseID) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: destination, reuseIdentifier: Self.destinationReuseID)
                view.annotation = destination
                view.markerTintColor = .systemRed
                view.glyphImage = UIImage(systemName: "flag.fill")
                view.displayPriority = .required
                view.canShowCallout = true
                view.clusteringIdentifier = nil
                return view
            }

            if let item = annotation as? EventAnnotation {
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: Self.featureReuseID) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: item, reuseIdentifier: Self.featureReuseID)
                view.annotation = item
                let kind = item.event.kind
                view.markerTintColor = NavigatorStyle.eventUIColor(kind)
                view.glyphText = nil
                view.glyphImage = UIImage(systemName: item.event.symbolName)
                view.glyphTintColor = .white
                switch kind {
                case .speedLimit(let kmh):
                    view.glyphImage = nil
                    view.glyphText = kmh.map(String.init) ?? "?"
                case .feature(let feature):
                    view.glyphTintColor = NavigatorStyle.featureGlyphUIColor(feature)
                default:
                    break
                }
                switch kind {
                case .feature(.speedCamera), .feature(.school), .feature(.kindergarten), .incident:
                    view.displayPriority = .defaultHigh
                case .maneuver, .lanes:
                    view.displayPriority = .init(rawValue: 200)
                default:
                    view.displayPriority = .defaultLow
                }
                view.clusteringIdentifier = "rv.event." + Self.clusterCategory(kind)
                view.canShowCallout = true
                view.titleVisibility = .hidden
                view.subtitleVisibility = .hidden
                return view
            }

            if let incident = annotation as? IncidentAnnotation {
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: Self.incidentReuseID) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: incident, reuseIdentifier: Self.incidentReuseID)
                view.annotation = incident
                view.markerTintColor = .systemRed
                view.glyphImage = UIImage(systemName: incident.incident.kind.symbolName)
                view.glyphTintColor = .white
                view.displayPriority = .defaultHigh
                view.clusteringIdentifier = nil
                view.canShowCallout = true
                return view
            }
            return nil
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard isActive, lastMode == .navigating, lastFollowing, let location = userLocation.location else { return }
            followCamera(on: mapView, location: location, animated: true)
        }

        func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
            // MapKit drops the follow mode when the user pans in idle mode.
            if mode == .none, lastMode == .idle, !isProgrammaticCameraChange {
                stopFollowing()
            }
        }

        // MARK: Clustering

        /// Markers cluster only with markers of the same category (so a cluster colour means one kind).
        static func clusterCategory(_ kind: RouteTimelineKind) -> String {
            switch kind {
            case .feature(let feature): return "f." + feature.rawValue
            case .incident(let incident): return "i." + incident.rawValue
            default: return kind.category
            }
        }
    }
}
