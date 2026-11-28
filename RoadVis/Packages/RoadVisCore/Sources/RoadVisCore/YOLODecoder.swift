import Foundation

/// A decoded detection before class mapping.
public struct RawDetection: Hashable, Sendable {
    /// Normalized box in the source image (top-left origin).
    public var box: BBox
    public var score: Double
    public var classIndex: Int

    public init(box: BBox, score: Double, classIndex: Int) {
        self.box = box
        self.score = score
        self.classIndex = classIndex
    }
}

/// Decoder for raw (non-pipeline) Ultralytics YOLO CoreML outputs.
/// Models exported with `nms=True` return `VNRecognizedObjectObservation` directly and do not need this.
public enum YOLODecoder {
    /// Decodes a raw YOLO output tensor given as contiguous row-major Float values.
    ///  - `[1, 4+nc, N]` (YOLOv8 / YOLO11, `nms=None` export): rows 0–3 = cx, cy, w, h in input pixels, then class scores → NMS.
    ///  - `[1, N, 6]` (YOLO26 / YOLOv10 `nms=False` export): x1, y1, x2, y2, score, class in input pixels → no NMS.
    /// The layout is detected from the shape (end-to-end when the last dimension is 6 and smaller than the middle one).
    /// - Parameters:
    ///   - inputWidth/inputHeight: model input size (e.g. 640).
    ///   - sourceWidth/sourceHeight: size of the image that was letterboxed into the input (Vision `.scaleFit`).
    ///     Pass nil when the image was stretched (`.scaleFill`) — then coordinates are simply divided by the input size.
    public static func decode(values: [Float], shape: [Int], inputWidth: Double, inputHeight: Double,
                              confidenceThreshold: Double, iouThreshold: Double, maxDetections: Int = 100,
                              sourceWidth: Double? = nil, sourceHeight: Double? = nil) -> [RawDetection] {
        var dims = Array(shape.drop(while: { $0 == 1 }))
        if dims.count < 2 { dims = shape }
        guard dims.count >= 2, inputWidth > 0, inputHeight > 0 else { return [] }
        let a = dims[dims.count - 2], b = dims[dims.count - 1]
        guard a > 0, b > 0, values.count >= a * b else { return [] }

        let mapper = CoordinateMapper(inputWidth: inputWidth, inputHeight: inputHeight,
                                      sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        var detections: [RawDetection] = []

        if b == 6 && a > b {
            // End-to-end layout [N, 6].
            for i in 0..<a {
                let base = i * 6
                let score = Double(values[base + 4])
                guard score >= confidenceThreshold, score.isFinite else { continue }
                let x1 = Double(values[base]), y1 = Double(values[base + 1])
                let x2 = Double(values[base + 2]), y2 = Double(values[base + 3])
                // `Int(Float)` traps on NaN / infinity / out-of-range values (FP16 overflow, corrupted output).
                let clsValue = values[base + 5].rounded()
                guard clsValue.isFinite, clsValue >= 0, clsValue < 10_000,
                      x1.isFinite, y1.isFinite, x2.isFinite, y2.isFinite else { continue }
                let cls = Int(clsValue)
                if let box = mapper.box(x1: x1, y1: y1, x2: x2, y2: y2) {
                    detections.append(RawDetection(box: box, score: score, classIndex: cls))
                }
            }
            detections.sort { $0.score > $1.score }
            return Array(detections.prefix(maxDetections))
        }

        // Channels-first layout [C, N] with C = 4 + nc (C < N). Also accept the transposed [N, C].
        let channelsFirst = a < b
        let channels = channelsFirst ? a : b
        let count = channelsFirst ? b : a
        guard channels > 4 else { return [] }
        @inline(__always) func value(_ c: Int, _ i: Int) -> Float {
            channelsFirst ? values[c * count + i] : values[i * channels + c]
        }
        for i in 0..<count {
            var bestScore: Float = 0
            var bestClass = -1
            for c in 4..<channels {
                let s = value(c, i)
                if s > bestScore { bestScore = s; bestClass = c - 4 }
            }
            let score = Double(bestScore)
            guard bestClass >= 0, score >= confidenceThreshold, score.isFinite else { continue }
            let cx = Double(value(0, i)), cy = Double(value(1, i))
            let w = Double(value(2, i)), h = Double(value(3, i))
            if let box = mapper.box(x1: cx - w / 2, y1: cy - h / 2, x2: cx + w / 2, y2: cy + h / 2) {
                detections.append(RawDetection(box: box, score: score, classIndex: bestClass))
            }
        }
        return nonMaxSuppression(detections, iouThreshold: iouThreshold, classAware: true, maxDetections: maxDetections)
    }

    /// Greedy non-maximum suppression.
    public static func nonMaxSuppression(_ detections: [RawDetection], iouThreshold: Double,
                                         classAware: Bool = true, maxDetections: Int = 100) -> [RawDetection] {
        let sorted = detections.sorted { $0.score > $1.score }
        var kept: [RawDetection] = []
        for d in sorted {
            if kept.count >= maxDetections { break }
            let suppressed = kept.contains { k in
                (!classAware || k.classIndex == d.classIndex) && k.box.iou(d.box) > iouThreshold
            }
            if !suppressed { kept.append(d) }
        }
        return kept
    }

    /// Maps input-pixel coordinates to normalized source-image coordinates (undoing a letterbox if needed).
    struct CoordinateMapper {
        let inputWidth: Double
        let inputHeight: Double
        let gain: Double
        let padX: Double
        let padY: Double
        let srcW: Double
        let srcH: Double

        init(inputWidth: Double, inputHeight: Double, sourceWidth: Double?, sourceHeight: Double?) {
            self.inputWidth = inputWidth
            self.inputHeight = inputHeight
            if let sw = sourceWidth, let sh = sourceHeight, sw > 0, sh > 0 {
                let g = min(inputWidth / sw, inputHeight / sh)
                gain = g
                padX = (inputWidth - sw * g) / 2
                padY = (inputHeight - sh * g) / 2
                srcW = sw
                srcH = sh
            } else {
                gain = 0
                padX = 0
                padY = 0
                srcW = 0
                srcH = 0
            }
        }

        func box(x1: Double, y1: Double, x2: Double, y2: Double) -> BBox? {
            var nx1: Double, ny1: Double, nx2: Double, ny2: Double
            if gain > 0 {
                nx1 = (x1 - padX) / gain / srcW
                nx2 = (x2 - padX) / gain / srcW
                ny1 = (y1 - padY) / gain / srcH
                ny2 = (y2 - padY) / gain / srcH
            } else {
                nx1 = x1 / inputWidth
                nx2 = x2 / inputWidth
                ny1 = y1 / inputHeight
                ny2 = y2 / inputHeight
            }
            let box = BBox(x: min(nx1, nx2), y: min(ny1, ny2), width: abs(nx2 - nx1), height: abs(ny2 - ny1)).clamped
            return box.width > 0.002 && box.height > 0.002 ? box : nil
        }
    }
}

public enum COCOLabels {
    /// The 80 COCO class names in Ultralytics order (index = class id).
    public static let names: [String] = [
        "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat", "traffic light",
        "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat", "dog", "horse", "sheep", "cow",
        "elephant", "bear", "zebra", "giraffe", "backpack", "umbrella", "handbag", "tie", "suitcase", "frisbee",
        "skis", "snowboard", "sports ball", "kite", "baseball bat", "baseball glove", "skateboard", "surfboard",
        "tennis racket", "bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple",
        "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair", "couch",
        "potted plant", "bed", "dining table", "toilet", "tv", "laptop", "mouse", "remote", "keyboard",
        "cell phone", "microwave", "oven", "toaster", "sink", "refrigerator", "book", "clock", "vase",
        "scissors", "teddy bear", "hair drier", "toothbrush",
    ]

    public static func name(for index: Int) -> String {
        names.indices.contains(index) ? names[index] : "class\(index)"
    }
}
