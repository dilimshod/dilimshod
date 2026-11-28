import MapKit
import SwiftUI

/// «Open route in Waze»: hands the destination (point B) to Waze through its universal link
/// (`ExternalNavigation.wazeURL`), which opens the Waze app when installed and the Waze website / App Store otherwise.
/// Waze builds its own route there. Hidden when the setting «Show “Open in Waze” button» is off or there is no
/// valid destination.
struct OpenInWazeButton: View {
    /// Larger, full-width style for the route options; compact for the trip panel.
    var prominent = false

    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL

    var body: some View {
        if app.settings.showWazeButton, let url = wazeURL {
            Button {
                openURL(url)
            } label: {
                Label(L("waze.open"), systemImage: "arrow.up.forward.app")
                    .font(prominent ? .subheadline.weight(.semibold) : .footnote.weight(.semibold))
                    .frame(maxWidth: prominent ? .infinity : nil, minHeight: prominent ? 44 : 32)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.bordered)
            .tint(.cyan)
            .buttonBorderShape(.roundedRectangle(radius: RVTheme.Radius.control))
            .frame(minHeight: 44)
            .accessibilityHint(L("waze.open.hint"))
        }
    }

    private var wazeURL: URL? {
        guard let item = app.navigation.destination else { return nil }
        return ExternalNavigation.wazeURL(destination: GeoPoint(item.placemark.coordinate))
    }
}
