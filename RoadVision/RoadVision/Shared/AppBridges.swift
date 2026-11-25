import CoreGraphics
import CoreLocation
import Foundation
import MapKit

// Conversions between the platform-independent RoadVisionCore types and Apple frameworks.
// NOTE: RoadVisionCore sources are compiled into this app target directly — never `import RoadVisionCore`.

extension GeoPoint {
    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var clLocation: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }
}

extension CLLocationCoordinate2D {
    var geoPoint: GeoPoint { GeoPoint(self) }
}

extension MKPolyline {
    /// All vertices of the polyline.
    var coordinates: [CLLocationCoordinate2D] {
        let count = pointCount
        guard count > 0 else { return [] }
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: count)
        getCoordinates(&coords, range: NSRange(location: 0, length: count))
        return coords
    }

    var geoPoints: [GeoPoint] { coordinates.map { GeoPoint($0) } }
}

extension BBox {
    /// From a normalized rect with top-left origin.
    init(_ rect: CGRect) {
        self.init(x: Double(rect.origin.x), y: Double(rect.origin.y),
                  width: Double(rect.size.width), height: Double(rect.size.height))
    }

    /// From a Vision normalized rect (origin bottom-left).
    init(visionRect rect: CGRect) {
        self.init(visionX: Double(rect.origin.x), visionY: Double(rect.origin.y),
                  width: Double(rect.size.width), height: Double(rect.size.height))
    }

    /// Normalized rect with top-left origin.
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    /// Normalized rect with bottom-left origin (Vision `regionOfInterest`, `boundingBox`).
    var visionRect: CGRect { CGRect(x: x, y: visionY, width: width, height: height) }

    /// Rect in a view of the given size (top-left origin), assuming the image fills the view exactly.
    func rect(in size: CGSize) -> CGRect {
        CGRect(x: x * size.width, y: y * size.height, width: width * size.width, height: height * size.height)
    }
}
