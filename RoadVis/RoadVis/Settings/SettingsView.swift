import SwiftUI

/// All user settings (see `AppSettings`) grouped by topic, plus data sources, licences and the safety disclaimer.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                LanguageSettingsSection()
                SettingsRecognitionSection()
                SettingsFollowingDistanceSection()
                DriverAssistSettingsSection()
                TripSettingsSection()
                SettingsExperimentsSection()
                SettingsNavigationSection()
                NavigationSettingsSection()
                SettingsRoadDataSection()
                SettingsSignalSection()
                SettingsAboutSection()
            }
            .navigationTitle(L("common.settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.done")) { dismiss() }
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
                    Text(l: "settings.rec.threshold")
                    Spacer()
                    Text(l: "settings.rec.confidenceValue", settingsPercent(settings.detectionConfidence))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.detectionConfidence, in: 0.15...0.8, step: 0.05)
                    .accessibilityLabel(L("settings.rec.threshold.a11y"))
                    .accessibilityValue(settingsPercent(settings.detectionConfidence))
            }
            statusRow(title: L("settings.rec.detector"), status: detectorStatus)
            Toggle(isOn: $settings.makeRecognitionEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(l: "settings.rec.makes")
                    Text(l: "settings.rec.makeModel", makeStatus.text)
                        .font(.caption)
                        .foregroundStyle(makeStatus.color)
                }
            }
            Toggle(L("settings.rec.distance"), isOn: $settings.showDistanceEstimates)
            Toggle(L("settings.rec.speed"), isOn: $settings.showSpeedEstimates)
            Toggle(L("settings.rec.pedestrians"), isOn: $settings.trackPedestrians)
            Toggle(L("settings.rec.lights"), isOn: $settings.detectTrafficLights)
            VStack(alignment: .leading, spacing: 4) {
                Picker(L("settings.rec.stabilization"), selection: $settings.videoStabilization) {
                    Text(l: "settings.rec.stabilization.off").tag("off")
                    Text(l: "settings.rec.stabilization.standard").tag("standard")
                    Text(l: "settings.rec.stabilization.strong").tag("strong")
                }
                Text(l: "settings.rec.stabilization.hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle(L("settings.rec.log"), isOn: $settings.recordExperimentLog)
                .onChange(of: settings.recordExperimentLog) { _, _ in
                    app.tripRecorder.syncCameraCSV()
                }
            LabeledContent(L("settings.rec.unique"), value: "\(app.recognition.totalUniqueVehicles)")
            Button(L("counters.reset"), role: .destructive) {
                confirmReset = true
            }
            .confirmationDialog(L("settings.rec.resetConfirm"), isPresented: $confirmReset, titleVisibility: .visible) {
                Button(L("common.reset"), role: .destructive) {
                    app.recognition.resetCounters()
                }
                Button(L("common.cancel"), role: .cancel) {}
            }
        } header: {
            Text(l: "recStatus.title")
        } footer: {
            Text(l: "settings.rec.footer")
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
        case .loading: return (L("settings.status.loading"), .secondary)
        case .ready(let name): return (L("settings.status.readyDetector", name), .green)
        case .missing: return (L("settings.status.noModel"), .orange)
        case .failed(let message): return (L("status.error", message), .red)
        }
    }

    private var makeStatus: (text: String, color: Color) {
        switch app.recognition.makeClassifierStatus {
        case .loading: return (L("settings.status.loading"), .secondary)
        case .ready(let name): return (L("settings.status.readyMake", name), .green)
        case .missing: return (L("settings.status.makeMissing"), .orange)
        case .failed(let message): return (L("status.error", message), .red)
        }
    }
}

// MARK: - Following distance

