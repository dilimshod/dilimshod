import SwiftUI

/// All user settings (see `AppSettings`) grouped by topic, plus data sources, licences and the safety disclaimer.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                SettingsRecognitionSection()
                SettingsFollowingDistanceSection()
                SettingsExperimentsSection()
                SettingsNavigationSection()
                NavigationSettingsSection()
                SettingsRoadDataSection()
                SettingsSignalSection()
                SettingsAssistantSection()
                SettingsAboutSection()
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// "35%" for 0.35.
private func settingsPercent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

/// Validates a user-entered server URL (http/https with a host); returns the trimmed string or nil.
private func settingsValidatedURL(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
          scheme == "https" || scheme == "http", let host = url.host, !host.isEmpty else {
        return nil
    }
    return trimmed
}

// MARK: - Recognition

private struct SettingsRecognitionSection: View {
    @Environment(AppState.self) private var app
    @State private var confirmReset = false

    var body: some View {
        @Bindable var settings = app.settings
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Порог детектора")
                    Spacer()
                    Text("уверенность ≥ \(settingsPercent(settings.detectionConfidence))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.detectionConfidence, in: 0.15...0.8, step: 0.05)
                    .accessibilityLabel("Минимальная уверенность детектора")
                    .accessibilityValue(settingsPercent(settings.detectionConfidence))
            }
            statusRow(title: "Детектор ТС", status: detectorStatus)
            Toggle(isOn: $settings.makeRecognitionEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Распознавать марки")
                    Text("Модель марок: \(makeStatus.text)")
                        .font(.caption)
                        .foregroundStyle(makeStatus.color)
                }
            }
            Toggle("≈ Расстояние до ТС (оценка)", isOn: $settings.showDistanceEstimates)
            Toggle("≈ Скорость других ТС (оценка)", isOn: $settings.showSpeedEstimates)
            Toggle("Пешеходы", isOn: $settings.trackPedestrians)
            Toggle("Светофоры и их цвет", isOn: $settings.detectTrafficLights)
            Toggle("Журнал для исследования (CSV)", isOn: $settings.recordExperimentLog)
            LabeledContent("Уникальных ТС за сессию", value: "\(app.recognition.totalUniqueVehicles)")
            Button("Сбросить счётчики", role: .destructive) {
                confirmReset = true
            }
            .confirmationDialog("Сбросить счётчики ТС?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Сбросить", role: .destructive) {
                    app.recognition.resetCounters()
                }
                Button("Отмена", role: .cancel) {}
            }
        } header: {
            Text("Распознавание")
        } footer: {
            Text("Уверенность — оценка самой модели, а не точность распознавания. ≈ Расстояние и скорость других ТС — оценка по одной камере, погрешность может быть большой.")
        }
    }

    private func statusRow(title: String, status: (text: String, color: Color)) -> some View {
        LabeledContent(title) {
            Text(status.text)
                .foregroundStyle(status.color)
                .multilineTextAlignment(.trailing)
        }
    }

    private var detectorStatus: (text: String, color: Color) {
        switch app.recognition.detectorStatus {
        case .loading: return ("загружается…", .secondary)
        case .ready(let name): return ("готов (\(name))", .green)
        case .missing: return ("модель не добавлена", .orange)
        case .failed(let message): return ("ошибка: \(message)", .red)
        }
    }

    private var makeStatus: (text: String, color: Color) {
        switch app.recognition.makeClassifierStatus {
        case .loading: return ("загружается…", .secondary)
        case .ready(let name): return ("готова (\(name))", .green)
        case .missing: return ("не добавлена в приложение", .orange)
        case .failed(let message): return ("ошибка: \(message)", .red)
        }
    }
}

// MARK: - Following distance

