import Foundation

/// Per-class detector confidence thresholds — the single source used by the detector (NMS floor) and the tracker.
///
/// Before this type existed the settings slider fed the NMS stage while the tracker applied its own hidden
/// 0.5 / 0.55 floors, so lowering the slider had no effect on persons, traffic lights and stop signs.
/// Now every class threshold is `base + (slider − defaultGlobal)`: the slider moves all classes together.
///
/// Bases come from a measurement on BDD100K val (300 images, IoU 0.5, COCO-pretrained weights, zero-shot; US
/// dashcam data — nothing was measured on Uzbek roads): the lowest threshold that still gave ≥ 90 % precision was
/// person 0.37 / car 0.33 / traffic light 0.57 for YOLO11s at 544×960, and person 0.47 / car 0.36 / light 0.62 for
/// YOLO11n at 640. Truck / bus / two-wheeler / stop-sign values are reasoning (too few or mislabelled instances).
public enum DetectionThresholds {
    /// Default of the settings slider (global threshold = threshold of cars / trucks / buses).
    public static let defaultGlobal: Double = 0.30
    /// Per-class thresholds at the default slider position.
    public static let classBase: [VehicleKind: Double] = [
        .car: 0.30, .truck: 0.30, .bus: 0.30,
        .motorcycle: 0.35, .bicycle: 0.35,
        .person: 0.40,
        // Traffic-light precision was only ≈ 50–58 % at 0.25 in the measurement, so lights stay at 0.50.
        .trafficLight: 0.50,
        .stopSign: 0.55,
        .other: 0.30,
    ]
    /// Bounds of any effective threshold.
    public static let minimum: Double = 0.10
    public static let maximum: Double = 0.90
    /// A confirmed track may be continued by a detection scoring down to `threshold × continuationFactor`
    /// (new tracks always need the full threshold). ByteTrack-style low-score association; the value is a
    /// conservative choice by reasoning, not a measurement.
    public static let continuationFactor: Double = 0.7
    /// Lowest value ever handed to the detector's own confidence / NMS stage.
    public static let detectorFloorMinimum: Double = 0.05

    /// Threshold of one class for the given slider value.
    public static func threshold(for kind: VehicleKind, global: Double = defaultGlobal) -> Double {
        let base = classBase[kind] ?? defaultGlobal
        let value = base + ((global.isFinite ? global : defaultGlobal) - defaultGlobal)
        return min(maximum, max(minimum, value))
    }

    /// Thresholds of all classes for the given slider value (what the tracker needs to open a track).
    public static func perClass(global: Double = defaultGlobal) -> [VehicleKind: Double] {
        var result: [VehicleKind: Double] = [:]
        for kind in VehicleKind.allCases {
            result[kind] = threshold(for: kind, global: global)
        }
        return result
    }

    /// Confidence floor for the detector itself (Core ML NMS stage / `YOLODecoder`): the lowest score that the
    /// tracker can still use for any class, i.e. the smallest class threshold times `continuationFactor`.
    public static func detectorFloor(global: Double = defaultGlobal, continuationFactor: Double = continuationFactor) -> Double {
        let lowest = perClass(global: global).values.min() ?? defaultGlobal
        return max(detectorFloorMinimum, lowest * min(1, max(0, continuationFactor)))
    }
}

/// Removes boxes that the per-class NMS leaves on one object under two confusable classes (car + truck, car + bus,
/// motorcycle + bicycle). Persons are never merged with vehicles (a rider on a motorcycle stays).
public enum CrossClassDuplicates {
    /// IoU from which two boxes of one confusable group are the same object. Measured on BDD100K val (conf ≥ 0.35):
    /// per-class NMS left such pairs in 14 % of frames with YOLO11s at 544×960 (2.5 % of vehicle boxes) and 7 % of
    /// frames with YOLO11n at 640.
    public static let iouThreshold: Double = 0.7

    /// 0 = car / truck / bus, 1 = motorcycle / bicycle, nil = never merged across classes.
    static func group(of kind: VehicleKind) -> Int? {
        switch kind {
        case .car, .truck, .bus: return 0
        case .motorcycle, .bicycle: return 1
        default: return nil
        }
    }

