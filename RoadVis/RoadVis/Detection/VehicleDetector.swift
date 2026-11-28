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

    /// Short localized description for status lines.
    var displayText: String {
        switch self {
        case .loading: return L("status.loading")
        case .ready(let name): return name
        case .missing: return L("status.modelMissing")
        case .failed(let message): return L("status.error", message)
        }
    }
}

/// A detector model downloaded from the RoadVis Trainer (`ModelUpdateService`): compiled `.mlmodelc` directories
/// of the landscape and portrait packages of one accepted version.
struct DownloadedDetectorModel: Equatable, Sendable {
    let version: String
    let landscapeName: String
    let landscapeURL: URL
    let portraitName: String
    let portraitURL: URL

    /// Key of the loaded model (`ModelStatus.ready` name, `Output.modelName`): "<package>@<version>".
    func loadedName(landscape: Bool) -> String {
        "\(landscape ? landscapeName : portraitName)@\(version)"
    }
}

/// YOLO object detector (Core ML + Vision).
///
/// Models. The app bundles four packages with a rectangular 16:9 input, so an upright camera frame fills the whole
/// model input (nothing is spent on letterbox padding):
/// - `RoadVisDetector` (YOLO11s, 960×544) and `RoadVisDetectorPortrait` (YOLO11s, 544×960) — `.full` quality;
/// - `RoadVisDetectorLite` / `RoadVisDetectorLitePortrait` (YOLO11n, same inputs) — `.lite` quality, chosen by the
///   worker's `DetectorQualityGovernor` while inference is too slow or the phone is hot.
/// The model is picked per frame from the frame orientation and `preferredLevel` and loaded lazily; when one is
/// missing or fails to load the next candidate is used (other tier → other orientation → the legacy single models
/// `yolo26n` / `yolo11n` / `yolov8n`), so a broken package degrades recognition instead of crashing it.
///
/// Box geometry. Both Ultralytics export flavours are supported:
/// - pipeline models exported with `nms=True` → `VNRecognizedObjectObservation`s. Vision normalises their boxes to
///   the model input, and whether it undoes a `.scaleFit` letterbox is undocumented — so pipelines always run with
///   `.scaleFill`: no padding exists, input-normalised equals frame-normalised under any Vision behaviour (with the
///   bundled models the stretch is 0.7 %; a model of another aspect ratio is stretched more, never misplaced);
/// - raw models (`nms=False`: YOLO26/YOLOv10 end-to-end or YOLOv8/YOLO11 `[1, 4+nc, N]`) → an `MLMultiArray` decoded
///   by `YOLODecoder`: `.scaleFill` when the aspect ratios match (`DetectorInputGeometry.fit`), otherwise `.scaleFit`
///   with the letterbox undone explicitly from the frame size.
///
/// Thresholds. `Options.confidenceThreshold` is the settings slider. The detector itself (NMS stage / decoder) runs
/// at `DetectionThresholds.detectorFloor`, the lowest score the tracker can still use; the per-class thresholds are
/// applied once, by `ObjectTracker` (`DetectionThresholds.perClass`), not a second time here.
///
/// Not thread-safe: create, load and use it on one serial queue. Inference is synchronous on the caller's queue.
final class VehicleDetector {
    static let landscapeModelName = "RoadVisDetector"
    static let portraitModelName = "RoadVisDetectorPortrait"
    static let liteLandscapeModelName = "RoadVisDetectorLite"
    static let litePortraitModelName = "RoadVisDetectorLitePortrait"
    /// Separator between the package name and the version in the name of a downloaded model.
    static let downloadedNameSeparator: Character = "@"
    /// Single-model bundles of earlier versions / user-supplied exports (any input size), tried last.
    static let legacyModelNames = ["yolo26n", "yolo11n", "yolov8n"]

