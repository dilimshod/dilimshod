import SwiftUI

/// Settings → «Кабинет водителя» (`docs/CABINET_API.md`): opt-in switch (registers the phone), driver name, website
/// QR login, status (points, level, trips, queue, last sync), «only on Wi-Fi», open the web cabinet, delete the
/// data on the server, privacy note. The server URL is the one of «Обучение модели» (`LearningSettings.serverURL`).
struct CabinetSettingsSection: View {
    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var nameText = ""
    @State private var showScanner = false
    @State private var confirmDelete = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        let cabinet = app.cabinet
        @Bindable var bindable = cabinet
        Section {
            Toggle(L("cabinet.enabled"), isOn: Binding(
                get: { cabinet.enabled },
                set: { cabinet.setEnabled($0) }
            ))
            if cabinet.enabled {
                Button {
                    showScanner = true
                } label: {
                    Label(L("cabinet.qr.button"), systemImage: "qrcode.viewfinder")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!cabinet.isRegistered)

                VStack(alignment: .leading, spacing: 4) {
                    Text(l: "cabinet.driverName")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(L("cabinet.driverName.placeholder"), text: $nameText)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($nameFocused)
                        .onSubmit(applyName)
                }

                statusRows(cabinet)

                Toggle(L("cabinet.wifiOnly"), isOn: $bindable.wifiOnly)

                Button {
                    cabinet.syncNow()
                } label: {
                    HStack {
                        Label(L("cabinet.syncNow"), systemImage: "arrow.triangle.2.circlepath")
                        if cabinet.isBusy {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(cabinet.isBusy)

                Button {
                    if let url = cabinet.dashboardURL { openURL(url) }
                } label: {
                    Label(L("cabinet.openDashboard"), systemImage: "safari")
                }
                .disabled(cabinet.dashboardURL == nil)
            }
            // Also offered after switching off, while a cabinet profile is known.
            if cabinet.enabled || (cabinet.isRegistered && cabinet.driverId != nil) {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    HStack {
                        Label(L("cabinet.delete"), systemImage: "trash")
                        if cabinet.isDeleting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(cabinet.isDeleting)
                .confirmationDialog(L("cabinet.delete.confirm"), isPresented: $confirmDelete,
                                    titleVisibility: .visible) {
                    Button(L("cabinet.delete.action"), role: .destructive) {
                        Task { @MainActor in
                            _ = await cabinet.deleteMyData()
                        }
                    }
                    Button(L("common.cancel"), role: .cancel) {}
                } message: {
                    Text(l: "cabinet.delete.message")
                }
            }
        } header: {
            Text(l: "cabinet.title")
        } footer: {
            Text(l: "cabinet.footer")
        }
        .fullScreenCover(isPresented: $showScanner) {
            QRLoginFlowView()
                .environment(app)
        }
        .onAppear {
            nameText = cabinet.driverName
            cabinet.refreshStatus()
        }
        .onChange(of: nameFocused) { _, focused in
            if !focused { applyName() }
        }
        .onChange(of: cabinet.driverName) { _, name in
            if !nameFocused { nameText = name }
        }
    }

    @ViewBuilder
    private func statusRows(_ cabinet: CabinetService) -> some View {
        LabeledContent(L("cabinet.status.account")) {
            Text(verbatim: accountText(cabinet))
                .multilineTextAlignment(.trailing)
                .foregroundStyle(cabinet.isRegistered ? Color.secondary : Color.orange)
        }
        LabeledContent(L("cabinet.status.points")) {
            Text(verbatim: cabinet.points.map { "\($0)" } ?? "—")
                .monospacedDigit()
        }
        LabeledContent(L("cabinet.status.level")) {
            Text(verbatim: cabinet.level.map { "\($0)" } ?? "—")
                .monospacedDigit()
        }
        LabeledContent(L("cabinet.status.trips")) {
            Text(verbatim: "\(cabinet.serverTripCount ?? cabinet.syncedTripCount)")
                .monospacedDigit()
        }
        LabeledContent(L("cabinet.status.pending")) {
            Text(verbatim: "\(cabinet.pendingCount)")
                .monospacedDigit()
        }
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(L("cabinet.status.lastSync")) {
                Text(verbatim: cabinet.lastSyncAt.map { LearningModelText.dateText($0) } ?? L("cabinet.status.never"))
                    .multilineTextAlignment(.trailing)
            }
            if let error = cabinet.lastError {
                Text(L("cabinet.status.error", error))
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if cabinet.tokenRejected {
                Button(L("cabinet.registerAgain")) {
                    cabinet.registerAgain()
                }
                .buttonStyle(.borderless)
                .font(.footnote.weight(.semibold))
                .disabled(cabinet.isBusy)
            }
        }
    }

    private func accountText(_ cabinet: CabinetService) -> String {
        if cabinet.isRegistering { return L("cabinet.status.registering") }
        if cabinet.isRegistered { return L("cabinet.status.registered", cabinet.serverDisplayName) }
        return L("cabinet.status.notRegistered")
    }

    private func applyName() {
        let trimmed = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            nameText = app.cabinet.driverName
            return
        }
        app.cabinet.rename(trimmed)
    }
}
