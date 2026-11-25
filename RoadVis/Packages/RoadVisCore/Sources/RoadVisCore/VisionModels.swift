import Foundation

/// Object classes the recognizer cares about. Raw values are stable identifiers (used in CSV logs).
public enum VehicleKind: String, CaseIterable, Codable, Hashable, Sendable {
    case car
    case truck
    case bus
    case motorcycle
    case bicycle
    case person
    case trafficLight
    case stopSign
    case other

    /// Maps a detector label. Accepts COCO names ("car", "traffic light"), snake/camel case,
    /// and common custom-dataset names ("van", "minibus", "lorry", "motorbike", "scooter").
    public init?(label: String) {
        let l = label.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch l {
        case "car", "sedan", "suv", "hatchback", "taxi", "pickup", "pickup truck", "van", "minivan", "jeep":
            self = .car
        case "truck", "lorry", "trailer", "tractor", "heavy truck", "light truck":
            self = .truck
        case "bus", "minibus", "coach", "trolleybus":
            self = .bus
        case "motorcycle", "motorbike", "moped", "scooter", "motor":
            self = .motorcycle
        case "bicycle", "bike", "cyclist":
            self = .bicycle
        case "person", "pedestrian", "people":
            self = .person
        case "traffic light", "trafficlight", "traffic signal":
            self = .trafficLight
        case "stop sign", "stopsign":
            self = .stopSign
        default:
            return nil
        }
    }

    /// COCO-80 class index (as used by Ultralytics YOLO models trained on COCO).
    public init?(cocoIndex: Int) {
        switch cocoIndex {
        case 0: self = .person
        case 1: self = .bicycle
        case 2: self = .car
        case 3: self = .motorcycle
        case 5: self = .bus
        case 7: self = .truck
        case 9: self = .trafficLight
        case 11: self = .stopSign
        default: return nil
        }
    }

    /// Russian display name used in the UI.
    public var displayName: String {
        switch self {
        case .car: return "Легковой"
        case .truck: return "Грузовик"
        case .bus: return "Автобус"
        case .motorcycle: return "Мотоцикл"
        case .bicycle: return "Велосипед"
        case .person: return "Пешеход"
        case .trafficLight: return "Светофор"
        case .stopSign: return "Знак STOP"
        case .other: return "Объект"
        }
    }

    /// SF Symbol name for the class.
    public var symbolName: String {
        switch self {
        case .car: return "car.fill"
        case .truck: return "truck.box.fill"
        case .bus: return "bus.fill"
        case .motorcycle: return "motorcycle"
        case .bicycle: return "bicycle"
        case .person: return "figure.walk"
        case .trafficLight: return "light.beacon.max.fill"
        case .stopSign: return "octagon.fill"
        case .other: return "questionmark.square"
        }
    }

    /// True for road vehicles that are counted and tracked.
    public var isVehicle: Bool {
        switch self {
        case .car, .truck, .bus, .motorcycle, .bicycle: return true
        default: return false
        }
    }

    /// Typical physical height in metres, used for rough monocular distance estimation.
    /// These are generic assumptions, not measurements of a specific vehicle.
    public var typicalHeightMeters: Double? {
        switch self {
        case .car: return 1.5
        case .truck: return 3.2
        case .bus: return 3.1
        case .motorcycle: return 1.3
        case .bicycle: return 1.1
        case .person: return 1.7
        case .trafficLight, .stopSign, .other: return nil
        }
    }

    /// Typical rear-view width in metres, used for the lead-vehicle distance estimate.
    /// Generic assumptions (passenger car ≈ 1.8 m, truck/bus ≈ 2.5 m), not measurements.
    public var typicalWidthMeters: Double? {
        switch self {
        case .car: return 1.8
        case .truck: return 2.5
        case .bus: return 2.55
        case .motorcycle: return 0.8
        case .bicycle: return 0.6
        case .person: return 0.5
        case .trafficLight, .stopSign, .other: return nil
        }
    }
}

/// Normalized bounding box in image space: origin top-left, x to the right, y down, all values 0...1.
/// (Vision uses a bottom-left origin — convert with `BBox(visionRect:)` in the app layer.)
public struct BBox: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Creates a box from Vision-style normalized coordinates (origin bottom-left).
    public init(visionX: Double, visionY: Double, width: Double, height: Double) {
        self.init(x: visionX, y: 1 - visionY - height, width: width, height: height)
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var area: Double { max(0, width) * max(0, height) }

    /// Vision-style rect origin y (bottom-left origin).
    public var visionY: Double { 1 - y - height }

    public func intersection(_ o: BBox) -> BBox? {
        let x0 = max(minX, o.minX), y0 = max(minY, o.minY)
        let x1 = min(maxX, o.maxX), y1 = min(maxY, o.maxY)
        guard x1 > x0, y1 > y0 else { return nil }
        return BBox(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Intersection over union, 0...1.
    public func iou(_ o: BBox) -> Double {
        guard let i = intersection(o) else { return 0 }
        let u = area + o.area - i.area
        return u > 0 ? i.area / u : 0
    }

    /// Clamps the box into the unit square.
    public var clamped: BBox {
        let x0 = min(1, max(0, minX)), y0 = min(1, max(0, minY))
        let x1 = min(1, max(0, maxX)), y1 = min(1, max(0, maxY))
        return BBox(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    /// Linear interpolation between two boxes (t = 0 → self, t = 1 → other).
    public func lerp(to o: BBox, t: Double) -> BBox {
        BBox(x: x + (o.x - x) * t, y: y + (o.y - y) * t,
             width: width + (o.width - width) * t, height: height + (o.height - height) * t)
    }
}

/// Colour state of a detected traffic light, estimated from pixel colours (heuristic).
public enum TrafficLightColor: String, Codable, Sendable, CaseIterable {
    case red, yellow, green, unknown

    public var displayName: String {
        switch self {
        case .red: return "Красный"
        case .yellow: return "Жёлтый"
        case .green: return "Зелёный"
        case .unknown: return "Не определён"
        }
    }
}

/// One detection on one frame (before tracking).
public struct Detection: Hashable, Sendable {
    public var kind: VehicleKind
    /// Detector label as returned by the model (e.g. "car").
    public var label: String
    /// Detector confidence 0...1 (this is model confidence, NOT accuracy).
    public var confidence: Double
    public var box: BBox
    /// Optional per-frame make/brand classification of the crop.
    public var make: String?
    public var makeConfidence: Double?
    /// Optional traffic light colour (only for `.trafficLight`).
    public var lightColor: TrafficLightColor?

    public init(kind: VehicleKind, label: String, confidence: Double, box: BBox,
                make: String? = nil, makeConfidence: Double? = nil, lightColor: TrafficLightColor? = nil) {
        self.kind = kind
        self.label = label
        self.confidence = confidence
        self.box = box
        self.make = make
        self.makeConfidence = makeConfidence
        self.lightColor = lightColor
    }
}
