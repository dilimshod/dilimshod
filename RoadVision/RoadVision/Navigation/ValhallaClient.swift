import Foundation

/// Errors produced by `ValhallaClient`. Descriptions are complete Russian sentences shown to the user.
enum ValhallaClientError: LocalizedError, Equatable {
    /// The configured server address is not a valid http(s) URL.
    case invalidEndpoint(String)
    /// The device has no usable internet connection.
    case offline
    /// The server did not answer within the request timeout.
    case timedOut
    /// Transport-level failure (DNS, TLS, connection lost …) with a short Russian reason.
    case network(String)
    /// The server rate-limited the app (HTTP 429).
    case rateLimited
    /// Non-2xx status without a readable Valhalla error message.
    case http(Int)
    /// Valhalla reported an error (`{"error_code", "error"}`) or the response could not be parsed.
    case server(code: Int?, message: String)
    /// The response contained no usable route / no edges.
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let value):
            return value.isEmpty
                ? "Не задан адрес сервера Valhalla (Настройки → Маршрутизация)."
                : "Некорректный адрес сервера Valhalla: \(value)"
        case .offline:
            return "Нет подключения к интернету — маршрут OpenStreetMap недоступен."
        case .timedOut:
            return "Сервер Valhalla не ответил вовремя. Попробуйте ещё раз."
        case .network(let reason):
            return "Нет связи с сервером Valhalla: \(reason)."
        case .rateLimited:
            return "Сервер Valhalla временно ограничил частоту запросов (HTTP 429). Попробуйте через минуту."
        case .http(let status):
            return "Сервер Valhalla вернул ошибку HTTP \(status)."
        case .server(let code, let message):
            return Self.describeServerError(code: code, message: message)
        case .emptyResult:
            return "Valhalla не нашёл маршрут между этими точками."
        }
    }

    /// Russian explanation for well-known Valhalla error codes; other messages are passed through.
    private static func describeServerError(code: Int?, message: String) -> String {
        switch code {
        case 170:
            return "Точки находятся в несвязанных частях дорожной сети OpenStreetMap — маршрут невозможен."
        case 171:
            return "Рядом с точкой старта или назначения нет подходящих дорог в OpenStreetMap."
        case 154:
            return "Маршрут слишком длинный для сервера Valhalla."
        case 442:
            return "Valhalla не нашёл маршрут между этими точками."
        case 443, 444:
            return "Не удалось сопоставить маршрут с дорогами OpenStreetMap."
        default:
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = trimmed.isEmpty ? "неизвестная ошибка" : trimmed
            if let code { return "Ошибка Valhalla (код \(code)): \(text)" }
            return "Ошибка Valhalla: \(text)"
        }
    }
}

