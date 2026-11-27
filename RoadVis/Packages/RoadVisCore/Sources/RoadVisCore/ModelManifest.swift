import Foundation

/// `GET /api/v1/model/latest?platform=…` response (`docs/TRAINING_API.md` §3). Unknown keys are ignored, every
/// part the iOS app does not need is optional.
public struct ModelManifest: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        /// Path relative to the package (`.mlpackage` directory) / model root, "/"-separated.
        public var path: String
        /// Lowercase hex SHA-256 of the file.
        public var sha256: String
        public var size: Int64

        public init(path: String, sha256: String, size: Int64) {
            self.path = path
            self.sha256 = sha256
            self.size = size
        }
    }

    /// The files of one Core ML package.
    public struct Package: Codable, Equatable, Sendable {
        public var name: String
        public var files: [File]

        public init(name: String, files: [File]) {
            self.name = name
            self.files = files
        }
    }

    public struct IOSModels: Codable, Equatable, Sendable {
        public var landscape: Package?
        public var portrait: Package?

        public init(landscape: Package?, portrait: Package?) {
            self.landscape = landscape
            self.portrait = portrait
        }
    }

    public struct AndroidModel: Codable, Equatable, Sendable {
        public var file: File?
        public var inputs: [[Int]]?

        public init(file: File?, inputs: [[Int]]?) {
            self.file = file
            self.inputs = inputs
        }
    }

    public struct Metrics: Codable, Equatable, Sendable {
        public struct Previous: Codable, Equatable, Sendable {
            public var map50: Double?

            public init(map50: Double?) {
                self.map50 = map50
            }
        }

        public var testImages: Int?
        public var map50: Double?
        public var precision: Double?
        public var recall: Double?
        public var previous: Previous?

        public init(testImages: Int? = nil, map50: Double? = nil, precision: Double? = nil, recall: Double? = nil,
                    previous: Previous? = nil) {
            self.testImages = testImages
            self.map50 = map50
            self.precision = precision
            self.recall = recall
            self.previous = previous
        }
    }

    public var version: String
    public var createdAt: String?
    public var baseModel: String?
    public var metrics: Metrics?
    public var ios: IOSModels?
    public var android: AndroidModel?

    public init(version: String, createdAt: String? = nil, baseModel: String? = nil, metrics: Metrics? = nil,
                ios: IOSModels? = nil, android: AndroidModel? = nil) {
        self.version = version
        self.createdAt = createdAt
        self.baseModel = baseModel
        self.metrics = metrics
        self.ios = ios
        self.android = android
    }

    public static func decode(_ data: Data) throws -> ModelManifest {
        try JSONDecoder().decode(ModelManifest.self, from: data)
    }

    /// Package for a frame orientation.
    public func iosPackage(landscape: Bool) -> Package? {
        landscape ? ios?.landscape : ios?.portrait
    }

    /// Both iOS packages are present, non-empty, with safe relative paths, plausible sizes and sha256 values, and a
    /// version that is safe as a folder name.
    public var isUsableForIOS: Bool {
        guard ModelUpdatePolicy.isSafeVersion(version),
              let landscape = ios?.landscape, let portrait = ios?.portrait else { return false }
        return [landscape, portrait].allSatisfy { package in
            !package.files.isEmpty && package.files.allSatisfy { file in
                ModelUpdatePolicy.isSafeRelativePath(file.path) && file.size >= 0
                    && file.size <= ModelUpdatePolicy.maxFileBytes && ModelUpdatePolicy.isSHA256Hex(file.sha256)
            }
        }
    }
}

/// Pure rules of the model update (`docs/TRAINING_API.md` "App model update rules").
public enum ModelUpdatePolicy {
    /// Class names of models published by the RoadVis Trainer, in output-index order (8 classes, underscore names;
    /// `VehicleKind(label:)` maps them). The bundled COCO models keep their 80-class names.
    public static let publishedClassNames: [String] = ["car", "truck", "bus", "motorcycle", "bicycle", "person",
                                                       "traffic_light", "stop_sign"]

    /// At most one manifest check per day.
    public static let checkIntervalSeconds: TimeInterval = 24 * 3600
    /// A downloaded model that produces no detector output for this long while frames arrive (driving) is reverted.
    public static let noOutputRevertSeconds: TimeInterval = 30
    /// Upper bound of one model file, bytes (a YOLO11s package is ≈ 20 MB).
    public static let maxFileBytes: Int64 = 300 * 1024 * 1024

    /// The daily check is due: updates enabled, on Wi-Fi, and no check in the last `checkIntervalSeconds` (a last
    /// check in the future — clock changed — does not block).
    public static func shouldCheck(enabled: Bool, onWiFi: Bool, lastCheck: Date?, now: Date) -> Bool {
        guard enabled, onWiFi else { return false }
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed < 0 || elapsed >= checkIntervalSeconds
    }

