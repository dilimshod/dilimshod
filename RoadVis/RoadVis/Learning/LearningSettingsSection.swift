import SwiftUI

/// Settings → «Обучение модели» (continuous learning, `docs/TRAINING_API.md`): opt-in switch, server and device
/// token, transfer rules, storage limit, model downloads, status counters and actions, privacy note.
struct LearningSettingsSection: View {
    @Environment(AppState.self) private var app
    @State private var serverText = ""
    @State private var serverError: String?
    @State private var tokenText = ""
    @State private var hasToken = false
    @State private var tokenMessage: String?
    @State private var confirmDelete = false

    var body: some View {
        let learning = app.learning
        @Bindable var settings = learning.settings
        Section {
            Toggle(L("learning.enabled"), isOn: $settings.enabled)
            // One server URL for continuous learning and the driver cabinet.
            VStack(alignment: .leading, spacing: 4) {
                Text(l: "learning.serverURL")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(LearningSettings.defaultServerURL, text: $serverText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(applyServer)
                    .onDisappear(perform: applyServer)
                if let serverError {
                    Text(serverError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .disabled(!settings.enabled && !app.cabinet.enabled)
            Group {
                if app.cabinet.enabled && hasToken {
                    Text(l: "cabinet.learning.usesCabinetToken")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                // Advanced: a token created on the server with `roadvis-trainer token create` (the driver cabinet
                // registers one automatically; both live in the same Keychain item).
                DisclosureGroup(L("cabinet.learning.advancedToken")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(l: "learning.token")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            SecureField(L("learning.token.placeholder"), text: $tokenText)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.done)
                                .onSubmit(saveToken)
                            Button(L("learning.token.save"), action: saveToken)
                                .buttonStyle(.borderless)
                                .disabled(tokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        HStack {
                            Text(tokenMessage ?? (hasToken ? L("learning.token.saved") : L("learning.token.missing")))
                                .font(.footnote)
                                .foregroundStyle(hasToken ? Color.green : Color.orange)
                            Spacer()
                            if hasToken {
                                Button(L("learning.token.remove"), role: .destructive, action: removeToken)
                                    .buttonStyle(.borderless)
                                    .font(.footnote)
                            }
                        }
                    }
                }
                Toggle(L("learning.wifiOnly"), isOn: $settings.wifiOnly)
                Toggle(L("learning.sendLocation"), isOn: $settings.sendLocation)
                Picker(L("learning.storageLimit"), selection: $settings.storageLimitMB) {
                    ForEach(LearningStorePolicy.limitChoicesMB, id: \.self) { megabytes in
                        Text(l: "learning.mb", "\(megabytes)").tag(megabytes)
                    }
                }
                Toggle(L("learning.downloadModels"), isOn: $settings.downloadModels)
            }
            .disabled(!settings.enabled)

            statusRows(learning)

            Button {
                learning.uploadNow()
            } label: {
                HStack {
                    Label(L("learning.uploadNow"), systemImage: "icloud.and.arrow.up")
                    if learning.uploader.isUploading {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(!settings.enabled || learning.uploader.isUploading || learning.pendingCount == 0)
            Button {
                learning.checkModelNow()
            } label: {
                HStack {
                    Label(L("learning.checkModel"), systemImage: "arrow.triangle.2.circlepath")
                    if learning.models.isChecking {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(!settings.enabled || learning.models.isChecking)
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label(L("learning.deleteAll"), systemImage: "trash")
            }
            .disabled(learning.pendingCount == 0)
            .confirmationDialog(L("learning.deleteAll.confirm"), isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(L("common.delete"), role: .destructive) {
                    learning.deleteAllSamples()
                }
                Button(L("common.cancel"), role: .cancel) {}
            }
        } header: {
            Text(l: "learning.title")
        } footer: {
            Text(l: "learning.footer")
        }
        .onAppear {
            serverText = learning.settings.serverURL
            hasToken = LearningKeychain.hasToken
            learning.refreshSummary()
        }
        .onChange(of: app.cabinet.hasToken) { _, _ in
            hasToken = LearningKeychain.hasToken
        }
    }

    @ViewBuilder
    private func statusRows(_ learning: LearningCoordinator) -> some View {
        LabeledContent(L("learning.status.collected")) {
            Text(L("learning.status.collectedValue", learning.pendingCount, megabytes(learning.pendingBytes)))
                .monospacedDigit()
        }
        LabeledContent(L("learning.status.thisTrip"), value: "\(learning.keptThisTrip)")
            .monospacedDigit()
        LabeledContent(L("learning.status.uploaded"), value: "\(learning.uploader.uploadedTotal)")
            .monospacedDigit()
        LabeledContent(L("learning.status.deleted")) {
            Text(L("learning.status.deletedValue", learning.deletedByQualityTotal, learning.deletedByLimit))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(L("learning.status.lastUpload")) {
                Text(learning.uploader.lastUploadAt.map { LearningModelText.dateText($0) } ?? L("learning.status.never"))
                    .multilineTextAlignment(.trailing)
            }
            if let error = learning.uploader.lastError {
                Text(L("learning.status.lastError", error))
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if let error = learning.collectorError {
                Text(L("learning.status.lastError", error))
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(L("learning.status.model")) {
                Text(LearningModelText.describe(learning.models.active))
                    .multilineTextAlignment(.trailing)
            }
            if let message = learning.models.lastMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func megabytes(_ bytes: Int64) -> String {
        L("learning.mb", RVFormat.appDecimal(Double(bytes) / 1_048_576, digits: 1))
    }

    private func applyServer() {
        let trimmed = serverText.trimmingCharacters(in: .whitespacesAndNewlines)
        let settings = app.learning.settings
        if trimmed.isEmpty {
            settings.serverURL = LearningSettings.defaultServerURL
            serverText = settings.serverURL
            serverError = nil
            return
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = url.host, !host.isEmpty else {
            serverError = L("learning.serverURL.invalid")
            return
        }
        if settings.serverURL != trimmed { settings.serverURL = trimmed }
        serverText = trimmed
        serverError = nil
    }

    private func saveToken() {
        let trimmed = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if LearningKeychain.setToken(trimmed) {
            tokenText = ""
            hasToken = true
            tokenMessage = nil
            app.cabinet.refreshTokenState()
        } else {
            tokenMessage = L("learning.token.error")
        }
    }

    private func removeToken() {
        LearningKeychain.setToken(nil)
        hasToken = LearningKeychain.hasToken
        tokenMessage = nil
        app.cabinet.refreshTokenState()
    }
}

/// Texts about the active detector model (Settings, recognition status sheet).
enum LearningModelText {
    /// "Bundled" or "2026-12-01-1 · 1 Dec 2026 · mAP50 0.71".
    static func describe(_ model: ModelUpdateService.InstalledModel?) -> String {
        guard let model else { return L("learning.model.bundled") }
        var date = "—"
        if let created = model.createdAt, let parsed = LearningSampleMeta.date(fromTimestamp: created) {
            date = dateText(parsed, withTime: false)
        } else {
            date = dateText(model.installedAt, withTime: false)
        }
        let map = model.map50.map { RVFormat.appDecimal($0, digits: 2) } ?? "—"
        return L("learning.model.downloaded", model.version, date, map)
    }

    static func dateText(_ date: Date, withTime: Bool = true) -> String {
        let locale = LocalizationManager.shared.locale
        if withTime {
            return date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(locale))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year().locale(locale))
    }
}
