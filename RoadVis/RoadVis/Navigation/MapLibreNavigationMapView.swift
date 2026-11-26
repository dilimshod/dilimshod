import MapLibre
import SwiftUI
import UIKit

/// Navigator map drawn by MapLibre Native over free OpenFreeMap vector tiles (CARTO raster fallback, see
/// `MapLibreBaseMap`). Used for the default map layer; Apple «Спутник / Гибрид» use `AppleNavigationMapView`.
///
/// - Routes: GeoJSON shape sources + line layers. Alternatives are gray; the selected route is drawn over a white
///   casing, coloured by speed-limit segments (`line-gradient` over `line-progress`, palette
///   `NavigatorStyle.speedLimitUIColor`) when known, else blue. Tapping near an alternative calls `onSelectRoute`
///   when `allowsRouteSelection` is true.
/// - Markers: timeline events (maneuvers, limit changes, signals, cameras, schools, POIs …) as a symbol layer with
///   collision detection and a placement priority (cameras / schools / incidents first), so dense stretches
///   declutter like the clustered MapKit markers did; destination and user incidents always shown. Tapping a marker
///   shows a callout bubble.
/// - Optional raster traffic tiles from `trafficTileTemplate` (https only), below the routes.
/// - Camera: `.navigating` + following → pitched camera behind the car (distance grows with speed), heading = GPS
///   course, smoothly animated between fixes; `.overview` → fits all routes; `.idle` + following → MapLibre's
///   follow mode (north up). Any user pan / pinch / rotate / tilt stops following (`isFollowing = false`).
/// - `isActive`: false while the navigator is hidden behind the camera screen — the map stays mounted (no re-creation
///   on mode switch) and camera updates are skipped; on activation the guidance camera snaps back at once.
/// - Long press → `onLongPress` with the coordinate.
///
/// Sources and layers are created once per loaded style and only their data is replaced, diffed by signature, so
/// SwiftUI updates never rebuild the map.
struct MapLibreNavigationMapView: UIViewRepresentable {
    var routes: [RouteOption]
    var selectedRouteID: Int?
    var destination: GeoPoint?
    var destinationTitle: String?
    var events: [RouteTimelineEvent]
    var speedLimitSegments: [SpeedLimitSegment]
    var incidents: [RoadIncident]
    var is3D: Bool
    var cameraMode: NavigationMapView.CameraMode
    var trafficTileTemplate: String
    var allowsRouteSelection: Bool
    var mapInsets: UIEdgeInsets
    var isActive: Bool
    @Binding var isFollowing: Bool
    var onSelectRoute: (Int) -> Void
    var onLongPress: (CLLocationCoordinate2D) -> Void
    var onBaseMapChange: (BaseMapSource) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MLNMapView {
        MapLibreBaseMap.configureAmbientCache()
        let map = MLNMapView(frame: .zero, styleURL: MapLibreBaseMap.styleURL)
        map.delegate = context.coordinator
        map.overrideUserInterfaceStyle = .dark
        map.tintColor = UIColor.systemBlue
        map.logoView.isHidden = true
        // The attribution is always visible in the navigator's footer (`BaseMapAttributionLinks`).
        map.attributionButton.isHidden = true
        map.showsUserLocation = true
        map.showsUserHeadingIndicator = true
        map.showsScale = true
        map.isPitchEnabled = true
        map.isRotateEnabled = true
        map.maximumZoomLevel = 20
        map.automaticallyAdjustsContentInset = false
        map.compassViewPosition = .topRight
        map.scaleBarPosition = .bottomLeft
        context.coordinator.install(on: map)
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.isFollowingBinding = $isFollowing
        coordinator.onSelectRoute = onSelectRoute
        coordinator.onLongPress = onLongPress
        coordinator.onBaseMapChange = onBaseMapChange
        coordinator.allowsRouteSelection = allowsRouteSelection
        coordinator.is3D = is3D
        coordinator.updateInsets(on: map, insets: mapInsets)
        coordinator.setContent(routes: routes, selectedID: selectedRouteID, segments: speedLimitSegments,
                               destination: destination, destinationTitle: destinationTitle, events: events,
                               incidents: incidents, trafficTemplate: trafficTileTemplate, on: map)
        let becameActive = isActive && !coordinator.isActive
        coordinator.isActive = isActive
        guard isActive else { return }
        coordinator.updateCamera(on: map, mode: cameraMode, following: isFollowing, routes: routes)
        if becameActive {
            coordinator.snapCameraAfterActivation(on: map)
        }
    }

