import Foundation
import Observation

/// Uploads collected samples to the RoadVis Trainer (`POST /api/v1/samples`, `docs/TRAINING_API.md` §2–3).
///
/// Rules: only with learning on and a device token; only on an allowed network (default Wi-Fi only:
/// `LearningNetworkMonitor`); never while the camera screen is active (`isCameraActive`); at most
/// `LearningUploadSchedule.batchSize` samples per run; after a failed run exponential back-off 1, 2, 4 … 60 min.
/// 201 / 409 delete the sample at once; 413 / 422 (the server will never take it) delete it too and count as
/// rejected; 401, 429, 5xx and network errors stop the run and keep the sample.
@Observable
@MainActor
final class LearningUploader {
    enum Trigger {
        /// App became active, navigator shown, follow-up run, background task: respects the back-off.
        case automatic
        /// «Upload now» button: ignores the back-off (still needs network, token and no camera screen).
        case manual
    }

    private(set) var isUploading = false
    private(set) var lastUploadAt: Date?
    /// Error of the last run (nil after a run without error).
    private(set) var lastError: String?
    /// Samples accepted by the server (201 / 409) since the feature was first used.
    private(set) var uploadedTotal: Int
    /// Samples the server refused for good (413 / 422).
    private(set) var rejectedTotal: Int

    /// True while the camera screen is visible (set by `LearningCoordinator`).
    @ObservationIgnored var isCameraActive: () -> Bool = { false }
    /// Called after every run that changed the local store.
    @ObservationIgnored var onStoreChanged: (() -> Void)?

    @ObservationIgnored private let settings: LearningSettings
    @ObservationIgnored private let store: LearningStore
    @ObservationIgnored private let network: LearningNetworkMonitor
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var schedule: LearningUploadSchedule
    @ObservationIgnored private var runTask: Task<Bool, Never>?
    @ObservationIgnored private var followUpTask: Task<Void, Never>?

    /// Pause before the next batch when a full batch went through and more samples wait.
    static let followUpDelay: Duration = .seconds(30)

    init(settings: LearningSettings, store: LearningStore = .shared, network: LearningNetworkMonitor = .shared,
         defaults: UserDefaults = .standard) {
        self.settings = settings
        self.store = store
        self.network = network
        self.defaults = defaults
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        configuration.httpAdditionalHeaders = ["User-Agent": LearningSettings.userAgent]
        session = URLSession(configuration: configuration)
        uploadedTotal = defaults.integer(forKey: Keys.uploadedTotal)
        rejectedTotal = defaults.integer(forKey: Keys.rejectedTotal)
        lastUploadAt = defaults.object(forKey: Keys.lastUploadAt) as? Date
        lastError = defaults.string(forKey: Keys.lastError)
        let failures = defaults.integer(forKey: Keys.failures)
        schedule = LearningUploadSchedule(failures: failures, nextAllowed: defaults.object(forKey: Keys.nextAllowed) as? Date)
    }

    /// Why a run cannot start now (nil = it can).
    func blockingReason(trigger: Trigger) -> String? {
        guard settings.enabled else { return L("learning.error.disabled") }
        guard settings.baseURL != nil else { return L("learning.error.badURL") }
        guard LearningKeychain.hasToken else { return L("learning.error.noToken") }
        guard network.allowsTransfer(wifiOnly: settings.wifiOnly) else {
            return settings.wifiOnly ? L("learning.error.noWiFi") : L("learning.error.offline")
        }
        guard !isCameraActive() else { return L("learning.error.camera") }
        if trigger == .automatic, !schedule.mayRun(now: Date()) { return L("learning.error.backoff") }
        return nil
    }

    /// Starts a run when allowed (no-op while one is running). Manual runs report a blocking reason as `lastError`.
    func runIfAllowed(trigger: Trigger) {
        guard runTask == nil else { return }
        if let reason = blockingReason(trigger: trigger) {
            if trigger == .manual { setError(reason) }
            return
        }
        guard !store.samples().isEmpty else {
            if trigger == .manual { setError(nil) }
            return
        }
        runTask = Task { [weak self] in
            guard let self else { return false }
            return await self.performRun()
        }
    }

