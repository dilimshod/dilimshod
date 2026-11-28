import AVFoundation
import SwiftUI
import UIKit

/// Full-screen QR camera (`AVCaptureMetadataOutput`, type `.qr`) on its own capture session.
///
/// The recognition camera (`CameraService`) uses the same back camera: the presenting view suspends it
/// (`AppState.suspendRecognitionCamera()`) and this view starts its session only once `isOtherCameraRunning`
/// reports the recognition session stopped (at most ≈ 1.5 s of waiting).
struct QRScannerView: UIViewControllerRepresentable {
    /// Codes are reported only while true.
    var isScanning: Bool
    var torchOn: Bool
    /// True while another capture session still holds the camera.
    var isOtherCameraRunning: @MainActor () -> Bool
    /// A QR code was read (string value).
    var onCode: @MainActor (String) -> Void
    /// The torch can / cannot be used.
    var onTorchAvailability: @MainActor (Bool) -> Void
    /// The capture session could not be configured.
    var onError: @MainActor (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        apply(to: controller)
        return controller
    }

    func updateUIViewController(_ controller: QRScannerViewController, context: Context) {
        apply(to: controller)
    }

    static func dismantleUIViewController(_ controller: QRScannerViewController, coordinator: ()) {
        controller.stopScanner()
    }

    private func apply(to controller: QRScannerViewController) {
        controller.isOtherCameraRunning = isOtherCameraRunning
        controller.onCode = onCode
        controller.onTorchAvailability = onTorchAvailability
        controller.onError = onError
        controller.isScanning = isScanning
        controller.setTorch(torchOn)
    }
}

/// Hosts the preview layer and drives `QRCaptureSession`.
final class QRScannerViewController: UIViewController {
    var isOtherCameraRunning: (@MainActor () -> Bool)?
    var onCode: (@MainActor (String) -> Void)?
    var onTorchAvailability: (@MainActor (Bool) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    var isScanning = true

    private let capture = QRCaptureSession()
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var startRequested = false
    private var stopped = false
    private var lastCode: String?
    private var lastCodeAt = Date.distantPast

    /// Polling step / attempts while the recognition session is stopping.
    private static let waitStep: TimeInterval = 0.05
    private static let maxWaitAttempts = 30

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        previewLayer.session = capture.session
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        capture.onCode = { [weak self] text in
            self?.handle(text)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
        applyRotation()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !startRequested else { return }
        startRequested = true
        startWhenCameraIsFree(attempt: 0)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopScanner()
    }

    /// Turns the torch off and stops the session (idempotent).
    func stopScanner() {
        guard !stopped else { return }
        stopped = true
        capture.stop()
    }

    func setTorch(_ on: Bool) {
        capture.setTorch(on)
    }

    private func startWhenCameraIsFree(attempt: Int) {
        guard !stopped else { return }
        if let busy = isOtherCameraRunning, busy(), attempt < Self.maxWaitAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.waitStep) { [weak self] in
                MainActor.assumeIsolated {
                    self?.startWhenCameraIsFree(attempt: attempt + 1)
                }
            }
            return
        }
        capture.start { [weak self] errorText, hasTorch in
            guard let self, !self.stopped else { return }
            if let errorText {
                self.onError?(errorText)
                return
            }
            self.onTorchAvailability?(hasTorch)
            self.rebuildRotationCoordinator()
        }
    }

    private func handle(_ text: String) {
        guard isScanning, !stopped else { return }
        let now = Date()
        // The same code is reported many times per second: once per 2 s is enough.
        if text == lastCode, now.timeIntervalSince(lastCodeAt) < 2 { return }
        lastCode = text
        lastCodeAt = now
        onCode?(text)
    }

    private func rebuildRotationCoordinator() {
        guard let device = capture.device else { return }
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        applyRotation()
    }

    private func applyRotation() {
        guard let coordinator = rotationCoordinator, let connection = previewLayer.connection else { return }
        let angle: CGFloat = coordinator.videoRotationAngleForHorizonLevelPreview
        if connection.isVideoRotationAngleSupported(angle), connection.videoRotationAngle != angle {
            connection.videoRotationAngle = angle
        }
    }
}

/// The scanner's capture session (configured and run on its own serial queue).
final class QRCaptureSession: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    /// Called on the main thread with every decoded QR string.
    var onCode: (@MainActor (String) -> Void)? {
        get { locked { storedOnCode } }
        set { locked { storedOnCode = newValue } }
    }
    /// The back camera once configured.
    var device: AVCaptureDevice? { locked { storedDevice } }

    private let queue = DispatchQueue(label: "uz.roadvis.qr.session", qos: .userInitiated)
    private let lock = NSLock()
    private var storedOnCode: (@MainActor (String) -> Void)?
    private var storedDevice: AVCaptureDevice?
    private var configured = false
    private var wantsTorch = false

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Configures (once) and starts the session. `completion` runs on the main thread with an error text or nil
    /// and whether the camera has a torch.
    func start(completion: @escaping @MainActor (_ error: String?, _ hasTorch: Bool) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let error = self.configureIfNeeded()
            if error == nil, !self.session.isRunning {
                self.session.startRunning()
            }
            let device = self.device
            let hasTorch = device.map { $0.hasTorch && $0.isTorchModeSupported(.on) } ?? false
            if error == nil { self.applyTorch() }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    completion(error, hasTorch)
                }
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.wantsTorch = false
            self.applyTorch()
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func setTorch(_ on: Bool) {
        queue.async { [weak self] in
            guard let self, self.wantsTorch != on else { return }
            self.wantsTorch = on
            self.applyTorch()
        }
    }

    // MARK: Session queue

    private func configureIfNeeded() -> String? {
        if configured { return nil }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return L("cabinet.qr.error.noCamera")
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: camera)
        } catch {
            return error.localizedDescription
        }
        session.beginConfiguration()
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            return L("cabinet.qr.error.noCamera")
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return L("cabinet.qr.error.noCamera")
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        if output.availableMetadataObjectTypes.contains(.qr) {
            output.metadataObjectTypes = [.qr]
        }
        session.commitConfiguration()
        locked { storedDevice = camera }
        configured = true
        return nil
    }

    private func applyTorch() {
        guard let device, device.hasTorch, device.isTorchModeSupported(.on) else { return }
        let mode: AVCaptureDevice.TorchMode = wantsTorch && session.isRunning ? .on : .off
        guard device.torchMode != mode else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = mode
            device.unlockForConfiguration()
        } catch {
            // The torch is optional.
        }
    }

    // MARK: AVCaptureMetadataOutputObjectsDelegate (main queue)

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        let codes: [AVMetadataMachineReadableCodeObject] = metadataObjects.compactMap {
            $0 as? AVMetadataMachineReadableCodeObject
        }
        guard let text = codes.first(where: { $0.type == .qr })?.stringValue, !text.isEmpty else { return }
        let handler = onCode
        MainActor.assumeIsolated {
            handler?(text)
        }
    }
}