    static func dismantleUIView(_ map: MLNMapView, coordinator: Coordinator) {
        map.delegate = nil
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, MLNMapViewDelegate, UIGestureRecognizerDelegate {
        var isFollowingBinding: Binding<Bool>?
        var onSelectRoute: ((Int) -> Void)?
        var onLongPress: ((CLLocationCoordinate2D) -> Void)?
        var onBaseMapChange: ((BaseMapSource) -> Void)?
        var allowsRouteSelection = false
        var is3D = true
        /// Mirrors `isActive` (false while the navigator is hidden).
        var isActive = true

        private enum ID {
            static let alternativesSource = "rv-routes-alt"
            static let selectedSource = "rv-route-selected"
            static let eventsSource = "rv-events"
            static let pinsSource = "rv-pins"
            static let alternativesLayer = "rv-routes-alt"
            static let casingLayer = "rv-route-casing"
            static let selectedLayer = "rv-route-selected"
            static let eventsLayer = "rv-events"
            static let pinsLayer = "rv-pins"
        }

        // Latest content (re-applied whenever a style finishes loading).
        private var routes: [RouteOption] = []
        private var selectedID: Int?
        private var segments: [SpeedLimitSegment] = []
        private var destination: GeoPoint?
        private var destinationTitle: String?
        private var events: [RouteTimelineEvent] = []
        private var incidents: [RoadIncident] = []
        private var trafficTemplate = ""

        // Style objects of the currently loaded style (nil until it has loaded).
        private weak var style: MLNStyle?
        private var alternativesSource: MLNShapeSource?
        private var selectedSource: MLNShapeSource?
        private var eventsSource: MLNShapeSource?
        private var pinsSource: MLNShapeSource?
        private var selectedLayer: MLNLineStyleLayer?
        private var trafficLayer: MLNRasterStyleLayer?
        private var trafficCounter = 0
        private var registeredImages: Set<String> = []

        private var routeSignature: [String]?
        private var markerSignature: [String]?
        private var appliedTrafficTemplate: String?
        private var baseMap: BaseMapSource = .openFreeMap
        private var appliedInsets: UIEdgeInsets?

        private var lastMode: NavigationMapView.CameraMode?
        private var lastFollowing = false
        private var fittedRouteSignature: [String] = []
        private var fittedInsets: UIEdgeInsets = .zero
        private var mapInsets: UIEdgeInsets = .zero
        private var lastCameraHeading: CLLocationDirection = 0

        private var callout: MapCalloutBubble?

        // MARK: Setup

        func install(on map: MLNMapView) {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.delegate = self
            map.addGestureRecognizer(tap)

            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            longPress.minimumPressDuration = 0.6
            longPress.delegate = self
            map.addGestureRecognizer(longPress)
        }

        func updateInsets(on map: MLNMapView, insets: UIEdgeInsets) {
            mapInsets = insets
            guard appliedInsets != insets else { return }
            appliedInsets = insets
            // Keep MapLibre's compass and scale bar clear of the SwiftUI overlays (and the right-hand buttons).
            map.compassViewMargins = CGPoint(x: 64, y: insets.top + 8)
            map.scaleBarMargins = CGPoint(x: 12, y: insets.bottom + 8)
        }

        // MARK: Content

        func setContent(routes: [RouteOption], selectedID: Int?, segments: [SpeedLimitSegment], destination: GeoPoint?,
                        destinationTitle: String?, events: [RouteTimelineEvent], incidents: [RoadIncident],
                        trafficTemplate: String, on map: MLNMapView) {
            self.routes = routes
            self.selectedID = selectedID
            self.segments = segments
            self.destination = destination
            self.destinationTitle = destinationTitle
            self.events = events
            self.incidents = incidents
            self.trafficTemplate = trafficTemplate
            applyContent()
        }

        private func applyContent() {
            guard let style else { return }
            applyRoutes(style: style)
            applyMarkers(style: style)
            applyTraffic(style: style)
        }

        /// A style finished loading (the initial one or the fallback): create our sources / layers and re-apply data.
        private func styleDidLoad(_ style: MLNStyle) {
            self.style = style
            registeredImages = []
            routeSignature = nil
            markerSignature = nil
            appliedTrafficTemplate = nil
            trafficLayer = nil

            let alternatives = MLNShapeSource(identifier: ID.alternativesSource, shape: nil, options: nil)
            let selected = MLNShapeSource(identifier: ID.selectedSource, shape: nil,
                                          options: [MLNShapeSourceOption.lineDistanceMetrics: true])
            let events = MLNShapeSource(identifier: ID.eventsSource, shape: nil, options: nil)
            let pins = MLNShapeSource(identifier: ID.pinsSource, shape: nil, options: nil)
            style.addSource(alternatives)
            style.addSource(selected)
            style.addSource(events)
            style.addSource(pins)
            alternativesSource = alternatives
            selectedSource = selected
            eventsSource = events
            pinsSource = pins

            let round = NSExpression(forConstantValue: "round")

            let alternativesLayer = MLNLineStyleLayer(identifier: ID.alternativesLayer, source: alternatives)
            alternativesLayer.lineColor = NSExpression(forConstantValue: UIColor.systemGray.withAlphaComponent(0.9))
            alternativesLayer.lineWidth = NSExpression(forConstantValue: 7)
            alternativesLayer.lineCap = round
            alternativesLayer.lineJoin = round
            style.addLayer(alternativesLayer)

            let casing = MLNLineStyleLayer(identifier: ID.casingLayer, source: selected)
            casing.lineColor = NSExpression(forConstantValue: UIColor.white)
            casing.lineWidth = NSExpression(forConstantValue: 11)
            casing.lineCap = round
            casing.lineJoin = round
            style.addLayer(casing)

            let selectedLine = MLNLineStyleLayer(identifier: ID.selectedLayer, source: selected)
            selectedLine.lineColor = NSExpression(forConstantValue: UIColor.systemBlue)
            selectedLine.lineWidth = NSExpression(forConstantValue: 8)
            selectedLine.lineCap = round
            selectedLine.lineJoin = round
            style.addLayer(selectedLine)
            selectedLayer = selectedLine

            // Timeline events: collision-checked, placed in `sortKey` order (lower first).
            let eventsLayer = MLNSymbolStyleLayer(identifier: ID.eventsLayer, source: events)
            eventsLayer.iconImageName = NSExpression(forKeyPath: "icon")
            eventsLayer.symbolSortKey = NSExpression(forKeyPath: "sortKey")
            eventsLayer.iconAllowsOverlap = NSExpression(forConstantValue: false)
            style.addLayer(eventsLayer)

            // Destination and own incidents: always drawn.
            let pinsLayer = MLNSymbolStyleLayer(identifier: ID.pinsLayer, source: pins)
            pinsLayer.iconImageName = NSExpression(forKeyPath: "icon")
            pinsLayer.iconAllowsOverlap = NSExpression(forConstantValue: true)
            pinsLayer.iconIgnoresPlacement = NSExpression(forConstantValue: true)
            style.addLayer(pinsLayer)

            applyContent()
        }

        /// The OpenFreeMap style could not be loaded: switch to the inline CARTO raster style (once).
        private func styleDidFail(on map: MLNMapView) {
            guard baseMap == .openFreeMap else { return }
            baseMap = .cartoFallback
            style = nil
            map.styleJSON = MapLibreBaseMap.fallbackStyleJSON
            let callback = onBaseMapChange
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    callback?(.cartoFallback)
                }
            }
        }

