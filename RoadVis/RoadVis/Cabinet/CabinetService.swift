import Foundation
import Observation
import UIKit

/// Driver cabinet (`docs/CABINET_API.md` §1, §2, §4): registers the phone as a driver profile, uploads every finished
/// trip, keeps the points / level of the profile and approves QR logins on the website.
///
/// Shared with continuous learning: the server URL is `LearningSettings.serverURL` and the device token is the one
/// in `LearningKeychain` (a token from the registration is also used for `/api/v1/samples`; a manually entered
/// training token works for the cabinet too — the server creates its driver profile lazily).
///
/// Trip upload: `TripRecorder.onFinished` → `tripFinished(_:)` puts the trip id into a small pending queue
/// (UserDefaults) and uploads it at once; the queue is retried when the app becomes active, when the network comes
/// back and after a failed run with exponential back-off (1, 2, 4 … 60 min, `LearningUploadSchedule`). Trips under
/// 300 m or 60 s are never queued. «Only on Wi-Fi» (default off — trips are small) limits trip uploads only;
/// registration, profile, QR approval and deletion are explicit actions and use any network.
///
/// "Log out everywhere" has no device-token endpoint in the contract: it is done on the website (Profile).
@Observable
@MainActor
final class CabinetService {
    /// The service of the running app (network-change callbacks).
    static weak var current: CabinetService?

    enum SyncTrigger {
        /// App became active, network returned, back-off expired: respects the back-off.
        case automatic
        /// A trip was just saved, the cabinet was switched on, «Sync now»: ignores the back-off.
        case immediate
    }

    /// Result of a QR login attempt (shown by `QRLoginFlowView`).
    enum QRLoginResult: Equatable {
        case approved
        /// 404: the QR expired (the page shows a new one).
        case expired
        /// 409: this QR was already used.
        case alreadyUsed
        /// The QR belongs to another site than the configured server.
        case foreignSite
        /// Not a RoadVis login QR at all.
        case notRoadVis
        /// 401: the server does not accept the device token.
        case unauthorized
        /// The cabinet is off / the phone is not registered.
        case notRegistered
        case network
        case server(Int)
    }

    // MARK: Settings (UserDefaults)

    /// «Кабинет водителя» switch (off by default). Change it with `setEnabled(_:)`.
    private(set) var enabled: Bool
    /// Upload trips only on Wi-Fi (default off: trips are small).
    var wifiOnly: Bool { didSet { defaults.set(wifiOnly, forKey: Keys.wifiOnly) } }
    /// Driver name of the profile (default: the device name). Change it with `rename(_:)`.
    private(set) var driverName: String

    // MARK: Status

    /// A device token is stored in the Keychain.
    private(set) var hasToken: Bool
    private(set) var driverId: String?
    private(set) var points: Int?
    private(set) var level: Int?
    /// Trips the server holds for this driver (`GET /api/v1/me`).
    private(set) var serverTripCount: Int?
    /// Trips this phone uploaded.
    private(set) var syncedTripCount: Int
    /// Last successful exchange with the server.
    private(set) var lastSyncAt: Date?
    /// Ids (lowercase UUID) of finished trips waiting for upload, oldest first.
    private(set) var pendingTripIDs: [String]
    private(set) var isRegistering = false
    private(set) var isSyncing = false
    private(set) var isDeleting = false
    /// Error of the last action (nil after a successful one).
    private(set) var lastError: String?
    /// The last error was a 401: the token is not accepted (deleted on the website, or another server).
    private(set) var tokenRejected = false

    var pendingCount: Int { pendingTripIDs.count }
    var isRegistered: Bool { hasToken }
    var isBusy: Bool { isRegistering || isSyncing || isDeleting }

    /// `<server>/` — the web dashboard.
    var dashboardURL: URL? {
        guard let base = learningSettings.baseURL else { return nil }
        let text = base.absoluteString
        return text.hasSuffix("/") ? base : URL(string: text + "/")
    }

    /// "trafficcounter.uz/roadvis".
    var serverDisplayName: String {
        guard let base = learningSettings.baseURL, let host = base.host else { return learningSettings.serverURL }
        let path = base.path == "/" ? "" : base.path
        return host + path
    }

    /// At most this many trips wait in the queue (the oldest are dropped).
    static let maxPendingTrips = 200

