import Foundation

/// Errors produced by `OSRMClient`. Descriptions are complete sentences in the app language.
enum OSRMClientError: LocalizedError, Equatable {
    case invalidEndpoint(String)
    case offline
    case timedOut
    case network(String)
    case rateLimited
    case http(Int)
    case server(code: String?, message: String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let value):
            return value.isEmpty ? L("osrmErr.noEndpoint")
                                 : L("osrmErr.badEndpoint", value)
        case .offline: return L("osrmErr.offline")
        case .timedOut: return L("osrmErr.timeout")
        case .network(let reason): return L("osrmErr.network", reason)
        case .rateLimited: return L("osrmErr.rateLimited")
        case .http(let status): return L("osrmErr.http", status)
        case .server(let code, let message): return Self.describeServerError(code: code, message: message)
        case .emptyResult: return L("osrmErr.noRoute")
        }
    }

    /// Localized `OSRMError.russianDescription`.
    private static func describeServerError(code: String?, message: String) -> String {
        switch code {
        case "NoRoute": return L("osrmErr.noRoute")
        case "NoSegment": return L("osrmErr.noSegment")
        case "TooBig": return L("osrmErr.tooBig")
        case "InvalidQuery", "InvalidValue", "InvalidOptions", "InvalidUrl", "InvalidService", "InvalidVersion":
            return L("osrmErr.rejected", code ?? "", message)
        case nil: return L("osrmErr.unparsable", message)
        default: return L("osrmErr.other", code ?? "", message)
        }
    }
}

/// HTTP client for an OSRM server (default: FOSSGIS `OSRM.defaultEndpoint`). Same fair-use behaviour as
/// `ValhallaClient`: strictly serialised requests ≥ 1.1 s apart, identifying User-Agent, configurable URL.
actor OSRMClient {
    static let requestTimeout: TimeInterval = 25
    static let minimumSpacing: TimeInterval = 1.1

    private var endpoint: String
    private let session: URLSession
    private var queueTail: Task<Void, Never>?
    private var nextAllowedStart: Date = .distantPast

    init(endpoint: String) {
        self.endpoint = endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.requestTimeout + 10
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": ValhallaClient.userAgent]
        self.session = URLSession(configuration: configuration)
    }

    func setEndpoint(_ newEndpoint: String) {
        endpoint = newEndpoint
    }

    /// Car routes (main + alternatives) with Russian instructions built from the OSRM maneuvers.
    func routes(from: GeoPoint, to: GeoPoint) async throws -> [NavRoute] {
        guard let url = OSRM.routeURL(endpoint: endpoint, from: from, to: to) else {
            throw OSRMClientError.invalidEndpoint(endpoint)
        }
        let previous = queueTail
        let job = Task { () async throws -> Data in
            await previous?.value
            try Task.checkCancellation()
            try await self.waitForSlot()
            defer { self.markRequestFinished() }
            return try await self.perform(url: url)
        }
        queueTail = Task { _ = await job.result }
        let data = try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
        let routes: [NavRoute]
        do {
            routes = try OSRM.parseRoutes(data, language: .app)
        } catch let error as OSRMError {
            throw OSRMClientError.server(code: error.code, message: error.message)
        }
        guard !routes.isEmpty else { throw OSRMClientError.emptyResult }
        return routes
    }

    private func waitForSlot() async throws {
        let wait = nextAllowedStart.timeIntervalSinceNow
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }

    private func markRequestFinished() {
        nextAllowedStart = Date().addingTimeInterval(Self.minimumSpacing)
    }

    private func perform(url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "GET"
        request.setValue(ValhallaClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: throw OSRMClientError.offline
            case .timedOut: throw OSRMClientError.timedOut
            case .cannotFindHost, .dnsLookupFailed: throw OSRMClientError.network(L("net.hostNotFound"))
            case .cannotConnectToHost, .networkConnectionLost: throw OSRMClientError.network(L("net.cannotConnect"))
            case .badURL, .unsupportedURL: throw OSRMClientError.invalidEndpoint(url.absoluteString)
            default: throw OSRMClientError.network(error.localizedDescription)
            }
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw OSRMClientError.network(L("net.unknownResponse")) }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 429 { throw OSRMClientError.rateLimited }
            // OSRM reports routing errors as JSON {"code": "NoRoute", "message": …} with HTTP 400.
            if let error = Self.osrmError(in: data) {
                throw OSRMClientError.server(code: error.code, message: error.message)
            }
            throw OSRMClientError.http(http.statusCode)
        }
        return data
    }

    private static func osrmError(in data: Data) -> OSRMError? {
        do {
            _ = try OSRM.parseRoutes(data)
            return nil
        } catch let error as OSRMError {
            return error.code == nil ? nil : error
        } catch {
            return nil
        }
    }
}