    /// Bundle resource names (`.mlmodelc`) in the order they are tried for a frame orientation and quality level.
    static func candidateModelNames(landscape: Bool, level: DetectorQualityGovernor.Level) -> [String] {
        let full = landscape ? landscapeModelName : portraitModelName
        let lite = landscape ? liteLandscapeModelName : litePortraitModelName
        let otherFull = landscape ? portraitModelName : landscapeModelName
        let otherLite = landscape ? litePortraitModelName : liteLandscapeModelName
        var names: [String] = level == .lite ? [lite, full] : [full, lite]
        // A model of the other orientation still works (stretched), which beats having no detector at all.
        names.append(contentsOf: level == .lite ? [otherLite, otherFull] : [otherFull, otherLite])
        names.append(contentsOf: legacyModelNames)
        return names
    }

    /// Model name and version as reported in the training-sample metadata (`LearningSampleMeta.model`): a downloaded
    /// model "<package>@<version>" → (package, version); a bundled one → (name, "bundled-<arch>-<input>").
    static func modelIdentity(loadedName: String) -> (name: String, version: String) {
        if let separator = loadedName.firstIndex(of: downloadedNameSeparator) {
            let name = String(loadedName[..<separator])
            let version = String(loadedName[loadedName.index(after: separator)...])
            return (name, version)
        }
        switch loadedName {
        case landscapeModelName: return (loadedName, "bundled-yolo11s-960x544")
        case portraitModelName: return (loadedName, "bundled-yolo11s-544x960")
        case liteLandscapeModelName: return (loadedName, "bundled-yolo11n-960x544")
        case litePortraitModelName: return (loadedName, "bundled-yolo11n-544x960")
        default: return (loadedName, "bundled-\(loadedName)")
        }
    }

    /// Per-frame detection options (taken from the user settings).
    struct Options: Equatable, Sendable {
        /// Settings slider: minimum detector score ("уверенность", not accuracy) of cars / trucks / buses; the other
        /// classes follow it with the offsets of `DetectionThresholds`.
        var confidenceThreshold: Double = DetectionThresholds.defaultGlobal
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
        /// Bundle name of the model that produced the detections.
        var modelName: String
    }

    /// One loaded Core ML model with its Vision request.
    private final class LoadedModel {
        let name: String
        let visionModel: VNCoreMLModel
        let request: VNCoreMLRequest
        let inputWidth: Double
        let inputHeight: Double
        /// True for `nms=True` exports (outputs `confidence` + `coordinates` → recognized-object observations).
        let isPipeline: Bool
        let classNames: [String]
        let thresholdInputNames: Set<String>
        var appliedThresholds: (confidence: Double, iou: Double)?
        /// Crop option currently set on `request` (true = `.scaleFill`); nil until the first frame.
        var usesFill: Bool?

        init(name: String, visionModel: VNCoreMLModel, request: VNCoreMLRequest, inputWidth: Double,
             inputHeight: Double, isPipeline: Bool, classNames: [String], thresholdInputNames: Set<String>) {
            self.name = name
            self.visionModel = visionModel
            self.request = request
            self.inputWidth = inputWidth
            self.inputHeight = inputHeight
            self.isPipeline = isPipeline
            self.classNames = classNames
            self.thresholdInputNames = thresholdInputNames
        }
    }

    /// State of the model used for the latest frame (or of the initial load).
    private(set) var status: ModelStatus = .loading
    /// Quality level requested for the next frames (the worker's `DetectorQualityGovernor` decides).
    var preferredLevel: DetectorQualityGovernor.Level = .full
    /// Downloaded model preferred for the `.full` level (nil = bundled models only). Setting it drops the loaded
    /// models of the previous downloaded version; the new one is loaded with the next frame.
    var downloadedModel: DownloadedDetectorModel? {
        didSet {
            guard downloadedModel != oldValue else { return }
            for name in loadedModels.keys where name.contains(Self.downloadedNameSeparator) {
                loadedModels[name] = nil
            }
            unavailableNames = unavailableNames.filter { !$0.contains(Self.downloadedNameSeparator) }
            pendingDownloadedFailure = nil
            isUsingDownloadedModel = false
        }
    }
    /// True when the model of the latest frame is the downloaded one.
    private(set) var isUsingDownloadedModel = false
    /// (version, error) of a downloaded model that failed to load, until `takeDownloadedModelFailure()` reads it.
    private var pendingDownloadedFailure: (version: String, message: String)?

