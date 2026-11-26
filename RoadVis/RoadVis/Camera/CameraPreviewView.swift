import AVFoundation
import SwiftUI
import UIKit

extension Notification.Name {
    /// Posted on the main thread (object: the `AVCaptureSession`) when a preview layer is attached to or detached
    /// from a session. `CameraService` rebuilds its rotation coordinator so frames follow the preview orientation;
    /// other previews of the same session re-attach if they lost their connection. `userInfo["event"]` is
    /// `"attach"` or `"detach"`.
    static let cameraPreviewLayerDidChange = Notification.Name("RoadVis.cameraPreviewLayerDidChange")
}

/// Live camera picture backed by an `AVCaptureVideoPreviewLayer` (aspect-fill).
///
/// The preview connection's `videoRotationAngle` is kept level with an `AVCaptureDevice.RotationCoordinator`
/// built for this layer (`videoRotationAngleForHorizonLevelPreview`, observed with KVO). `CameraService` uses the
/// same preview-based angle for its frames while a preview is attached, so boxes drawn with aspect-fill geometry
/// line up with the picture in every orientation.
///
/// `isConnected = false` keeps the view (and its layer) alive but disconnects it from the session. The app keeps
/// the full-screen preview and the navigator's PiP window mounted at the same time, but connects only the visible
/// one: some iOS versions allow a single connected preview layer per session, and a hidden layer must not steal the
/// connection. When a peer disconnects, a connected preview that lost its connection re-attaches itself.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let videoGravity: AVLayerVideoGravity
    let isConnected: Bool

    init(session: AVCaptureSession, videoGravity: AVLayerVideoGravity = .resizeAspectFill, isConnected: Bool = true) {
        self.session = session
        self.videoGravity = videoGravity
        self.isConnected = isConnected
    }

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.videoGravity = videoGravity
        if isConnected {
            view.attach(session: session)
        }
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        if uiView.previewLayer.videoGravity != videoGravity {
            uiView.previewLayer.videoGravity = videoGravity
        }
        if isConnected {
            if uiView.previewLayer.session !== session {
                uiView.attach(session: session)
            }
        } else if uiView.previewLayer.session != nil {
            uiView.detach()
        }
    }

    static func dismantleUIView(_ uiView: PreviewUIView, coordinator: ()) {
        uiView.detach()
    }

    /// UIView whose backing layer is the preview layer (resizes with the view, no manual frame handling).
    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        // swiftlint:disable:next force_cast
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
        private var rotationObservation: NSKeyValueObservation?
        private var runningObservation: NSKeyValueObservation?
        private var notificationToken: NSObjectProtocol?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        // No deinit: `dismantleUIView` calls `detach()`, which removes the notification observer; KVO
        // observations invalidate themselves when released.

        /// Connects the layer to `session` and starts keeping its rotation level.
        func attach(session: AVCaptureSession) {
            if let old = previewLayer.session, old !== session {
                detach()
            }
            previewLayer.session = session
            observe(session: session)
            rebuildRotationCoordinator()
            Self.post(session: session, event: "attach")
        }

        /// Disconnects the layer from its session.
        func detach() {
            rotationObservation?.invalidate()
            rotationObservation = nil
            runningObservation?.invalidate()
            runningObservation = nil
            rotationCoordinator = nil
            if let notificationToken {
                NotificationCenter.default.removeObserver(notificationToken)
                self.notificationToken = nil
            }
            guard let session = previewLayer.session else { return }
            previewLayer.session = nil
            Self.post(session: session, event: "detach")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, let session = previewLayer.session else { return }
            // The interface orientation is known only once the layer is in a window.
            rebuildRotationCoordinator()
            Self.post(session: session, event: "attach")
        }

        // MARK: Private

        private static func post(session: AVCaptureSession, event: String) {
            NotificationCenter.default.post(name: .cameraPreviewLayerDidChange, object: session,
                                            userInfo: ["event": event])
        }

        private func observe(session: AVCaptureSession) {
            runningObservation?.invalidate()
            // The camera device is added to the session on the session queue; once the session runs, the device
            // is known and the coordinator can be (re)built.
            runningObservation = Self.observeRunning(of: session) { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.rebuildRotationCoordinator()
                    }
                }
            }
            if notificationToken == nil {
                notificationToken = NotificationCenter.default.addObserver(
                    forName: .cameraPreviewLayerDidChange, object: session, queue: .main
                ) { [weak self] note in
                    let event = note.userInfo?["event"] as? String
                    MainActor.assumeIsolated {
                        self?.handlePeerChange(event: event)
                    }
                }
            }
        }

        /// Another preview of the same session went away: if this layer lost its connection (some iOS versions
        /// allow only one connected preview layer per session), reconnect it.
        private func handlePeerChange(event: String?) {
            guard event == "detach", window != nil, let session = previewLayer.session,
                  previewLayer.connection == nil else { return }
            previewLayer.session = nil
            previewLayer.session = session
            rebuildRotationCoordinator()
            Self.post(session: session, event: "attach")
        }

        private func rebuildRotationCoordinator() {
            rotationObservation?.invalidate()
            rotationObservation = nil
            guard let session = previewLayer.session,
                  let device = session.inputs.lazy
                    .compactMap({ ($0 as? AVCaptureDeviceInput)?.device })
                    .first(where: { $0.hasMediaType(.video) }) else {
                rotationCoordinator = nil
                return
            }
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            rotationCoordinator = coordinator
            applyRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
            rotationObservation = Self.observePreviewAngle(of: coordinator) { [weak self] angle in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.applyRotation(angle)
                    }
                }
            }
        }

        private func applyRotation(_ angle: CGFloat) {
            guard let connection = previewLayer.connection,
                  connection.isVideoRotationAngleSupported(angle),
                  connection.videoRotationAngle != angle else { return }
            connection.videoRotationAngle = angle
        }

        /// KVO helpers are nonisolated so the change handlers are plain (non-main-actor) closures:
        /// AVFoundation may call them on any thread; they hop to the main queue themselves.
        private nonisolated static func observePreviewAngle(
            of coordinator: AVCaptureDevice.RotationCoordinator,
            handler: @escaping @Sendable (CGFloat) -> Void
        ) -> NSKeyValueObservation {
            coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { _, change in
                if let angle = change.newValue { handler(angle) }
            }
        }

        private nonisolated static func observeRunning(
            of session: AVCaptureSession,
            handler: @escaping @Sendable () -> Void
        ) -> NSKeyValueObservation {
            session.observe(\.isRunning, options: [.new]) { _, change in
                if change.newValue == true { handler() }
            }
        }
    }
}