private struct SettingsFollowingDistanceSection: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Section {
            Toggle("Дистанция до впереди идущего", isOn: $settings.followingDistanceEnabled)
            Group {
                Stepper(value: $settings.followingTimeGapDry, in: 1...4, step: 0.5) {
                    HStack {
                        Text("Интервал на сухой дороге")
                        Spacer()
                        Text("\(RVFormat.decimal(settings.followingTimeGapDry, digits: 1)) с")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Stepper(value: $settings.stoppedGapMeters, in: 1...10, step: 0.5) {
                    HStack {
                        Text("Зазор в пробке / у светофора")
                        Spacer()
                        Text("\(RVFormat.decimal(settings.stoppedGapMeters, digits: 1)) м")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Stepper(value: $settings.reactionTimeSeconds, in: 0.5...2.5, step: 0.1) {
                    HStack {
                        Text("Время реакции")
                        Spacer()
                        Text("\(RVFormat.decimal(settings.reactionTimeSeconds, digits: 1)) с")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Picker("Покрытие дороги", selection: $settings.roadSurfaceMode) {
                    Text("Авто (по погоде)").tag("auto")
                    ForEach(RoadSurfaceCondition.allCases, id: \.self) { surface in
                        Text(surface.displayName).tag(surface.rawValue)
                    }
                }
                Toggle("Предупреждения: вибрация, звук, голос", isOn: $settings.distanceWarningsEnabled)
                Toggle("Показывать свою полосу", isOn: $settings.showEgoCorridor)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Линия горизонта")
                        Spacer()
                        Text(settingsPercent(settings.corridorHorizon))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.corridorHorizon, in: 0.25...0.65, step: 0.01)
                        .accessibilityLabel("Линия горизонта для коридора полосы")
                        .accessibilityValue(settingsPercent(settings.corridorHorizon))
                }
            }
            .disabled(!settings.followingDistanceEnabled)
            NavigationLink {
                DistanceNormsView()
            } label: {
                Label("Требования к дистанции", systemImage: "book.closed")
            }
        } header: {
            Text("Дистанция")
        } footer: {
            Text("Безопасный интервал: мокро ×2, снег ×3, гололёд ×5 от сухого. Расстояние до машины впереди — ≈ оценка по одной камере и не заменяет внимание водителя. Линию горизонта подстройте под крепление телефона: на ней сходится коридор вашей полосы.")
        }
    }
}

// MARK: - Experiments

private struct SettingsExperimentFile: Identifiable, Hashable {
    let url: URL
    let displayName: String
    let size: Int64
    let modified: Date?
    var id: URL { url }
}

private struct SettingsExperimentsSection: View {
    @Environment(AppState.self) private var app
    @State private var files: [SettingsExperimentFile] = []

    var body: some View {
        Section {
            if app.recognition.isRecording {
                Label("Идёт запись журнала — файлы появятся после остановки", systemImage: "record.circle")
                    .foregroundStyle(.red)
            }
            if files.isEmpty {
                Text("Файлов пока нет. Включите «Журнал для исследования» и запустите запись на экране камеры.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(files) { file in
                    ShareLink(item: file.url) {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.text")
                                .font(.title3)
                                .foregroundStyle(.cyan)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.displayName)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(details(of: file))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44)
                    }
                }
                .onDelete(perform: delete)
            }
        } header: {
            Text("Эксперименты")
        } footer: {
            Text("CSV: покадровые детекции и сводка «детекции в кадрах ↔ уникальные ТС». Нажмите, чтобы отправить; смахните влево, чтобы удалить.")
        }
        .onAppear(perform: reload)
        .onChange(of: app.recognition.isRecording) { _, _ in
            reload()
        }
    }

    private func reload() {
        files = Self.loadFiles()
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets where files.indices.contains(index) {
            try? FileManager.default.removeItem(at: files[index].url)
        }
        files.remove(atOffsets: offsets)
    }

    private func details(of file: SettingsExperimentFile) -> String {
        let size = ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
        guard let modified = file.modified else { return size }
        return "\(modified.formatted(date: .abbreviated, time: .shortened)) · \(size)"
    }

    /// Documents/Experiments — where `RecognitionPipeline.stopRecording()` writes its CSV files.
    static func experimentsDirectory() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Experiments", isDirectory: true)
    }

    /// All CSV files in Documents/Experiments (including sub-folders), newest first.
    static func loadFiles() -> [SettingsExperimentFile] {
        guard let directory = experimentsDirectory() else { return [] }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles]) else {
            return []
        }
        var result: [SettingsExperimentFile] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "csv" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == false { continue }
            let parent = url.deletingLastPathComponent().lastPathComponent
            let name = parent == "Experiments" ? url.lastPathComponent : "\(parent)/\(url.lastPathComponent)"
            result.append(SettingsExperimentFile(url: url, displayName: name,
                                                 size: Int64(values?.fileSize ?? 0),
                                                 modified: values?.contentModificationDate))
        }
        return result.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }
}

