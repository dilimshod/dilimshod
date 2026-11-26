import MapKit
import MapLibre
import SwiftUI
import UIKit

/// Live map of a trip: planned route (grey, dashed), driven track (blue), A and B pins and coloured event markers.
/// Drawn by MapLibre Native over the free OpenFreeMap dark vector map (CARTO raster fallback), with the base-map
/// attribution in the bottom-right corner.
struct TripMapView: View {
    let trip: Trip
    var height: CGFloat = 260
    /// Event to highlight (selected in the list).
    var highlightedEventID: UUID?

    @State private var baseMap: BaseMapSource = .openFreeMap

    var body: some View {
        TripMapLibreView(trip: trip, highlightedEventID: highlightedEventID) { source in
            baseMap = source
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 6) {
                BaseMapAttributionLinks(source: baseMap)
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .tint(Color.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.5), in: Capsule())
            .padding(6)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: RVTheme.Radius.panel, style: .continuous))
    }

    static func pin(letter: String, color: Color) -> some View {
        Text(letter)
            .font(.system(size: 13, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(color, in: Circle())
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .shadow(radius: 2)
    }

    /// All coordinates of the trip (track, route, A, B, events).
    static func allCoordinates(_ trip: Trip) -> [GeoPoint] {
        var all = trip.points.map(\.coordinate) + trip.routePolyline
        if let a = trip.origin.coordinate { all.append(a) }
        if let b = trip.destination?.coordinate { all.append(b) }
        all += trip.events.compactMap(\.coordinate)
        return all.filter(\.isValid)
    }

    /// Map rect around the whole trip with a 15 % margin (≥ ≈ 600 m). Used by the PDF snapshot (`MKMapSnapshotter`).
    static func mapRect(for trip: Trip) -> MKMapRect {
        let points = allCoordinates(trip).map { MKMapPoint($0.coordinate) }
        guard let first = points.first else {
            return MKMapRect(origin: MKMapPoint(CLLocationCoordinate2D(latitude: 41.31, longitude: 69.28)),
                             size: MKMapSize(width: 20_000, height: 20_000))
        }
        var rect = MKMapRect(origin: first, size: MKMapSize(width: 0, height: 0))
        for p in points.dropFirst() {
            rect = rect.union(MKMapRect(origin: p, size: MKMapSize(width: 0, height: 0)))
        }
        let minSide = 600 * MKMapPointsPerMeterAtLatitude(first.coordinate.latitude)
        let width = max(rect.size.width, minSide)
        let height = max(rect.size.height, minSide)
        let padded = MKMapRect(x: rect.midX - width * 0.65, y: rect.midY - height * 0.65,
                               width: width * 1.3, height: height * 1.3)
        return padded
    }
}

/// MapLibre map view of `TripMapView`.
struct TripMapLibreView: UIViewRepresentable {
    let trip: Trip
    var highlightedEventID: UUID?
    var onBaseMapChange: (BaseMapSource) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MLNMapView {
        MapLibreBaseMap.configureAmbientCache()
        let map = MLNMapView(frame: .zero, styleURL: MapLibreBaseMap.styleURL)
        map.delegate = context.coordinator
        map.overrideUserInterfaceStyle = .dark
        map.logoView.isHidden = true
        // The attribution is drawn by `TripMapView` over the map.
        map.attributionButton.isHidden = true
        map.showsUserLocation = false
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        map.compassView.isHidden = true
        map.maximumZoomLevel = 19
        map.automaticallyAdjustsContentInset = false
        let coordinator = context.coordinator
        coordinator.trip = trip
        coordinator.highlightedEventID = highlightedEventID
        // The frame is known only after SwiftUI's first layout pass.
        DispatchQueue.main.async { [weak map] in
            MainActor.assumeIsolated {
                guard let map else { return }
                coordinator.fitIfNeeded(on: map)
            }
        }
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onBaseMapChange = onBaseMapChange
        coordinator.update(trip: trip, highlightedEventID: highlightedEventID, on: map)
    }

    static func dismantleUIView(_ map: MLNMapView, coordinator: Coordinator) {
        map.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, MLNMapViewDelegate {
        var trip: Trip?
        var highlightedEventID: UUID?
        var onBaseMapChange: ((BaseMapSource) -> Void)?

        private enum ID {
            static let routeSource = "rv-trip-route"
            static let trackSource = "rv-trip-track"
            static let eventsSource = "rv-trip-events"
            static let pinsSource = "rv-trip-pins"
        }

        private weak var style: MLNStyle?
        private var routeSource: MLNShapeSource?
        private var trackSource: MLNShapeSource?
        private var eventsSource: MLNShapeSource?
        private var pinsSource: MLNShapeSource?
        private var appliedTripID: UUID?
        private var appliedHighlight: UUID??
        private var fittedTripID: UUID?
        private var baseMap: BaseMapSource = .openFreeMap

        func update(trip: Trip, highlightedEventID: UUID?, on map: MLNMapView) {
            if self.trip?.id != trip.id {
                fittedTripID = nil
            }
            self.trip = trip
            self.highlightedEventID = highlightedEventID
            apply()
            fitIfNeeded(on: map)
        }

        /// Fits the camera to the whole trip once per trip (when the view has a size).
        func fitIfNeeded(on map: MLNMapView) {
            guard let trip, fittedTripID != trip.id, map.bounds.width > 0, map.bounds.height > 0 else { return }
            let points = TripMapView.allCoordinates(trip)
            guard !points.isEmpty else { return }
            fittedTripID = trip.id
            var south = 90.0, north = -90.0, west = 180.0, east = -180.0
            for point in points {
                south = min(south, point.latitude)
                north = max(north, point.latitude)
                west = min(west, point.longitude)
                east = max(east, point.longitude)
            }
            // At least ≈ 600 m across.
            let minSpan = 0.0055
            if north - south < minSpan {
                let mid = (north + south) / 2
                south = mid - minSpan / 2
                north = mid + minSpan / 2
            }
            if east - west < minSpan {
                let mid = (east + west) / 2
                west = mid - minSpan / 2
                east = mid + minSpan / 2
            }
            let bounds = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: south, longitude: west),
                                             ne: CLLocationCoordinate2D(latitude: north, longitude: east))
            map.setVisibleCoordinateBounds(bounds, edgePadding: UIEdgeInsets(top: 28, left: 28, bottom: 28, right: 28),
                                           animated: false, completionHandler: nil)
        }

        private func styleDidLoad(_ style: MLNStyle, on map: MLNMapView) {
            self.style = style
            appliedTripID = nil
            appliedHighlight = nil

            let route = MLNShapeSource(identifier: ID.routeSource, shape: nil, options: nil)
            let track = MLNShapeSource(identifier: ID.trackSource, shape: nil, options: nil)
            let events = MLNShapeSource(identifier: ID.eventsSource, shape: nil, options: nil)
            let pins = MLNShapeSource(identifier: ID.pinsSource, shape: nil, options: nil)
            style.addSource(route)
            style.addSource(track)
            style.addSource(events)
            style.addSource(pins)
            routeSource = route
            trackSource = track
            eventsSource = events
            pinsSource = pins

            let round = NSExpression(forConstantValue: "round")
            let routeLayer = MLNLineStyleLayer(identifier: ID.routeSource, source: route)
            routeLayer.lineColor = NSExpression(forConstantValue: UIColor.systemGray.withAlphaComponent(0.8))
            routeLayer.lineWidth = NSExpression(forConstantValue: 5)
            routeLayer.lineDashPattern = NSExpression(forConstantValue: [1.2, 1.2])
            routeLayer.lineCap = round
            routeLayer.lineJoin = round
            style.addLayer(routeLayer)

            let trackLayer = MLNLineStyleLayer(identifier: ID.trackSource, source: track)
            trackLayer.lineColor = NSExpression(forConstantValue: UIColor(RVTheme.accent))
            trackLayer.lineWidth = NSExpression(forConstantValue: 4)
            trackLayer.lineCap = round
            trackLayer.lineJoin = round
            style.addLayer(trackLayer)

            let eventsLayer = MLNSymbolStyleLayer(identifier: ID.eventsSource, source: events)
            eventsLayer.iconImageName = NSExpression(forKeyPath: "icon")
            eventsLayer.symbolSortKey = NSExpression(forKeyPath: "sortKey")
            eventsLayer.iconAllowsOverlap = NSExpression(forConstantValue: true)
            style.addLayer(eventsLayer)

            let pinsLayer = MLNSymbolStyleLayer(identifier: ID.pinsSource, source: pins)
            pinsLayer.iconImageName = NSExpression(forKeyPath: "icon")
            pinsLayer.iconAllowsOverlap = NSExpression(forConstantValue: true)
            pinsLayer.iconIgnoresPlacement = NSExpression(forConstantValue: true)
            style.addLayer(pinsLayer)

            apply()
            fitIfNeeded(on: map)
        }

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

        private func registerImage(_ name: String, in style: MLNStyle, make: () -> UIImage) {
            if style.image(forName: name) == nil {
                style.setImage(make(), forName: name)
            }
        }

        private func apply() {
            guard let style, let trip else { return }
            if appliedTripID != trip.id {
                appliedTripID = trip.id
                appliedHighlight = nil
                routeSource?.shape = MapLibreBaseMap.shape(
                    features: [MapLibreBaseMap.lineFeature(trip.routePolyline)].compactMap { $0 })
                trackSource?.shape = MapLibreBaseMap.shape(
                    features: [MapLibreBaseMap.lineFeature(trip.points.map(\.coordinate))].compactMap { $0 })

                var pins: [[String: Any]] = []
                let endpoints: [(String, GeoPoint?, UIColor)] = [
                    ("A", trip.origin.coordinate ?? trip.points.first?.coordinate, UIColor(RVTheme.safe)),
                    ("B", trip.destination?.coordinate ?? trip.points.last?.coordinate, UIColor(RVTheme.danger)),
                ]
                for (letter, coordinate, color) in endpoints {
                    guard let coordinate else { continue }
                    let name = MapMarkerImage.name(prefix: "trip-pin", color: color, symbolName: nil, text: letter,
                                                   glyphColor: .white, diameter: 26)
                    registerImage(name, in: style) {
                        MapMarkerImage.make(color: color, symbolName: nil, text: letter, diameter: 26)
                    }
                    if let feature = MapLibreBaseMap.pointFeature(coordinate, properties: ["icon": name]) {
                        pins.append(feature)
                    }
                }
                pinsSource?.shape = MapLibreBaseMap.shape(features: pins)
            }

            let highlight: UUID? = highlightedEventID
            if let applied = appliedHighlight, applied == highlight { return }
            appliedHighlight = .some(highlight)
            var features: [[String: Any]] = []
            for event in trip.events {
                guard let coordinate = event.coordinate else { continue }
                let isHighlighted = event.id == highlight
                let color = UIColor(TripStyle.color(event.kind))
                let diameter: CGFloat = isHighlighted ? 30 : 20
                let symbol = event.kind.symbolName
                let name = MapMarkerImage.name(prefix: "trip-ev", color: color, symbolName: symbol, text: nil,
                                               glyphColor: .white, diameter: diameter)
                registerImage(name, in: style) {
                    MapMarkerImage.make(color: color, symbolName: symbol, diameter: diameter)
                }
                if let feature = MapLibreBaseMap.pointFeature(coordinate, properties: [
                    "icon": name,
                    "sortKey": isHighlighted ? 0 : 1,
                ]) {
                    features.append(feature)
                }
            }
            eventsSource?.shape = MapLibreBaseMap.shape(features: features)
        }

        // MARK: MLNMapViewDelegate (called on the main thread)

        nonisolated func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            MainActor.assumeIsolated {
                self.styleDidLoad(style, on: mapView)
            }
        }

        nonisolated func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
            MainActor.assumeIsolated {
                self.styleDidFail(on: mapView)
            }
        }
    }
}