    @ObservationIgnored private let learningSettings: LearningSettings
    @ObservationIgnored private let trips: TripStore
    @ObservationIgnored private let network: LearningNetworkMonitor
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var schedule: LearningUploadSchedule
    @ObservationIgnored private var pendingRename: Bool
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    init(learningSettings: LearningSettings, trips: TripStore, network: LearningNetworkMonitor = .shared,
         defaults: UserDefaults = .standard) {
        self.learningSettings = learningSettings
        self.trips = trips
        self.network = network
        self.defaults = defaults
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpAdditionalHeaders = ["User-Agent": LearningSettings.userAgent]
        session = URLSession(configuration: configuration)

        enabled = defaults.bool(forKey: Keys.enabled)
        wifiOnly = defaults.bool(forKey: Keys.wifiOnly)
        let storedName = defaults.string(forKey: Keys.driverName)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        driverName = storedName.isEmpty ? UIDevice.current.name : storedName
        hasToken = LearningKeychain.hasToken
        driverId = defaults.string(forKey: Keys.driverId)
        points = defaults.object(forKey: Keys.points) as? Int
        level = defaults.object(forKey: Keys.level) as? Int
        serverTripCount = defaults.object(forKey: Keys.serverTripCount) as? Int
        syncedTripCount = defaults.integer(forKey: Keys.syncedTripCount)
        lastSyncAt = defaults.object(forKey: Keys.lastSyncAt) as? Date
        pendingTripIDs = defaults.stringArray(forKey: Keys.pending) ?? []
        pendingRename = defaults.bool(forKey: Keys.pendingRename)
        lastError = defaults.string(forKey: Keys.lastError)
        schedule = LearningUploadSchedule(failures: defaults.integer(forKey: Keys.failures),
                                          nextAllowed: defaults.object(forKey: Keys.nextAllowed) as? Date)
        Self.current = self
    }