// MARK: - Navigation

/// General navigator preferences. Routing engine, Valhalla server, route attributes and traffic sources are in
/// `NavigationSettingsSection` (navigator slice), which follows this section in the form.
private struct SettingsNavigationSection: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Section {
            Toggle("Голосовые подсказки", isOn: $settings.voiceGuidanceEnabled)
            Toggle("Избегать платных дорог", isOn: $settings.avoidTolls)
            Toggle("Избегать автомагистралей", isOn: $settings.avoidHighways)
            Toggle("Окно камеры поверх карты", isOn: $settings.showCameraPiP)
            Toggle("Предупреждать о превышении скорости", isOn: $settings.speedWarningEnabled)
            Stepper(value: $settings.speedWarningTolerance, in: 0...30, step: 1) {
                HStack {
                    Text("Допуск")
                    Spacer()
                    Text("+\(Int(settings.speedWarningTolerance)) км/ч")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!settings.speedWarningEnabled)
            Stepper(value: $settings.incidentLifetimeMinutes, in: 15...720, step: 15) {
                HStack {
                    Text("Срок жизни отметок")
                    Spacer()
                    Text(RVFormat.duration(settings.incidentLifetimeMinutes * 60))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Навигация")
        } footer: {
            Text("Ограничение скорости берётся из OpenStreetMap и может отсутствовать или быть устаревшим. Отметки о ДТП, ремонте и т. п. хранятся только на этом телефоне и удаляются по истечении срока.")
        }
    }
}

// MARK: - Road data

private struct SettingsRoadDataSection: View {
    @Environment(AppState.self) private var app
    @State private var choice = ""
    @State private var customEndpoint = ""
    @State private var customError: String?

    private static let customTag = "custom"

