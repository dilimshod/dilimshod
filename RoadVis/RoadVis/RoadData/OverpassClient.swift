import Foundation

/// Errors produced by `OverpassClient`. Descriptions are Russian fragments meant to follow a prefix such as
/// "Нет связи с OpenStreetMap (Overpass): ".
enum OverpassClientError: LocalizedError, Equatable {
    /// Every endpoint is cooling down after HTTP 429/406; the next attempt makes sense after `retryAfter` seconds.
    case rateLimited(retryAfter: TimeInterval)
    /// The servers rejected the query itself (HTTP 400). Retrying the same query elsewhere does not help.
    case badQuery(String)
    /// The device has no usable internet connection.
    case offline
    /// Every endpoint was tried and failed; one human-readable reason per endpoint.
    case allEndpointsFailed([String])
    /// Neither the configured endpoint nor any fallback is a valid http(s) URL.
    case noValidEndpoint

    var errorDescription: String? {
        switch self {
        case .rateLimited(let retryAfter):
            let seconds = max(1, Int(retryAfter.rounded(.up)))
            return "серверы временно ограничили частоту запросов, повтор через \(seconds) с"
        case .badQuery(let message):
            return message.isEmpty ? "сервер отклонил запрос" : "сервер отклонил запрос (\(message))"
        case .offline:
            return "нет подключения к интернету"
        case .allEndpointsFailed(let reasons):
            return reasons.isEmpty ? "все серверы недоступны" : "все серверы недоступны — " + reasons.joined(separator: "; ")
        case .noValidEndpoint:
            return "не задан корректный адрес сервера Overpass"
        }
    }
}