        // MARK: Routes

        private static func routeKey(_ option: RouteOption) -> String {
            let first = option.route.polyline.first ?? GeoPoint(0, 0)
            let last = option.route.polyline.last ?? GeoPoint(0, 0)
            return "\(option.id)|\(option.source.rawValue)|\(option.route.polyline.count)|\(Int(option.distance))|"
                + String(format: "%.5f,%.5f>%.5f,%.5f", first.latitude, first.longitude, last.latitude, last.longitude)
        }

        private func applyRoutes(style: MLNStyle) {
            let effectiveSelected = selectedID ?? routes.first?.id
            let alternatives = routes.filter { $0.id != effectiveSelected }
            let selected = routes.first { $0.id == effectiveSelected }
            let segmentKey = segments.isEmpty ? "" : "sl\(segments.count)|\(Int(segments.last?.end ?? 0))|"
                + segments.map { "\($0.limitKmh ?? 0)" }.joined(separator: ",")
            var signature = alternatives.map { Self.routeKey($0) + "#alt" }
            if let selected {
                signature.append(Self.routeKey(selected) + "#sel" + segmentKey)
            }
            guard signature != routeSignature else { return }
            routeSignature = signature

            var alternativeFeatures: [[String: Any]] = []
            for option in alternatives {
                if let feature = MapLibreBaseMap.lineFeature(option.route.polyline, properties: ["routeID": option.id]) {
                    alternativeFeatures.append(feature)
                }
            }
            alternativesSource?.shape = MapLibreBaseMap.shape(features: alternativeFeatures)

            var selectedFeatures: [[String: Any]] = []
            var gradient: NSExpression?
            if let selected,
               let feature = MapLibreBaseMap.lineFeature(selected.route.polyline, properties: ["routeID": selected.id]) {
                selectedFeatures.append(feature)
                gradient = Self.speedLimitGradient(segments, length: Geo.polylineLength(selected.route.polyline))
            }
            selectedSource?.shape = MapLibreBaseMap.shape(features: selectedFeatures)
            selectedLayer?.lineGradient = gradient
        }

