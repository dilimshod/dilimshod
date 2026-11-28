import SwiftUI

// MARK: - App description

/// What RoadVis is and does (trilingual).
struct AppDescriptionView: View {
    private let localization = LocalizationManager.shared

    private let features: [(icon: String, key: String)] = [
        ("car.2.fill", "desc.f.vehicles"),
        ("arrow.left.and.right", "desc.f.distance"),
        ("light.beacon.max", "desc.f.lights"),
        ("exclamationmark.triangle", "desc.f.signs"),
        ("road.lanes", "desc.f.lanes"),
        ("speaker.wave.2.fill", "desc.f.voice"),
        ("map.fill", "desc.f.navigator"),
        ("chart.bar.doc.horizontal", "desc.f.reports"),
    ]

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        AboutAppBadge(size: 60)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(l: "desc.title")
                                .font(.title2.weight(.bold))
                            Text(l: "desc.tagline")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(l: "desc.intro")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            Section {
                ForEach(features, id: \.key) { feature in
                    Label {
                        Text(l: feature.key)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: feature.icon)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            } header: {
                Text(l: "desc.featuresHeader")
            }

            Section {
                Label {
                    Text(l: "desc.privacy")
                } icon: {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.green)
                }
                Label {
                    Text(l: "desc.safety")
                } icon: {
                    Image(systemName: "exclamationmark.octagon")
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle(L("about.description"))
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.locale, localization.locale)
    }
}

// MARK: - Public offer (oferta)

/// Public offer / terms of use (trilingual). Template text — marked as not legal advice.
struct OfferView: View {
    private let localization = LocalizationManager.shared

    /// Apple's required MapKit route-guidance disclaimer — shown verbatim in English in every language.
    static let mapKitDisclaimer = "YOUR USE OF THIS REAL TIME ROUTE GUIDANCE APPLICATION IS AT YOUR SOLE RISK. LOCATION DATA MAY NOT BE ACCURATE."

    private let sectionNumbers = 1...9

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(l: "offer.title")
                        .font(.title2.weight(.bold))
                    Text(l: "offer.subtitle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Label {
                    Text(l: "offer.templateNote")
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle.fill")
                }
                .foregroundStyle(.orange)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.15)))

                ForEach(Array(sectionNumbers), id: \.self) { number in
                    AboutParagraph(L("offer.s\(number).body"), title: L("offer.s\(number).title"))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(l: "offer.mapkitHeader")
                        .font(.headline)
                    Text(verbatim: Self.mapKitDisclaimer)
                        .font(.footnote.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Developer.all) { developer in
                        Link(destination: developer.telegramURL) {
                            Label {
                                Text(verbatim: "\(developer.name) — \(developer.telegramHandle)")
                            } icon: {
                                Image(systemName: "paperplane.fill")
                            }
                        }
                    }
                }
                .font(.subheadline)
            }
            .padding()
            .textSelection(.enabled)
        }
        .navigationTitle(L("about.offer"))
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.locale, localization.locale)
    }
}

// MARK: - Developers

/// A developer of RoadVis shown on the Developers screen.
struct Developer: Identifiable {
    let id: String
    /// Proper name — kept in Latin script in every language.
    let name: String
    let roleKey: String
    let telegramHandle: String
    let initials: String

    var telegramURL: URL {
        URL(string: "https://t.me/\(telegramHandle.trimmingCharacters(in: CharacterSet(charactersIn: "@")))")
            ?? URL(fileURLWithPath: "/")
    }

    static let all: [Developer] = [
        Developer(id: "dilimshod", name: "Dilshod Imamaliyev", roleKey: "dev.dilshod.role",
                  telegramHandle: "@dilimshod", initials: "DI"),
        Developer(id: "engineer_iroad", name: "Soataliyev Raximjon", roleKey: "dev.raximjon.role",
                  telegramHandle: "@engineer_iroad", initials: "SR"),
    ]
}

/// About the developers: names, roles, Telegram links (t.me/dilimshod, t.me/engineer_iroad).
struct DevelopersView: View {
    private let localization = LocalizationManager.shared

    var body: some View {
        List {
            Section {
                Text(l: "dev.intro")
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Developer.all) { developer in
                Section {
                    HStack(alignment: .top, spacing: 14) {
                        Circle()
                            .fill(Color.accentColor.opacity(0.25))
                            .frame(width: 48, height: 48)
                            .overlay(
                                Text(verbatim: developer.initials)
                                    .font(.headline)
                                    .foregroundStyle(Color.accentColor)
                            )
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: developer.name)
                                .font(.headline)
                            Text(l: developer.roleKey)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)

                    Link(destination: developer.telegramURL) {
                        Label {
                            Text(verbatim: "\(L("dev.telegram")): \(developer.telegramHandle)")
                        } icon: {
                            Image(systemName: "paperplane.fill")
                        }
                    }
                }
            }
            Section {
                Text(l: "dev.contactNote")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L("dev.title"))
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.locale, localization.locale)
    }
}

// MARK: - Data sources & licences

/// Data sources, licences and the safety notice (trilingual).
struct DataSourcesView: View {
    private let localization = LocalizationManager.shared

    var body: some View {
        List {
            Section {
                row("sources.maps.title", "sources.maps.detail")
                VStack(alignment: .leading, spacing: 6) {
                    row("sources.basemap.title", "sources.basemap.detail")
                    Link("openfreemap.org", destination: MapLibreBaseMap.openFreeMapURL)
                        .font(.footnote)
                }
                VStack(alignment: .leading, spacing: 6) {
                    row("sources.osm.title", "sources.osm.detail")
                    if let copyright = URL(string: "https://www.openstreetmap.org/copyright") {
                        Link(L("sources.osm.copyright"), destination: copyright)
                            .font(.footnote)
                    }
                    if let fixTheMap = URL(string: "https://www.openstreetmap.org/fixthemap") {
                        Link(L("sources.osm.fix"), destination: fixTheMap)
                            .font(.footnote)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    row("sources.weather.title", "sources.weather.detail")
                    if let openMeteo = URL(string: "https://open-meteo.com/") {
                        Link("open-meteo.com", destination: openMeteo)
                            .font(.footnote)
                    }
                }
                row("sources.yolo.title", "sources.yolo.detail")
                row("sources.speech.title", "sources.speech.detail")
            } header: {
                Text(l: "sources.title")
            }

            Section {
                Text(l: "sources.safety.body")
                    .font(.footnote)
                Text(verbatim: OfferView.mapKitDisclaimer)
                    .font(.footnote.weight(.semibold))
            } header: {
                Text(l: "sources.safety.header")
            }
        }
        .navigationTitle(L("about.sources"))
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.locale, localization.locale)
    }

    private func row(_ titleKey: String, _ detailKey: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(l: titleKey)
                .font(.subheadline.weight(.semibold))
            Text(l: detailKey)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