/// Client for the public OpenStreetMap Overpass API.
///
/// Fair-use behaviour required by the public instances:
/// - requests are strictly serialised — never two in flight at once, even when several callers await `run` together
///   (actors are re-entrant across `await`, so an explicit FIFO chain of tasks is used instead of relying on isolation);
/// - a unique `User-Agent` is sent with every request;
/// - HTTP 429 / 406 put the endpoint on a 30 s cool-down (or the server's `Retry-After`) and the next endpoint is tried;
/// - HTTP 502/503/504 and HTML error pages (Overpass reports errors as HTML even for `[out:json]`) move on to the next
///   endpoint immediately;
/// - complete responses are cached in memory for 10 minutes (at most 50 queries), keyed by the exact query text.
///
/// A JSON response with a top-level `"remark"` (runtime error such as a server-side timeout) is treated as partial:
/// it is returned when it contains elements but is never cached; an empty partial response counts as a failure.
actor OverpassClient {
    /// Identifies the app to Overpass operators (also used for Open-Meteo requests).
    static let userAgent = "RoadVis-iOS/1.0 (+https://github.com/dilimshod)"
    /// Default per-request timeout, seconds (current-road queries use `[timeout:15]`).
    static let requestTimeout: TimeInterval = 25
    /// Timeout for route-feature queries: their server-side `[timeout:25]` plus queueing at the server.
    static let routeQueryTimeout: TimeInterval = 45
    /// Cool-down applied to an endpoint after HTTP 429/406 when the server sends no `Retry-After`.
    static let rateLimitCooldown: TimeInterval = 30
    /// Lifetime of cached responses, seconds.
    static let cacheTTL: TimeInterval = 10 * 60
    /// Maximum number of cached queries.
    static let cacheCapacity = 50

    private struct CacheEntry {
        let elements: [OSMElement]
        let storedAt: Date
    }

    /// Result of one HTTP attempt against one endpoint.
    private enum AttemptOutcome {
        case complete([OSMElement])
        case partial([OSMElement], remark: String)
        case failed(String)
        case rateLimited(String)
        case rejected(String)
    }

    private var primaryEndpoint: String
    private let fallbackEndpoints: [String]
    private let session: URLSession
    private var cooldownUntil: [String: Date] = [:]
    private var cache: [String: CacheEntry] = [:]
    /// Tail of the FIFO request chain; every new request waits for it before touching the network.
    private var queueTail: Task<Void, Never>?

    /// - Parameters:
    ///   - primaryEndpoint: endpoint tried first (the one chosen in Settings).
    ///   - fallbacks: further endpoints tried in order when the primary fails; duplicates of the primary are skipped.
    init(primaryEndpoint: String, fallbacks: [String] = AppSettings.overpassEndpoints) {
        self.primaryEndpoint = Self.normalized(primaryEndpoint)
        self.fallbackEndpoints = fallbacks.map { Self.normalized($0) }
        let configuration = URLSessionConfiguration.ephemeral
        // Per-request timeouts are set on each URLRequest; the session limits only cap them.
        configuration.timeoutIntervalForRequest = Self.routeQueryTimeout
        configuration.timeoutIntervalForResource = Self.routeQueryTimeout + 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        self.session = URLSession(configuration: configuration)
    }

    /// Changes the endpoint tried first (e.g. after the user picked another server in Settings).
    func setPrimaryEndpoint(_ endpoint: String) {
        let value = Self.normalized(endpoint)
        guard value != primaryEndpoint else { return }
        primaryEndpoint = value
    }

    /// Drops every cached response.
    func clearCache() {
        cache.removeAll()
    }

    /// Runs an Overpass QL query (POST `data=<query>`) and returns the decoded elements.
    ///
    /// Requests are queued: this call waits until every earlier request has finished. Cancelling the calling task
    /// cancels this request (also while it is still waiting in the queue) without disturbing the others.
    /// - Parameter timeout: client-side timeout of each HTTP attempt; must exceed the query's `[timeout:N]`.
    func run(_ query: String, timeout: TimeInterval = OverpassClient.requestTimeout) async throws -> [OSMElement] {
        if let cached = cachedElements(for: query) { return cached }
        let previous = queueTail
        let job = Task { () async throws -> [OSMElement] in
            await previous?.value
            try Task.checkCancellation()
            // An identical query may have been answered while this one was waiting.
            if let cached = self.cachedElements(for: query) { return cached }
            return try await self.fetchWithFallback(query, timeout: timeout)
        }
        queueTail = Task { _ = await job.result }
        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }

    // MARK: - Endpoint fallback

    private func fetchWithFallback(_ query: String, timeout: TimeInterval) async throws -> [OSMElement] {
        let endpoints = orderedEndpoints()
        guard !endpoints.isEmpty else { throw OverpassClientError.noValidEndpoint }

        let now = Date()
        let available = endpoints.filter { (cooldownUntil[$0] ?? .distantPast) <= now }
        guard !available.isEmpty else {
            let soonest = endpoints.compactMap { cooldownUntil[$0] }.min()
            let wait = soonest.map { $0.timeIntervalSince(now) } ?? Self.rateLimitCooldown
            throw OverpassClientError.rateLimited(retryAfter: max(1, wait))
        }

        let body = OverpassQuery.formBody(query)
        var reasons: [String] = []
        var rejection: String?
        var emptyPartial = false
        var rateLimitedCount = 0
        for endpoint in available {
            try Task.checkCancellation()
            let host = Self.hostName(endpoint)
            guard let url = URL(string: endpoint), let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http", url.host != nil else {
                reasons.append("\(host): некорректный адрес")
                continue
            }
            switch try await attempt(url: url, endpoint: endpoint, body: body, timeout: timeout) {
            case .complete(let elements):
                store(elements, for: query)
                return elements
            case .partial(let elements, let remark):
                if !elements.isEmpty { return elements }
                emptyPartial = true
                reasons.append("\(host): \(Self.shortened(remark))")
            case .failed(let reason):
                reasons.append("\(host): \(reason)")
            case .rateLimited(let reason):
                rateLimitedCount += 1
                reasons.append("\(host): \(reason)")
            case .rejected(let message):
                rejection = message
                reasons.append("\(host): запрос отклонён")
            }
        }
        // A 400 from one server while no other server accepted the query means the query itself is invalid.
        if let rejection, !emptyPartial { throw OverpassClientError.badQuery(rejection) }
        if rateLimitedCount == available.count {
            let soonest = endpoints.compactMap { cooldownUntil[$0] }.min()
            let wait = soonest.map { $0.timeIntervalSinceNow } ?? Self.rateLimitCooldown
            throw OverpassClientError.rateLimited(retryAfter: max(1, wait))
        }
        throw OverpassClientError.allEndpointsFailed(reasons)
    }

    /// One POST to one endpoint. Throws only for conditions where trying other endpoints is pointless
    /// (cancellation, no internet connection).
    private func attempt(url: URL, endpoint: String, body: Data, timeout: TimeInterval) async throws -> AttemptOutcome {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: max(5, timeout))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
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
                throw OverpassClientError.offline
            case .timedOut:
                return .failed("истекло время ожидания")
            case .cannotFindHost, .dnsLookupFailed:
                return .failed("сервер не найден")
            case .cannotConnectToHost, .networkConnectionLost:
                return .failed("не удалось подключиться")
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                return .failed("ошибка защищённого соединения")
            default:
                return .failed(error.localizedDescription)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return .failed(error.localizedDescription)
        }
        if Task.isCancelled { throw CancellationError() }

        guard let http = response as? HTTPURLResponse else {
            return .failed("неизвестный ответ сервера")
        }
        switch http.statusCode {
        case 200:
            if Self.looksLikeHTML(data) {
                return .failed("сервер вернул страницу ошибки (\(Self.shortened(Self.textSummary(of: data))))")
            }
            let elements: [OSMElement]
            do {
                elements = try OverpassQuery.decode(data)
            } catch {
                return .failed("не удалось разобрать ответ")
            }
            if let remark = Self.remark(in: data) {
                return .partial(elements, remark: remark)
            }
            return .complete(elements)
        case 429, 406:
            let wait = Self.retryAfter(from: http) ?? Self.rateLimitCooldown
            cooldownUntil[endpoint] = Date().addingTimeInterval(wait)
            return .rateLimited("слишком много запросов (HTTP \(http.statusCode))")
        case 400:
            return .rejected(Self.shortened(Self.textSummary(of: data)))
        case 502, 503, 504:
            return .failed("сервер перегружен (HTTP \(http.statusCode))")
        default:
            return .failed("HTTP \(http.statusCode)")
        }
    }

    /// Primary endpoint first, then the fallbacks, without duplicates or empty entries.
    private func orderedEndpoints() -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for endpoint in [primaryEndpoint] + fallbackEndpoints where !endpoint.isEmpty {
            if seen.insert(endpoint.lowercased()).inserted {
                result.append(endpoint)
            }
        }
        return result
    }

    // MARK: - Cache

    private func cachedElements(for query: String) -> [OSMElement]? {
        guard let entry = cache[query] else { return nil }
        guard Date().timeIntervalSince(entry.storedAt) < Self.cacheTTL else {
            cache[query] = nil
            return nil
        }
        return entry.elements
    }

    private func store(_ elements: [OSMElement], for query: String) {
        let now = Date()
        cache = cache.filter { now.timeIntervalSince($0.value.storedAt) < Self.cacheTTL }
        cache[query] = CacheEntry(elements: elements, storedAt: now)
        while cache.count > Self.cacheCapacity {
            guard let oldest = cache.min(by: { $0.value.storedAt < $1.value.storedAt })?.key else { break }
            cache[oldest] = nil
        }
    }

    // MARK: - Helpers

    private static func normalized(_ endpoint: String) -> String {
        var value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private static func hostName(_ endpoint: String) -> String {
        URL(string: endpoint)?.host ?? (endpoint.isEmpty ? "(пусто)" : endpoint)
    }

    /// Overpass error pages are HTML even when JSON output was requested.
    private static func looksLikeHTML(_ data: Data) -> Bool {
        for byte in data.prefix(256) {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF: continue   // whitespace and UTF-8 BOM
            default: return byte == UInt8(ascii: "<")
            }
        }
        return false
    }

    /// Top-level `"remark"` of an Overpass JSON response (present when the query hit a runtime error).
    private static func remark(in data: Data) -> String? {
        guard data.range(of: Data("\"remark\"".utf8)) != nil else { return nil }
        struct RemarkProbe: Decodable { let remark: String? }
        guard let probe = try? JSONDecoder().decode(RemarkProbe.self, from: data),
              let remark = probe.remark?.trimmingCharacters(in: .whitespacesAndNewlines), !remark.isEmpty else {
            return nil
        }
        return remark
    }

    /// Plain-text summary of an (HTML) error body: the `<p>` paragraphs mentioning "error" (where Overpass prints
    /// "Error: …"), else the page title / heading, else the first text of the page.
    private static func textSummary(of data: Data) -> String {
        let html = String(decoding: data.prefix(16_384), as: UTF8.self)
        let paragraphs = blocks(named: "p", in: html)
            .map(plainText)
            .filter { $0.range(of: "error", options: .caseInsensitive) != nil }
        if !paragraphs.isEmpty {
            return paragraphs.joined(separator: " ")
        }
        for tag in ["title", "h1", "h2"] {
            if let text = blocks(named: tag, in: html).map(plainText).first(where: { !$0.isEmpty }) {
                return text
            }
        }
        let text = plainText(html)
        return text.isEmpty ? "пустая страница" : text
    }

    /// Inner HTML of every `<tag …>…</tag>` element (case-insensitive, non-nested).
    private static func blocks(named tag: String, in html: String) -> [String] {
        let pattern = "<\(tag)(\\s[^>]*)?>(.*?)</\(tag)\\s*>"
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            Range(match.range(at: 2), in: html).map { String(html[$0]) }
        }
    }

    /// Tags removed, common entities decoded, whitespace collapsed.
    private static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, replacement) in [("&quot;", "\""), ("&lt;", "<"), ("&gt;", ">"), ("&#39;", "'"),
                                      ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func shortened(_ text: String, limit: Int = 160) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    /// `Retry-After` in seconds (delta form only), clamped to a sane range.
    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces),
              let seconds = Double(value), seconds.isFinite else { return nil }
        return min(300, max(5, seconds))
    }
}