        /// `line-gradient` with sharp colour changes at the speed-limit segment boundaries (blue between segments).
        private static func speedLimitGradient(_ segments: [SpeedLimitSegment], length: Double) -> NSExpression? {
            guard length > 0, !segments.isEmpty else { return nil }
            let blue = MapLibreBaseMap.rgba(UIColor.systemBlue)
            var stops: [(Double, String)] = []
            func add(_ position: Double, _ color: String) {
                let clamped = max(0, min(1, position))
                if let last = stops.last, clamped <= last.0 + 0.000_01 {
                    // Interpolation stops must strictly increase; nudge the boundary forward.
                    let nudged = min(1, last.0 + 0.000_02)
                    guard nudged > last.0 else { return }
                    stops.append((nudged, color))
                } else {
                    stops.append((clamped, color))
                }
            }
            var cursor = 0.0
            for segment in segments.sorted(by: { $0.start < $1.start }) {
                let start = max(0, min(1, segment.start / length))
                let end = max(0, min(1, segment.end / length))
                guard end > start else { continue }
                let color = MapLibreBaseMap.rgba(NavigatorStyle.speedLimitUIColor(segment.limitKmh))
                if start > cursor + 0.000_05 {
                    // Gap without a known segment: blue.
                    add(cursor, blue)
                    add(start - 0.000_02, blue)
                }
                add(start, color)
                add(end - 0.000_02, color)
                cursor = end
            }
            if cursor < 1 - 0.000_05 {
                add(cursor, blue)
                add(1, blue)
            }
            guard stops.count >= 2 else { return nil }
            var json: [Any] = ["interpolate", ["linear"], ["line-progress"]]
            for (position, color) in stops {
                json.append(position)
                json.append(["to-color", color])
            }
            return NSExpression(mglJSONObject: json)
        }

        // MARK: Markers

        private struct Marker {
            let key: String
            let coordinate: GeoPoint
            let icon: String
            let makeImage: () -> UIImage
            let title: String
            let subtitle: String
            let sortKey: Int
        }

