import CoreML
import CoreVideo
import Foundation
import Vision

/// Load state of an optional Core ML model.
enum ModelStatus: Equatable, Sendable {
    case loading
    /// Loaded; the associated value is the model name (bundle resource name).
    case ready(String)
    /// The model is not in the app bundle.
    case missing
    /// The model exists but could not be loaded (error description).
    case failed(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// Model name when ready.
    var modelName: String? {
        if case .ready(let name) = self { return name }
        return nil
    }

    /// Short Russian description for status lines.
    var displayText: String {
        switch self {
        case .loading: return "загрузка…"
        case .ready(let name): return name
        case .missing: return "модель не установлена"
        case .failed(let message): return "ошибка: \(message)"
        }
    }
}

/// YOLO object detector (Core ML + Vision).
///
/// Supports both Ultralytics export flavours:
/// - pipeline models exported with `nms=True` → `VNRecognizedObjectObservation`s (Vision maps the boxes back to the
///   frame, `confidenceThreshold`/`iouThreshold` inputs are fed through `featureProvider`);
/// - raw models (`nms=False`, YOLO26/YOLOv10 end-to-end or YOLOv8/YOLO11 `[1, 4+nc, N]`) → an `MLMultiArray` that
///   is decoded by `YOLODecoder` (letterbox of `.scaleFit` undone with the frame size).
///
/// Not thread-safe: create, load and use it on one serial queue. Inference is synchronous on the caller's queue.
final class VehicleDetector {
    /// Bundle resource names (`.mlmodelc`), first found wins.
    static let candidateModelNames = ["RoadVisDetector", "yolo26n", "yolo11n", "yolov8n"]

    /// Per-frame detection options (taken from the user settings).
    struct Options: Equatable, Sendable {
        /// Minimum detector score ("уверенность", not accuracy).
        var confidenceThreshold: Double = 0.35
        /// NMS IoU threshold (raw models and pipeline models with an `iouThreshold` input).
        var iouThreshold: Double = 0.45
        var trackPedestrians: Bool = true
        var detectTrafficLights: Bool = true
        var maxDetections: Int = 60
    }

    /// Result of one inference.
    struct Output {
        var detections: [Detection]
        /// Wall-clock duration of the Vision request, milliseconds.
        var inferenceMs: Double
    }

    private(set) var status: ModelStatus = .loading

    private var coreMLModel: MLModel?
    private var visionModel: VNCoreMLModel?
    private var request: VNCoreMLRequest?
    private var inputWidth: Double = 640
    private var inputHeight: Double = 640
    private var classNames: [String] = COCOLabels.names
    private var thresholdInputNames: Set<String> = []
    private var appliedThresholds: (confidence: Double, iou: Double)?
    /// Reused buffer for raw tensor values (avoids a large allocation per frame).
    private var tensorBuffer: [Float] = []

    // MARK: - Loading

    /// Loads the first available detector model from `bundle`. Safe to call again (no-op when already ready).
    @discardableResult
    func load(bundle: Bundle = .main) -> ModelStatus {
        if status.isReady { return status }
        guard let located = Self.locateModel(in: bundle) else {
            status = .missing
            return status
        }
        let (name, url) = located
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            let model = try MLModel(contentsOf: url, configuration: configuration)
            let vnModel = try VNCoreMLModel(for: model)
            let request = VNCoreMLRequest(model: vnModel)
            request.imageCropAndScaleOption = .scaleFit

            let description = model.modelDescription
            if let imageInput = description.inputDescriptionsByName.values.first(where: { $0.type == .image }),
               let constraint = imageInput.imageConstraint,
               constraint.pixelsWide > 0, constraint.pixelsHigh > 0 {
                inputWidth = Double(constraint.pixelsWide)
                inputHeight = Double(constraint.pixelsHigh)
            }
            thresholdInputNames = Set(description.inputDescriptionsByName.keys)
                .intersection(["iouThreshold", "confidenceThreshold"])
            classNames = Self.classNames(from: description) ?? COCOLabels.names

            coreMLModel = model
            visionModel = vnModel
            self.request = request
            appliedThresholds = nil
            status = .ready(name)
        } catch {
            status = .failed(error.localizedDescription)
        }
        return status
    }

    private static func locateModel(in bundle: Bundle) -> (String, URL)? {
        for name in candidateModelNames {
            if let url = bundle.url(forResource: name, withExtension: "mlmodelc") {
                return (name, url)
            }
        }
        return nil
    }

    /// Class names from the model: `classLabels` (classifier-style metadata) or the Ultralytics `names`
    /// user-defined metadata (a Python dict literal such as `{0: 'person', 1: 'bicycle', …}`).
    static func classNames(from description: MLModelDescription) -> [String]? {
        if let labels = description.classLabels?.compactMap({ $0 as? String }), !labels.isEmpty {
            return labels
        }
        guard let userDefined = description.metadata[MLModelMetadataKey.creatorDefinedKey] as? [String: String],
              let namesLiteral = userDefined["names"] else { return nil }
        return parseUltralyticsNames(namesLiteral)
    }

