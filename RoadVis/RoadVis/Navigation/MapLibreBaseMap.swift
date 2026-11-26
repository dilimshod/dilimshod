import Foundation
import MapLibre
import SwiftUI
import UIKit

/// Base map actually shown by a MapLibre map view.
enum BaseMapSource: Equatable, Sendable {
    /// OpenFreeMap vector tiles ("dark" style, OpenMapTiles schema, OpenStreetMap data).
    case openFreeMap
    /// CARTO "Dark Matter" raster tiles, used only when the OpenFreeMap style cannot be loaded.
    case cartoFallback
}

/// Free base map for the MapLibre map views (navigator and trip report). No API key, no account.
///
/// - Default: the OpenFreeMap "dark" vector style (https://openfreemap.org — free, no registration, no usage limits
///   for reasonable use). Attribution: "© OpenFreeMap © OpenMapTiles © OpenStreetMap contributors".
/// - Fallback (style download failed, `mapViewDidFailLoadingMap`): an inline raster style with CARTO dark tiles
///   (free for light use). Attribution: "© OpenStreetMap contributors © CARTO".
///
/// Tiles, glyphs, sprites and the style are cached by MapLibre in its ambient cache (limited to about 100 MB, see
/// `configureAmbientCache()`); only the visible area is requested, nothing is bulk-downloaded.
enum MapLibreBaseMap {
    static let styleURL = URL(string: "https://tiles.openfreemap.org/styles/dark")!

    static let openFreeMapURL = URL(string: "https://openfreemap.org")!
    static let openMapTilesURL = URL(string: "https://www.openmaptiles.org/")!
    static let osmCopyrightURL = URL(string: "https://www.openstreetmap.org/copyright")!
    static let cartoAttributionsURL = URL(string: "https://carto.com/attributions")!

    /// Maximum size of MapLibre's ambient (automatic) tile cache.
    static let ambientCacheBytes: UInt = 100 * 1024 * 1024

    /// Inline MapLibre style (spec v8) with CARTO "Dark Matter" retina raster tiles over a dark background.
    /// No glyphs or sprites are needed: the app's own symbol layers use icon images only.
    static let fallbackStyleJSON: String = {
        let tiles = ["a", "b", "c", "d"].map { "https://\($0).basemaps.cartocdn.com/dark_all/{z}/{x}/{y}@2x.png" }
        let style: [String: Any] = [
            "version": 8,
            "name": "CARTO Dark Matter (fallback)",
            "sources": [
                "carto-dark": [
                    "type": "raster",
                    "tiles": tiles,
                    "tileSize": 256,
                    "minzoom": 0,
                    "maxzoom": 20,
                    "attribution": "© OpenStreetMap contributors © CARTO",
                ] as [String: Any],
            ],
            "layers": [
                ["id": "background", "type": "background", "paint": ["background-color": "#0e0e10"]] as [String: Any],
                ["id": "carto-dark", "type": "raster", "source": "carto-dark"] as [String: Any],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: style, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"version\":8,\"sources\":{},\"layers\":[]}"
        }
        return json
    }()

    @MainActor private static var ambientCacheConfigured = false

    /// Limits MapLibre's ambient cache to `ambientCacheBytes` (once per launch).
    @MainActor static func configureAmbientCache() {
        guard !ambientCacheConfigured else { return }
        ambientCacheConfigured = true
        MLNOfflineStorage.shared.setMaximumAmbientCacheSize(ambientCacheBytes) { _ in }
    }

    /// "rgba(r, g, b, a)" for style expressions.
    static func rgba(_ color: UIColor) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        if !color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            var white: CGFloat = 0
            if color.getWhite(&white, alpha: &alpha) {
                red = white
                green = white
                blue = white
            } else {
                alpha = 1
            }
        }
        func channel(_ value: CGFloat) -> Int { Int((max(0, min(1, value)) * 255).rounded()) }
        return "rgba(\(channel(red)), \(channel(green)), \(channel(blue)), \(String(format: "%.3f", Double(max(0, min(1, alpha))))))"
    }

    /// GeoJSON `FeatureCollection` → MapLibre shape (nil if the JSON cannot be encoded / parsed).
    static func shape(features: [[String: Any]]) -> MLNShape? {
        let collection: [String: Any] = ["type": "FeatureCollection", "features": features]
        guard JSONSerialization.isValidJSONObject(collection),
              let data = try? JSONSerialization.data(withJSONObject: collection, options: []) else { return nil }
        return try? MLNShape(data: data, encoding: String.Encoding.utf8.rawValue)
    }

    /// GeoJSON LineString feature.
    static func lineFeature(_ points: [GeoPoint], properties: [String: Any] = [:]) -> [String: Any]? {
        let coordinates: [[Double]] = points.filter(\.isValid).map { [$0.longitude, $0.latitude] }
        guard coordinates.count >= 2 else { return nil }
        return ["type": "Feature",
                "geometry": ["type": "LineString", "coordinates": coordinates] as [String: Any],
                "properties": properties]
    }

    /// GeoJSON Point feature.
    static func pointFeature(_ point: GeoPoint, properties: [String: Any]) -> [String: Any]? {
        guard point.isValid else { return nil }
        return ["type": "Feature",
                "geometry": ["type": "Point", "coordinates": [point.longitude, point.latitude]] as [String: Any],
                "properties": properties]
    }
}

