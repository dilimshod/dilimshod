import Foundation

/// Errors produced while interpreting an Overpass API response body.
public enum OverpassError: Error, Equatable, Sendable, LocalizedError {
    /// The server answered with an HTML page (Overpass reports errors as HTML even for `[out:json]`,
    /// proxies return HTML 502/504 pages). The associated text is the extracted error message.
    case htmlError(String)
    /// The body is not valid Overpass JSON.
    case invalidJSON(String)
    /// The body is empty.
    case emptyResponse

    /// Russian, user-facing description.
    public var errorDescription: String? {
        switch self {
        case .htmlError(let message):
            if isRateLimited { return "Сервер OpenStreetMap (Overpass) перегружен или ограничил частоту запросов. Повторим позже." }
            if isTimeout { return "Сервер OpenStreetMap (Overpass) не ответил вовремя. Повторим позже." }
            return "Сервер OpenStreetMap (Overpass) вернул ошибку: \(message)"
        case .invalidJSON(let message):
            return "Не удалось разобрать ответ OpenStreetMap: \(message)"
        case .emptyResponse:
            return "Сервер OpenStreetMap вернул пустой ответ."
        }
    }

    /// The server asked us to slow down (Overpass `rate_limited`, HTTP 429 page).
    public var isRateLimited: Bool {
        guard case .htmlError(let m) = self else { return false }
        let l = m.lowercased()
        return l.contains("rate_limited") || l.contains("too many requests") || l.contains("429")
    }

    /// Gateway / query timeout (HTTP 504 page or Overpass "Query timed out").
    public var isTimeout: Bool {
        guard case .htmlError(let m) = self else { return false }
        let l = m.lowercased()
        return l.contains("timed out") || l.contains("time-out") || l.contains("timeout") || l.contains("504")
            || l.contains("dispatcher_client")
    }

    /// Whether repeating the request (possibly at another endpoint, after a pause) can help.
    public var isRetryable: Bool {
        switch self {
        case .htmlError(let m):
            if isRateLimited || isTimeout { return true }
            let l = m.lowercased()
            return l.contains("502") || l.contains("503") || l.contains("bad gateway") || l.contains("unavailable")
                || l.contains("out of memory")
        case .emptyResponse: return true
        case .invalidJSON: return false
        }
    }
}

/// Builds Overpass QL queries and decodes their responses. Networking lives in the app layer (`OverpassClient`).
public enum OverpassQuery {
    /// Maximum number of polyline vertices passed to one `featuresAlong` query.
    public static let maxPolylinePoints: Int = 100

    /// `highway=*` values that are never driven by cars; excluded from the road selector.
    public static let excludedHighwayValues: [String] = [
        "footway", "path", "cycleway", "steps", "pedestrian", "bridleway", "corridor", "elevator",
        "platform", "proposed", "construction", "abandoned", "disused", "razed", "bus_stop", "services", "rest_area",
    ]

    /// Ways with `highway=*` (drivable classes only) within `radius` metres, returned with tags and geometry
    /// (`out tags geom`), plus `highway=traffic_signals` nodes within `signalRadius` (`out`, with coordinates).
    public static func roadsAround(_ p: GeoPoint, radius: Double = 30, signalRadius: Double = 80, timeout: Int = 15) -> String {
        let point = coordinates([p])
        return """
        [out:json][timeout:\(max(1, timeout))];
        way(around:\(meters(radius)),\(point))[highway][highway!~"\(excludedHighwayRegex)"];
        out tags geom;
        node(around:\(meters(signalRadius)),\(point))[highway=traffic_signals];
        out;
        """
    }

    /// Road features along a polyline (`around:R,lat1,lon1,lat2,lon2,…`): traffic signals, pedestrian crossings,
    /// speed cameras, stop / give-way signs, traffic calming, railway level crossings, highway=construction ways
    /// (within `radius`) and schools / kindergartens (within 150 m), all with `out tags center qt`.
    ///
    /// A polyline longer than `maxPolylinePoints` vertices is simplified (Douglas–Peucker) to fit; split long routes
    /// into chunks with `Geo.chunk` first to keep the detail. An empty polyline yields a valid query with no results.
    public static func featuresAlong(_ polyline: [GeoPoint], radius: Double = 35, timeout: Int = 25) -> String {
        let header = "[out:json][timeout:\(max(1, timeout))];"
        let valid = polyline.filter(\.isValid)
        guard !valid.isEmpty else { return header + "\nout;" }
        var points = valid.count > maxPolylinePoints ? Geo.simplify(valid, maxPoints: maxPolylinePoints) : valid
        if points.count > maxPolylinePoints { points = Array(points.prefix(maxPolylinePoints)) }
        let poly = coordinates(points)
        let r = meters(radius)
        let schoolRadius = meters(max(radius, 150))
        return """
        \(header)
        (
          node(around:\(r),\(poly))[highway~"^(traffic_signals|crossing|speed_camera|stop|give_way)$"];
          node(around:\(r),\(poly))[traffic_calming];
          node(around:\(r),\(poly))[railway=level_crossing];
          nwr(around:\(schoolRadius),\(poly))[amenity~"^(school|kindergarten)$"];
          way(around:\(r),\(poly))[highway=construction];
        );
        out tags center qt;
        """
    }

    /// Request body for `POST /api/interpreter` with `Content-Type: application/x-www-form-urlencoded`:
    /// `data=<query>` where every byte except the RFC 3986 unreserved characters (`A–Z a–z 0–9 - . _ ~`)
    /// is percent-encoded as UTF-8.
    public static func formBody(_ query: String) -> Data {
        Data(("data=" + percentEncode(query)).utf8)
    }