    private var bundle: Bundle = .main
    /// Loaded models by bundle name. Only models used for the current frame orientation are kept.
    private var loadedModels: [String: LoadedModel] = [:]
    /// Names that are not in the bundle or failed to load (not tried again).
    private var unavailableNames: Set<String> = []
    private var lastLoadError: String?
    private var foundAnyModel = false
    private var loadedForLandscape: Bool?
    /// Reused buffer for raw tensor values (avoids a large allocation per frame).
    private var tensorBuffer: [Float] = []

    // MARK: - Loading

    /// Loads the detector for the given frame orientation from `bundle`. Safe to call again (no-op when already
    /// ready). The model of the other orientation / quality level is loaded on first use by `detect`.
    @discardableResult
    func load(bundle: Bundle = .main, landscape: Bool = true) -> ModelStatus {
        if status.isReady { return status }
        self.bundle = bundle
        _ = model(landscape: landscape, level: preferredLevel)
        return status
    }

    /// The model for a frame orientation and quality level: the first candidate that is in the bundle and loads.
    /// Updates `status`. Returns nil when no candidate is usable.
    private func model(landscape: Bool, level: DetectorQualityGovernor.Level) -> LoadedModel? {
        let orientationChanged: Bool = loadedForLandscape != landscape
        if orientationChanged, loadedForLandscape != nil {
            // The device was rotated: free the models of the previous orientation.
            loadedModels.removeAll()
        }
        loadedForLandscape = landscape
        if orientationChanged {
            // Warm the other quality tier now (a load happens here anyway: start-up or rotation), so a later
            // full <-> lite switch of the governor finds its model loaded and never loads one on a driving frame.
            let otherLevel: DetectorQualityGovernor.Level = level == .full ? .lite : .full
            _ = resolveModel(landscape: landscape, level: otherLevel)
        }
        // The requested level is resolved last, so `status` names the model in use.
        return resolveModel(landscape: landscape, level: level)
    }

    /// First candidate for the orientation and level that is in the bundle and loads (already loaded ones are
    /// reused). Updates `status`.
    private func resolveModel(landscape: Bool, level: DetectorQualityGovernor.Level) -> LoadedModel? {
        if level == .full, let downloaded = resolveDownloadedModel(landscape: landscape) {
            isUsingDownloadedModel = true
            return downloaded
        }
        isUsingDownloadedModel = false
        for name in Self.candidateModelNames(landscape: landscape, level: level) {
            if let loaded = loadedModels[name] {
                setStatus(.ready(name))
                return loaded
            }
            if unavailableNames.contains(name) { continue }
            guard let url = bundle.url(forResource: name, withExtension: "mlmodelc") else {
                unavailableNames.insert(name)
                continue
            }
            foundAnyModel = true
            do {
                let loaded = try Self.loadModel(name: name, url: url)
                loadedModels[name] = loaded
                setStatus(.ready(name))
                return loaded
            } catch {
                unavailableNames.insert(name)
                lastLoadError = error.localizedDescription
            }
        }
        setStatus(foundAnyModel ? .failed(lastLoadError ?? "") : .missing)
        return nil
    }

    /// The downloaded model for the orientation (loaded on first use); nil without one or when it failed to load
    /// (the failure is remembered for `takeDownloadedModelFailure()` and not retried for this version).
    private func resolveDownloadedModel(landscape: Bool) -> LoadedModel? {
        guard let downloaded = downloadedModel else { return nil }
        let name = downloaded.loadedName(landscape: landscape)
        if let loaded = loadedModels[name] {
            setStatus(.ready(name))
            return loaded
        }
        if unavailableNames.contains(name) { return nil }
        let url = landscape ? downloaded.landscapeURL : downloaded.portraitURL
        do {
            let loaded = try Self.loadModel(name: name, url: url,
                                            fallbackClassNames: ModelUpdatePolicy.publishedClassNames)
            loadedModels[name] = loaded
            setStatus(.ready(name))
            return loaded
        } catch {
            unavailableNames.insert(name)
            pendingDownloadedFailure = (downloaded.version, error.localizedDescription)
            return nil
        }
    }