    /// Returns `detections` (order kept) without the lower-scored box of every cross-class pair of one group whose
    /// IoU is at least `iouThreshold`. Same-class pairs are left to the detector's own NMS.
    public static func suppress(_ detections: [Detection], iouThreshold: Double = iouThreshold) -> [Detection] {
        guard detections.count > 1 else { return detections }
        let order = detections.indices.sorted {
            detections[$0].confidence != detections[$1].confidence
                ? detections[$0].confidence > detections[$1].confidence : $0 < $1
        }
        var keptIndices: [Int] = []
        var removed = [Bool](repeating: false, count: detections.count)
        for index in order {
            let candidate = detections[index]
            if let group = group(of: candidate.kind) {
                let duplicate = keptIndices.contains { kept in
                    let other = detections[kept]
                    return other.kind != candidate.kind && Self.group(of: other.kind) == group
                        && other.box.iou(candidate.box) >= iouThreshold
                }
                if duplicate {
                    removed[index] = true
                    continue
                }
            }
            keptIndices.append(index)
        }
        return detections.indices.filter { !removed[$0] }.map { detections[$0] }
    }
}

/// How a camera frame is fitted into a fixed-size detector input.
public enum DetectorInputFit: Equatable, Sendable {
    /// Aspect ratios (almost) match: the frame is stretched over the whole input (Vision `.scaleFill`); boxes
    /// normalised to the input are already normalised to the frame.
    case fill
    /// Aspect kept, centred, padded (Vision `.scaleFit` / Android `Letterbox`); boxes must be un-letterboxed.
    case letterbox
}

/// Geometry of one detector input versus one frame size (pure, shared by the iOS and Android detectors).
public struct DetectorInputGeometry: Equatable, Sendable {
    /// Relative aspect mismatch up to which stretching is used instead of a letterbox. 544×960 for a 1080×1920
    /// frame is a 0.7 % stretch; 384×640 for a 720×1280 frame is 6.7 % and gets a letterbox.
    public static let fillTolerance: Double = 0.05

    public var inputWidth: Double
    public var inputHeight: Double
    public var sourceWidth: Double
    public var sourceHeight: Double

    public init(inputWidth: Double, inputHeight: Double, sourceWidth: Double, sourceHeight: Double) {
        self.inputWidth = inputWidth
        self.inputHeight = inputHeight
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
    }

    /// True for frames at least as wide as high (the landscape model is used).
    public static func isLandscape(width: Double, height: Double) -> Bool { width >= height }

    /// |inputAspect / sourceAspect − 1|; infinity for degenerate sizes.
    public var aspectMismatch: Double {
        guard inputWidth > 0, inputHeight > 0, sourceWidth > 0, sourceHeight > 0 else { return .infinity }
        return abs((inputWidth / inputHeight) / (sourceWidth / sourceHeight) - 1)
    }

    public var fit: DetectorInputFit { aspectMismatch < Self.fillTolerance ? .fill : .letterbox }

    /// Share of the model input covered by the picture (1 for `.fill`).
    public var usedInputFraction: Double {
        guard fit == .letterbox, inputWidth > 0, inputHeight > 0, sourceWidth > 0, sourceHeight > 0 else { return 1 }
        let gain = min(inputWidth / sourceWidth, inputHeight / sourceHeight)
        return (sourceWidth * gain) * (sourceHeight * gain) / (inputWidth * inputHeight)
    }

    /// Maps a box normalised to the model input (top-left origin) to a box normalised to the frame.
    /// `.fill` → unchanged; `.letterbox` → the centred padding is removed (same convention as `YOLODecoder`).
    public func frameBox(fromInputNormalized box: BBox) -> BBox {
        guard fit == .letterbox else { return box.clamped }
        let gain = min(inputWidth / sourceWidth, inputHeight / sourceHeight)
        let padX = (inputWidth - sourceWidth * gain) / 2
        let padY = (inputHeight - sourceHeight * gain) / 2
        let x1 = (box.minX * inputWidth - padX) / gain / sourceWidth
        let x2 = (box.maxX * inputWidth - padX) / gain / sourceWidth
        let y1 = (box.minY * inputHeight - padY) / gain / sourceHeight
        let y2 = (box.maxY * inputHeight - padY) / gain / sourceHeight
        return BBox(x: x1, y: y1, width: x2 - x1, height: y2 - y1).clamped
    }
}

/// Chooses between the full and the lite detector from the measured inference time (and the thermal state).
///
/// Nothing in this project was timed on a phone, so the detector quality is not fixed at build time: the heavier
/// configuration is used only while the app's own `inferenceMs` shows that the device keeps up.
/// - iOS: `.full` = YOLO11s, `.lite` = YOLO11n (same 544×960 input).
/// - Android: `.full` = 544×960, `.lite` = 384×640 input of the same YOLO11n.
public struct DetectorQualityGovernor: Sendable {
    public enum Level: String, Sendable {
        case full
        case lite
    }

