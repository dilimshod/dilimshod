import SwiftUI

/// Settings sections of the navigator («Маршрутизация», «Пробки»). Its body consists of `Section`s only, so it is
/// meant to be placed inside the `Form` of `SettingsView`.
struct NavigationSettingsSection: View {
    @Environment(AppState.self) private var app
    @AppStorage(NavigatorSettingsKeys.osrmEndpoint) private var osrmEndpoint = OSRM.defaultEndpoint

    var body: some View {
        @Bindable var settings = app.settings

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
            Toggle(L("navset.appleTraffic"), isOn: $settings.showTrafficOnMap)
                .frame(minHeight: 44)

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
