import Foundation
import MapKit

/// Free raster tile sources built from OpenStreetMap data, used as the navigator's base map.
///
/// Usage policies:
/// - tile.openstreetmap.org — https://operations.osmfoundation.org/policies/tiles/ : identifying User-Agent, honour
///   HTTP caching (`Cache-Control` / `Expires` / `ETag`), no bulk download / prefetch / offline areas, visible
///   "© OpenStreetMap contributors" attribution linking to the copyright page.
/// - basemaps.cartocdn.com — free for light, non-commercial use with "© OpenStreetMap contributors © CARTO".
enum OSMTileSource: String, CaseIterable, Sendable {
    case openStreetMap
    case cartoDark
    case cartoVoyager

    /// URL template: `{z}/{x}/{y}` tile path, `{r}` = "@2x" on retina screens (CARTO only).
    var urlTemplate: String {
        switch self {
        case .openStreetMap: return "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
        case .cartoDark: return "https://basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png"
        case .cartoVoyager: return "https://basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png"
        }
    }

    /// Highest zoom level requested (the map scales the z19 tiles beyond it).
    var maximumZ: Int { 19 }

    /// True when the source uses CARTO's servers / styles ("© CARTO" attribution).
    var isCARTO: Bool { self != .openStreetMap }

    /// Dark tiles: the map uses the dark interface style so MapKit's own controls stay readable.
    var isDark: Bool { self == .cartoDark }

    static let osmCopyrightURL = URL(string: "https://www.openstreetmap.org/copyright")!
    static let cartoAttributionsURL = URL(string: "https://carto.com/attributions")!
}

/// Base-map tile overlay for an `OSMTileSource` (`canReplaceMapContent = true`, so Apple's map, labels and POIs are
/// not drawn underneath).
///
/// Tiles are fetched by `OSMTileOverlay.session`, not by MapKit's default loader, so every request carries the
/// app's identifying User-Agent and goes through a 100 MB on-disk `URLCache` that follows the server's cache headers
/// (`.useProtocolCachePolicy`: fresh tiles come from disk, stale ones are revalidated with `If-None-Match` /
/// `If-Modified-Since`). MapKit asks only for tiles of the visible area; nothing is prefetched or bulk-downloaded.
///
/// Tile size stays 256: standard OSM tiles are 256 px (MapKit scales them on retina); CARTO tiles are requested
/// as 512 px "@2x" images on retina screens, which MapKit draws into the same 256-point tile for sharp text.
final class OSMTileOverlay: MKTileOverlay {
    let source: OSMTileSource

    /// Identifying User-Agent required by the OSM tile usage policy (stable product name + contact URL).
    static let userAgent = "RoadVis-iOS/1.0 (+https://github.com/dilimshod/dilimshod)"

    /// Shared session with a persistent disk cache (Library/Caches/OSMTiles) for all tile sources.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let cache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 100 * 1024 * 1024,
                             directory: cachesDirectory?.appendingPathComponent("OSMTiles", isDirectory: true))
        configuration.urlCache = cache
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    init(source: OSMTileSource) {
        self.source = source
        super.init(urlTemplate: source.urlTemplate)
        canReplaceMapContent = true
        minimumZ = 0
        maximumZ = source.maximumZ
        tileSize = CGSize(width: 256, height: 256)
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        let retina = path.contentScaleFactor >= 2
        let string = source.urlTemplate
            .replacingOccurrences(of: "{z}", with: String(path.z))
            .replacingOccurrences(of: "{x}", with: String(path.x))
            .replacingOccurrences(of: "{y}", with: String(path.y))
            .replacingOccurrences(of: "{r}", with: retina ? "@2x" : "")
        // The templates are constants, so this never fails; fall back to the template's host just in case.
        return URL(string: string) ?? URL(string: "https://tile.openstreetmap.org/0/0/0.png")!
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        var request = URLRequest(url: url(forTilePath: path), cachePolicy: .useProtocolCachePolicy,
                                 timeoutInterval: 20)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let task = Self.session.dataTask(with: request) { data, response, error in
            if let error {
                result(nil, error)
                return
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result(nil, URLError(.badServerResponse))
                return
            }
            result(data, nil)
        }
        task.resume()
    }
}
