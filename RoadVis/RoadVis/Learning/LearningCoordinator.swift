import BackgroundTasks
import Foundation
import Observation
import UIKit

/// Continuous learning in the app (`docs/TRAINING_API.md`): owns the settings, the local sample store, the uploader
/// and the model update service, and wires them to the recognition pipeline and the app lifecycle.
///
/// - Collection runs inside `RecognitionWorker` (`LearningCollector`); this object switches it on / off and keeps
///   the counters of the Settings screen.
/// - Uploads and the daily model check run when the app becomes active and when the navigator is shown, never while
///   the camera screen is active, plus a `BGProcessingTask` (`LearningBackgroundTasks`) after the app went to the
///   background.
@Observable
@MainActor
final class LearningCoordinator {
    /// The coordinator of the running app (for the background-task handler registered at launch).
    static weak var current: LearningCoordinator?

    let settings: LearningSettings
    let uploader: LearningUploader
    let models: ModelUpdateService
    let store: LearningStore

    /// Complete samples waiting for upload and their size, bytes.
    private(set) var pendingCount = 0
    private(set) var pendingBytes: Int64 = 0
    /// Frames kept during the current trip (the per-trip cap is `HardExampleSelector.Config.maxPerTrip`).
    private(set) var keptThisTrip = 0
    /// Frames dropped by the quality / duplicate gate (never stored) plus samples the server refused (413 / 422).
    private(set) var deletedByQuality: Int
    /// Samples deleted by the size cap or the 14-day age limit.
    private(set) var deletedByLimit: Int
    /// Last local error of the collector (JPEG / file write).
    private(set) var collectorError: String?

    /// True while the camera screen is visible and the app is in the foreground.
    @ObservationIgnored var isCameraActive: () -> Bool = { false } {
        didSet { uploader.isCameraActive = isCameraActive }
    }

    @ObservationIgnored private let recognition: RecognitionPipeline
    @ObservationIgnored private let location: LocationService
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let network: LearningNetworkMonitor
    @ObservationIgnored private var started = false
    @ObservationIgnored private var qualityRejectsSinceSave = 0

    init(recognition: RecognitionPipeline, location: LocationService, defaults: UserDefaults = .standard) {
        let settings = LearningSettings(defaults: defaults)
        self.settings = settings
        self.recognition = recognition
        self.location = location
        self.defaults = defaults
        self.store = .shared
        self.network = .shared
        self.uploader = LearningUploader(settings: settings, defaults: defaults)
        self.models = ModelUpdateService(settings: settings, defaults: defaults)
        deletedByQuality = defaults.integer(forKey: Keys.deletedByQuality)
        deletedByLimit = defaults.integer(forKey: Keys.deletedByLimit)

        models.applyModel = { [weak recognition] model in
            recognition?.setDownloadedModel(model)
        }
        uploader.onStoreChanged = { [weak self] in
            self?.refreshSummary()
        }
        recognition.onLearningEvent = { [weak self] event in
            self?.handle(event)
        }
        recognition.onDownloadedModelFailure = { [weak self] version, reason in
            self?.models.revert(version: version, reason: reason)
        }
        Self.current = self
    }

    /// Called once from `AppState.start()`.
    func start() {
        guard !started else { return }
        started = true
        network.start()
        pushOptions()
        models.applyActiveModel()
        observeSettings()
        refreshSummary()
        // Age limit / size cap also apply while nothing new is collected.
        applyRetentionInBackground()
    }

    // MARK: - Lifecycle hooks (AppState)

    /// App became active (foreground).
    func appBecameActive() {
        guard settings.enabled else { return }
        refreshSummary()
        applyRetentionInBackground()
        runNetworkWork()
    }

    /// The navigator replaced the camera screen.
    func enteredNavigator() {
        guard settings.enabled else { return }
        runNetworkWork()
    }

    /// The camera screen became active: uploads stop at the next sample.
    func enteredCamera() {
        uploader.cancel()
    }

    /// App went to the background: ask for a background processing slot when samples wait.
    func appEnteredBackground() {
        defaults.set(deletedByQuality, forKey: Keys.deletedByQuality)
        guard settings.enabled else { return }
        refreshSummary()
        if pendingCount > 0 || settings.downloadModels {
            LearningBackgroundTasks.schedule()
        }
    }

    /// A trip recording started: the per-trip counter restarts.
    func tripStarted() {
        keptThisTrip = 0
        recognition.resetLearningTrip()
    }

    // MARK: - Settings actions

    func uploadNow() {
        uploader.runIfAllowed(trigger: .manual)
    }

    func checkModelNow() {
        models.checkNow()
    }

