import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Vision

/// Collects hard training frames on the device (`docs/TRAINING_API.md` §1–2): runs `HardExampleSelector` on every
/// processed frame and saves the kept ones (JPEG, long side 960 px, quality 0.8, faces pixellated + metadata json)
/// to `LearningStore`.
///
/// Threading
/// - `process`, `resetMemory`, `resetTrip` and `disable` are called on the recognition processing queue only
///   (`RecognitionWorker.queue`); the selector and the held frame are confined to it.
/// - Per frame the cost is a few array copies; the quality metrics (≈ 0.5 ms on a 160-px gray copy) are computed only
///   when the selector would keep the frame apart from its quality. The previous camera buffer is retained only
///   while it can still be kept (`HardExampleSelector.pendingMayBeKept`).
/// - A kept frame is copied out of the camera's buffer pool (one memcpy) and encoded on a private utility queue
///   (face detection, scaling, JPEG, file write, retention).
final class LearningCollector: @unchecked Sendable {
    /// Per-frame context that goes into the metadata.
    struct Context: Sendable {
        var sendLocation: Bool
        var latitude: Double?
        var longitude: Double?
        /// Name of the detector model that produced the frame's detections (`VehicleDetector.Output.modelName`).
        var modelName: String
        var storageLimitMB: Int
    }

    /// Reported (on the utility queue) after a kept frame was written or the quality gate rejected one.
    enum Event: Sendable {
        case saved(keptThisTrip: Int, deletedByLimit: Int)
        case rejectedByQuality
        case saveFailed(String)
    }

    /// Long side of the saved JPEG, pixels.
    static let jpegLongSide: CGFloat = 960
    static let jpegQuality: CGFloat = 0.8
    static let platform = "ios"

    private let store: LearningStore
    private let encodeQueue = DispatchQueue(label: "learning.encode", qos: .utility)
    private lazy var ciContext = CIContext(options: [.cacheIntermediates: false])

    // MARK: Processing-queue confined
    private var selector = HardExampleSelector()
    private var heldBuffer: CVPixelBuffer?
    private var heldContext: Context?
    private var heldDate = Date()
    private var isActive = false

    // MARK: Lock-protected
    private let lock = NSLock()
    private var storedEventHandler: (@Sendable (Event) -> Void)?

    init(store: LearningStore = .shared) {
        self.store = store
    }

