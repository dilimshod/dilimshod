import CoreLocation
import MapKit
import SwiftUI

/// Destination search sheet: text field bound to `PlaceSearchService.query`, live suggestions, free-text results
/// (on Return), recent destinations and a "Ищем…" state. Selecting a place calls `onSelect` with its map item.
struct SearchView: View {
    @Bindable var search: PlaceSearchService
    /// Current position for distance labels (optional).
    var userLocation: GeoPoint?
    var onSelect: (MKMapItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFieldFocused: Bool
    @State private var results: [MKMapItem] = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                List {
                    statusSection
                    if trimmedQuery.isEmpty {
                        recentsSection
                    } else {
                        resultsSection
                        completionsSection
                    }
                }
                .listStyle(.insetGrouped)
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(L("nav.whereTo"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.close")) { dismiss() }
                }
            }
        }
        .onAppear {
            isFieldFocused = true
        }
        .onDisappear {
            searchTask?.cancel()
            search.reset()
        }
        .onChange(of: search.query) { _, _ in
            if !results.isEmpty { results = [] }
        }
    }

    private var trimmedQuery: String {
        search.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Field

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)
            TextField(L("search.placeholder"), text: $search.query)
                .font(.title3)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isFieldFocused)
                .onSubmit { runTextSearch() }
            if !search.query.isEmpty {
                Button {
                    search.query = ""
                    results = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 52)
                }
                .accessibilityLabel(L("search.clear"))
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Sections

    @ViewBuilder
    private var statusSection: some View {
        if search.isSearching {
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(l: "search.searching")
                        .font(.headline)
                }
                .frame(minHeight: 52)
            }
        } else if let error = search.errorMessage {
            Section {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(minHeight: 52)
            }
        }
    }

    @ViewBuilder
    private var recentsSection: some View {
        if search.recents.isEmpty {
            Section {
                Text(l: "search.empty")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 52, alignment: .leading)
            }
        } else {
            Section {
                ForEach(search.recents) { recent in
                    Button {
                        select(search.mapItem(for: recent))
                    } label: {
                        row(title: recent.name, subtitle: recent.subtitle, systemImage: "clock.arrow.circlepath",
                            distance: distance(to: recent.coordinate))
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    let items = offsets.map { search.recents[$0] }
                    items.forEach { search.removeRecent($0) }
                }
            } header: {
                HStack {
                    Text(l: "search.recents")
                    Spacer()
                    Button(L("search.clear")) { search.clearRecents() }
                        .font(.caption.weight(.semibold))
                        .textCase(nil)
                }
            }
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        if !results.isEmpty {
            Section(L("search.results")) {
                ForEach(results, id: \.self) { item in
                    Button {
                        select(item)
                    } label: {
                        row(title: PlaceSearchService.displayName(for: item),
                            subtitle: PlaceSearchService.subtitle(for: item),
                            systemImage: "mappin.circle.fill",
                            distance: distance(to: GeoPoint(item.placemark.coordinate)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var completionsSection: some View {
        if !search.completions.isEmpty {
            Section(L("search.suggestions")) {
                ForEach(search.completions, id: \.self) { completion in
                    Button {
                        resolve(completion)
                    } label: {
                        row(title: completion.title,
                            subtitle: completion.subtitle.isEmpty ? nil : completion.subtitle,
                            systemImage: completion.subtitle.isEmpty ? "magnifyingglass" : "mappin.and.ellipse",
                            distance: nil)
                    }
                    .buttonStyle(.plain)
                    .disabled(search.isSearching)
                }
            }
        } else if search.isCompleting {
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(l: "search.loadingSuggestions")
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 52)
            }
        } else if results.isEmpty, !search.isSearching {
            Section {
                Button {
                    runTextSearch()
                } label: {
                    row(title: L("search.searchFor", trimmedQuery), subtitle: nil, systemImage: "magnifyingglass", distance: nil)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func row(title: String, subtitle: String?, systemImage: String, distance: Double?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let distance {
                Text(RVFormat.appDistance(distance))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

    // MARK: Actions

    private func distance(to point: GeoPoint) -> Double? {
        guard let userLocation, userLocation.isValid, point.isValid else { return nil }
        return Geo.distance(userLocation, point)
    }

    private func runTextSearch() {
        let text = trimmedQuery
        guard !text.isEmpty else { return }
        searchTask?.cancel()
        searchTask = Task {
            do {
                let items = try await search.search(text)
                guard !Task.isCancelled else { return }
                results = items
            } catch {
                // The service publishes a Russian `errorMessage`.
            }
        }
    }

    private func resolve(_ completion: MKLocalSearchCompletion) {
        searchTask?.cancel()
        searchTask = Task {
            do {
                let item = try await search.resolve(completion)
                guard !Task.isCancelled else { return }
                select(item)
            } catch {
                // The service publishes a Russian `errorMessage`.
            }
        }
    }

    private func select(_ item: MKMapItem) {
        isFieldFocused = false
        onSelect(item)
        dismiss()
    }
}