    /// Strict `application/x-www-form-urlencoded` component encoding (spaces become `%20`).
    public static func percentEncode(_ string: String) -> String {
        let hex = Array("0123456789ABCDEF")
        var out = ""
        out.reserveCapacity(string.utf8.count * 3)
        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                out.append(Character(Unicode.Scalar(byte)))
            default:
                out.append("%")
                out.append(hex[Int(byte >> 4)])
                out.append(hex[Int(byte & 0x0F)])
            }
        }
        return out
    }

    /// Decodes the elements of an Overpass JSON response.
    /// - Throws: `OverpassError.htmlError` when the body is an HTML (error) page, `.emptyResponse`, `.invalidJSON`.
    public static func decode(_ data: Data) throws -> [OSMElement] {
        try decodeResponse(data).elements
    }

    /// Like `decode`, but also returns the `remark` (partial result marker) and data timestamp.
    public static func decodeResponse(_ data: Data) throws -> OverpassResponse {
        guard let first = firstSignificantByte(data) else { throw OverpassError.emptyResponse }
        if first == UInt8(ascii: "<") {
            throw OverpassError.htmlError(htmlErrorMessage(data))
        }
        do {
            return try JSONDecoder().decode(OverpassResponse.self, from: data)
        } catch let error as DecodingError {
            throw OverpassError.invalidJSON(describe(error))
        } catch {
            throw OverpassError.invalidJSON(String(describing: error))
        }
    }

    /// Extracts a readable message from an Overpass/nginx HTML error page:
    /// `<p>` paragraphs mentioning "Error", else `<title>` / `<h1>`, else the first text of the page.
    public static func htmlErrorMessage(_ data: Data) -> String {
        let html = String(decoding: data, as: UTF8.self)
        let paragraphs = elements(named: "p", in: html)
            .map(plainText)
            .filter { $0.range(of: "error", options: .caseInsensitive) != nil }
        if !paragraphs.isEmpty {
            return truncate(paragraphs.joined(separator: " "), to: 400)
        }
        for tag in ["title", "h1", "h2"] {
            if let text = elements(named: tag, in: html).map(plainText).first(where: { !$0.isEmpty }) {
                return truncate(text, to: 400)
            }
        }
        let text = plainText(html)
        return text.isEmpty ? "HTML-ответ без описания" : truncate(text, to: 200)
    }

    // MARK: - Private helpers

    static var excludedHighwayRegex: String {
        "^(" + excludedHighwayValues.joined(separator: "|") + ")$"
    }

    /// Radius in whole metres (Overpass accepts decimals, but integers keep queries cacheable).
    static func meters(_ value: Double) -> String {
        guard value.isFinite else { return "30" }
        return String(Int(max(1, value.rounded())))
    }

    /// "lat,lon,lat,lon,…" with 6 decimals (≈ 0.1 m) and a '.' separator regardless of locale.
    static func coordinates(_ points: [GeoPoint]) -> String {
        points.map { String(format: "%.6f,%.6f", $0.latitude, $0.longitude) }.joined(separator: ",")
    }

    private static func firstSignificantByte(_ data: Data) -> UInt8? {
        var index = data.startIndex
        // Skip a UTF-8 BOM.
        if data.count >= 3, data[index] == 0xEF, data[index + 1] == 0xBB, data[index + 2] == 0xBF {
            index += 3
        }
        while index < data.endIndex {
            let b = data[index]
            if b != 0x20 && b != 0x09 && b != 0x0A && b != 0x0D { return b }
            index += 1
        }
        return nil
    }

    /// Inner HTML of every `<name ...>…</name>` element (case-insensitive, non-nested).
    private static func elements(named name: String, in html: String) -> [String] {
        var results: [String] = []
        var searchRange = html.startIndex..<html.endIndex
        while let open = html.range(of: "<\(name)", options: .caseInsensitive, range: searchRange) {
            // The tag name must end here (avoid matching <pre> for <p>).
            guard open.upperBound < html.endIndex else { break }
            let next = html[open.upperBound]
            guard next == ">" || next == " " || next == "\t" || next == "\n" || next == "\r" else {
                searchRange = open.upperBound..<html.endIndex
                continue
            }
            guard let tagEnd = html.range(of: ">", range: open.upperBound..<html.endIndex) else { break }
            guard let close = html.range(of: "</\(name)", options: .caseInsensitive,
                                         range: tagEnd.upperBound..<html.endIndex) else {
                results.append(String(html[tagEnd.upperBound...]))
                break
            }
            results.append(String(html[tagEnd.upperBound..<close.lowerBound]))
            searchRange = close.upperBound..<html.endIndex
        }
        return results
    }

    /// Removes tags, decodes the common entities and collapses whitespace.
    private static func plainText(_ html: String) -> String {
        var text = ""
        var inTag = false
        for ch in html {
            if ch == "<" { inTag = true; text.append(" "); continue }
            if ch == ">" { inTag = false; continue }
            if !inTag { text.append(ch) }
        }
        let entities = ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&amp;": "&"]
        for (entity, value) in entities {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        let words = text.split(whereSeparator: { $0.isWhitespace })
        var joined = words.joined(separator: " ")
        // "Error : line 1" → "Error: line 1" (artefact of removing <strong>…</strong>).
        joined = joined.replacingOccurrences(of: " :", with: ":")
        return joined
    }

    private static func truncate(_ s: String, to length: Int) -> String {
        s.count <= length ? s : String(s.prefix(length)) + "…"
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .dataCorrupted(let ctx): return ctx.debugDescription
        case .keyNotFound(let key, _): return "нет поля \(key.stringValue)"
        case .typeMismatch(_, let ctx): return "неверный тип: \(ctx.debugDescription)"
        case .valueNotFound(_, let ctx): return "нет значения: \(ctx.debugDescription)"
        @unknown default: return String(describing: error)
        }
    }
}
