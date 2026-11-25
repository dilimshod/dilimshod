import MapKit
import SwiftUI

/// Live map of a trip: planned route (grey), driven track (blue), A and B pins and coloured event markers.
struct TripMapView: View {
    let trip: Trip
    var height: CGFloat = 260
    /// Event to highlight (selected in the list).
    var highlightedEventID: UUID?

    var body: some View {
        Map(initialPosition: .rect(Self.mapRect(for: trip))) {
            if trip.routePolyline.count >= 2 {
                MapPolyline(coordinates: trip.routePolyline.map(\.coordinate))
                    .stroke(Color.gray.opacity(0.7), style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: [6, 6]))
            }
            if trip.points.count >= 2 {
                MapPolyline(coordinates: trip.points.map(\.coordinate.coordinate))
                    .stroke(RVTheme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            if let a = trip.origin.coordinate ?? trip.points.first?.coordinate {
                Annotation(trip.origin.name ?? "A", coordinate: a.coordinate) {
                    Self.pin(letter: "A", color: RVTheme.safe)
                }
            }
            if let b = trip.destination?.coordinate ?? trip.points.last?.coordinate {
                Annotation(trip.destination?.name ?? "B", coordinate: b.coordinate) {
                    Self.pin(letter: "B", color: RVTheme.danger)
                }
            }
            ForEach(trip.events.filter { $0.coordinate != nil }) { event in
                Annotation(event.kind.tripReportTitle, coordinate: event.coordinate!.coordinate, anchor: .center) {
                    Image(systemName: event.kind.symbolName)
                        .font(.system(size: event.id == highlightedEventID ? 15 : 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: event.id == highlightedEventID ? 30 : 20, height: event.id == highlightedEventID ? 30 : 20)
                        .background(TripStyle.color(event.kind), in: Circle())
                        .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                        .shadow(radius: 2)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
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

    /// Map rect around the whole trip with a 15 % margin (≥ ≈ 600 m).
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
