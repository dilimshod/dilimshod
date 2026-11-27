import CoreML
import CryptoKit
import Foundation
import Observation

/// Downloads improved detector models from the RoadVis Trainer ("App model update rules" in
/// `docs/TRAINING_API.md`).
///
/// - At most one manifest check per day on Wi-Fi while learning and "download improved models" are on
///   (`ModelUpdatePolicy.shouldCheck`), plus the «Check for model update» button.
/// - Every file of both iOS packages is downloaded into a temporary folder, its size and SHA-256 (CryptoKit) are
///   verified, the `.mlpackage` directories are rebuilt from the relative paths and compiled with
///   `MLModel.compileModel(at:)`, and each compiled model is loaded once as a check. Only then the version folder
///   `Application Support/RoadVisModels/<version>/` is moved into place (one rename) and the detector is switched.
/// - The bundled models stay the permanent fallback: when the downloaded model fails to load or produces no output
///   for 30 s of driving (`RecognitionWorker` → `ModelHealthMonitor`), `revert(version:reason:)` switches back and
///   remembers the version as bad (never downloaded again).
@Observable
@MainActor
final class ModelUpdateService {
    /// What is stored next to a compiled version (`info.json`) and shown in Settings.
    struct InstalledModel: Codable, Equatable, Sendable {
        var version: String
        var createdAt: String?
        var map50: Double?
        var landscapeName: String
        var portraitName: String
        var installedAt: Date
    }