private struct SettingsFollowingDistanceSection: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Section {
            Toggle(L("settings.fd.enabled"), isOn: $settings.followingDistanceEnabled)
            Group {
                Stepper(value: $settings.followingTimeGapDry, in: 1...4, step: 0.5) {
                    HStack {
                        Text(l: "settings.fd.dryGap")
                        Spacer()
                        Text(verbatim: "\(RVFormat.appDecimal(settings.followingTimeGapDry, digits: 1)) \(RVFormat.appSeconds)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Stepper(value: $settings.hoodLengthMeters, in: 0...4, step: 0.1) {
                    HStack {
                        Text(l: "settings.fd.hood")
                        Spacer()
                        Text(verbatim: "\(RVFormat.appDecimal(settings.hoodLengthMeters, digits: 1)) \(RVFormat.appMeters)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                HoodCalibrationRow()
                Stepper(value: $settings.stoppedGapMeters, in: 1...10, step: 0.5) {
                    HStack {
                        Text(l: "settings.fd.stoppedGap")
                        Spacer()
                        Text(verbatim: "\(RVFormat.appDecimal(settings.stoppedGapMeters, digits: 1)) \(RVFormat.appMeters)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Stepper(value: $settings.reactionTimeSeconds, in: 0.5...2.5, step: 0.1) {
                    HStack {
                        Text(l: "settings.fd.reaction")
                        Spacer()
                        Text(verbatim: "\(RVFormat.appDecimal(settings.reactionTimeSeconds, digits: 1)) \(RVFormat.appSeconds)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Picker(L("settings.fd.surface"), selection: $settings.roadSurfaceMode) {
                    Text(l: "settings.fd.surfaceAuto").tag("auto")
                    ForEach(RoadSurfaceCondition.allCases, id: \.self) { surface in
                        Text(surface.localizedName).tag(surface.rawValue)
                    }
                }
                Toggle(L("settings.fd.warnings"), isOn: $settings.distanceWarningsEnabled)
                Toggle(L("settings.fd.corridor"), isOn: $settings.showEgoCorridor)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(l: "settings.fd.horizon")
                        Spacer()
                        Text(settingsPercent(settings.corridorHorizon))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.corridorHorizon, in: 0.25...0.65, step: 0.01)
                        .disabled(settings.autoHorizonEnabled)
                        .accessibilityLabel(L("settings.fd.horizon.a11y"))
                        .accessibilityValue(settingsPercent(settings.corridorHorizon))
                }
                Toggle(L("settings.fd.horizonAuto"), isOn: $settings.autoHorizonEnabled)
                Text(l: "settings.fd.horizonAuto.hint")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .disabled(!settings.followingDistanceEnabled)
            NavigationLink {
                DistanceNormsView()
            } label: {
                Label(L("fd.norms.title"), systemImage: "book.closed")
            }
        } header: {
            Text(l: "settings.fd.title")
        } footer: {
            Text(l: "settings.fd.footer")
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
                Label(L("settings.exp.recording"), systemImage: "record.circle")
                    .foregroundStyle(.red)
            }
            if files.isEmpty {
                Text(l: "settings.exp.empty")
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
            Text(l: "settings.exp.title")
        } footer: {
            Text(l: "settings.exp.footer")
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
            Toggle(L("settings.nav.voice"), isOn: $settings.voiceGuidanceEnabled)
            Toggle(L("settings.nav.avoidTolls"), isOn: $settings.avoidTolls)
            Toggle(L("settings.nav.avoidHighways"), isOn: $settings.avoidHighways)
            Toggle(L("settings.nav.pip"), isOn: $settings.showCameraPiP)
            Toggle(L("settings.nav.speedWarning"), isOn: $settings.speedWarningEnabled)
            Stepper(value: $settings.speedWarningTolerance, in: 0...30, step: 1) {
                HStack {
                    Text(l: "settings.nav.tolerance")
                    Spacer()
                    Text(verbatim: "+\(Int(settings.speedWarningTolerance)) \(RVFormat.appKmh)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!settings.speedWarningEnabled)
            Stepper(value: $settings.incidentLifetimeMinutes, in: 15...720, step: 15) {
                HStack {
                    Text(l: "settings.nav.incidentLifetime")
                    Spacer()
                    Text(RVFormat.appDuration(settings.incidentLifetimeMinutes * 60))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(l: "settings.nav.title")
        } footer: {
            Text(l: "settings.nav.footer")
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
            Toggle(L("settings.road.osm"), isOn: $settings.roadDataEnabled)
            Picker(L("settings.road.server"), selection: $choice) {
                ForEach(AppSettings.overpassEndpoints, id: \.self) { endpoint in
                    Text(Self.hostName(endpoint)).tag(endpoint)
                }
                Text(l: "settings.customServer").tag(Self.customTag)
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
            Text(l: "settings.road.title")
        } footer: {
            Text(l: "settings.road.footer")
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
            customError = L("settings.road.invalidURL")
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
                    Text(l: "settings.signal.cycle")
                    Spacer()
                    Text(verbatim: "\(Int(settings.signalCycleSeconds)) \(RVFormat.appSeconds)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(l: "settings.signal.green")
                    Spacer()
                    Text(settingsPercent(settings.signalGreenRatio))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.signalGreenRatio, in: 0.2...0.8, step: 0.05)
                    .accessibilityLabel(L("settings.signal.green.a11y"))
                    .accessibilityValue(settingsPercent(settings.signalGreenRatio))
            }
            LabeledContent(L("settings.signal.modelWait")) {
                Text(l: "settings.signal.modelWaitValue", RVFormat.appDuration(estimate.expectedWaitSeconds), settingsPercent(estimate.stopProbability))
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
            }
            Toggle(L("settings.signal.learn"), isOn: $settings.learnSignalTimings)
            Text(l: "settings.signal.observations", app.signals.observationCount)
                .monospacedDigit()
            Button(L("settings.signal.reset"), role: .destructive) {
                confirmReset = true
            }
            .disabled(app.signals.observationCount == 0)
            .confirmationDialog(L("settings.signal.resetConfirm"), isPresented: $confirmReset,
                                titleVisibility: .visible) {
                Button(L("common.delete"), role: .destructive) {
                    app.signals.resetLearnedData()
                }
                Button(L("common.cancel"), role: .cancel) {}
            }
        } header: {
            Text(l: "settings.signal.title")
        } footer: {
            Text(l: "settings.signal.footer")
        }
    }
}

// MARK: - About

private struct SettingsAboutSection: View {
    var body: some View {
        Section {
            NavigationLink {
                AboutHubView(embedInNavigationStack: false)
            } label: {
                Label(L("settings.about.link"), systemImage: "info.circle")
            }
            LabeledContent(L("common.version"), value: versionText)
        } header: {
            Text(l: "about.title")
        }

        Section {
            sourceRow(title: L("sources.maps.title"),
                      detail: L("sources.maps.detail"))
            VStack(alignment: .leading, spacing: 6) {
                sourceRow(title: L("sources.basemap.title"),
                          detail: L("sources.basemap.detail"))
                Link("openfreemap.org", destination: MapLibreBaseMap.openFreeMapURL)
                    .font(.footnote)
            }
            VStack(alignment: .leading, spacing: 6) {
                sourceRow(title: L("sources.osm.title"),
                          detail: L("sources.osm.detail"))
                if let copyright = URL(string: "https://www.openstreetmap.org/copyright") {
                    Link("openstreetmap.org/copyright", destination: copyright)
                        .font(.footnote)
                }
                if let fixTheMap = URL(string: "https://www.openstreetmap.org/fixthemap") {
                    Link(L("sources.osm.fix"), destination: fixTheMap)
                        .font(.footnote)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                sourceRow(title: L("sources.weather.title"), detail: L("sources.weather.detail"))
                if let openMeteo = URL(string: "https://open-meteo.com/") {
                    Link("open-meteo.com", destination: openMeteo)
                        .font(.footnote)
                }
            }
            sourceRow(title: L("sources.yolo.title"),
                      detail: L("sources.yolo.detail") + " " + L("settings.sources.makeLicense"))
        } header: {
            Text(l: "about.sources")
        }

        Section {
            Text(l: "sources.safety.body")
                .font(.footnote)
            Text(verbatim: "YOUR USE OF THIS REAL TIME ROUTE GUIDANCE APPLICATION IS AT YOUR SOLE RISK. LOCATION DATA MAY NOT BE ACCURATE.")
                .font(.footnote.weight(.semibold))
        } header: {
            Text(l: "sources.safety.header")
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


/// Calibrates the bonnet offset while standing behind another car: the user enters the real bumper-to-bumper gap,
/// the app sets `hoodLengthMeters = camera distance − real gap`.
private struct HoodCalibrationRow: View {
    @Environment(AppState.self) private var app
    @State private var realGap: Double = 1.5
    @State private var resultText: String?

    var body: some View {
        let cameraDistance = app.recognition.leadVehicle?.cameraDistanceMeters
        VStack(alignment: .leading, spacing: 6) {
            Stepper(value: $realGap, in: 0.5...6, step: 0.1) {
                HStack {
                    Text(l: "settings.fd.calib.real")
                    Spacer()
                    Text(verbatim: "\(RVFormat.appDecimal(realGap, digits: 1)) \(RVFormat.appMeters)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                guard let d = cameraDistance else { return }
                let hood = min(4, max(0, d - realGap))
                app.settings.hoodLengthMeters = (hood * 10).rounded() / 10
                resultText = L("settings.fd.calib.done", RVFormat.appDecimal(app.settings.hoodLengthMeters, digits: 1))
            } label: {
                Label(L("settings.fd.calib.button"), systemImage: "ruler")
            }
            // Not the default style: in a Form row that would make the whole row (labels, hint) trigger calibration.
            .buttonStyle(.borderless)
            .disabled(cameraDistance == nil)
            Text(resultText ?? (cameraDistance == nil ? L("settings.fd.calib.noLead") : L("settings.fd.calib.hint")))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