    public struct Config: Sendable {
        public var startLevel: Level
        /// `.full` mean inference time above which the detector drops to `.lite`, ms.
        public var downgradeAboveMs: Double
        /// `.lite` mean inference time below which `.full` is tried, ms. Keep it under
        /// `downgradeAboveMs / (cost of full ÷ cost of lite)`, otherwise the two levels alternate.
        public var upgradeBelowMs: Double
        /// Frames averaged for a decision.
        public var windowFrames: Int
        /// Frames ignored after a level change (model load, first-run warm-up).
        public var settleFrames: Int
        /// Seconds to stay on `.lite` after a downgrade before `.full` is tried again; doubled after every
        /// downgrade that follows an upgrade within `failedUpgradeSeconds`, up to `maxRetrySeconds`.
        public var retrySeconds: Double
        public var maxRetrySeconds: Double
        public var failedUpgradeSeconds: Double

        public init(startLevel: Level, downgradeAboveMs: Double, upgradeBelowMs: Double, windowFrames: Int = 30,
                    settleFrames: Int = 5, retrySeconds: Double = 30, maxRetrySeconds: Double = 480,
                    failedUpgradeSeconds: Double = 20) {
            self.startLevel = startLevel
            self.downgradeAboveMs = downgradeAboveMs
            self.upgradeBelowMs = upgradeBelowMs
            self.windowFrames = max(1, windowFrames)
            self.settleFrames = max(0, settleFrames)
            self.retrySeconds = retrySeconds
            self.maxRetrySeconds = maxRetrySeconds
            self.failedUpgradeSeconds = failedUpgradeSeconds
        }

        /// iOS: YOLO11s ↔ YOLO11n. 55 ms keeps the detector inside the 66 ms budget of the 15 fps pipeline.
        /// The way back assumes the s model costs ≈ 3.3× the n model (21.6 vs 6.5 GFLOPs — an estimate from FLOPs,
        /// not a Neural Engine measurement): 55 / 3.3 ≈ 16 ms, rounded down.
        public static let iOS = Config(startLevel: .full, downgradeAboveMs: 55, upgradeBelowMs: 15)
        /// Android: 544×960 ↔ 384×640 of YOLO11n. Starts small. Measured cost ratio (ONNX Runtime, 1 CPU thread,
        /// x86): 1.29 / 0.58 = 2.2×, so the way up is 70 / 2.2 ≈ 31 ms, rounded down.
        public static let android = Config(startLevel: .lite, downgradeAboveMs: 70, upgradeBelowMs: 30)
    }

    public let config: Config
    public private(set) var level: Level
    private var sum: Double = 0
    private var count: Int = 0
    private var skip: Int
    private var lastUpgradeAt: TimeInterval?
    private var liteSince: TimeInterval?
    private var currentRetry: Double

    public init(config: Config) {
        self.config = config
        level = config.startLevel
        skip = config.settleFrames
        currentRetry = config.retrySeconds
    }

    /// Feeds one frame. Returns the level to use for the next frames.
    /// - Parameters:
    ///   - inferenceMs: duration of this frame's inference at the current `level`.
    ///   - constrained: true while the device asks for less work (thermal state serious / critical).
    @discardableResult
    public mutating func record(inferenceMs: Double, constrained: Bool = false, timestamp: TimeInterval) -> Level {
        if level == .lite, liteSince == nil { liteSince = timestamp }
        if constrained {
            if level == .full { downgrade(at: timestamp) }
            // No upgrade attempts while constrained: restart the waiting time.
            liteSince = timestamp
            resetWindow()
            return level
        }
        guard inferenceMs.isFinite, inferenceMs >= 0 else { return level }
        if skip > 0 {
            skip -= 1
            return level
        }
        sum += inferenceMs
        count += 1
        guard count >= config.windowFrames else { return level }
        let mean = sum / Double(count)
        sum = 0
        count = 0
        switch level {
        case .full:
            if mean > config.downgradeAboveMs { downgrade(at: timestamp) }
        case .lite:
            let waited = timestamp - (liteSince ?? timestamp)
            if mean < config.upgradeBelowMs, waited >= (config.startLevel == .lite && lastUpgradeAt == nil ? 0 : currentRetry) {
                level = .full
                lastUpgradeAt = timestamp
                liteSince = nil
                resetWindow()
            }
        }
        return level
    }

    /// Back to the start level (new drive).
    public mutating func reset() {
        level = config.startLevel
        lastUpgradeAt = nil
        liteSince = nil
        currentRetry = config.retrySeconds
        resetWindow()
    }

    private mutating func downgrade(at timestamp: TimeInterval) {
        if let upgraded = lastUpgradeAt, timestamp - upgraded <= config.failedUpgradeSeconds {
            currentRetry = min(config.maxRetrySeconds, currentRetry * 2)
        } else {
            currentRetry = config.retrySeconds
        }
        level = .lite
        liteSince = timestamp
        resetWindow()
    }

    private mutating func resetWindow() {
        sum = 0
        count = 0
        skip = config.settleFrames
    }
}
