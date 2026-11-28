import Foundation
import Network
import Observation
import Security

/// Settings of the continuous-learning feature ("Обучение модели"), persisted in UserDefaults. Everything is off
/// by default; the device token lives in the Keychain (`LearningKeychain`), never in UserDefaults.
@Observable
final class LearningSettings {
    @ObservationIgnored private let defaults: UserDefaults

    static let defaultServerURL = "https://trafficcounter.uz/roadvis"

    /// Master switch: collect hard frames, upload them, download improved models.
    var enabled: Bool { didSet { defaults.set(enabled, forKey: Keys.enabled) } }
    /// RoadVis Trainer base URL.
    var serverURL: String { didSet { defaults.set(serverURL, forKey: Keys.serverURL) } }
    /// Upload / download only on Wi-Fi (not expensive, not constrained).
    var wifiOnly: Bool { didSet { defaults.set(wifiOnly, forKey: Keys.wifiOnly) } }
    /// Put `lat` / `lon` into the sample metadata.
    var sendLocation: Bool { didSet { defaults.set(sendLocation, forKey: Keys.sendLocation) } }
    /// Local storage cap, MB (one of `LearningStorePolicy.limitChoicesMB`).
    var storageLimitMB: Int { didSet { defaults.set(storageLimitMB, forKey: Keys.storageLimitMB) } }
    /// Check daily for an improved model and switch to it.
    var downloadModels: Bool { didSet { defaults.set(downloadModels, forKey: Keys.downloadModels) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: Keys.enabled) == nil ? false : defaults.bool(forKey: Keys.enabled)
        serverURL = defaults.string(forKey: Keys.serverURL) ?? Self.defaultServerURL
        wifiOnly = defaults.object(forKey: Keys.wifiOnly) == nil ? true : defaults.bool(forKey: Keys.wifiOnly)
        sendLocation = defaults.object(forKey: Keys.sendLocation) == nil ? false : defaults.bool(forKey: Keys.sendLocation)
        storageLimitMB = LearningStorePolicy.normalizedLimitMB(
            defaults.object(forKey: Keys.storageLimitMB) == nil ? LearningStorePolicy.defaultLimitMB
                : defaults.integer(forKey: Keys.storageLimitMB))
        downloadModels = defaults.object(forKey: Keys.downloadModels) == nil ? true : defaults.bool(forKey: Keys.downloadModels)
    }

    /// Validated base URL (http/https with a host), nil when the setting is not a usable URL.
    var baseURL: URL? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// `User-Agent` of every Trainer request: "RoadVis-iOS/<version>".
    static var userAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return "RoadVis-iOS/\(version)"
    }

    private enum Keys {
        static let enabled = "rv.learning.enabled"
        static let serverURL = "rv.learning.serverURL"
        static let wifiOnly = "rv.learning.wifiOnly"
        static let sendLocation = "rv.learning.sendLocation"
        static let storageLimitMB = "rv.learning.storageLimitMB"
        static let downloadModels = "rv.learning.downloadModels"
    }
}

/// Device token of the RoadVis Trainer in the Keychain (generic password, this device only, readable after the
/// first unlock so background uploads work).
enum LearningKeychain {
    private static let service = "uz.roadvis.learning"
    private static let account = "deviceToken"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// The stored token (nil when none).
    static func token() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status: OSStatus = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static var hasToken: Bool { token() != nil }

    /// Stores (or with an empty / nil value deletes) the token. Returns false on a Keychain error.
    @discardableResult
    static func setToken(_ token: String?) -> Bool {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let deleteStatus: OSStatus = SecItemDelete(baseQuery as CFDictionary)
        guard !trimmed.isEmpty else {
            return deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound
        }
        var item = baseQuery
        item[kSecValueData as String] = Data(trimmed.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status: OSStatus = SecItemAdd(item as CFDictionary, nil)
        return status == errSecSuccess
    }
}

/// Current network path (`NWPathMonitor`), readable from any thread.
final class LearningNetworkMonitor: @unchecked Sendable {
    static let shared = LearningNetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "learning.network", qos: .utility)
    private let lock = NSLock()
    private var satisfied = false
    private var unmetered = false
    private var started = false
    private var handlers: [UUID: @Sendable () -> Void] = [:]

    /// Registers a handler called (on the monitor's queue) whenever the path changes: connected / disconnected or
    /// Wi-Fi ↔ cellular. Used to retry pending work when the network returns (driver cabinet).
    @discardableResult
    func addChangeHandler(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        handlers[id] = handler
        lock.unlock()
        return id
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(path)
        }
        monitor.start(queue: queue)
    }

    private func update(_ path: NWPath) {
        let isSatisfied = path.status == .satisfied
        // Wi-Fi (or Ethernet) that is neither expensive (cellular, personal hotspot) nor constrained (Low Data Mode).
        let isUnmetered = isSatisfied && !path.isExpensive && !path.isConstrained
        lock.lock()
        let changed = satisfied != isSatisfied || unmetered != isUnmetered
        satisfied = isSatisfied
        unmetered = isUnmetered
        let callbacks: [@Sendable () -> Void] = changed ? Array(handlers.values) : []
        lock.unlock()
        for callback in callbacks { callback() }
    }

    /// Any network.
    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return satisfied
    }

    /// Wi-Fi-like network: not expensive and not constrained.
    var isWiFi: Bool {
        lock.lock()
        defer { lock.unlock() }
        return unmetered
    }

    /// Transfers are allowed under the "Wi-Fi only" setting.
    func allowsTransfer(wifiOnly: Bool) -> Bool {
        wifiOnly ? isWiFi : isConnected
    }
}
