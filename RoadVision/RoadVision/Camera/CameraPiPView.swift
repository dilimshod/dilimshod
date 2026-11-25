import SwiftUI

/// Small live camera window with recognition boxes, used on top of the navigator.
/// Tapping it switches back to the full-screen camera.
struct CameraPiPView: View {
    let pipeline: RecognitionPipeline
    @Environment(AppState.self) private var app
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    init(pipeline: RecognitionPipeline) {
        self.pipeline = pipeline
    }

    private var size: CGSize {
        verticalSizeClass == .compact ? CGSize(width: 200, height: 120) : CGSize(width: 160, height: 110)
    }

    private var isLive: Bool {
        pipeline.isRunning && !pipeline.cameraPermissionDenied && !pipeline.isCameraInterrupted
    }

    var body: some View {
        ZStack {
            Color.black
            if isLive {
                CameraPreviewView(session: pipeline.camera.session)
                PiPDetectionLayer(pipeline: pipeline)
            } else {
                placeholder
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .topLeading) {
            if isLive, let color = pipeline.currentLightColor {
                TrafficLightDotView(color: color, size: 16)
                    .padding(7)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isLive {
                VisibleCountBadge(count: pipeline.totalVisibleVehicles)
                    .padding(6)
            }
        }
        .overlay(alignment: .topTrailing) {
            if pipeline.isRecording {
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
                    .padding(8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 10, x: 0, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            app.switchTo(.camera)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Открыть камеру на весь экран")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            app.switchTo(.camera)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: pipeline.cameraPermissionDenied ? "video.slash.fill" : "camera.fill")
                .font(.system(size: 26, weight: .semibold))
            Text(pipeline.cameraPermissionDenied ? "Нет доступа" : "Камера")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.white.opacity(0.75))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    private var accessibilityText: String {
        guard isLive else { return "Камера" }
        var text = "Камера, в кадре \(pipeline.totalVisibleVehicles) ТС"
        if let color = pipeline.currentLightColor {
            text += ", светофор: \(color.displayName.lowercased())"
        }
        return text
    }
}

/// Boxes only (no labels) — a separate view so only it re-renders with every processed frame.
private struct PiPDetectionLayer: View {
    let pipeline: RecognitionPipeline

    var body: some View {
        DetectionOverlayView(tracks: pipeline.tracks, imageSize: pipeline.frameSize,
                             showDistance: false, showSpeed: false, showLabels: false)
    }
}

/// Number of currently visible confirmed vehicles.
private struct VisibleCountBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "car.fill")
                .font(.system(size: 10, weight: .bold))
            Text("\(count)")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.black.opacity(0.6), in: Capsule())
    }
}