// MARK: - Marker images

/// Round map marker images (coloured disc, white rim, SF Symbol glyph or short text) for MapLibre symbol layers.
enum MapMarkerImage {
    /// Disc with an SF Symbol (or `text` when given) in `glyphColor`.
    static func make(color: UIColor, symbolName: String?, text: String? = nil, glyphColor: UIColor = .white,
                     diameter: CGFloat = 26) -> UIImage {
        let rim: CGFloat = diameter >= 24 ? 2 : 1.5
        let shadow: CGFloat = 2
        let side = diameter + shadow * 2
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { context in
            let cg = context.cgContext
            let disc = CGRect(x: shadow, y: shadow, width: diameter, height: diameter)
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: 1), blur: shadow, color: UIColor.black.withAlphaComponent(0.45).cgColor)
            UIColor.white.setFill()
            UIBezierPath(ovalIn: disc).fill()
            cg.restoreGState()
            color.setFill()
            UIBezierPath(ovalIn: disc.insetBy(dx: rim, dy: rim)).fill()

            if let text, !text.isEmpty {
                let fontSize = diameter * (text.count >= 3 ? 0.34 : 0.42)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: fontSize, weight: .heavy),
                    .foregroundColor: glyphColor,
                ]
                let string = NSAttributedString(string: text, attributes: attributes)
                let size = string.size()
                string.draw(at: CGPoint(x: disc.midX - size.width / 2, y: disc.midY - size.height / 2))
            } else if let symbolName {
                let configuration = UIImage.SymbolConfiguration(pointSize: diameter * 0.46, weight: .bold)
                if let glyph = UIImage(systemName: symbolName, withConfiguration: configuration)?
                    .withTintColor(glyphColor, renderingMode: .alwaysOriginal) {
                    let size = glyph.size
                    glyph.draw(in: CGRect(x: disc.midX - size.width / 2, y: disc.midY - size.height / 2,
                                          width: size.width, height: size.height))
                }
            }
        }
    }

    /// Stable, style-image-safe name for a marker look.
    static func name(prefix: String, color: UIColor, symbolName: String?, text: String?, glyphColor: UIColor,
                     diameter: CGFloat) -> String {
        [prefix, MapLibreBaseMap.rgba(color), symbolName ?? "-", text ?? "-", MapLibreBaseMap.rgba(glyphColor),
         String(Int(diameter))].joined(separator: "|")
    }
}

// MARK: - Callout

/// Small callout bubble (title + subtitle) shown above a tapped map marker. Positioned by its owner.
final class MapCalloutBubble: UIView {
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let stack = UIStackView()
    /// Marker coordinate the bubble points at.
    var coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.12, alpha: 0.94)
        layer.cornerRadius = 10
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.4
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)
        isUserInteractionEnabled = false

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2
        titleLabel.preferredMaxLayoutWidth = 240
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        subtitleLabel.numberOfLines = 2
        subtitleLabel.preferredMaxLayoutWidth = 240
        stack.axis = .vertical
        stack.spacing = 2
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(title: String, subtitle: String?) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = (subtitle ?? "").isEmpty
        accessibilityLabel = [title, subtitle].compactMap { $0 }.joined(separator: ", ")
    }

    /// Sizes the bubble (max 260 pt wide) and places its bottom centre `gap` points above `point`.
    func place(above point: CGPoint, gap: CGFloat = 18) {
        let fitting = systemLayoutSizeFitting(CGSize(width: 260, height: UIView.layoutFittingCompressedSize.height),
                                              withHorizontalFittingPriority: .fittingSizeLevel,
                                              verticalFittingPriority: .fittingSizeLevel)
        let width = min(260, max(80, fitting.width))
        let height = systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                                             withHorizontalFittingPriority: .required,
                                             verticalFittingPriority: .fittingSizeLevel).height
        frame = CGRect(x: point.x - width / 2, y: point.y - gap - height, width: width, height: height)
    }
}

// MARK: - Attribution

/// Credits for the MapLibre base map; required while the map is visible.
struct BaseMapAttributionLinks: View {
    let source: BaseMapSource

    var body: some View {
        switch source {
        case .openFreeMap:
            Link(destination: MapLibreBaseMap.openFreeMapURL) { Text(verbatim: "© OpenFreeMap") }
            Link(destination: MapLibreBaseMap.openMapTilesURL) { Text(verbatim: "© OpenMapTiles") }
            Link(L("nav.osmCredit"), destination: MapLibreBaseMap.osmCopyrightURL)
        case .cartoFallback:
            Link(L("nav.osmCredit"), destination: MapLibreBaseMap.osmCopyrightURL)
            Link(destination: MapLibreBaseMap.cartoAttributionsURL) { Text(verbatim: "© CARTO") }
        }
    }
}
