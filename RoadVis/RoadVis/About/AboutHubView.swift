import SwiftUI

/// "About" hub: app description, public offer (oferta), developers, data sources & licences, version.
/// Fully trilingual (texts in Localization/Strings+uz/ru/en.swift).
///
/// Present it standalone (sheet / tab): `AboutHubView()` — wraps itself in a `NavigationStack`.
/// Push it from a screen that already has a `NavigationStack` (e.g. Settings):
/// `NavigationLink { AboutHubView(embedInNavigationStack: false) } label: { … }`.
struct AboutHubView: View {
    var embedInNavigationStack: Bool = true

    var body: some View {
        if embedInNavigationStack {
            NavigationStack { AboutHubList() }
        } else {
            AboutHubList()
        }
    }
}

/// The list itself (no navigation container).
struct AboutHubList: View {
    private let localization = LocalizationManager.shared

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    AboutAppBadge()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "RoadVis")
                            .font(.title3.weight(.bold))
                        Text(l: "desc.tagline")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)

                NavigationLink {
                    AppDescriptionView()
                } label: {
                    Label { Text(l: "about.description") } icon: { Image(systemName: "info.circle") }
                }
                NavigationLink {
                    DevelopersView()
                } label: {
                    Label { Text(l: "about.developers") } icon: { Image(systemName: "person.2") }
                }
            } header: {
                Text(l: "about.section.app")
            }

            Section {
                NavigationLink {
                    OfferView()
                } label: {
                    Label { Text(l: "about.offer") } icon: { Image(systemName: "doc.text") }
                }
                NavigationLink {
                    DataSourcesView()
                } label: {
                    Label { Text(l: "about.sources") } icon: { Image(systemName: "map") }
                }
            } header: {
                Text(l: "about.section.legal")
            }

            Section {
                LabeledContent {
                    Text(verbatim: AppVersion.text)
                        .monospacedDigit()
                } label: {
                    Label { Text(l: "about.version") } icon: { Image(systemName: "number") }
                }
            } footer: {
                Text(l: "about.footer")
            }
        }
        .navigationTitle(L("about.title"))
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.locale, localization.locale)
    }
}

/// "1.0 (1)" from the bundle.
enum AppVersion {
    static var text: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}

/// Small rounded app mark used in the About screens.
struct AboutAppBadge: View {
    var size: CGFloat = 52

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [Color.blue, Color.teal], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "car.fill")
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .accessibilityHidden(true)
    }
}

/// Paragraph block used by the About detail screens.
struct AboutParagraph: View {
    let title: String?
    let text: String

    init(_ text: String, title: String? = nil) {
        self.title = title
        self.text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(verbatim: title)
                    .font(.headline)
            }
            Text(verbatim: text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