    /// Receives collector events (on the utility queue).
    var eventHandler: (@Sendable (Event) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedEventHandler
        }
        set {
            lock.lock()
            storedEventHandler = newValue
            lock.unlock()
        }
    }

    // MARK: - Processing queue

    /// Feeds one processed frame. `pixelBuffer` is the upright BGRA frame `frame` was computed from. The decision
    /// made here is about the PREVIOUS frame (the selector's 1-frame memory), whose buffer was held for this.
    func process(pixelBuffer: CVPixelBuffer, frame: HardExampleFrame, context: Context) {
        isActive = true
        let previousBuffer = heldBuffer
        var measured: FrameQualityMetrics?
        let decision = selector.evaluate(frame) { _ in
            guard let previousBuffer else { return nil }
            let metrics = Self.quality(of: previousBuffer)
            measured = metrics
            return metrics
        }
        if decision.keep, let previousBuffer, let previousContext = heldContext, let previousFrame = frameOfDecision,
           let metrics = measured, let copy = Self.copy(previousBuffer) {
            enqueueSave(buffer: copy, reasons: decision.reasons, context: previousContext, capturedAt: heldDate,
                        frame: previousFrame, quality: metrics)
        } else if measured != nil && !decision.keep {
            eventHandler?(.rejectedByQuality)
        }
        // Hold this frame only while the next call can still keep it.
        frameOfDecision = frame
        if selector.pendingMayBeKept() {
            heldBuffer = pixelBuffer
            heldContext = context
            heldDate = Date()
        } else {
            heldBuffer = nil
            heldContext = nil
        }
    }

    /// The frame `selector` holds in memory (decided by the next `process`).
    private var frameOfDecision: HardExampleFrame?

    /// Frames stopped or the tracker was reset: forget the held frame (vanished tracks are not dead ones).
    func resetMemory() {
        selector.resetMemory()
        frameOfDecision = nil
        heldBuffer = nil
        heldContext = nil
    }

    /// A trip started: the per-trip counter restarts.
    func resetTrip() {
        selector.resetTrip()
    }

    /// Learning switched off: drop the held buffer (cheap when already off).
    func disable() {
        guard isActive else { return }
        isActive = false
        resetMemory()
    }

    // MARK: - Quality

    /// Sharpness / brightness / dHash of a BGRA buffer on its 160-px-wide gray copy.
    static func quality(of buffer: CVPixelBuffer) -> FrameQualityMetrics? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA, !CVPixelBufferIsPlanar(buffer),
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { _ = CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let gray: GrayImage = FrameQuality.grayFromBGRA(
            base: UnsafeRawPointer(base), width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), targetWidth: FrameQuality.analysisWidth)
        guard gray.width > 0 else { return nil }
        return FrameQuality.metrics(gray)
    }

    /// Copies a BGRA camera buffer into a new buffer owned by the app (the camera's pool gets its buffer back).
    static func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA, !CVPixelBufferIsPlanar(source) else {
            return nil
        }
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        var destination: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &destination) == kCVReturnSuccess,
              let copy = destination else { return nil }
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return nil }
        defer { _ = CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(copy, []) == kCVReturnSuccess else { return nil }
        defer { _ = CVPixelBufferUnlockBaseAddress(copy, []) }
        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let destinationBase = CVPixelBufferGetBaseAddress(copy) else { return nil }
        let sourceStride = CVPixelBufferGetBytesPerRow(source)
        let destinationStride = CVPixelBufferGetBytesPerRow(copy)
        let rowBytes = min(width * 4, min(sourceStride, destinationStride))
        for row in 0..<height {
            memcpy(destinationBase + row * destinationStride, sourceBase + row * sourceStride, rowBytes)
        }
        return copy
    }

    // MARK: - Encoding (utility queue)

    private func enqueueSave(buffer: CVPixelBuffer, reasons: [String], context: Context, capturedAt: Date,
                             frame: HardExampleFrame, quality: FrameQualityMetrics) {
        let handoff = OwnedBuffer(buffer: buffer)
        let keptThisTrip = selector.keptThisTrip
        encodeQueue.async { [self] in
            autoreleasepool {
                save(buffer: handoff.buffer, reasons: reasons, context: context, capturedAt: capturedAt,
                     frame: frame, quality: quality, keptThisTrip: keptThisTrip)
            }
        }
    }

    private func save(buffer: CVPixelBuffer, reasons: [String], context: Context, capturedAt: Date,
                      frame: HardExampleFrame, quality: FrameQualityMetrics, keptThisTrip: Int) {
        guard let encoded = encodeJPEG(buffer) else {
            eventHandler?(.saveFailed("JPEG"))
            return
        }
        let id = UUID().uuidString.lowercased()
        let identity = VehicleDetector.modelIdentity(loadedName: context.modelName)
        let info = Bundle.main.infoDictionary
        let appVersion = info?["CFBundleShortVersionString"] as? String ?? "0"
        let meta = LearningSampleMeta.make(
            id: id, capturedAt: capturedAt, platform: Self.platform, appVersion: appVersion,
            modelName: identity.name, modelVersion: identity.version, imageWidth: encoded.width,
            imageHeight: encoded.height, reasons: reasons, speedKmh: frame.ownSpeedKmh,
            latitude: context.sendLocation ? context.latitude : nil,
            longitude: context.sendLocation ? context.longitude : nil,
            detections: frame.detections, tracks: frame.tracks, quality: quality)
        do {
            let json = try meta.encoded()
            try store.save(id: id, jpeg: encoded.data, meta: json)
            let plan = store.applyRetention(LearningStorePolicy(limitMB: context.storageLimitMB))
            eventHandler?(.saved(keptThisTrip: keptThisTrip, deletedByLimit: plan.all.count))
        } catch {
            eventHandler?(.saveFailed(error.localizedDescription))
        }
    }

    /// Upright JPEG with the long side scaled to `jpegLongSide` (never enlarged) and every detected face pixellated.
    private func encodeJPEG(_ buffer: CVPixelBuffer) -> (data: Data, width: Int, height: Int)? {
        let source = CIImage(cvPixelBuffer: buffer)
        let extent = source.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale: CGFloat = min(1, Self.jpegLongSide / max(extent.width, extent.height))
        var image: CIImage = source
        if scale < 1 {
            let filter = CIFilter(name: "CILanczosScaleTransform")
            filter?.setValue(source, forKey: kCIInputImageKey)
            filter?.setValue(scale, forKey: kCIInputScaleKey)
            filter?.setValue(1.0, forKey: kCIInputAspectRatioKey)
            image = filter?.outputImage ?? source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let width = Int((extent.width * scale).rounded(.down))
        let height = Int((extent.height * scale).rounded(.down))
        guard width > 0, height > 0 else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        image = image.cropped(to: bounds)

        // Faces are found on the full-resolution frame (small faces at a distance), then blurred in the scaled one.
        // Vision and Core Image both use a bottom-left origin, so normalized face boxes map directly.
        for face in Self.detectFaces(in: buffer) {
            var rect = VNImageRectForNormalizedRect(face, width, height)
            // Margin around the face box (hair, chin) — the detector box is tight.
            rect = rect.insetBy(dx: -rect.width * 0.25, dy: -rect.height * 0.25).intersection(bounds)
            guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { continue }
            let pixellate = CIFilter(name: "CIPixellate")
            pixellate?.setValue(image, forKey: kCIInputImageKey)
            pixellate?.setValue(max(8, max(rect.width, rect.height) / 5), forKey: kCIInputScaleKey)
            pixellate?.setValue(CIVector(x: rect.midX, y: rect.midY), forKey: kCIInputCenterKey)
            guard let blocks = pixellate?.outputImage else { continue }
            image = blocks.cropped(to: rect).composited(over: image)
        }
        image = image.cropped(to: bounds)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let qualityKey = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        guard let data = ciContext.jpegRepresentation(of: image, colorSpace: colorSpace,
                                                      options: [qualityKey: Self.jpegQuality]) else { return nil }
        return (data, width, height)
    }

    /// Normalized face rectangles (Vision coordinates, bottom-left origin) of an upright frame.
    private static func detectFaces(in buffer: CVPixelBuffer) -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        let faces: [VNFaceObservation] = request.results ?? []
        return faces.map { $0.boundingBox }
    }
}

/// Hands a pixel buffer owned by the collector to the encode queue (exclusive ownership transfer).
private struct OwnedBuffer: @unchecked Sendable {
    let buffer: CVPixelBuffer
}
