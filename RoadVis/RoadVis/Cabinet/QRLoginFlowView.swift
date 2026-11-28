import AVFoundation
import SwiftUI
import UIKit

/// «Войти на сайт (QR)» (`docs/CABINET_API.md` §4): full-screen QR scanner with a viewfinder, torch and cancel →
/// confirmation sheet «Войти на сайт как <driverName>?» with the site host → `POST /api/v1/auth/qr/approve` →
/// result (checkmark + haptic, or a clear error). Present it with `.fullScreenCover`.
///
/// The recognition camera is suspended while this screen is shown (`AppState.suspendRecognitionCamera()`) and
/// restored when it closes.
struct QRLoginFlowView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private enum Permission {
        case unknown, authorized, denied
    }

    /// Wrapper so a payload can drive `.sheet(item:)`.
    private struct PendingLogin: Identifiable {
        let id = UUID()
        let payload: QRLoginPayload
    }

    @State private var permission: Permission = .unknown
    @State private var pending: PendingLogin?
    @State private var isSending = false
    @State private var result: CabinetService.QRLoginResult?
    @State private var torchOn = false
    @State private var torchAvailable = false
    @State private var cameraError: String?
    @State private var suspended = false

    var body: some View {
        let cabinet = app.cabinet
        let ready = cabinet.enabled && cabinet.isRegistered
        ZStack {
            Color.black.ignoresSafeArea()
            if ready {
                scannerLayer
            } else {
                notReadyPanel(cabinet)
            }
            if let result {
                resultPanel(result)
            }
        }
        .overlay(alignment: .top) {
            topBar(showTorch: ready && permission == .authorized && result == nil)
        }
        .sheet(item: $pending, onDismiss: {
            isSending = false
        }) { login in
            confirmationSheet(login.payload, cabinet: cabinet)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .appLocale()
        .onAppear {
            if !suspended {
                suspended = true
                app.suspendRecognitionCamera()
            }
            checkPermission()
        }
        .onDisappear {
            torchOn = false
            if suspended {
                suspended = false
                app.resumeRecognitionCamera()
            }
        }
    }

    // MARK: - Scanner

    @ViewBuilder
    private var scannerLayer: some View {
        switch permission {
        case .unknown:
            ProgressView()
                .tint(.white)
        case .denied:
            messagePanel(icon: "camera.fill", title: L("cabinet.qr.noPermission.title"),
                         text: L("cabinet.qr.noPermission.text")) {
                Button(L("cabinet.qr.openSettings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.borderedProminent)
            }
        case .authorized:
            ZStack {
                QRScannerView(
                    isScanning: pending == nil && result == nil,
                    torchOn: torchOn,
                    isOtherCameraRunning: { app.isRecognitionCameraRunning },
                    onCode: handleCode,
                    onTorchAvailability: { torchAvailable = $0 },
                    onError: { cameraError = $0 }
                )
                .ignoresSafeArea()
                QRViewfinderOverlay()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                VStack {
                    Spacer()
                    Text(verbatim: cameraError ?? L("cabinet.qr.hint"))
                        .font(.callout.weight(.medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.horizontal, 24)
                        .padding(.bottom, 40)
                }
            }
        }
    }

    private func topBar(showTorch: Bool) -> some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.5), in: Circle())
            }
            .accessibilityLabel(L("common.cancel"))
            Spacer()
            if showTorch && torchAvailable {
                Button {
                    torchOn.toggle()
                } label: {
                    Image(systemName: torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.headline)
                        .foregroundStyle(torchOn ? Color.yellow : Color.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.5), in: Circle())
                }
                .accessibilityLabel(L("cabinet.qr.torch"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func checkPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permission = .authorized
        case .notDetermined:
            permission = .unknown
            Task { @MainActor in
                let granted: Bool = await AVCaptureDevice.requestAccess(for: .video)
                permission = granted ? .authorized : .denied
            }
        case .denied, .restricted:
            permission = .denied
        @unknown default:
            permission = .denied
        }
    }

    private func handleCode(_ text: String) {
        guard pending == nil, result == nil else { return }
        switch app.cabinet.parseLogin(text) {
        case .success(let payload):
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            torchOn = false
            pending = PendingLogin(payload: payload)
        case .failure(let error):
            show(app.cabinet.result(for: error))
        }
    }

    // MARK: - Confirmation

    private func confirmationSheet(_ payload: QRLoginPayload, cabinet: CabinetService) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.tint)
                .padding(.top, 8)
            Text(l: "cabinet.qr.confirm.title", cabinet.driverName)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
            VStack(spacing: 4) {
                Text(l: "cabinet.qr.confirm.site")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(verbatim: payload.host)
                    .font(.headline.monospaced())
            }
            Text(l: "cabinet.qr.confirm.hint")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
            Button {
                approve(payload)
            } label: {
                HStack {
                    if isSending { ProgressView().tint(.white) }
                    Text(l: "cabinet.qr.confirm.approve")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSending)
            Button(role: .cancel) {
                pending = nil
            } label: {
                Text(l: "common.cancel")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .disabled(isSending)
        }
        .padding(24)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isSending)
        .appLocale()
    }

    private func approve(_ payload: QRLoginPayload) {
        guard !isSending else { return }
        isSending = true
        Task { @MainActor in
            let outcome = await app.cabinet.approveLogin(payload)
            isSending = false
            pending = nil
            show(outcome)
        }
    }

    private func show(_ outcome: CabinetService.QRLoginResult) {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(outcome == .approved ? .success : .error)
        withAnimation(.easeOut(duration: 0.2)) {
            result = outcome
        }
    }

    // MARK: - Result

    private func resultPanel(_ outcome: CabinetService.QRLoginResult) -> some View {
        let success = outcome == .approved
        return ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 72, weight: .semibold))
                    .foregroundStyle(success ? Color.green : Color.orange)
                    .symbolEffect(.bounce, value: success)
                Text(verbatim: Self.title(for: outcome))
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                Text(verbatim: Self.message(for: outcome))
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.8))
                VStack(spacing: 10) {
                    if !success {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { result = nil }
                        } label: {
                            Text(l: "cabinet.qr.scanAgain")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button {
                        dismiss()
                    } label: {
                        Text(l: success ? "cabinet.qr.done" : "cabinet.qr.close")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
                .padding(.top, 8)
            }
            .padding(28)
            .frame(maxWidth: 460)
        }
        .transition(.opacity)
    }

    static func title(for outcome: CabinetService.QRLoginResult) -> String {
        switch outcome {
        case .approved: return L("cabinet.qr.result.approved")
        case .expired: return L("cabinet.qr.result.expired")
        case .alreadyUsed: return L("cabinet.qr.result.alreadyUsed")
        case .foreignSite: return L("cabinet.qr.result.foreignSite")
        case .notRoadVis: return L("cabinet.qr.result.notRoadVis")
        case .unauthorized: return L("cabinet.qr.result.unauthorized")
        case .notRegistered: return L("cabinet.qr.result.notRegistered")
        case .network: return L("cabinet.qr.result.network")
        case .server: return L("cabinet.qr.result.server")
        }
    }

    static func message(for outcome: CabinetService.QRLoginResult) -> String {
        switch outcome {
        case .approved: return L("cabinet.qr.result.approved.text")
        case .expired: return L("cabinet.qr.result.expired.text")
        case .alreadyUsed: return L("cabinet.qr.result.alreadyUsed.text")
        case .foreignSite: return L("cabinet.qr.result.foreignSite.text")
        case .notRoadVis: return L("cabinet.qr.result.notRoadVis.text")
        case .unauthorized: return L("cabinet.qr.result.unauthorized.text")
        case .notRegistered: return L("cabinet.qr.result.notRegistered.text")
        case .network: return L("cabinet.qr.result.network.text")
        case .server(let code): return L("cabinet.error.http", code)
        }
    }

    // MARK: - Not ready

    @ViewBuilder
    private func notReadyPanel(_ cabinet: CabinetService) -> some View {
        if cabinet.enabled {
            // Switched on, registration still running or failed.
            messagePanel(icon: "person.crop.circle.badge.clock", title: L("cabinet.qr.notReady.registering"),
                         text: cabinet.lastError ?? L("cabinet.status.registering")) {
                if cabinet.isBusy {
                    ProgressView().tint(.white)
                } else {
                    Button(L("cabinet.syncNow")) { cabinet.syncNow() }
                        .buttonStyle(.borderedProminent)
                }
            }
        } else {
            messagePanel(icon: "person.text.rectangle", title: L("cabinet.qr.notReady.title"),
                         text: L("cabinet.qr.notReady.text")) {
                Button(L("cabinet.qr.notReady.enable")) { cabinet.setEnabled(true) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func messagePanel<Actions: View>(icon: String, title: String, text: String,
                                             @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text(verbatim: title)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
            Text(verbatim: text)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
            actions()
                .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: 460)
    }
}

/// Dimmed screen with a clear rounded square in the middle and corner marks.
struct QRViewfinderOverlay: View {
    var body: some View {
        GeometryReader { proxy in
            let side: CGFloat = min(min(proxy.size.width, proxy.size.height) * 0.68, 320)
            let rect = CGRect(x: (proxy.size.width - side) / 2, y: (proxy.size.height - side) / 2,
                              width: side, height: side)
            ZStack {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: proxy.size))
                    path.addRoundedRect(in: rect, cornerSize: CGSize(width: 24, height: 24))
                }
                .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                QRViewfinderCorners()
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    .frame(width: side, height: side)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
    }
}

/// Four rounded corner marks of the viewfinder.
struct QRViewfinderCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let length: CGFloat = min(rect.width, rect.height) * 0.18
        let radius: CGFloat = 24
        var path = Path()
        // Top left
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + length))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + length, y: rect.minY))
        // Top right
        path.move(to: CGPoint(x: rect.maxX - length, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + length))
        // Bottom right
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - length))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - length, y: rect.maxY))
        // Bottom left
        path.move(to: CGPoint(x: rect.minX + length, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - length))
        return path
    }
}