/// HTTP client for a Valhalla routing server (default: the public FOSSGIS instance
/// `Valhalla.defaultEndpoint`, see `docs/CONTRACTS.md` 2.3).
///
/// Fair-use behaviour required by the FOSSGIS usage policy:
/// - requests are strictly serialised and at least `minimumSpacing` (1.1 s) apart, measured from the end of the
///   previous request. Actors are re-entrant across `await`, so an explicit FIFO chain of tasks is used instead of
///   relying on actor isolation alone;
/// - an identifying `User-Agent` is sent with every request;
/// - the server address is configurable (`setEndpoint(_:)`, Settings → Маршрутизация).
///
/// Request bodies are built and responses parsed by the core `Valhalla` enum; this type only does the networking
/// and maps failures to Russian `ValhallaClientError`s.
actor ValhallaClient {
    /// Identifies the app to the server operators.
    static let userAgent = "RoadVision-iOS/1.0 (+https://github.com/dilimshod/dilimshod)"
    /// Per-request timeout, seconds.
    static let requestTimeout: TimeInterval = 25
    /// Minimum pause between the end of one request and the start of the next, seconds.
    static let minimumSpacing: TimeInterval = 1.1

    private var endpoint: String
    private let session: URLSession
    /// Tail of the FIFO request chain; every new request waits for it before touching the network.
    private var queueTail: Task<Void, Never>?
    /// Earliest moment the next request may start.
    private var nextAllowedStart: Date = .distantPast

    /// - Parameter endpoint: server base URL, e.g. `https://valhalla1.openstreetmap.de` (trailing slash optional).
    init(endpoint: String) {
        self.endpoint = Self.normalized(endpoint)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.requestTimeout + 10
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        self.session = URLSession(configuration: configuration)
    }

    /// Changes the server used by subsequent requests (the rate-limit chain is kept).
    func setEndpoint(_ newEndpoint: String) {
        endpoint = Self.normalized(newEndpoint)
    }

    // MARK: - Public API

    /// Car routes from `from` to `to`: the main route first, followed by up to two alternates.
    /// - Parameters:
    ///   - heading: current travel direction (degrees) so the route starts in the direction the car is moving;
    ///     nil when unknown.
    ///   - avoidTolls / avoidHighways: costing preferences (soft avoidance, as in Valhalla).
    func routes(from: GeoPoint, to: GeoPoint, heading: Double?, avoidTolls: Bool, avoidHighways: Bool) async throws -> [NavRoute] {
        let body: Data
        do {
            body = try Valhalla.routeRequestBody(from: from, to: to, heading: heading, language: "ru-RU",
                                                 alternates: 2, avoidTolls: avoidTolls, avoidHighways: avoidHighways)
        } catch {
            throw ValhallaClientError.server(code: nil, message: "не удалось сформировать запрос")
        }
        let data = try await post(path: "route", body: body)
        let routes: [NavRoute]
        do {
            routes = try Valhalla.parseRoutes(data)
        } catch let error as ValhallaError {
            throw ValhallaClientError.server(code: error.code, message: error.message)
        }
        let usable = routes.filter { $0.polyline.count >= 2 }
        guard !usable.isEmpty else { throw ValhallaClientError.emptyResult }
        return usable
    }

    /// Per-edge attributes (speed limit, lanes per direction, typical speed, traffic signals) along `polyline`.
    /// - Parameter edgeWalk: true only for shapes produced by Valhalla itself; other polylines (Apple routes) are
    ///   map-matched (`map_snap`) and should be simplified to ≤ 1000 points by the caller.
    func traceAttributes(polyline: [GeoPoint], edgeWalk: Bool) async throws -> [RouteEdgeAttributes] {
        guard polyline.count >= 2 else { throw ValhallaClientError.emptyResult }
        let body: Data
        do {
            body = try Valhalla.traceAttributesBody(polyline: polyline, edgeWalk: edgeWalk)
        } catch {
            throw ValhallaClientError.server(code: nil, message: "не удалось сформировать запрос")
        }
        let data = try await post(path: "trace_attributes", body: body)
        let edges: [RouteEdgeAttributes]
        do {
            edges = try Valhalla.parseTraceAttributes(data, fallbackPolyline: polyline)
        } catch let error as ValhallaError {
            throw ValhallaClientError.server(code: error.code, message: error.message)
        }
        guard !edges.isEmpty else { throw ValhallaClientError.emptyResult }
        return edges
    }

    // MARK: - Request queue

    /// Queues a JSON POST to `<endpoint>/<path>` behind all earlier requests and returns the 2xx body.
    /// Cancelling the calling task cancels this request (also while it is waiting in the queue).
    private func post(path: String, body: Data) async throws -> Data {
        guard let url = Self.url(endpoint: endpoint, path: path) else {
            throw ValhallaClientError.invalidEndpoint(endpoint)
        }
        let previous = queueTail
        let job = Task { () async throws -> Data in
            await previous?.value
            try Task.checkCancellation()
            try await self.waitForSlot()
            defer { self.markRequestFinished() }
            return try await self.perform(url: url, body: body)
        }
        queueTail = Task { _ = await job.result }
        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }

    /// Sleeps until `nextAllowedStart` (FOSSGIS: at most one request per second).
    private func waitForSlot() async throws {
        let wait = nextAllowedStart.timeIntervalSinceNow
        if wait > 0 {
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    private func markRequestFinished() {
        nextAllowedStart = Date().addingTimeInterval(Self.minimumSpacing)
    }

    /// One HTTP attempt. Maps transport errors and non-2xx statuses to `ValhallaClientError`.
    private func perform(url: URL, body: Data) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .cancelled:
                throw CancellationError()
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
                throw ValhallaClientError.offline
            case .timedOut:
                throw ValhallaClientError.timedOut
            case .cannotFindHost, .dnsLookupFailed:
                throw ValhallaClientError.network("сервер не найден")
            case .cannotConnectToHost, .networkConnectionLost:
                throw ValhallaClientError.network("не удалось подключиться")
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                throw ValhallaClientError.network("ошибка защищённого соединения")
            case .badURL, .unsupportedURL:
                throw ValhallaClientError.invalidEndpoint(url.absoluteString)
            default:
                throw ValhallaClientError.network(error.localizedDescription)
            }
        } catch is CancellationError {
            throw CancellationError()
        }
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else {
            throw ValhallaClientError.network("неизвестный ответ сервера")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 429 { throw ValhallaClientError.rateLimited }
            // Valhalla reports errors as JSON {"error_code": 171, "error": "...", "status_code": 400}.
            do {
                _ = try Valhalla.parseRoutes(data)
            } catch let error as ValhallaError {
                if error.code != nil || !Self.isGenericParseMessage(error.message) {
                    throw ValhallaClientError.server(code: error.code, message: error.message)
                }
            } catch {
                // Not a Valhalla error body — fall through to the HTTP status.
            }
            throw ValhallaClientError.http(http.statusCode)
        }
        return data
    }

    // MARK: - Helpers

    /// True for the parser's own messages ("not JSON", "no trip") that do not describe a server error.
    private static func isGenericParseMessage(_ message: String) -> Bool {
        message.hasPrefix("Ответ Valhalla") || message.hasPrefix("В ответе Valhalla")
    }

    private static func normalized(_ endpoint: String) -> String {
        var value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// `<endpoint>/<path>` when the endpoint is an http(s) URL with a host.
    static func url(endpoint: String, path: String) -> URL? {
        let base = normalized(endpoint)
        guard let url = URL(string: base + "/" + path),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host != nil else { return nil }
        return url
    }
}