    /// Runs one batch now and waits for it (background processing task). Returns false when it failed.
    func runForBackgroundTask() async -> Bool {
        if let running = runTask { return await running.value }
        guard blockingReason(trigger: .automatic) == nil else { return true }
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            return await self.performRun()
        }
        runTask = task
        return await task.value
    }

    /// Stops the current run (camera screen opened, background time expired).
    func cancel() {
        runTask?.cancel()
        followUpTask?.cancel()
        followUpTask = nil
    }

    // MARK: - Run

    private func performRun() async -> Bool {
        isUploading = true
        defer {
            isUploading = false
            runTask = nil
        }
        guard let base = settings.baseURL, let token = LearningKeychain.token() else { return false }
        let batch = Array(store.samples().prefix(LearningUploadSchedule.batchSize))
        let endpoint = base.appendingPathComponent("api/v1/samples")
        var failure: String?
        var processed = 0
        for sample in batch {
            if Task.isCancelled || isCameraActive() { break }
            guard network.allowsTransfer(wifiOnly: settings.wifiOnly) else {
                failure = settings.wifiOnly ? L("learning.error.noWiFi") : L("learning.error.offline")
                break
            }
            let outcome: LearningUploadOutcome
            let statusCode: Int
            do {
                let result = try await upload(sample, to: endpoint, token: token)
                statusCode = result
                outcome = LearningUploadOutcome(statusCode: result)
            } catch {
                if Task.isCancelled { break }
                failure = error.localizedDescription
                break
            }
            processed += 1
            switch outcome {
            case .uploaded:
                store.delete(id: sample.id)
                uploadedTotal += 1
                defaults.set(uploadedTotal, forKey: Keys.uploadedTotal)
            case .rejected:
                store.delete(id: sample.id)
                rejectedTotal += 1
                defaults.set(rejectedTotal, forKey: Keys.rejectedTotal)
            case .unauthorized:
                failure = L("learning.error.unauthorized")
            case .retryLater:
                failure = statusCode == 429 ? L("learning.error.rateLimit") : L("learning.error.http", statusCode)
            }
            if outcome.stopsRun { break }
        }
        if processed > 0 { onStoreChanged?() }
        let now = Date()
        if let failure {
            schedule.recordFailure(now: now)
            setError(failure)
        } else {
            schedule.recordSuccess()
            if processed > 0 {
                lastUploadAt = now
                defaults.set(now, forKey: Keys.lastUploadAt)
            }
            setError(nil)
        }
        defaults.set(schedule.failures, forKey: Keys.failures)
        defaults.set(schedule.nextAllowed, forKey: Keys.nextAllowed)
        // A full batch went through and more samples wait: another run after a short pause.
        if failure == nil, processed == batch.count, batch.count == LearningUploadSchedule.batchSize,
           !store.samples().isEmpty {
            followUpTask?.cancel()
            followUpTask = Task { [weak self] in
                try? await Task.sleep(for: Self.followUpDelay)
                guard !Task.isCancelled, let self else { return }
                self.followUpTask = nil
                self.runIfAllowed(trigger: .automatic)
            }
        }
        return failure == nil
    }

    /// One multipart request; returns the HTTP status code.
    private func upload(_ sample: LearningStore.Sample, to endpoint: URL, token: String) async throws -> Int {
        let image = try Data(contentsOf: sample.imageURL)
        let meta = try Data(contentsOf: sample.metaURL)
        let boundary = "RoadVis-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(LearningSettings.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body = Self.multipartBody(boundary: boundary, sampleID: sample.id, image: image, meta: meta)
        let (_, response) = try await session.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return http.statusCode
    }

    /// `image` (image/jpeg, filename `<id>.jpg`) and `meta` (application/json form field) parts.
    nonisolated static func multipartBody(boundary: String, sampleID: String, image: Data, meta: Data) -> Data {
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"image\"; filename=\"\(sampleID).jpg\"\r\n")
        append("Content-Type: image/jpeg\r\n\r\n")
        body.append(image)
        append("\r\n--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"meta\"\r\n")
        append("Content-Type: application/json\r\n\r\n")
        body.append(meta)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    private func setError(_ message: String?) {
        if lastError != message { lastError = message }
        defaults.set(message, forKey: Keys.lastError)
    }

    private enum Keys {
        static let uploadedTotal = "rv.learning.uploadedTotal"
        static let rejectedTotal = "rv.learning.rejectedTotal"
        static let lastUploadAt = "rv.learning.lastUploadAt"
        static let lastError = "rv.learning.lastUploadError"
        static let failures = "rv.learning.uploadFailures"
        static let nextAllowed = "rv.learning.uploadNextAllowed"
    }
}
