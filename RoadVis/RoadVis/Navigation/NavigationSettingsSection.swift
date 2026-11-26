import SwiftUI

/// Settings sections of the navigator («Карта», «Маршрутизация», «Пробки», «Источники камер и событий»). Its body consists of `Section`s only, so it is
/// meant to be placed inside the `Form` of `SettingsView`.
struct NavigationSettingsSection: View {
    @Environment(AppState.self) private var app
    @AppStorage(NavigatorSettingsKeys.osrmEndpoint) private var osrmEndpoint = OSRM.defaultEndpoint
    @AppStorage(NavigatorSettingsKeys.mapStyle) private var mapStyleRaw = NavigatorMapStyle.default.rawValue

    var body: some View {
        @Bindable var settings = app.settings
        let mapStyle = NavigatorMapStyle.resolve(mapStyleRaw)

        Section {
            Picker(L("nav.mapLayer"), selection: Binding(get: { mapStyle.rawValue }, set: { mapStyleRaw = $0 })) {
                ForEach(NavigatorMapStyle.allCases) { option in
                    Label(option.displayName, systemImage: option.symbolName).tag(option.rawValue)
                }
            }
            .pickerStyle(.inline)
        } header: {
            Text(l: "navset.map")
        } footer: {
            Text(l: "navset.map.footer")
        }

        Section {
            Picker(L("navset.engine"), selection: $settings.routingEngine) {
                ForEach(RoutingEngineOption.allCases) { engine in
                    Text(engine.displayName).tag(engine.rawValue)
                }
            }
            .pickerStyle(.inline)

            VStack(alignment: .leading, spacing: 6) {
                Text(l: "navset.valhallaServer")
                    .font(.subheadline.weight(.semibold))
                TextField(Valhalla.defaultEndpoint, text: $settings.valhallaEndpoint)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                if ValhallaClient.url(endpoint: settings.valhallaEndpoint, path: "route") == nil {
                    Label(L("navset.badURL"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 4)

            if settings.valhallaEndpoint != Valhalla.defaultEndpoint {
                Button(L("navset.resetValhalla")) {
                    settings.valhallaEndpoint = Valhalla.defaultEndpoint
                }
                .frame(minHeight: 44)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(l: "navset.osrmServer")
                    .font(.subheadline.weight(.semibold))
                TextField(OSRM.defaultEndpoint, text: $osrmEndpoint)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                if OSRM.routeURL(endpoint: osrmEndpoint, from: GeoPoint(41.3, 69.2), to: GeoPoint(41.31, 69.21)) == nil {
                    Label(L("navset.badOSRMURL"),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 4)

            if osrmEndpoint != OSRM.defaultEndpoint {
                Button(L("navset.resetOSRM")) {
                    osrmEndpoint = OSRM.defaultEndpoint
                }
                .frame(minHeight: 44)
            }

            Toggle(L("navset.routeAttributes"),
                   isOn: $settings.routeAttributesEnabled)
                .frame(minHeight: 44)
        } header: {
            Text(l: "navset.routing")
        } footer: {
            Text(l: "navset.routing.footer")
        }

        Section {
            // Apple traffic is drawn only on the Apple «Гибрид» layer (not over OSM tiles or plain imagery).
            if mapStyle == .hybrid {
                Toggle(L("navset.appleTraffic"), isOn: $settings.showTrafficOnMap)
                    .frame(minHeight: 44)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(l: "navset.customTiles")
                    .font(.subheadline.weight(.semibold))
                TextField("https://…/{z}/{x}/{y}.png", text: $settings.trafficTileTemplate)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                if let problem = tileTemplateProblem(settings.trafficTileTemplate) {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 4)

            if !settings.trafficTileTemplate.isEmpty {
                Button(L("navset.customTiles.off"), role: .destructive) {
                    settings.trafficTileTemplate = ""
                }
                .frame(minHeight: 44)
            }
        } header: {
            Text(l: "navset.traffic")
        } footer: {
            Text(l: "navset.traffic.footer")
        }

        CameraSourcesSettingsSection()
    }

    /// Localized problem description for a non-empty, invalid tile template; nil when empty or valid.
    private func tileTemplateProblem(_ template: String) -> String? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") {
            return L("navset.tiles.http")
        }
        if !lower.hasPrefix("https://") {
            return L("navset.tiles.https")
        }
        let missing = ["{z}", "{x}", "{y}"].filter { !trimmed.contains($0) }
        if !missing.isEmpty {
            return L("navset.tiles.missing", missing.joined(separator: ", "))
        }
        return nil
    }
}

/// «Источники камер и событий»: the «Open in Waze» button, speed cameras from OpenStreetMap and the user's own marks
/// of cameras and events (with deleting them). Waze / ContraCam data cannot be embedded, hence the hand-off to Waze.
private struct CameraSourcesSettingsSection: View {
    @Environment(AppState.self) private var app
    @State private var confirmsDeletingMarks = false

    var body: some View {
        @Bindable var settings = app.settings
        let marks = app.incidents.incidents.count
        Section {
            Toggle(L("navset.sources.waze"), isOn: $settings.showWazeButton)
                .frame(minHeight: 44)
            Toggle(L("navset.sources.osmCameras"), isOn: $settings.osmCamerasEnabled)
                .frame(minHeight: 44)
                .onChange(of: settings.osmCamerasEnabled) { app.navigation.applyDataSourceSettings() }
            Toggle(L("navset.sources.ownMarks"), isOn: $settings.ownMarksEnabled)
                .frame(minHeight: 44)
                .onChange(of: settings.ownMarksEnabled) { app.navigation.applyDataSourceSettings() }
            if marks > 0 {
                Button(L("navset.sources.deleteMarks", marks), role: .destructive) {
                    confirmsDeletingMarks = true
                }
                .frame(minHeight: 44)
                .confirmationDialog(L("navset.sources.deleteMarks.confirm"), isPresented: $confirmsDeletingMarks,
                                    titleVisibility: .visible) {
                    Button(L("navset.sources.deleteMarks.action"), role: .destructive) {
                        app.incidents.removeAll()
                        app.navigation.refreshIncidents()
                    }
                    Button(L("common.cancel"), role: .cancel) {}
                }
            }
        } header: {
            Text(l: "navset.sources")
        } footer: {
            Text(l: "navset.sources.footer")
        }
    }
}