    /// Download the manifest's model: it is usable for iOS, it is not the active one, not remembered as bad, and not
    /// already installed (`installedVersions`).
    public static func shouldDownload(_ manifest: ModelManifest, activeVersion: String?, badVersions: Set<String>,
                                      installedVersions: Set<String> = []) -> Bool {
        manifest.isUsableForIOS && manifest.version != activeVersion && !badVersions.contains(manifest.version)
            && !installedVersions.contains(manifest.version)
    }

    /// Switch to a freshly installed model only when every file was verified and both packages compiled.
    public static func shouldSwitch(verifiedFiles: Int, expectedFiles: Int, compiledPackages: Int,
                                    version: String, badVersions: Set<String>) -> Bool {
        expectedFiles > 0 && verifiedFiles == expectedFiles && compiledPackages == 2 && !badVersions.contains(version)
    }

    /// The version that should be active at start-up: the stored one unless it is remembered as bad or its files
    /// are gone; nil = the bundled model.
    public static func activeVersion(stored: String?, badVersions: Set<String>, isInstalled: (String) -> Bool) -> String? {
        guard let stored, !badVersions.contains(stored), isSafeVersion(stored), isInstalled(stored) else { return nil }
        return stored
    }

    /// Relative "/"-separated path without empty, "." or ".." components, not absolute, no backslashes.
    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= 512, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Version usable as a folder name: 1–64 of `[A-Za-z0-9._-]`, not starting with a dot.
    public static func isSafeVersion(_ version: String) -> Bool {
        guard !version.isEmpty, version.count <= 64, !version.hasPrefix(".") else { return false }
        return version.unicodeScalars.allSatisfy { scalar in
            (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z") || (scalar >= "0" && scalar <= "9")
                || scalar == "." || scalar == "_" || scalar == "-"
        }
    }

    public static func isSHA256Hex(_ text: String) -> Bool {
        text.count == 64 && text.unicodeScalars.allSatisfy { scalar in
            (scalar >= "0" && scalar <= "9") || (scalar >= "a" && scalar <= "f") || (scalar >= "A" && scalar <= "F")
        }
    }

    /// Local path of a manifest file inside the rebuilt package: a leading "<name>.mlpackage/" component is dropped
    /// (the server may list package files with or without it).
    public static func packageRelativePath(_ path: String, packageName: String) -> String {
        let prefix = packageName + ".mlpackage/"
        if path.hasPrefix(prefix), path.count > prefix.count {
            return String(path.dropFirst(prefix.count))
        }
        return path
    }

    /// Server-side path of an iOS package file: "<name>.mlpackage/<path>" (e.g.
    /// "RoadVisDetector.mlpackage/Manifest.json"), where `path` is the manifest entry's path relative to the package.
    public static func iosFilePath(_ path: String, packageName: String) -> String {
        packageName + ".mlpackage/" + packageRelativePath(path, packageName: packageName)
    }

    /// `GET /api/v1/model/{version}/files/{path}` URL: every path component percent-encoded, "/" kept.
    public static func fileURL(base: URL, version: String, path: String) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#;")
        guard let encodedVersion = version.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        var encodedComponents: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            guard let encoded = String(component).addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            encodedComponents.append(encoded)
        }
        let baseString = base.absoluteString.hasSuffix("/") ? String(base.absoluteString.dropLast()) : base.absoluteString
        return URL(string: baseString + "/api/v1/model/" + encodedVersion + "/files/" + encodedComponents.joined(separator: "/"))
    }
}

/// Watches a downloaded model in use: "no detector output for 30 s of driving" → revert to the bundled model.
/// Time is accumulated only over frames that arrive while driving (gaps over `maxFrameGap` do not count), and any
/// detection resets it.
public struct ModelHealthMonitor: Sendable {
    public var limitSeconds: TimeInterval
    public var maxFrameGap: TimeInterval
    /// Seconds of driving frames without any detector output so far.
    public private(set) var silentSeconds: TimeInterval = 0
    private var lastTimestamp: TimeInterval?

    public init(limitSeconds: TimeInterval = ModelUpdatePolicy.noOutputRevertSeconds, maxFrameGap: TimeInterval = 1) {
        self.limitSeconds = limitSeconds
        self.maxFrameGap = maxFrameGap
    }

    public mutating func reset() {
        silentSeconds = 0
        lastTimestamp = nil
    }

    /// Records one processed frame; returns true when the model should be reverted. `hadOutput`: the detector ran
    /// and returned at least one detection. `driving`: own speed ≥ 5 km/h or unknown.
    public mutating func record(timestamp: TimeInterval, hadOutput: Bool, driving: Bool) -> Bool {
        defer { lastTimestamp = timestamp }
        if hadOutput {
            silentSeconds = 0
            return false
        }
        guard driving, let last = lastTimestamp else { return false }
        let dt = timestamp - last
        if dt > 0, dt <= maxFrameGap {
            silentSeconds += dt
        }
        return silentSeconds >= limitSeconds
    }
}