    /// Called once from `AppState.start()`.
    func start() {
        guard !started else { return }
        started = true
        network.start()
        network.addChangeHandler {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    CabinetService.current?.networkChanged()
                }
            }
        }
        refreshTokenState()
        sync(trigger: .automatic)
    }

    // MARK: - Lifecycle hooks

    /// App became active (foreground): retry pending work.
    func appBecameActive() {
        refreshTokenState()
        sync(trigger: .automatic)
    }

    /// A trip was finalised and saved (`TripRecorder.onFinished`): queue it and upload it now.
    func tripFinished(_ trip: Trip) {
        guard enabled else { return }
        let stats = TripStats.compute(trip)
        guard CabinetTripPayload.isUploadable(distanceMeters: stats.distanceMeters,
                                              durationSeconds: stats.duration) else { return }
        let id = trip.id.uuidString.lowercased()
        if !pendingTripIDs.contains(id) {
            pendingTripIDs.append(id)
            if pendingTripIDs.count > Self.maxPendingTrips {
                pendingTripIDs.removeFirst(pendingTripIDs.count - Self.maxPendingTrips)
            }
            savePending()
        }
        sync(trigger: .immediate)
    }

    private func networkChanged() {
        guard enabled, network.isConnected else { return }
        sync(trigger: .automatic)
    }

    // MARK: - Settings actions

    /// «Кабинет водителя» switch. Switching on registers the phone when no token exists, then syncs.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        defaults.set(on, forKey: Keys.enabled)
        if on {
            schedule.recordSuccess()
            saveSchedule()
            sync(trigger: .immediate)
        } else {
            runTask?.cancel()
            retryTask?.cancel()
            retryTask = nil
        }
    }

    /// «Sync now» (also refreshes points / level).
    func syncNow() {
        guard enabled else { return }
        if !network.isConnected {
            setError(L("cabinet.error.offline"))
            return
        }
        sync(trigger: .immediate)
    }

    /// Re-reads the token (it may have been entered / removed in the learning section).
    func refreshTokenState() {
        let present = LearningKeychain.hasToken
        if hasToken != present { hasToken = present }
    }

    /// Settings appeared: refresh points / level when nothing else runs.
    func refreshStatus() {
        refreshTokenState()
        guard enabled, hasToken, runTask == nil, network.isConnected else { return }
        runTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.refreshMe()
            self.runTask = nil
        }
    }

    /// New driver name: stored locally at once and sent to the server (`PATCH /api/v1/me`), retried with the next
    /// sync when that fails.
    func rename(_ name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !trimmed.isEmpty, trimmed != driverName else { return }
        driverName = trimmed
        defaults.set(trimmed, forKey: Keys.driverName)
        pendingRename = true
        defaults.set(true, forKey: Keys.pendingRename)
        guard enabled, hasToken else { return }
        sync(trigger: .immediate)
    }

    /// The server refused the token (401): forget it and register this phone again (a new, empty profile).
    func registerAgain() {
        guard enabled, !isBusy else { return }
        LearningKeychain.setToken(nil)
        hasToken = false
        tokenRejected = false
        clearProfile()
        sync(trigger: .immediate)
    }

    /// `DELETE /api/v1/me`: deletes the profile, trips, web sessions and the token on the server; then forgets the
    /// token, the queue and the status here and switches the cabinet off. Returns false (with `lastError`) on failure.
    func deleteMyData() async -> Bool {
        guard hasToken else {
            finishDeletion()
            return true
        }
        guard !isDeleting else { return false }
        isDeleting = true
        defer { isDeleting = false }
        runTask?.cancel()
        do {
            let (status, _) = try await send("DELETE", CabinetAPI.mePath, body: nil)
            switch status {
            case 200, 202, 204, 404:
                finishDeletion()
                return true
            case 401, 403:
                tokenRejected = true
                setError(L("cabinet.error.unauthorized"))
            default:
                setError(httpError(status))
            }
        } catch {
            setError(L("cabinet.error.network"))
        }
        return false
    }

    // MARK: - QR login (§4)

    /// Checks a scanned QR against the configured server URL.
    func parseLogin(_ text: String) -> Result<QRLoginPayload, QRLoginPayload.ParseError> {
        QRLoginPayload.parse(text, configuredBase: learningSettings.serverURL)
    }

    /// Maps a QR parse error to the result shown to the driver.
    func result(for error: QRLoginPayload.ParseError) -> QRLoginResult {
        switch error {
        case .foreignSite, .insecure: return .foreignSite
        case .notALink, .missingParameters, .badConfiguredBase: return .notRoadVis
        }
    }

    /// `POST /api/v1/auth/qr/approve` with the device token.
    func approveLogin(_ payload: QRLoginPayload) async -> QRLoginResult {
        refreshTokenState()
        guard enabled, hasToken else { return .notRegistered }
        do {
            let body = try JSONEncoder().encode(QRApproveRequest(challengeId: payload.challengeId, nonce: payload.nonce))
            let (status, _) = try await send("POST", CabinetAPI.qrApprovePath, body: body)
            switch QRApproveOutcome(statusCode: status) {
            case .approved:
                markSynced()
                return .approved
            case .expired: return .expired
            case .alreadyUsed: return .alreadyUsed
            case .unauthorized:
                tokenRejected = true
                return .unauthorized
            case .serverError(let code): return .server(code)
            }
        } catch {
            return .network
        }
    }

    // MARK: - Sync

    private func sync(trigger: SyncTrigger) {
        guard enabled, runTask == nil, !isDeleting else { return }
        guard learningSettings.baseURL != nil else {
            setError(L("cabinet.error.badURL"))
            return
        }
        guard network.isConnected else { return }
        if trigger == .automatic, !schedule.mayRun(now: Date()) {
            scheduleRetry()
            return
        }
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.performSync()
            self.runTask = nil
        }
    }

    private func performSync() async {
        isSyncing = true
        defer { isSyncing = false }
        var failure: String?
        if !hasToken {
            failure = await register()
        }
        if failure == nil, pendingRename {
            failure = await pushRename()
        }
        var waitingForStore = false
        if failure == nil, !pendingTripIDs.isEmpty, network.allowsTransfer(wifiOnly: wifiOnly) {
            let outcome = await uploadPending()
            failure = outcome.failure
            waitingForStore = outcome.waitingForStore
        }
        if failure == nil {
            failure = await refreshMe()
        }
        if Task.isCancelled { return }
        if let failure {
            schedule.recordFailure(now: Date())
            setError(failure)
        } else {
            schedule.recordSuccess()
            setError(nil)
        }
        saveSchedule()
        if failure != nil {
            scheduleRetry()
        } else if waitingForStore {
            // The trip history was still loading: try again shortly.
            scheduleRetry(after: 3)
        }
    }

    /// `POST /api/v1/devices/register`; stores the token. Returns an error text or nil.
    private func register() async -> String? {
        guard !isRegistering else { return L("cabinet.status.registering") }
        isRegistering = true
        defer { isRegistering = false }
        let request = CabinetRegisterRequest(platform: CabinetAPI.platformIOS, appVersion: Self.appVersion,
                                             deviceName: UIDevice.current.name, driverName: driverName,
                                             language: LocalizationManager.shared.language.rawValue)
        do {
            let body = try JSONEncoder().encode(request)
            let (status, data) = try await send("POST", CabinetAPI.registerPath, body: body, authorized: false)
            guard status == 200 || status == 201 else {
                return status == 429 ? L("cabinet.error.rateLimit") : httpError(status)
            }
            let response = try JSONDecoder().decode(CabinetRegisterResponse.self, from: data)
            guard LearningKeychain.setToken(response.deviceToken) else { return L("cabinet.error.keychain") }
            hasToken = true
            tokenRejected = false
            driverId = response.driverId
            defaults.set(response.driverId, forKey: Keys.driverId)
            // The registration carried the current name.
            pendingRename = false
            defaults.set(false, forKey: Keys.pendingRename)
            let name = response.driverName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, name != driverName {
                driverName = name
                defaults.set(name, forKey: Keys.driverName)
            }
            markSynced()
            return nil
        } catch is DecodingError {
            return L("cabinet.error.badResponse")
        } catch {
            return L("cabinet.error.network")
        }
    }

    /// `PATCH /api/v1/me`. Returns an error text or nil.
    private func pushRename() async -> String? {
        do {
            let body = try JSONEncoder().encode(CabinetRenameRequest(driverName: driverName))
            let (status, data) = try await send("PATCH", CabinetAPI.mePath, body: body)
            switch status {
            case 200, 204:
                pendingRename = false
                defaults.set(false, forKey: Keys.pendingRename)
                if let me = try? JSONDecoder().decode(CabinetMe.self, from: data) { apply(me) }
                return nil
            case 401, 403:
                tokenRejected = true
                return L("cabinet.error.unauthorized")
            case 422:
                // The server refuses this name for good: keep it locally, stop retrying.
                pendingRename = false
                defaults.set(false, forKey: Keys.pendingRename)
                return L("cabinet.error.badName")
            default:
                return httpError(status)
            }
        } catch {
            return L("cabinet.error.network")
        }
    }

    /// `GET /api/v1/me`: points, level, trip count. Returns an error text or nil.
    private func refreshMe() async -> String? {
        do {
            let (status, data) = try await send("GET", CabinetAPI.mePath, body: nil)
            switch status {
            case 200:
                let me = try JSONDecoder().decode(CabinetMe.self, from: data)
                apply(me)
                markSynced()
                return nil
            case 401, 403:
                tokenRejected = true
                return L("cabinet.error.unauthorized")
            default:
                return httpError(status)
            }
        } catch is DecodingError {
            return L("cabinet.error.badResponse")
        } catch {
            return L("cabinet.error.network")
        }
    }

    /// Uploads the queue in order; stops at the first error that needs a retry.
    private func uploadPending() async -> (failure: String?, waitingForStore: Bool) {
        let version = Self.appVersion
        var waitingForStore = false
        for id in pendingTripIDs {
            if Task.isCancelled { return (nil, waitingForStore) }
            guard enabled, network.allowsTransfer(wifiOnly: wifiOnly) else { break }
            guard let uuid = UUID(uuidString: id) else {
                removePending(id)
                continue
            }
            guard let trip = trips.trip(id: uuid) else {
                // Deleted from the history → nothing to upload; history not loaded yet → later.
                if trips.isLoaded { removePending(id) } else { waitingForStore = true }
                continue
            }
            let body: Data? = await Task.detached(priority: .utility) { () -> Data? in
                guard let payload = CabinetTripPayload.make(trip: trip, appVersion: version) else { return nil }
                return try? payload.encoded()
            }.value
            guard let body else {
                // Too short (or not encodable): never uploaded.
                removePending(id)
                continue
            }
            let status: Int
            do {
                status = try await send("POST", CabinetAPI.tripsPath, body: body).status
            } catch {
                if Task.isCancelled { return (nil, waitingForStore) }
                return (L("cabinet.error.network"), waitingForStore)
            }
            switch CabinetTripUploadOutcome(statusCode: status) {
            case .uploaded:
                removePending(id)
                syncedTripCount += 1
                defaults.set(syncedTripCount, forKey: Keys.syncedTripCount)
                markSynced()
            case .rejected:
                removePending(id)
            case .unauthorized:
                tokenRejected = true
                return (L("cabinet.error.unauthorized"), waitingForStore)
            case .retryLater:
                return (status == 429 ? L("cabinet.error.rateLimit") : httpError(status), waitingForStore)
            }
        }
        return (nil, waitingForStore)
    }

    // MARK: - HTTP

    private enum RequestError: Error {
        case noServer
        case noToken
        case badResponse
    }

    /// One JSON request to `<server>/<path>`; returns the status code and the body.
    private func send(_ method: String, _ path: String, body: Data?,
                      authorized: Bool = true) async throws -> (status: Int, data: Data) {
        guard let base = learningSettings.baseURL else { throw RequestError.noServer }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue(LearningSettings.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authorized {
            guard let token = LearningKeychain.token() else { throw RequestError.noToken }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RequestError.badResponse }
        return (http.statusCode, data)
    }

    // MARK: - Private

    private func scheduleRetry(after seconds: TimeInterval? = nil) {
        retryTask?.cancel()
        let delay: TimeInterval
        if let seconds {
            delay = seconds
        } else if let next = schedule.nextAllowed {
            delay = max(1, next.timeIntervalSinceNow)
        } else {
            retryTask = nil
            return
        }
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            self.sync(trigger: .automatic)
        }
    }

    private func apply(_ me: CabinetMe) {
        driverId = me.driverId
        points = me.points
        level = me.level
        serverTripCount = me.tripCount
        defaults.set(me.driverId, forKey: Keys.driverId)
        defaults.set(me.points, forKey: Keys.points)
        defaults.set(me.level, forKey: Keys.level)
        defaults.set(me.tripCount, forKey: Keys.serverTripCount)
        let name = me.driverName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pendingRename, !name.isEmpty, name != driverName {
            driverName = name
            defaults.set(name, forKey: Keys.driverName)
        }
    }

    private func markSynced() {
        let now = Date()
        lastSyncAt = now
        defaults.set(now, forKey: Keys.lastSyncAt)
    }

    private func removePending(_ id: String) {
        pendingTripIDs.removeAll { $0 == id }
        savePending()
    }

    private func savePending() {
        defaults.set(pendingTripIDs, forKey: Keys.pending)
    }

    private func saveSchedule() {
        defaults.set(schedule.failures, forKey: Keys.failures)
        defaults.set(schedule.nextAllowed, forKey: Keys.nextAllowed)
    }

    private func clearProfile() {
        driverId = nil
        points = nil
        level = nil
        serverTripCount = nil
        for key in [Keys.driverId, Keys.points, Keys.level, Keys.serverTripCount] {
            defaults.removeObject(forKey: key)
        }
    }

    private func finishDeletion() {
        runTask?.cancel()
        runTask = nil
        retryTask?.cancel()
        retryTask = nil
        LearningKeychain.setToken(nil)
        hasToken = false
        tokenRejected = false
        clearProfile()
        pendingTripIDs = []
        savePending()
        syncedTripCount = 0
        defaults.set(0, forKey: Keys.syncedTripCount)
        lastSyncAt = nil
        defaults.removeObject(forKey: Keys.lastSyncAt)
        schedule.recordSuccess()
        saveSchedule()
        setError(nil)
        enabled = false
        defaults.set(false, forKey: Keys.enabled)
    }

    private func setError(_ message: String?) {
        if lastError != message { lastError = message }
        defaults.set(message, forKey: Keys.lastError)
    }

    private func httpError(_ status: Int) -> String {
        L("cabinet.error.http", status)
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private enum Keys {
        static let enabled = "rv.cabinet.enabled"
        static let wifiOnly = "rv.cabinet.wifiOnly"
        static let driverName = "rv.cabinet.driverName"
        static let driverId = "rv.cabinet.driverId"
        static let points = "rv.cabinet.points"
        static let level = "rv.cabinet.level"
        static let serverTripCount = "rv.cabinet.serverTripCount"
        static let syncedTripCount = "rv.cabinet.syncedTripCount"
        static let lastSyncAt = "rv.cabinet.lastSyncAt"
        static let pending = "rv.cabinet.pendingTrips"
        static let pendingRename = "rv.cabinet.pendingRename"
        static let lastError = "rv.cabinet.lastError"
        static let failures = "rv.cabinet.failures"
        static let nextAllowed = "rv.cabinet.nextAllowed"
    }
}