    func deleteAllSamples() {
        let store = self.store
        DispatchQueue.global(qos: .utility).async {
            store.deleteAll()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    LearningCoordinator.current?.refreshSummary()
                }
            }
        }
        pendingCount = 0
        pendingBytes = 0
    }

    /// Recounts the stored samples (off the main thread).
    func refreshSummary() {
        let store = self.store
        DispatchQueue.global(qos: .utility).async {
            let summary = store.summary()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let coordinator = LearningCoordinator.current else { return }
                    if coordinator.pendingCount != summary.count { coordinator.pendingCount = summary.count }
                    if coordinator.pendingBytes != summary.bytes { coordinator.pendingBytes = summary.bytes }
                }
            }
        }
    }

    /// Runs one upload batch and, if due, the model check (background processing task).
    func runBackgroundWork() async -> Bool {
        guard settings.enabled else { return true }
        models.checkIfDue()
        return await uploader.runForBackgroundTask()
    }

    // MARK: - Private

    private func runNetworkWork() {
        uploader.runIfAllowed(trigger: .automatic)
        models.checkIfDue()
    }

    private func handle(_ event: LearningCollector.Event) {
        switch event {
        case .saved(let kept, let deleted):
            keptThisTrip = kept
            if deleted > 0 {
                deletedByLimit += deleted
                defaults.set(deletedByLimit, forKey: Keys.deletedByLimit)
            }
            if collectorError != nil { collectorError = nil }
            refreshSummary()
        case .rejectedByQuality:
            deletedByQuality += 1
            // Written in batches: this can fire several times per second while the picture is dark or blurred.
            qualityRejectsSinceSave += 1
            if qualityRejectsSinceSave >= 20 {
                qualityRejectsSinceSave = 0
                defaults.set(deletedByQuality, forKey: Keys.deletedByQuality)
            }
        case .saveFailed(let message):
            collectorError = message
        }
    }

    /// Total of quality rejects shown in Settings (local gate + server 413 / 422).
    var deletedByQualityTotal: Int { deletedByQuality + uploader.rejectedTotal }

    private func applyRetentionInBackground() {
        let store = self.store
        let policy = LearningStorePolicy(limitMB: settings.storageLimitMB)
        DispatchQueue.global(qos: .utility).async {
            let plan = store.applyRetention(policy)
            let deleted = plan.all.count
            let summary = store.summary()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let coordinator = LearningCoordinator.current else { return }
                    if deleted > 0 {
                        coordinator.deletedByLimit += deleted
                        coordinator.defaults.set(coordinator.deletedByLimit, forKey: Keys.deletedByLimit)
                    }
                    coordinator.pendingCount = summary.count
                    coordinator.pendingBytes = summary.bytes
                }
            }
        }
    }

    private func pushOptions() {
        recognition.setLearningOptions(enabled: settings.enabled, sendLocation: settings.sendLocation,
                                       storageLimitMB: settings.storageLimitMB)
    }

    /// Re-pushes the options when a learning setting changes; switching learning off goes back to the bundled model.
    private func observeSettings() {
        withObservationTracking {
            _ = settings.enabled
            _ = settings.sendLocation
            _ = settings.storageLimitMB
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pushOptions()
                self.models.applyActiveModel()
                // A smaller storage limit applies at once.
                self.applyRetentionInBackground()
                self.observeSettings()
            }
        }
    }

    private enum Keys {
        static let deletedByQuality = "rv.learning.deletedByQuality"
        static let deletedByLimit = "rv.learning.deletedByLimit"
    }
}

/// `BGProcessingTask` that uploads one batch (and runs the daily model check) while the app is in the background.
/// The identifier is listed under `BGTaskSchedulerPermittedIdentifiers` in Config/Info.plist and project.yml.
enum LearningBackgroundTasks {
    static let identifier = "uz.roadvis.RoadVis.learning.upload"
    /// Earliest start after scheduling.
    static let delay: TimeInterval = 15 * 60

    /// Registers the launch handler. Must run before the app finishes launching (`RoadVisApp.init`).
    static func register() {
        _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            let box = BackgroundTaskBox(task: task)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    LearningBackgroundTasks.handle(box)
                }
            }
        }
    }

    /// Requests the next run (no-op error on the simulator / when background tasks are off).
    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: delay)
        try? BGTaskScheduler.shared.submit(request)
    }

    @MainActor
    private static func handle(_ box: BackgroundTaskBox) {
        guard let coordinator = LearningCoordinator.current, coordinator.settings.enabled else {
            box.task.setTaskCompleted(success: true)
            return
        }
        let work = Task { @MainActor in
            let success = await coordinator.runBackgroundWork()
            coordinator.refreshSummary()
            if coordinator.pendingCount > 0 { LearningBackgroundTasks.schedule() }
            box.task.setTaskCompleted(success: success)
        }
        box.task.expirationHandler = {
            work.cancel()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    LearningCoordinator.current?.uploader.cancel()
                }
            }
        }
    }
}

/// Hands a `BGTask` from the scheduler's queue to the main actor.
private struct BackgroundTaskBox: @unchecked Sendable {
    let task: BGTask
}
