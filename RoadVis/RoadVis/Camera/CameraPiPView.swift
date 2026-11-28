import SwiftUI

/// Small live camera window with recognition boxes, used on top of the navigator.
/// Shows the traffic-light colour, the number of visible vehicles and — when a lead vehicle is tracked — a badge with
/// the ≈ gap to it in the status colour; a pedestrian on / about to enter the roadway shows a small red (orange for
/// caution) walking-figure badge at the top. Tapping it switches back to the full-screen camera.
///
/// `isActive` is false while the navigator is hidden behind the camera screen: the preview layer stays mounted but
/// disconnected (the full-screen preview owns the session connection) and the per-frame overlays are not built.
struct CameraPiPView: View {
    let pipeline: RecognitionPipeline
    let isActive: Bool
    @Environment(AppState.self) private var app
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    init(pipeline: RecognitionPipeline, isActive: Bool = true) {
        self.pipeline = pipeline
        self.isActive = isActive
    }

    private var size: CGSize {
        verticalSizeClass == .compact ? CGSize(width: 176, height: 104) : CGSize(width: 136, height: 96)
    }

    private var isLive: Bool {
        isActive && pipeline.isRunning && !pipeline.cameraPermissionDenied && !pipeline.isCameraInterrupted
    }

    var body: some View {
        ZStack {
            Color.black
            if !pipeline.cameraPermissionDenied {
                // Always mounted (no layer re-creation on screen switches); connected only while visible and live.
                CameraPreviewView(session: pipeline.camera.session, isConnected: isLive)
            }
            if isLive {
                PiPDetectionLayer(pipeline: pipeline)
            } else if isActive {
                placeholder
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .topLeading) {
            if isLive, let color = pipeline.currentLightColor {
                TrafficLightDotView(color: color, size: 12)
                    .padding(6)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isLive {
                VisibleCountBadge(count: pipeline.totalVisibleVehicles)
                    .padding(6)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if isLive, let lead = pipeline.leadVehicle {
                LeadDistanceBadge(distanceMeters: lead.distanceMeters,
                                  status: pipeline.followingAssessment?.status ?? .unknown)
                    .padding(6)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(RVTheme.snappy, value: pipeline.leadVehicle == nil)
        .overlay(alignment: .top) {
            if isLive, let hazard = pipeline.topPedestrianHazard {
                PedestrianHazardBadge(hazard: hazard)
                    .padding(.top, 5)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            } else if isLive, let staff = pipeline.topRoadStaff {
                RoadStaffBadge(sighting: staff)
                    .padding(.top, 5)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(RVTheme.snappy, value: pipeline.topPedestrianHazard == nil)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            app.switchTo(.camera)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(L("pip.hint"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            app.switchTo(.camera)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: pipeline.cameraPermissionDenied ? "video.slash.fill" : "camera.fill")
                .font(.system(size: 26, weight: .semibold))
            Text(verbatim: pipeline.cameraPermissionDenied ? L("pip.noAccess") : L("common.camera"))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.white.opacity(0.75))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    private var accessibilityText: String {
        guard isLive else { return L("common.camera") }
        var text = L("pip.a11y.inFrame", pipeline.totalVisibleVehicles)
        if let color = pipeline.currentLightColor {
            text += L("pip.a11y.light", color.localizedName.lowercased())
        }
        if pipeline.topPedestrianHazard != nil {
            text += L("pip.a11y.pedestrian")
        }
        if let lead = pipeline.leadVehicle {
            let d = lead.distanceMeters
            text += L("pip.a11y.lead", RVFormat.appSpokenMeters(d))
            if let status = pipeline.followingAssessment?.status, status != .unknown {
                text += ", \(status.localizedName.lowercased())"
            }
        }
        return text
    }
}

/// Boxes only (no labels) — a separate view so only it re-renders with every processed frame.
/// The lead vehicle's bracket is drawn in its status colour.
private struct PiPDetectionLayer: View {
    let pipeline: RecognitionPipeline

    var body: some View {
        let lead = pipeline.leadVehicle
        DetectionOverlayView(tracks: pipeline.tracks, imageSize: pipeline.frameSize,
                             showLabels: false,
                             lead: lead,
                             leadStatus: lead == nil ? .unknown : (pipeline.followingAssessment?.status ?? .unknown),
                             pedestrianHazards: DetectionOverlayView.hazardLevels(pipeline.pedestrianHazards))
    }
}

/// "≈ 18 м" capsule in the status colour of the gap to the lead vehicle.
private struct LeadDistanceBadge: View {
    let distanceMeters: Double
    let status: DistanceStatus

    var body: some View {
        let color = RVTheme.statusColor(status)
        HStack(spacing: 3) {
            Image(systemName: "car.rear.fill")
                .font(.system(size: 9, weight: .bold))
            Text(FollowingDistanceText.gap(distanceMeters))
                .rvNumeric(12, weight: .heavy)
                .contentTransition(.numericText())
        }
        .foregroundStyle(status == .unknown ? Color.white : Color.black)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(status == .unknown ? Color.black.opacity(0.6) : color, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
        .rvPulse(status == .danger, minOpacity: 0.55, period: 0.7)
        .animation(RVTheme.snappy, value: FollowingDistanceText.gap(distanceMeters))
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