    var body: some View {
        @Bindable var settings = app.settings
        Section {
            Toggle("Данные OpenStreetMap", isOn: $settings.roadDataEnabled)
            Picker("Сервер Overpass API", selection: $choice) {
                ForEach(AppSettings.overpassEndpoints, id: \.self) { endpoint in
                    Text(Self.hostName(endpoint)).tag(endpoint)
                }
                Text("Свой сервер").tag(Self.customTag)
            }
            .disabled(!settings.roadDataEnabled)
            .onAppear(perform: syncChoice)
            .onChange(of: choice) { _, newValue in
                choiceChanged(newValue)
            }
            if choice == Self.customTag {
                TextField("https://example.org/api/interpreter", text: $customEndpoint)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(applyCustomEndpoint)
                    .onDisappear(perform: applyCustomEndpoint)
                if let customError {
                    Text(customError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("Данные о дорогах")
        } footer: {
            Text("Полосы, ограничения скорости, светофоры, переходы, камеры и ремонт — из OpenStreetMap (© участники OpenStreetMap, лицензия ODbL) через публичный Overpass API. Если сервер не отвечает, используется резервный.")
        }
    }

    private static func hostName(_ endpoint: String) -> String {
        URL(string: endpoint)?.host ?? endpoint
    }

    private func syncChoice() {
        let current = app.settings.overpassEndpoint
        if AppSettings.overpassEndpoints.contains(current) {
            choice = current
        } else {
            customEndpoint = current
            choice = Self.customTag
        }
    }

    private func choiceChanged(_ newValue: String) {
        if newValue == Self.customTag {
            let current = app.settings.overpassEndpoint
            if customEndpoint.isEmpty && !AppSettings.overpassEndpoints.contains(current) {
                customEndpoint = current
            }
        } else if !newValue.isEmpty, app.settings.overpassEndpoint != newValue {
            app.settings.overpassEndpoint = newValue
            customError = nil
        }
    }

    private func applyCustomEndpoint() {
        let trimmed = customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            customError = nil
            return
        }
        guard let valid = settingsValidatedURL(trimmed) else {
            customError = "Введите адрес вида https://…/api/interpreter"
            return
        }
        app.settings.overpassEndpoint = valid
        customEndpoint = valid
        customError = nil
    }
}

// MARK: - Traffic signals

private struct SettingsSignalSection: View {
    @Environment(AppState.self) private var app
    @State private var confirmReset = false

    var body: some View {
        @Bindable var settings = app.settings
        let estimate = SignalWaitModel.estimate(settings.signalAssumptions)
        Section {
            Stepper(value: $settings.signalCycleSeconds, in: 40...180, step: 5) {
                HStack {
                    Text("Цикл светофора")
                    Spacer()
                    Text("\(Int(settings.signalCycleSeconds)) с")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Доля зелёного")
                    Spacer()
                    Text(settingsPercent(settings.signalGreenRatio))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.signalGreenRatio, in: 0.2...0.8, step: 0.05)
                    .accessibilityLabel("Доля зелёного сигнала")
                    .accessibilityValue(settingsPercent(settings.signalGreenRatio))
            }
            LabeledContent("Ожидание по модели") {
                Text("≈ \(RVFormat.duration(estimate.expectedWaitSeconds)) (оценка), остановка в \(settingsPercent(estimate.stopProbability)) случаев")
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
            }
            Toggle("Учиться на моих остановках", isOn: $settings.learnSignalTimings)
            Text("Накоплено наблюдений: \(app.signals.observationCount)")
                .monospacedDigit()
            Button("Сбросить накопленные данные", role: .destructive) {
                confirmReset = true
            }
            .disabled(app.signals.observationCount == 0)
            .confirmationDialog("Удалить все наблюдения у светофоров?", isPresented: $confirmReset,
                                titleVisibility: .visible) {
                Button("Удалить", role: .destructive) {
                    app.signals.resetLearnedData()
                }
                Button("Отмена", role: .cancel) {}
            }
        } header: {
            Text("Светофоры")
        } footer: {
            Text("Реальные фазы светофоров в Узбекистане публично недоступны, поэтому время ожидания — оценка: модель светофора с фиксированным циклом (цикл и доля зелёного выше) плюс ваши собственные остановки у светофоров, если включено обучение. Наблюдения хранятся только на телефоне.")
        }
    }
}

// MARK: - AI assistant

private struct SettingsAssistantSection: View {
    @Environment(AppState.self) private var app
    @State private var apiKeyDraft = ""
    @State private var keyIsSaved = false
    /// Preset whose key is currently in `apiKeyDraft` — a draft is only ever saved under this preset.
    @State private var draftPresetID: String?
    @State private var savedKeyPresetIDs: Set<String> = []
    @State private var models: [String] = []
    @State private var isLoadingModels = false
    @State private var modelsError: String?
    @State private var isTesting = false
    @State private var testResult: ChatConnectionTestResult?
    @State private var appleStatus: AppleIntelligenceStatus = .unavailable

    var body: some View {
        @Bindable var settings = app.settings
        let providerID = settings.aiProviderID
        let preset = ChatPresets.preset(id: providerID)
        Section {
            Picker("Сервис", selection: $settings.aiProviderID) {
                ForEach(ChatBackendResolver.selectableProviderIDs, id: \.self) { id in
                    Text(ChatBackendResolver.providerTitle(for: id)).tag(id)
                }
            }
            // Lifecycle handlers live on one row (not on the Section) so that they run exactly once.
            .onAppear {
                loadKey(for: app.settings.aiProviderID)
                refreshSavedKeys()
                appleStatus = AppleOnDeviceBackend.status(localeIdentifier: app.settings.speechLocaleIdentifier)
            }
            .onDisappear {
                saveKey(for: app.settings.aiProviderID)
            }
            .onChange(of: settings.aiProviderID) { oldValue, newValue in
                providerChanged(from: oldValue, to: newValue)
            }
            .onChange(of: settings.speechLocaleIdentifier) { _, newValue in
                appleStatus = AppleOnDeviceBackend.status(localeIdentifier: newValue)
            }
            providerInfo(providerID: providerID, preset: preset)
            if providerID == ChatPresets.autoID {
                autoKeyLinks
            }
            if let preset {
                if ChatBackendResolver.acceptsAPIKey(preset.id) {
                    keyRows(preset)
                }
                if ChatBackendResolver.usesCustomBaseURL(preset.id) {
                    baseURLRow(preset)
                }
                modelRows(preset)
            }
            testRows
        } header: {
            Text("ИИ‑помощник")
        } footer: {
            Text("Все варианты бесплатны. Ключи API хранятся только в Связке ключей iPhone и отправляются лишь выбранному сервису. Названия моделей меняются — при ошибке загрузите актуальный список.")
        }

        Section {
            Picker("Язык речи", selection: $settings.speechLocaleIdentifier) {
                Text("Русский").tag("ru-RU")
                Text("Oʻzbekcha").tag("uz-UZ")
                Text("English").tag("en-US")
            }
            if settings.languageCode == "uz" {
                Text("iOS не распознаёт узбекскую речь: говорите по-русски или пишите по-узбекски — помощник ответит на узбекском. Узбекского голоса в iOS нет, поэтому ответы читаются русским голосом.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Toggle("Озвучивать ответы", isOn: $settings.speakAssistantReplies)
            Toggle("Передавать данные поездки", isOn: $settings.assistantIncludeDrivingContext)
        } header: {
            Text("Речь и данные поездки")
        } footer: {
            Text("С вопросом выбранному ИИ‑сервису отправляются: скорость, название дороги и полосы, маршрут и время в пути, погода и счётчики ТС. Точные координаты не отправляются. Речь распознаётся на устройстве, если iPhone это поддерживает.")
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func providerInfo(providerID: String, preset: ChatProviderPreset?) -> some View {
        if providerID == ChatPresets.autoID {
            Text("Сейчас по порядку: \(ChatBackendResolver.autoChainDescription(settings: app.settings)). Сервисы с ключом участвуют, только если ключ сохранён (кнопки ниже).")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if providerID == ChatPresets.appleOnDeviceID {
            Label(appleStatus.message,
                  systemImage: appleStatus.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(appleStatus.isAvailable ? Color.green : Color.orange)
        } else if let preset {
            Text(preset.notes)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var autoKeyLinks: some View {
        ForEach(ChatPresets.all.filter(\.requiresAPIKey)) { keyed in
            NavigationLink {
                SettingsAPIKeyEditor(preset: keyed) {
                    refreshSavedKeys()
                }
            } label: {
                let hasKey = savedKeyPresetIDs.contains(keyed.id)
                HStack {
                    Label(chatProviderShortName(keyed), systemImage: "key.fill")
                    Spacer()
                    Text(hasKey ? "ключ сохранён" : "нет ключа")
                        .font(.footnote)
                        .foregroundStyle(hasKey ? Color.green : Color.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func keyRows(_ preset: ChatProviderPreset) -> some View {
        SecureField(preset.requiresAPIKey ? "Ключ API" : "Ключ API (если нужен)", text: $apiKeyDraft)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .onSubmit {
                saveKey(for: preset.id)
            }
        HStack {
            Label(keyIsSaved ? "Ключ сохранён в Связке ключей" : "Ключ не сохранён",
                  systemImage: keyIsSaved ? "checkmark.seal.fill" : "key")
                .font(.footnote)
                .foregroundStyle(keyIsSaved ? Color.green : Color.secondary)
            Spacer()
            if keyIsSaved {
                Button("Удалить", role: .destructive) {
                    apiKeyDraft = ""
                    saveKey(for: preset.id)
                }
                .font(.footnote)
                .buttonStyle(.borderless)
            } else if !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Сохранить") {
                    saveKey(for: preset.id)
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.borderless)
            }
        }
        if let keyURL = preset.keyURL, let url = URL(string: keyURL) {
            Link(destination: url) {
                Label("Получить бесплатный ключ", systemImage: "arrow.up.right.square")
            }
        }
    }

    @ViewBuilder
    private func baseURLRow(_ preset: ChatProviderPreset) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Адрес сервера")
                .font(.subheadline)
            TextField(preset.baseURL.isEmpty ? "http://192.168.1.10:8080/v1" : preset.baseURL,
                      text: Bindable(app.settings).aiCustomBaseURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Text("Формат: http://IP‑адрес‑Mac:порт/v1. Телефон и Mac должны быть в одной сети Wi‑Fi.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func modelRows(_ preset: ChatProviderPreset) -> some View {
        let placeholder = preset.defaultModel.isEmpty ? "Модель (обязательно)" : "Модель (по умолчанию \(preset.defaultModel))"
        TextField(placeholder, text: Bindable(app.settings).aiModel)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        Button {
            loadModels(preset)
        } label: {
            HStack {
                Label("Загрузить список моделей", systemImage: "arrow.down.circle")
                Spacer()
                if isLoadingModels {
                    ProgressView()
                }
            }
        }
        .disabled(isLoadingModels)
        if let modelsError {
            Text(modelsError)
                .font(.footnote)
                .foregroundStyle(.red)
        }
        if !models.isEmpty {
            Picker("Доступные модели (\(models.count))", selection: Bindable(app.settings).aiModel) {
                if !preset.defaultModel.isEmpty {
                    Text("По умолчанию (\(preset.defaultModel))").tag("")
                }
                ForEach(models, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .pickerStyle(.navigationLink)
        }
    }

    @ViewBuilder
    private var testRows: some View {
        Button {
            runTest()
        } label: {
            HStack {
                Label("Проверить соединение", systemImage: "bolt.horizontal.circle")
                Spacer()
                if isTesting {
                    ProgressView()
                }
            }
        }
        .disabled(isTesting)
        if let testResult {
            Label {
                Text(testResult.summary)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: testResult.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(testResult.success ? Color.green : Color.red)
            }
        }
    }

    // MARK: Actions

    private func loadKey(for presetID: String) {
        if ChatBackendResolver.acceptsAPIKey(presetID) {
            apiKeyDraft = ChatBackendResolver.apiKey(for: presetID) ?? ""
        } else {
            apiKeyDraft = ""
        }
        draftPresetID = presetID
        keyIsSaved = !apiKeyDraft.isEmpty
    }

    /// Writes the key field to the Keychain (empty → deletes the stored key).
    private func saveKey(for presetID: String) {
        guard presetID == draftPresetID, ChatBackendResolver.acceptsAPIKey(presetID) else { return }
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainStore.shared.set(trimmed.isEmpty ? nil : trimmed, for: ChatBackendResolver.apiKeyAccount(for: presetID))
        apiKeyDraft = trimmed
        keyIsSaved = !trimmed.isEmpty
        refreshSavedKeys()
    }

    private func refreshSavedKeys() {
        savedKeyPresetIDs = Set(ChatPresets.all.map(\.id).filter { ChatBackendResolver.apiKey(for: $0) != nil })
    }

    private func providerChanged(from oldValue: String, to newValue: String) {
        saveKey(for: oldValue)
        loadKey(for: newValue)
        let settings = app.settings
        // Model ids are provider-specific.
        settings.aiModel = ""
        models = []
        modelsError = nil
        testResult = nil
        if let preset = ChatPresets.preset(id: newValue), ChatBackendResolver.usesCustomBaseURL(newValue) {
            let current = settings.aiCustomBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let presetDefaults = Set(ChatPresets.all.map(\.baseURL).filter { !$0.isEmpty })
            if current.isEmpty || presetDefaults.contains(current) {
                settings.aiCustomBaseURL = preset.baseURL
            }
        }
        appleStatus = AppleOnDeviceBackend.status(localeIdentifier: settings.speechLocaleIdentifier)
    }

    private func loadModels(_ preset: ChatProviderPreset) {
        saveKey(for: preset.id)
        let effective = ChatBackendResolver.effectivePreset(preset, settings: app.settings)
        let key = ChatBackendResolver.apiKey(for: preset.id)
        isLoadingModels = true
        modelsError = nil
        Task {
            do {
                let list = try await ChatModelCatalog.fetchModels(for: effective, apiKey: key)
                models = list
                if list.isEmpty {
                    modelsError = "Сервер не вернул ни одной подходящей модели"
                }
            } catch {
                models = []
                modelsError = chatErrorDescription(error)
            }
            isLoadingModels = false
        }
    }

    private func runTest() {
        saveKey(for: app.settings.aiProviderID)
        isTesting = true
        testResult = nil
        let settings = app.settings
        Task {
            let result = await ChatConnectionTester.run(settings: settings)
            testResult = result
            isTesting = false
        }
    }
}

/// Key editor for one keyed provider (used from the "Авто" mode list).
private struct SettingsAPIKeyEditor: View {
    let preset: ChatProviderPreset
    var onChange: () -> Void

    @State private var draft = ""
    @State private var saved = false

    /// - Parameters:
    ///   - preset: keyed provider whose key is edited.
    ///   - onChange: called after the key was saved or deleted.
    init(preset: ChatProviderPreset, onChange: @escaping () -> Void) {
        self.preset = preset
        self.onChange = onChange
    }

    private var account: String { ChatBackendResolver.apiKeyAccount(for: preset.id) }

    var body: some View {
        Form {
            Section {
                SecureField("Ключ API", text: $draft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(save)
                Button("Сохранить", action: save)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if saved {
                    Button("Удалить ключ", role: .destructive) {
                        draft = ""
                        save()
                    }
                }
            } header: {
                Text(chatProviderShortName(preset))
            } footer: {
                Text(preset.notes)
            }
            if let keyURL = preset.keyURL, let url = URL(string: keyURL) {
                Section {
                    Link(destination: url) {
                        Label("Получить бесплатный ключ", systemImage: "arrow.up.right.square")
                    }
                }
            }
        }
        .navigationTitle("Ключ API")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            draft = KeychainStore.shared.string(for: account) ?? ""
            saved = !draft.isEmpty
        }
        .onDisappear(perform: save)
    }

    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainStore.shared.set(trimmed.isEmpty ? nil : trimmed, for: account)
        draft = trimmed
        saved = !trimmed.isEmpty
        onChange()
    }
}

// MARK: - About

private struct SettingsAboutSection: View {
    var body: some View {
        Section {
            LabeledContent("Версия", value: versionText)
        } header: {
            Text("О приложении")
        }

        Section {
            sourceRow(title: "Карты, поиск и маршруты",
                      detail: "Apple Maps (MapKit); пробки и время в пути — данные Apple, где они есть.")
            VStack(alignment: .leading, spacing: 6) {
                sourceRow(title: "Данные о дорогах и маршруты OSM",
                          detail: "© участники OpenStreetMap, лицензия ODbL. Запросы через Overpass API и Valhalla (FOSSGIS).")
                if let copyright = URL(string: "https://www.openstreetmap.org/copyright") {
                    Link("openstreetmap.org/copyright", destination: copyright)
                        .font(.footnote)
                }
                if let fixTheMap = URL(string: "https://www.openstreetmap.org/fixthemap") {
                    Link("Сообщить об ошибке на карте", destination: fixTheMap)
                        .font(.footnote)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                sourceRow(title: "Погода", detail: "Weather data by Open-Meteo.com, лицензия CC BY 4.0.")
                if let openMeteo = URL(string: "https://open-meteo.com/") {
                    Link("open-meteo.com", destination: openMeteo)
                        .font(.footnote)
                }
            }
            sourceRow(title: "Распознавание ТС",
                      detail: "Модели Ultralytics YOLO распространяются по лицензии AGPL-3.0; для закрытого коммерческого распространения нужна корпоративная лицензия Ultralytics. Модель марок — по лицензии её набора данных.")
            sourceRow(title: "ИИ‑помощник",
                      detail: "Pollinations, Google Gemini, Groq, OpenRouter, Ollama, LM Studio и Apple Intelligence: действуют условия использования и политика конфиденциальности соответствующего сервиса. Сообщения отправляются выбранному сервису напрямую.")
        } header: {
            Text("Источники данных и лицензии")
        }

        Section {
            Text("RoadVision — вспомогательное приложение. Следите за дорогой и соблюдайте ПДД. Полосы, ограничения скорости, светофоры, пробки и события могут быть неточными или устаревшими; расстояния, скорости других ТС и время на светофорах — лишь оценки. Не управляйте телефоном во время движения.")
                .font(.footnote)
            Text("YOUR USE OF THIS REAL TIME ROUTE GUIDANCE APPLICATION IS AT YOUR SOLE RISK. LOCATION DATA MAY NOT BE ACCURATE.")
                .font(.footnote.weight(.semibold))
        } header: {
            Text("Безопасность")
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    private func sourceRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