    /// Parses `{0: 'person', 1: "traffic light", …}` into an index-ordered array (gaps filled with "classN").
    static func parseUltralyticsNames(_ literal: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d+)\s*:\s*(['"])(.*?)\2"#) else { return nil }
        let ns = literal as NSString
        var byIndex: [Int: String] = [:]
        for match in regex.matches(in: literal, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges >= 4,
                  let index = Int(ns.substring(with: match.range(at: 1))) else { continue }
            byIndex[index] = ns.substring(with: match.range(at: 3))
        }
        guard let maxIndex = byIndex.keys.max(), maxIndex < 10_000 else { return nil }
        return (0...maxIndex).map { byIndex[$0] ?? "class\($0)" }
    }

    // MARK: - Inference

    /// Runs the detector on the frame behind `handler` (created with orientation `.up` for an upright buffer).
    /// - Parameters:
    ///   - imageWidth/imageHeight: pixel size of the buffer (needed to undo the `.scaleFit` letterbox).
    /// - Returns: nil when the model is not loaded or Vision failed.
    func detect(handler: VNImageRequestHandler, imageWidth: Int, imageHeight: Int, options: Options) -> Output? {
        guard let request, let visionModel else { return nil }
        updateThresholds(on: visionModel, options: options)

        let start = DispatchTime.now().uptimeNanoseconds
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000

        let results = request.results ?? []
        var detections: [Detection] = []
        let objects = results.compactMap { $0 as? VNRecognizedObjectObservation }
        if !objects.isEmpty {
            detections = mapRecognizedObjects(objects, options: options)
        } else {
            let features = results.compactMap { $0 as? VNCoreMLFeatureValueObservation }
            detections = decodeRawFeatures(features, imageWidth: imageWidth, imageHeight: imageHeight, options: options)
        }
        return Output(detections: detections, inferenceMs: elapsedMs)
    }

    /// Feeds the NMS thresholds into pipeline models that expose them as optional inputs.
    private func updateThresholds(on model: VNCoreMLModel, options: Options) {
        guard !thresholdInputNames.isEmpty else { return }
        let confidence = min(max(options.confidenceThreshold, 0.01), 0.99)
        let iou = min(max(options.iouThreshold, 0.05), 0.95)
        if let applied = appliedThresholds, applied.confidence == confidence, applied.iou == iou { return }
        var values: [String: Any] = [:]
        if thresholdInputNames.contains("confidenceThreshold") {
            values["confidenceThreshold"] = MLFeatureValue(double: confidence)
        }
        if thresholdInputNames.contains("iouThreshold") {
            values["iouThreshold"] = MLFeatureValue(double: iou)
        }
        if let provider = try? MLDictionaryFeatureProvider(dictionary: values) {
            model.featureProvider = provider
            appliedThresholds = (confidence, iou)
        }
    }

    private func mapRecognizedObjects(_ objects: [VNRecognizedObjectObservation], options: Options) -> [Detection] {
        var detections: [Detection] = []
        detections.reserveCapacity(objects.count)
        for object in objects {
            guard let top = object.labels.first else { continue }
            let confidence = Double(object.confidence)
            guard confidence >= options.confidenceThreshold,
                  let kind = Self.acceptedKind(label: top.identifier, classIndex: nil, options: options) else { continue }
            let box = BBox(visionRect: object.boundingBox).clamped
            guard box.width > 0.002, box.height > 0.002 else { continue }
            detections.append(Detection(kind: kind, label: top.identifier, confidence: confidence, box: box))
        }
        detections.sort { $0.confidence > $1.confidence }
        return Array(detections.prefix(options.maxDetections))
    }

    private func decodeRawFeatures(_ features: [VNCoreMLFeatureValueObservation], imageWidth: Int, imageHeight: Int,
                                   options: Options) -> [Detection] {
        // The detection head is the largest multi-array output (segmentation models also emit mask prototypes).
        let arrays = features.compactMap { $0.featureValue.multiArrayValue }.filter { $0.shape.count >= 2 }
        guard let tensor = arrays.max(by: { $0.count < $1.count }),
              let shape = Self.copyFloats(from: tensor, into: &tensorBuffer) else { return [] }
        let raw = YOLODecoder.decode(values: tensorBuffer, shape: shape,
                                     inputWidth: inputWidth, inputHeight: inputHeight,
                                     confidenceThreshold: options.confidenceThreshold,
                                     iouThreshold: options.iouThreshold,
                                     maxDetections: options.maxDetections * 2,
                                     sourceWidth: imageWidth > 0 ? Double(imageWidth) : nil,
                                     sourceHeight: imageHeight > 0 ? Double(imageHeight) : nil)
        var detections: [Detection] = []
        detections.reserveCapacity(raw.count)
        for item in raw {
            let label = classNames.indices.contains(item.classIndex) ? classNames[item.classIndex] : COCOLabels.name(for: item.classIndex)
            guard let kind = Self.acceptedKind(label: label, classIndex: item.classIndex, options: options) else { continue }
            detections.append(Detection(kind: kind, label: label, confidence: item.score, box: item.box))
        }
        return Array(detections.prefix(options.maxDetections))
    }

    /// Maps a label to a `VehicleKind` and applies the class filters from the settings.
    static func acceptedKind(label: String, classIndex: Int?, options: Options) -> VehicleKind? {
        var kind = VehicleKind(label: label)
        if kind == nil, let classIndex, label.hasPrefix("class") {
            kind = VehicleKind(cocoIndex: classIndex)
        }
        guard let kind else { return nil }
        switch kind {
        case .person where !options.trackPedestrians: return nil
        case .trafficLight where !options.detectTrafficLights: return nil
        default: return kind
        }
    }

    // MARK: - MLMultiArray → [Float]

    /// Copies a multi-array into `buffer` as contiguous row-major `Float`s, honouring the array's strides
    /// (Core ML may pad rows) and data type. Returns the logical shape, or nil for unsupported layouts.
    static func copyFloats(from array: MLMultiArray, into buffer: inout [Float]) -> [Int]? {
        let shape = array.shape.map { $0.intValue }
        let strides = array.strides.map { $0.intValue }
        guard !shape.isEmpty, shape.count == strides.count, shape.allSatisfy({ $0 > 0 }) else { return nil }
        let total = shape.reduce(1, *)
        guard total > 0, total <= 50_000_000 else { return nil }
        if buffer.count != total {
            buffer = [Float](repeating: 0, count: total)
        }

        let dataType = array.dataType
        var elementSize = 0
        if dataType == .float32 || dataType == .int32 {
            elementSize = 4
        } else if dataType == .double {
            elementSize = 8
        } else if dataType == .float16 {
            #if arch(arm64)
            elementSize = 2
            #endif
        }

        // Highest element offset reachable with these strides (for a bounds check).
        let maxOffset = zip(shape, strides).reduce(0) { $0 + ($1.0 - 1) * max(0, $1.1) }

        guard elementSize > 0 else {
            copyViaNSNumber(array, shape: shape, into: &buffer)
            return shape
        }

        let rank = shape.count
        let innerCount = shape[rank - 1]
        let innerStride = strides[rank - 1]
        let outerCount = total / innerCount

        let copied: Bool = array.withUnsafeBytes { raw -> Bool in
            guard (maxOffset + 1) * elementSize <= raw.count else { return false }
            return buffer.withUnsafeMutableBufferPointer { destination -> Bool in
                var counter = [Int](repeating: 0, count: rank)
                for outer in 0..<outerCount {
                    var base = 0
                    for d in 0..<(rank - 1) { base += counter[d] * strides[d] }
                    let dst = outer * innerCount
                    if dataType == .float32 {
                        let src = raw.bindMemory(to: Float.self)
                        for i in 0..<innerCount { destination[dst + i] = src[base + i * innerStride] }
                    } else if dataType == .double {
                        let src = raw.bindMemory(to: Double.self)
                        for i in 0..<innerCount { destination[dst + i] = Float(src[base + i * innerStride]) }
                    } else if dataType == .int32 {
                        let src = raw.bindMemory(to: Int32.self)
                        for i in 0..<innerCount { destination[dst + i] = Float(src[base + i * innerStride]) }
                    } else {
                        #if arch(arm64)
                        let src = raw.bindMemory(to: Float16.self)
                        for i in 0..<innerCount { destination[dst + i] = Float(src[base + i * innerStride]) }
                        #endif
                    }
                    // Advance the multi-index over all but the innermost dimension (row-major).
                    var d = rank - 2
                    while d >= 0 {
                        counter[d] += 1
                        if counter[d] < shape[d] { break }
                        counter[d] = 0
                        d -= 1
                    }
                }
                return true
            }
        }
        if !copied {
            copyViaNSNumber(array, shape: shape, into: &buffer)
        }
        return shape
    }

    /// Slow but layout-agnostic fallback (Float16 on non-arm64 simulators, unknown data types).
    private static func copyViaNSNumber(_ array: MLMultiArray, shape: [Int], into buffer: inout [Float]) {
        let rank = shape.count
        var index = [Int](repeating: 0, count: rank)
        var key = [NSNumber](repeating: 0, count: rank)
        for linear in 0..<buffer.count {
            for d in 0..<rank { key[d] = NSNumber(value: index[d]) }
            buffer[linear] = array[key].floatValue
            var d = rank - 1
            while d >= 0 {
                index[d] += 1
                if index[d] < shape[d] { break }
                index[d] = 0
                d -= 1
            }
        }
    }
}