    /// A downloaded model that failed to load since the last call: (version, error message). Read once.
    func takeDownloadedModelFailure() -> (version: String, message: String)? {
        defer { pendingDownloadedFailure = nil }
        return pendingDownloadedFailure
    }

    private func setStatus(_ newStatus: ModelStatus) {
        if status != newStatus { status = newStatus }
    }

    /// Loads one compiled model. CPU + Neural Engine is requested first (what the Ultralytics iOS SDK uses; keeps the
    /// GPU free for the camera preview and the map); all compute units are the fallback when that fails.
    /// `fallbackClassNames`: class names used when the model carries none (COCO for the bundled models, the 8
    /// published classes `ModelUpdatePolicy.publishedClassNames` for a downloaded one).
    private static func loadModel(name: String, url: URL,
                                  fallbackClassNames: [String] = COCOLabels.names) throws -> LoadedModel {
        let model: MLModel
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            model = try MLModel(contentsOf: url, configuration: configuration)
        } catch {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            model = try MLModel(contentsOf: url, configuration: configuration)
        }
        let vnModel = try VNCoreMLModel(for: model)
        let request = VNCoreMLRequest(model: vnModel)

        let description = model.modelDescription
        var inputWidth: Double = 640
        var inputHeight: Double = 640
        if let imageInput = description.inputDescriptionsByName.values.first(where: { $0.type == .image }),
           let constraint = imageInput.imageConstraint,
           constraint.pixelsWide > 0, constraint.pixelsHigh > 0 {
            inputWidth = Double(constraint.pixelsWide)
            inputHeight = Double(constraint.pixelsHigh)
        }
        let outputs = description.outputDescriptionsByName
        let isPipeline = outputs["coordinates"] != nil && outputs["confidence"] != nil
        let thresholdInputNames = Set(description.inputDescriptionsByName.keys)
            .intersection(["iouThreshold", "confidenceThreshold"])
        let classNames = Self.classNames(from: description) ?? fallbackClassNames
        return LoadedModel(name: name, visionModel: vnModel, request: request, inputWidth: inputWidth,
                           inputHeight: inputHeight, isPipeline: isPipeline, classNames: classNames,
                           thresholdInputNames: thresholdInputNames)
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
    ///   - imageWidth/imageHeight: pixel size of the buffer (selects the landscape / portrait model and, for raw
    ///     models of another aspect ratio, undoes the `.scaleFit` letterbox).
    /// - Returns: nil when no model is usable or Vision failed.
    func detect(handler: VNImageRequestHandler, imageWidth: Int, imageHeight: Int, options: Options) -> Output? {
        let landscape = DetectorInputGeometry.isLandscape(width: Double(imageWidth), height: Double(imageHeight))
        guard let loaded = model(landscape: landscape, level: preferredLevel) else { return nil }
        let geometry = DetectorInputGeometry(inputWidth: loaded.inputWidth, inputHeight: loaded.inputHeight,
                                             sourceWidth: Double(imageWidth), sourceHeight: Double(imageHeight))
        let fill = loaded.isPipeline || geometry.fit == .fill
        if loaded.usesFill != fill {
            loaded.request.imageCropAndScaleOption = fill ? .scaleFill : .scaleFit
            loaded.usesFill = fill
        }
        let floor = DetectionThresholds.detectorFloor(global: options.confidenceThreshold)
        updateThresholds(on: loaded, confidence: floor, iou: options.iouThreshold)

        let request = loaded.request
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
            detections = mapRecognizedObjects(objects, floor: floor, options: options)
        } else {
            let features = results.compactMap { $0 as? VNCoreMLFeatureValueObservation }
            detections = decodeRawFeatures(features, model: loaded, floor: floor,
                                           sourceWidth: fill ? nil : Double(imageWidth),
                                           sourceHeight: fill ? nil : Double(imageHeight), options: options)
        }
        // One object reported as car + truck (per-class NMS) would open two tracks.
        detections = CrossClassDuplicates.suppress(detections)
        return Output(detections: Array(detections.prefix(options.maxDetections)), inferenceMs: elapsedMs,
                      modelName: loaded.name)
    }

    /// Feeds the NMS thresholds into pipeline models that expose them as optional inputs.
    private func updateThresholds(on loaded: LoadedModel, confidence rawConfidence: Double, iou rawIoU: Double) {
        guard !loaded.thresholdInputNames.isEmpty else { return }
        let confidence = min(max(rawConfidence, 0.01), 0.99)
        let iou = min(max(rawIoU, 0.05), 0.95)
        if let applied = loaded.appliedThresholds, applied.confidence == confidence, applied.iou == iou { return }
        var values: [String: Any] = [:]
        if loaded.thresholdInputNames.contains("confidenceThreshold") {
            values["confidenceThreshold"] = MLFeatureValue(double: confidence)
        }
        if loaded.thresholdInputNames.contains("iouThreshold") {
            values["iouThreshold"] = MLFeatureValue(double: iou)
        }
        if let provider = try? MLDictionaryFeatureProvider(dictionary: values) {
            loaded.visionModel.featureProvider = provider
            loaded.appliedThresholds = (confidence, iou)
        }
    }

    /// True when the tracker can use a detection of this class and score at all (class threshold × continuation
    /// factor). Everything else is dropped here so it does not use up `maxDetections`.
    private static func isUsable(kind: VehicleKind, confidence: Double, options: Options) -> Bool {
        let threshold = DetectionThresholds.threshold(for: kind, global: options.confidenceThreshold)
        return confidence >= threshold * DetectionThresholds.continuationFactor
    }

    private func mapRecognizedObjects(_ objects: [VNRecognizedObjectObservation], floor: Double,
                                      options: Options) -> [Detection] {
        var detections: [Detection] = []
        detections.reserveCapacity(objects.count)
        for object in objects {
            guard let top = object.labels.first else { continue }
            let confidence = Double(object.confidence)
            guard confidence >= floor,
                  let kind = Self.acceptedKind(label: top.identifier, classIndex: nil, options: options),
                  Self.isUsable(kind: kind, confidence: confidence, options: options) else { continue }
            // `.scaleFill`: the box is normalised to the model input, which is the whole frame.
            let box = BBox(visionRect: object.boundingBox).clamped
            guard box.width > 0.002, box.height > 0.002 else { continue }
            detections.append(Detection(kind: kind, label: top.identifier, confidence: confidence, box: box))
        }
        detections.sort { $0.confidence > $1.confidence }
        return detections
    }

    private func decodeRawFeatures(_ features: [VNCoreMLFeatureValueObservation], model loaded: LoadedModel,
                                   floor: Double, sourceWidth: Double?, sourceHeight: Double?,
                                   options: Options) -> [Detection] {
        // The detection head is the largest multi-array output (segmentation models also emit mask prototypes).
        let arrays = features.compactMap { $0.featureValue.multiArrayValue }.filter { $0.shape.count >= 2 }
        guard let tensor = arrays.max(by: { $0.count < $1.count }),
              let shape = Self.copyFloats(from: tensor, into: &tensorBuffer) else { return [] }
        let raw = YOLODecoder.decode(values: tensorBuffer, shape: shape,
                                     inputWidth: loaded.inputWidth, inputHeight: loaded.inputHeight,
                                     confidenceThreshold: floor,
                                     iouThreshold: options.iouThreshold,
                                     maxDetections: options.maxDetections * 2,
                                     sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        let classNames = loaded.classNames
        var detections: [Detection] = []
        detections.reserveCapacity(raw.count)
        for item in raw {
            let label = classNames.indices.contains(item.classIndex) ? classNames[item.classIndex] : COCOLabels.name(for: item.classIndex)
            guard let kind = Self.acceptedKind(label: label, classIndex: item.classIndex, options: options),
                  Self.isUsable(kind: kind, confidence: item.score, options: options) else { continue }
            detections.append(Detection(kind: kind, label: label, confidence: item.score, box: item.box))
        }
        return detections
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