    enum UpdateError: LocalizedError {
        case notConfigured
        case server(Int)
        case invalidManifest
        case checksum(String)
        case size(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return L("learning.error.noToken")
            case .server(let code): return L("learning.error.http", code)
            case .invalidManifest: return L("learning.error.manifest")
            case .checksum(let path): return L("learning.error.checksum", path)
            case .size(let path): return L("learning.error.checksum", path)
            }
        }
    }

    /// Active downloaded model (nil = the bundled one).
    private(set) var active: InstalledModel?
    private(set) var isChecking = false
    /// Result of the last check (localized), e.g. "up to date" or an error.
    private(set) var lastMessage: String?
    private(set) var lastCheck: Date?
    private(set) var badVersions: Set<String>

    /// Applies a model to the detector (nil = bundled). Set by `LearningCoordinator`.
    @ObservationIgnored var applyModel: ((DownloadedDetectorModel?) -> Void)?

    @ObservationIgnored private let settings: LearningSettings
    @ObservationIgnored private let network: LearningNetworkMonitor
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var checkTask: Task<Void, Never>?

    nonisolated static var modelsDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("RoadVisModels", isDirectory: true)
    }

    init(settings: LearningSettings, network: LearningNetworkMonitor = .shared, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.network = network
        self.defaults = defaults
        let bad = Set(defaults.stringArray(forKey: Keys.badVersions) ?? [])
        badVersions = bad
        lastCheck = defaults.object(forKey: Keys.lastCheck) as? Date
        let stored = defaults.string(forKey: Keys.activeVersion)
        var installed: InstalledModel?
        if let version = ModelUpdatePolicy.activeVersion(stored: stored, badVersions: bad,
                                                         isInstalled: { Self.loadInfo(version: $0) != nil }) {
            installed = Self.loadInfo(version: version)
        }
        if installed == nil, stored != nil {
            defaults.removeObject(forKey: Keys.activeVersion)
        }
        active = installed
        // Launch-time cleanup: only the active version stays on disk (also removes leftover staging folders).
        var keep = Set<String>()
        if let installed { keep.insert(installed.version) }
        Self.removeVersions(except: keep, includingStaging: true)
    }

    /// The detector model of the active version (nil = bundled).
    var activeDetectorModel: DownloadedDetectorModel? {
        guard let active else { return nil }
        return Self.detectorModel(for: active)
    }

    /// Pushes the active model to the detector (start-up, learning toggled).
    func applyActiveModel() {
        applyModel?(settings.enabled ? activeDetectorModel : nil)
    }

    // MARK: - Checking

    /// Daily automatic check (app active / navigator shown).
    func checkIfDue() {
        guard settings.enabled, settings.downloadModels,
              ModelUpdatePolicy.shouldCheck(enabled: true, onWiFi: network.isWiFi, lastCheck: lastCheck, now: Date())
        else { return }
        startCheck()
    }

    /// «Check for model update» button: no daily limit; needs an allowed network.
    func checkNow() {
        guard settings.enabled else {
            lastMessage = L("learning.error.disabled")
            return
        }
        guard network.allowsTransfer(wifiOnly: settings.wifiOnly) else {
            lastMessage = settings.wifiOnly ? L("learning.error.noWiFi") : L("learning.error.offline")
            return
        }
        startCheck()
    }

    private func startCheck() {
        guard checkTask == nil else { return }
        guard let base = settings.baseURL, let token = LearningKeychain.token() else {
            lastMessage = UpdateError.notConfigured.errorDescription
            return
        }
        isChecking = true
        lastMessage = L("learning.model.checking")
        let activeVersion = active?.version
        let bad = badVersions
        let installed = Set(Self.installedVersions())
        checkTask = Task { [weak self] in
            let result: Result<InstalledModel?, Error>
            do {
                let manifest = try await Self.fetchManifest(base: base, token: token)
                if let manifest, ModelUpdatePolicy.shouldDownload(manifest, activeVersion: activeVersion,
                                                                  badVersions: bad, installedVersions: installed) {
                    let installedModel = try await Self.install(manifest: manifest, base: base, token: token)
                    result = .success(installedModel)
                } else if let manifest, !manifest.isUsableForIOS {
                    result = .failure(UpdateError.invalidManifest)
                } else if let manifest, manifest.version != activeVersion, installed.contains(manifest.version),
                          !bad.contains(manifest.version), let info = Self.loadInfo(version: manifest.version) {
                    // Already on disk (e.g. after a revert of a newer one was undone): switch without downloading.
                    result = .success(info)
                } else {
                    result = .success(nil)
                }
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.finishCheck(result)
        }
    }

    private func finishCheck(_ result: Result<InstalledModel?, Error>) {
        checkTask = nil
        isChecking = false
        let now = Date()
        lastCheck = now
        defaults.set(now, forKey: Keys.lastCheck)
        switch result {
        case .success(let installed?):
            guard !badVersions.contains(installed.version) else { return }
            activate(installed)
            lastMessage = L("learning.model.updated", installed.version)
        case .success(nil):
            lastMessage = L("learning.model.upToDate")
        case .failure(let error):
            lastMessage = L("common.errorWith", error.localizedDescription)
        }
    }

    /// Atomic switch: the version folder is complete on disk; remember it and hand it to the detector.
    private func activate(_ installed: InstalledModel) {
        active = installed
        defaults.set(installed.version, forKey: Keys.activeVersion)
        applyActiveModel()
        // Older version folders are removed at the next launch (the detector may still use one until it switches).
    }

    // MARK: - Revert

    /// The downloaded `version` failed (load error / no output for 30 s): back to the bundled model, remembered as bad.
    func revert(version: String, reason: String) {
        badVersions.insert(version)
        defaults.set(Array(badVersions).sorted(), forKey: Keys.badVersions)
        guard active?.version == version else { return }
        active = nil
        defaults.removeObject(forKey: Keys.activeVersion)
        applyModel?(nil)
        lastMessage = L("learning.model.reverted", version, reason)
    }

    // MARK: - Network + files (off the main actor)

    private nonisolated static func makeRequest(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(LearningSettings.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60
        return request
    }

    /// `GET /api/v1/model/latest?platform=ios`: nil on 204 (no accepted model yet).
    private nonisolated static func fetchManifest(base: URL, token: String) async throws -> ModelManifest? {
        var components = URLComponents(url: base.appendingPathComponent("api/v1/model/latest"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "platform", value: "ios")]
        guard let url = components?.url else { throw UpdateError.invalidManifest }
        var urlRequest = makeRequest(url, token: token)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 204 { return nil }
        guard http.statusCode == 200 else { throw UpdateError.server(http.statusCode) }
        do {
            return try ModelManifest.decode(data)
        } catch {
            throw UpdateError.invalidManifest
        }
    }

    /// Downloads, verifies, compiles and test-loads both packages, then moves the version folder into place.
    private nonisolated static func install(manifest: ModelManifest, base: URL, token: String) async throws -> InstalledModel {
        guard manifest.isUsableForIOS, let landscape = manifest.ios?.landscape, let portrait = manifest.ios?.portrait else {
            throw UpdateError.invalidManifest
        }
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory.appendingPathComponent("RoadVisModelUpdate-\(UUID().uuidString)",
                                                                         isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }

        // Staging folder on the same volume as the final one, so the switch is a single rename.
        let root = modelsDirectory
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        var moved = false
        defer { if !moved { try? fileManager.removeItem(at: staging) } }

        var verified = 0
        var compiled = 0
        let expected = landscape.files.count + portrait.files.count
        for package in [landscape, portrait] {
            let packageURL = work.appendingPathComponent("\(package.name).mlpackage", isDirectory: true)
            for file in package.files {
                try Task.checkCancellation()
                let local = ModelUpdatePolicy.packageRelativePath(file.path, packageName: package.name)
                guard ModelUpdatePolicy.isSafeRelativePath(local),
                      let url = ModelUpdatePolicy.fileURL(
                          base: base, version: manifest.version,
                          path: ModelUpdatePolicy.iosFilePath(file.path, packageName: package.name)) else {
                    throw UpdateError.invalidManifest
                }
                let destination = packageURL.appendingPathComponent(local)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                let (temporary, response) = try await URLSession.shared.download(for: makeRequest(url, token: token))
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    try? fileManager.removeItem(at: temporary)
                    throw UpdateError.server((response as? HTTPURLResponse)?.statusCode ?? 0)
                }
                if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
                try fileManager.moveItem(at: temporary, to: destination)
                let attributes = try fileManager.attributesOfItem(atPath: destination.path)
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
                guard size == file.size else { throw UpdateError.size(file.path) }
                guard try sha256Hex(of: destination) == file.sha256.lowercased() else {
                    throw UpdateError.checksum(file.path)
                }
                verified += 1
            }
            let compiledURL = try await MLModel.compileModel(at: packageURL)
            // Test load: a model that does not load is never switched to.
            _ = try MLModel(contentsOf: compiledURL)
            let target = staging.appendingPathComponent("\(package.name).mlmodelc", isDirectory: true)
            if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
            try fileManager.moveItem(at: compiledURL, to: target)
            compiled += 1
        }
        guard ModelUpdatePolicy.shouldSwitch(verifiedFiles: verified, expectedFiles: expected,
                                             compiledPackages: compiled, version: manifest.version, badVersions: []) else {
            throw UpdateError.invalidManifest
        }
        let info = InstalledModel(version: manifest.version, createdAt: manifest.createdAt, map50: manifest.metrics?.map50,
                                  landscapeName: landscape.name, portraitName: portrait.name, installedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(info).write(to: staging.appendingPathComponent("info.json"), options: [.atomic])
        let final = root.appendingPathComponent(manifest.version, isDirectory: true)
        if fileManager.fileExists(atPath: final.path) { try fileManager.removeItem(at: final) }
        try fileManager.moveItem(at: staging, to: final)
        moved = true
        return info
    }

    /// Lowercase hex SHA-256 of a file, read in 1 MB chunks.
    nonisolated static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func loadInfo(version: String) -> InstalledModel? {
        guard ModelUpdatePolicy.isSafeVersion(version) else { return nil }
        let folder = modelsDirectory.appendingPathComponent(version, isDirectory: true)
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("info.json")) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let info = try? decoder.decode(InstalledModel.self, from: data), info.version == version else { return nil }
        let model = detectorModel(for: info)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: model.landscapeURL.path),
              fileManager.fileExists(atPath: model.portraitURL.path) else { return nil }
        return info
    }

    nonisolated static func detectorModel(for info: InstalledModel) -> DownloadedDetectorModel {
        let folder = modelsDirectory.appendingPathComponent(info.version, isDirectory: true)
        return DownloadedDetectorModel(
            version: info.version,
            landscapeName: info.landscapeName,
            landscapeURL: folder.appendingPathComponent("\(info.landscapeName).mlmodelc", isDirectory: true),
            portraitName: info.portraitName,
            portraitURL: folder.appendingPathComponent("\(info.portraitName).mlmodelc", isDirectory: true))
    }

    nonisolated static func installedVersions() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: modelsDirectory.path)) ?? []
        return names.filter { !$0.hasPrefix(".") && ModelUpdatePolicy.isSafeVersion($0) }
    }

    /// Deletes every version folder except `keep` (and leftover ".staging-…" folders when `includingStaging`).
    nonisolated static func removeVersions(except keep: Set<String>, includingStaging: Bool = false) {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: modelsDirectory.path)) ?? []
        for name in names where !keep.contains(name) && (includingStaging || !name.hasPrefix(".")) {
            try? fileManager.removeItem(at: modelsDirectory.appendingPathComponent(name, isDirectory: true))
        }
    }

    private enum Keys {
        static let activeVersion = "rv.learning.activeModelVersion"
        static let badVersions = "rv.learning.badModelVersions"
        static let lastCheck = "rv.learning.lastModelCheck"
    }
}
