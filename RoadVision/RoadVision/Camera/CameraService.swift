import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Errors reported when the capture session cannot be configured.
enum CameraServiceError: LocalizedError {
    case noCamera
    case cannotAddInput
    case cannotAddOutput
    case inputFailed(String)

    var errorDescription: String? {
        switch self {
        case .noCamera: return "На устройстве не найдена основная камера"
        case .cannotAddInput: return "Не удалось подключить камеру к сеансу съёмки"
        case .cannotAddOutput: return "Не удалось получить видеопоток с камеры"
        case .inputFailed(let message): return "Ошибка камеры: \(message)"
        }
    }
}

/// `AVCaptureSession` wrapper for the back wide-angle camera delivering upright BGRA frames.
///
/// Threading
/// - All session configuration, start and stop run on the serial `camera.session` queue (never on main).
/// - Frames are delivered to `frameHandler` on the serial `camera.frames` queue.
/// - Public state (`isRunning`, `isInterrupted`, `horizontalFieldOfView`, handlers) is lock-protected and can be
///   read from any thread (hence `@unchecked Sendable`).
///
/// Orientation
/// - The video data output connection gets a `videoRotationAngle` from an `AVCaptureDevice.RotationCoordinator`
///   (iOS 17), so frames are always upright and Vision can use orientation `.up`; normalized boxes then map
///   directly onto the buffer.
/// - While a preview layer is attached to `session` (see `CameraPreviewView`), the coordinator is built with that
///   layer and the *preview* angle is applied to the frames too, so frames and preview agree even when the
///   interface orientation differs from the physical device orientation (rotation lock, phone upside down).
///   Without a preview, the coordinator uses `previewLayer: nil` and `videoRotationAngleForHorizonLevelCapture`.
final class CameraService: NSObject, @unchecked Sendable {
    /// The capture session (attach it to an `AVCaptureVideoPreviewLayer` for display).
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "camera.session", qos: .userInitiated)
    private let framesQueue = DispatchQueue(label: "camera.frames", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()

    // MARK: Session-queue state
    private var device: AVCaptureDevice?
    private var isConfigured = false
    private var configurationError: CameraServiceError?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var wantsRunning = false
    private var restartAttempts = 0

    // MARK: Lock-protected state
    private let lock = NSLock()
    private var storedFrameHandler: ((CVPixelBuffer, CMTime) -> Void)?
    private var storedStateHandler: (@Sendable (_ isRunning: Bool, _ isInterrupted: Bool) -> Void)?
    private var storedFieldOfView: Double = 65
    private var storedIsRunning = false
    private var storedIsInterrupted = false
    private var storedRotationAngle: Double = 90

    private var sessionObservations: [NSKeyValueObservation] = []
    private var notificationTokens: [NSObjectProtocol] = []

    /// Default horizontal field of view used until the device format is known.
    static let fallbackFieldOfView: Double = 65

    override init() {
        super.init()
        observeSession()
    }

    deinit {
        sessionObservations.forEach { $0.invalidate() }
        rotationObservation?.invalidate()
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Authorization

    /// Current camera authorization status.
    static var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// Shows the system camera permission prompt (only the first time) and returns whether access is granted.
    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    // MARK: - Public state

    /// Called on the `camera.frames` queue with every upright BGRA frame and its presentation time.
    var frameHandler: ((CVPixelBuffer, CMTime) -> Void)? {
        get { withLock { storedFrameHandler } }
        set { withLock { storedFrameHandler = newValue } }
    }

    /// Called on an arbitrary queue whenever the session starts/stops running or is interrupted by the system
    /// (another app uses the camera, Split View, phone call, thermal pressure…).
    var stateHandler: (@Sendable (_ isRunning: Bool, _ isInterrupted: Bool) -> Void)? {
        get { withLock { storedStateHandler } }
        set { withLock { storedStateHandler = newValue } }
    }

    /// Horizontal field of view of the sensor's long side, degrees (`activeFormat.videoFieldOfView`).
    var horizontalFieldOfView: Double { withLock { storedFieldOfView } }

    /// True while the capture session is running.
    var isRunning: Bool { withLock { storedIsRunning } }

    /// True while the system has interrupted the session.
    var isInterrupted: Bool { withLock { storedIsInterrupted } }

    /// Rotation angle (degrees) currently applied to the video data output.
    var videoRotationAngle: Double { withLock { storedRotationAngle } }

    // MARK: - Start / stop

    /// Configures the session on first use and starts it. `completion` is called on the session queue with
    /// `nil` on success or the configuration error.
    func start(completion: (@Sendable (Error?) -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = true
            self.restartAttempts = 0
            do {
                try self.configureIfNeeded()
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                completion?(nil)
            } catch {
                self.wantsRunning = false
                completion?(error)
            }
        }
    }

    /// Stops the session (asynchronously, on the session queue).
    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = false
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    // MARK: - Configuration (session queue)

    private func configureIfNeeded() throws {
        if isConfigured { return }
        if let configurationError { throw configurationError }

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            configurationError = .noCamera
            throw CameraServiceError.noCamera
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: camera)
        } catch {
            throw CameraServiceError.inputFailed(error.localizedDescription)
        }

        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraServiceError.cannotAddInput
        }
        session.addInput(input)

        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: framesQueue)
        guard session.canAddOutput(videoOutput) else {
            session.removeInput(input)
            session.commitConfiguration()
            throw CameraServiceError.cannotAddOutput
        }
        session.addOutput(videoOutput)
        session.commitConfiguration()

        // Frame rate and focus must be set after the preset was applied (a preset change resets them).
        configureDevice(camera)

        device = camera
        isConfigured = true
        let fov = Double(camera.activeFormat.videoFieldOfView)
        withLock { storedFieldOfView = fov.isFinite && fov > 10 && fov < 170 ? fov : Self.fallbackFieldOfView }

        refreshRotationCoordinator()
    }

    /// 30 fps, continuous autofocus and auto-exposure.
    private func configureDevice(_ camera: AVCaptureDevice) {
        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }
            let thirtyFPS = CMTime(value: 1, timescale: 30)
            let supports30 = camera.activeFormat.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
            }
            if supports30 {
                camera.activeVideoMinFrameDuration = thirtyFPS
                camera.activeVideoMaxFrameDuration = thirtyFPS
            }
            if camera.isFocusModeSupported(.continuousAutoFocus) {
                camera.focusMode = .continuousAutoFocus
            }
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
            if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                camera.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        } catch {
            // The defaults of the preset (usually 30 fps, continuous AF/AE) remain in effect.
        }
    }

    // MARK: - Rotation (session queue)

    /// (Re)creates the rotation coordinator. Uses the preview layer currently attached to the session, if any.
    private func refreshRotationCoordinator() {
        guard let device else { return }
        rotationObservation?.invalidate()
        rotationObservation = nil

        let previewLayer = session.connections.lazy.compactMap { $0.videoPreviewLayer }.first
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator

        if previewLayer != nil {
            applyOutputRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
            rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview,
                                                      options: [.new]) { [weak self] _, change in
                guard let angle = change.newValue else { return }
                self?.sessionQueue.async { self?.applyOutputRotation(angle) }
            }
        } else {
            applyOutputRotation(coordinator.videoRotationAngleForHorizonLevelCapture)
            rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture,
                                                      options: [.new]) { [weak self] _, change in
                guard let angle = change.newValue else { return }
                self?.sessionQueue.async { self?.applyOutputRotation(angle) }
            }
        }
    }

    private func applyOutputRotation(_ angle: CGFloat) {
        guard let connection = videoOutput.connection(with: .video),
              connection.isVideoRotationAngleSupported(angle) else { return }
        if connection.videoRotationAngle != angle {
            connection.videoRotationAngle = angle
        }
        withLock { storedRotationAngle = Double(angle) }
    }

    // MARK: - Session state observation

    private func observeSession() {
        let running = session.observe(\.isRunning, options: [.new]) { [weak self] _, change in
            guard let self, let value = change.newValue else { return }
            self.withLock { self.storedIsRunning = value }
            self.notifyState()
            if !value {
                self.sessionQueue.async { self.restartIfNeeded() }
            } else {
                self.sessionQueue.async { self.restartAttempts = 0 }
            }
        }
        let interrupted = session.observe(\.isInterrupted, options: [.new]) { [weak self] _, change in
            guard let self, let value = change.newValue else { return }
            self.withLock { self.storedIsInterrupted = value }
            self.notifyState()
        }
        sessionObservations = [running, interrupted]

        // A preview layer was attached to / detached from this session → rebuild the rotation coordinator.
        let token = NotificationCenter.default.addObserver(forName: .cameraPreviewLayerDidChange,
                                                           object: session, queue: nil) { [weak self] _ in
            self?.sessionQueue.async { self?.refreshRotationCoordinator() }
        }
        notificationTokens.append(token)
    }

    private func notifyState() {
        let (handler, running, interrupted) = withLock { (storedStateHandler, storedIsRunning, storedIsInterrupted) }
        handler?(running, interrupted)
    }

    /// Restarts the session when it stopped by itself (e.g. media services were reset) while it should run.
    /// Interruptions end on their own and are not restarted here.
    private func restartIfNeeded() {
        guard wantsRunning, isConfigured, !session.isRunning, !session.isInterrupted else { return }
        guard restartAttempts < 3 else { return }
        restartAttempts += 1
        let delay = Double(restartAttempts)
        sessionQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wantsRunning, !self.session.isRunning, !self.session.isInterrupted else { return }
            self.session.startRunning()
        }
    }

    // MARK: - Helpers

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

// MARK: - Frames

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let handler = frameHandler,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        handler(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}