        private func applyMarkers(style: MLNStyle) {
            var pins: [Marker] = []
            var eventMarkers: [Marker] = []

            if let destination, destination.isValid {
                let color = UIColor.systemRed
                let icon = MapMarkerImage.name(prefix: "dest", color: color, symbolName: "flag.fill", text: nil,
                                               glyphColor: .white, diameter: 30)
                pins.append(Marker(key: "dest|\(destination.description)|\(destinationTitle ?? "")", coordinate: destination,
                                   icon: icon,
                                   makeImage: { MapMarkerImage.make(color: color, symbolName: "flag.fill", diameter: 30) },
                                   title: destinationTitle ?? L("nav.mapPoint"), subtitle: "", sortKey: 0))
            }
            for incident in incidents where incident.coordinate.isValid {
                let color = NavigatorStyle.incidentUIColor(incident.kind)
                let symbol = incident.kind.symbolName
                let icon = MapMarkerImage.name(prefix: "inc", color: color, symbolName: symbol, text: nil,
                                               glyphColor: .white, diameter: 26)
                pins.append(Marker(key: "i|\(incident.id.uuidString)|\(incident.coordinate.description)|\(incident.date.timeIntervalSince1970)",
                                   coordinate: incident.coordinate, icon: icon,
                                   makeImage: { MapMarkerImage.make(color: color, symbolName: symbol) },
                                   title: incident.kind.localizedName,
                                   subtitle: L("map.yourMarker", RVFormat.clock(incident.date)), sortKey: 0))
            }
            for event in events where event.kind != .destination {
                guard let coordinate = event.coordinate, coordinate.isValid else { continue }
                let kind = event.kind
                let color = NavigatorStyle.eventUIColor(kind)
                var symbol: String? = event.symbolName
                var text: String?
                var glyphColor = UIColor.white
                switch kind {
                case .speedLimit(let kmh):
                    symbol = nil
                    text = kmh.map(String.init) ?? "?"
                case .feature(let feature):
                    glyphColor = NavigatorStyle.featureGlyphUIColor(feature)
                default:
                    break
                }
                let sortKey: Int
                switch kind {
                case .feature(.speedCamera), .feature(.school), .feature(.kindergarten), .incident:
                    sortKey = 0
                case .maneuver, .lanes:
                    sortKey = 1
                default:
                    sortKey = 2
                }
                let icon = MapMarkerImage.name(prefix: "ev", color: color, symbolName: symbol, text: text,
                                               glyphColor: glyphColor, diameter: 26)
                let subtitle = [event.detail, event.source].compactMap { $0 }.joined(separator: " · ")
                let finalSymbol = symbol
                let finalText = text
                let finalGlyph = glyphColor
                eventMarkers.append(Marker(key: "e|\(event.id)|\(kind.category)|\(Int(event.distanceAlongRoute))|\(event.title)",
                                           coordinate: coordinate, icon: icon,
                                           makeImage: {
                                               MapMarkerImage.make(color: color, symbolName: finalSymbol, text: finalText,
                                                                   glyphColor: finalGlyph)
                                           },
                                           title: event.title, subtitle: subtitle, sortKey: sortKey))
            }

            let signature = pins.map(\.key) + ["|"] + eventMarkers.map(\.key)
            guard signature != markerSignature else { return }
            markerSignature = signature

            for marker in pins + eventMarkers where !registeredImages.contains(marker.icon) {
                registeredImages.insert(marker.icon)
                if style.image(forName: marker.icon) == nil {
                    style.setImage(marker.makeImage(), forName: marker.icon)
                }
            }
            pinsSource?.shape = MapLibreBaseMap.shape(features: pins.compactMap(Self.feature))
            eventsSource?.shape = MapLibreBaseMap.shape(features: eventMarkers.compactMap(Self.feature))
        }

        private static func feature(_ marker: Marker) -> [String: Any]? {
            MapLibreBaseMap.pointFeature(marker.coordinate, properties: [
                "icon": marker.icon,
                "title": marker.title,
                "subtitle": marker.subtitle,
                "sortKey": marker.sortKey,
            ])
        }

        // MARK: Traffic tiles

        private func applyTraffic(style: MLNStyle) {
            let template = trafficTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
            let valid = AppleNavigationMapView.Coordinator.isValidTileTemplate(template) ? template : ""
            guard valid != appliedTrafficTemplate else { return }
            appliedTrafficTemplate = valid
            // Layers are hidden rather than removed (cheap; a style reload clears them anyway).
            trafficLayer?.isVisible = false
            trafficLayer = nil
            guard !valid.isEmpty, let routesLayer = style.layer(withIdentifier: ID.alternativesLayer) else { return }
            trafficCounter += 1
            let source = MLNRasterTileSource(identifier: "rv-traffic-\(trafficCounter)", tileURLTemplates: [valid],
                                             options: [MLNTileSourceOption.minimumZoomLevel: 3,
                                                       MLNTileSourceOption.maximumZoomLevel: 19,
                                                       MLNTileSourceOption.tileSize: 256])
            style.addSource(source)
            let layer = MLNRasterStyleLayer(identifier: "rv-traffic-layer-\(trafficCounter)", source: source)
            layer.rasterOpacity = NSExpression(forConstantValue: 0.85)
            style.insertLayer(layer, below: routesLayer)
            trafficLayer = layer
        }

        // MARK: Camera

        func updateCamera(on map: MLNMapView, mode: NavigationMapView.CameraMode, following: Bool, routes: [RouteOption]) {
            let modeChanged = mode != lastMode
            let followingChanged = following != lastFollowing
            lastMode = mode
            lastFollowing = following

            switch mode {
            case .idle:
                if following {
                    if map.userTrackingMode != MLNUserTrackingMode.follow {
                        flattenCamera(map)
                        map.setUserTrackingMode(MLNUserTrackingMode.follow, animated: !modeChanged, completionHandler: nil)
                    }
                } else if map.userTrackingMode != MLNUserTrackingMode.none {
                    map.setUserTrackingMode(MLNUserTrackingMode.none, animated: false, completionHandler: nil)
                }
                if modeChanged { fittedRouteSignature = [] }

            case .overview:
                if map.userTrackingMode != MLNUserTrackingMode.none {
                    map.setUserTrackingMode(MLNUserTrackingMode.none, animated: false, completionHandler: nil)
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
                if map.userTrackingMode != MLNUserTrackingMode.none {
                    map.setUserTrackingMode(MLNUserTrackingMode.none, animated: false, completionHandler: nil)
                }
                if following, modeChanged || followingChanged, let location = map.userLocation?.location {
                    followCamera(on: map, location: location, animated: true)
                }
                if modeChanged { fittedRouteSignature = [] }
            }
        }

        /// The navigator became visible again: put the guidance camera behind the car at once (its updates were
        /// skipped while hidden), so the map does not fly in from a stale position.
        func snapCameraAfterActivation(on map: MLNMapView) {
            guard lastMode == .navigating, lastFollowing, let location = map.userLocation?.location else { return }
            followCamera(on: map, location: location, animated: false)
        }

        private func fitRoutes(on map: MLNMapView, routes: [RouteOption], animated: Bool) {
            var south = 90.0, north = -90.0, west = 180.0, east = -180.0
            var any = false
            for option in routes {
                for point in option.route.polyline where point.isValid {
                    south = min(south, point.latitude)
                    north = max(north, point.latitude)
                    west = min(west, point.longitude)
                    east = max(east, point.longitude)
                    any = true
                }
            }
            guard any else { return }
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
            let bounds = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: south, longitude: west),
                                             ne: CLLocationCoordinate2D(latitude: north, longitude: east))
            map.setVisibleCoordinateBounds(bounds, edgePadding: padding, animated: animated, completionHandler: nil)
        }

        /// Removes pitch and rotation (before fitting or following north-up).
        private func flattenCamera(_ map: MLNMapView) {
            let camera: MLNMapCamera = map.camera
            guard camera.pitch > 0.5 || abs(camera.heading) > 0.5 else { return }
            camera.pitch = 0
            camera.heading = 0
            map.setCamera(camera, animated: false)
        }

        /// Pitched camera behind the car: 45–52° pitch, 600–900 m from the car (growing with speed), heading = GPS
        /// course. Animated linearly over about one GPS interval, so consecutive fixes blend into smooth motion.
        private func followCamera(on map: MLNMapView, location: CLLocation, animated: Bool) {
            let speedKmh = location.speed >= 0 ? location.speed * 3.6 : 0
            if location.course >= 0, speedKmh >= 5 {
                lastCameraHeading = location.course
            }
            let distance = min(900, max(600, 600 + speedKmh * 4))
            let pitch: CGFloat = is3D ? (speedKmh > 60 ? 45 : 52) : 0
            // `distance` is the eye-to-car distance (as MapKit's camera); MapLibre takes the eye altitude.
            let altitude: CLLocationDistance = distance * cos(Double(pitch) * .pi / 180)
            let camera = MLNMapCamera(lookingAtCenter: location.coordinate, altitude: altitude, pitch: pitch,
                                      heading: lastCameraHeading)
            if animated {
                map.setCamera(camera, withDuration: 1.0,
                              animationTimingFunction: CAMediaTimingFunction(name: CAMediaTimingFunctionName.linear))
            } else {
                map.setCamera(camera, animated: false)
            }
        }

        private func stopFollowing() {
            guard let binding = isFollowingBinding, binding.wrappedValue else { return }
            binding.wrappedValue = false
        }

        // MARK: Gestures

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let map = recognizer.view as? MLNMapView, style != nil else { return }
            let point = recognizer.location(in: map)

            if allowsRouteSelection {
                let rect = CGRect(x: point.x - 30, y: point.y - 30, width: 60, height: 60)
                let features = map.visibleFeatures(in: rect, styleLayerIdentifiers: Set([ID.alternativesLayer]))
                for feature in features {
                    if let number = feature.attributes["routeID"] as? NSNumber {
                        hideCallout()
                        onSelectRoute?(number.intValue)
                        return
                    }
                }
            }

            let rect = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
            let features = map.visibleFeatures(in: rect, styleLayerIdentifiers: Set([ID.pinsLayer, ID.eventsLayer]))
            var best: (feature: MLNFeature, distance: CGFloat)?
            for feature in features {
                let screen = map.convert(feature.coordinate, toPointTo: map)
                let distance = hypot(screen.x - point.x, screen.y - point.y)
                if best == nil || distance < best!.distance {
                    best = (feature, distance)
                }
            }
            guard let found = best?.feature, let title = found.attributes["title"] as? String else {
                hideCallout()
                return
            }
            showCallout(on: map, coordinate: found.coordinate, title: title,
                        subtitle: found.attributes["subtitle"] as? String)
        }

        @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let map = recognizer.view as? MLNMapView else { return }
            let point = recognizer.location(in: map)
            let coordinate = map.convert(point, toCoordinateFrom: map)
            guard CLLocationCoordinate2DIsValid(coordinate) else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onLongPress?(coordinate)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        // MARK: Callout

        private func showCallout(on map: MLNMapView, coordinate: CLLocationCoordinate2D, title: String, subtitle: String?) {
            let bubble = callout ?? MapCalloutBubble(frame: .zero)
            if bubble.superview !== map {
                map.addSubview(bubble)
            }
            callout = bubble
            bubble.coordinate = coordinate
            bubble.configure(title: title, subtitle: (subtitle ?? "").isEmpty ? nil : subtitle)
            positionCallout(on: map)
            bubble.isHidden = false
        }

        private func hideCallout() {
            callout?.removeFromSuperview()
            callout = nil
        }

        private func positionCallout(on map: MLNMapView) {
            guard let bubble = callout else { return }
            let point = map.convert(bubble.coordinate, toPointTo: map)
            bubble.place(above: point)
            bubble.isHidden = !map.bounds.insetBy(dx: -40, dy: -40).contains(point)
        }

        // MARK: MLNMapViewDelegate (called on the main thread)

        nonisolated func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            MainActor.assumeIsolated {
                self.styleDidLoad(style)
            }
        }

        nonisolated func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
            MainActor.assumeIsolated {
                self.styleDidFail(on: mapView)
            }
        }

        nonisolated func mapView(_ mapView: MLNMapView, didUpdate userLocation: MLNUserLocation?) {
            MainActor.assumeIsolated {
                guard self.isActive, self.lastMode == .navigating, self.lastFollowing,
                      let location = userLocation?.location else { return }
                self.followCamera(on: mapView, location: location, animated: true)
            }
        }

        nonisolated func mapView(_ mapView: MLNMapView, regionWillChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            MainActor.assumeIsolated {
                let gestures: MLNCameraChangeReason = [.gesturePan, .gesturePinch, .gestureRotate, .gestureZoomIn,
                                                       .gestureZoomOut, .gestureOneFingerZoom, .gestureTilt]
                if !reason.intersection(gestures).isEmpty {
                    self.stopFollowing()
                }
            }
        }

        nonisolated func mapView(_ mapView: MLNMapView, regionIsChangingWith reason: MLNCameraChangeReason) {
            MainActor.assumeIsolated {
                self.positionCallout(on: mapView)
            }
        }

        nonisolated func mapView(_ mapView: MLNMapView, regionDidChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            MainActor.assumeIsolated {
                self.positionCallout(on: mapView)
            }
        }
    }
}
