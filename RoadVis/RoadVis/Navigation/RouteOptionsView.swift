import SwiftUI

/// Route preview panel: compact cards for every distinct option (time, delta to the fastest, distance, arrival,
/// engine badges, signals, max / average limit, share of main roads, tolls / highways), the selected route's strip,
/// a summary of what lies on it, the routing notice, "Сравнить" (detailed comparison sheet), "Поехали" and "Отмена".
struct RouteOptionsView: View {
    @Environment(AppState.self) private var app
    @State private var showsComparison = false

    var body: some View {
        let nav = app.navigation
        VStack(alignment: .leading, spacing: 8) {
            header(nav)

            if let notice = nav.routingNotice {
                Label(notice, systemImage: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    let fastest = nav.routeOptions.map(\.expectedTravelTime).min() ?? 0
                    ForEach(nav.routeOptions) { option in
                        RouteOptionCard(option: option, facts: nav.facts(for: option), fastestTime: fastest,
                                        isSelected: option.id == nav.selectedRouteOption?.id)
                            .onTapGesture { nav.selectedRouteID = option.id }
                            .accessibilityAddTraits(.isButton)
                    }
                }
            }
            .frame(maxHeight: nav.routeOptions.count > 2 ? 250 : nil)
            .fixedSize(horizontal: false, vertical: nav.routeOptions.count <= 2)

            if let option = nav.selectedRouteOption {
                RouteStripView(totalDistance: nav.routeLength, distanceAlong: 0, segments: nav.speedLimitSegments,
                               events: nav.timeline, showsPosition: false, height: 6)
                RouteContentSummary(events: nav.timeline, option: option)
            }
            dataStatus(nav)

            HStack(spacing: 8) {
                Button {
                    showsComparison = true
                } label: {
                    Label(L("routes.compare"), systemImage: "list.bullet.rectangle")
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 50)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: RVTheme.Radius.control))

                Button {
                    app.startDrive()
                } label: {
                    Label(L("routes.go"), systemImage: "location.north.line.fill")
                        .font(.title3.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .buttonBorderShape(.roundedRectangle(radius: RVTheme.Radius.control))
                .disabled(nav.selectedRouteOption == nil)
            }
            OpenInWazeButton(prominent: true)
        }
        .padding(12)
        .rvGlass(cornerRadius: RVTheme.Radius.card)
        .sheet(isPresented: $showsComparison) {
            RouteComparisonSheet()
                .presentationDetents([.medium, .large])
        }
    }

    private func header(_ nav: NavigationService) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(l: "routes.header", nav.routeOptions.count)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(verbatim: nav.destinationName ?? L("weather.destination"))
                    .font(.headline)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                nav.stopNavigation()
            } label: {
                Text(l: "common.cancel")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
        }
    }

    @ViewBuilder
    private func dataStatus(_ nav: NavigationService) -> some View {
        if nav.isLoadingRouteAttributes || app.roadInfo.isLoadingRouteFeatures {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(l: "routes.loadingAttributes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if let problem = nav.routeAttributesError ?? app.roadInfo.routeFeaturesCoverageNote {
            Label(problem, systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
    }
}

/// "На маршруте: 12 светофоров · 2 камеры · 3 школы · 4 АЗС" for the selected option.
struct RouteContentSummary: View {
    let events: [RouteTimelineEvent]
    let option: RouteOption

    var body: some View {
        let items = summaryItems
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items) { item in
                        Label("\(item.count)", systemImage: item.symbol)
                            .font(RVTheme.font(11, weight: .semibold))
                            .foregroundStyle(item.color)
                            .accessibilityLabel("\(item.label): \(item.count)")
                    }
                }
            }
        }
    }

    private struct Item: Identifiable {
        let symbol: String
        let count: Int
        let color: Color
        let label: String
        var id: String { symbol }
    }

    private var summaryItems: [Item] {
        func count(_ predicate: (RouteTimelineKind) -> Bool) -> Int { events.filter { predicate($0.kind) }.count }
        var items: [Item] = []
        let signals = count { $0 == .trafficSignal }
        if signals > 0 { items.append(Item(symbol: "light.beacon.max", count: signals, color: .orange, label: L("settings.signal.title"))) }
        let pairs: [(RouteFeatureKind, String)] = [(.speedCamera, L("routes.sum.cameras")), (.school, L("routes.sum.schools")),
                                                   (.kindergarten, L("routes.sum.kindergartens")),
                                                   (.pedestrianCrossing, L("routes.sum.crossings")),
                                                   (.trafficCalming, L("routes.sum.bumps")),
                                                   (.railwayCrossing, L("routes.sum.railway")),
                                                   (.construction, L("feature.construction")), (.fuel, L("feature.fuel")),
                                                   (.parking, L("routes.sum.parkings"))]
        for (kind, label) in pairs {
            let n = kind == .speedCamera ? count { $0.isSpeedCamera } : count { $0 == .feature(kind) }
            if n > 0 {
                items.append(Item(symbol: kind.symbolName, count: n, color: NavigatorStyle.eventColor(.feature(kind)),
                                  label: label))
            }
        }
        let maneuvers = count { if case .maneuver = $0 { return true } else { return false } }
        if maneuvers > 0 {
            items.append(Item(symbol: "arrow.triangle.turn.up.right.diamond", count: maneuvers, color: .white,
                              label: L("routes.sum.maneuvers")))
        }
        return items
    }
}

/// One alternative in `RouteOptionsView`.
private struct RouteOptionCard: View {
    let option: RouteOption
    let facts: RouteFacts
    let fastestTime: Double
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(RVFormat.appDuration(option.expectedTravelTime))
                    .font(RVTheme.font(22, weight: .bold))
                    .monospacedDigit()
                if let delta = RouteComparison.delayText(option.expectedTravelTime, comparedTo: fastestTime, language: .app) {
                    Text(delta)
                        .font(RVTheme.font(12, weight: .bold))
                        .foregroundStyle(RVTheme.caution)
                } else {
                    Text(l: "routes.fastest")
                        .font(RVTheme.font(11, weight: .bold))
                        .foregroundStyle(RVTheme.safe)
                }
                Text(RVFormat.appDistance(option.distance))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(RVFormat.clock(Date().addingTimeInterval(option.expectedTravelTime)))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? RVTheme.accent : Color.secondary)
            }
            Text(option.name)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(option.sources, id: \.self) { EngineBadge(source: $0) }
                    if let signals = facts.signalCount {
                        RVBadge(text: "\(signals)", color: .orange, systemImage: "light.beacon.max")
                            .accessibilityLabel(L("routes.signals.a11y", signals))
                    }
                    if let maxLimit = facts.maxSpeedLimitKmh {
                        RVBadge(text: L("routes.upTo", maxLimit), color: NavigatorStyle.speedLimitColor(maxLimit), systemImage: "speedometer")
                            .accessibilityLabel(L("routes.maxLimit.a11y", maxLimit))
                    }
                    if let share = facts.primaryRoadShare {
                        RVBadge(text: L("routes.mainShare", Int((share * 100).rounded())), color: .teal, systemImage: "road.lanes")
                    }
                    if facts.hasTolls { RVBadge(text: L("routes.toll"), color: .yellow, systemImage: "dollarsign.circle") }
                    if facts.hasHighways { RVBadge(text: L("routes.highways"), color: .teal, systemImage: "car.rear.road.lane") }
                    if let unpaved = facts.unpavedShare, unpaved >= 0.05 {
                        RVBadge(text: L("routes.unpavedShare", Int((unpaved * 100).rounded())), color: .brown, systemImage: "exclamationmark.triangle")
                    }
                }
            }
            if let traffic = option.traffic {
                Label("Apple Maps: \(traffic.localizedSummary)", systemImage: "car.2.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(NavigatorStyle.congestionColor(traffic.level))
            } else if !option.source.mayIncludeTraffic {
                Text(l: "routes.osmTimeNote")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(option.route.advisories.prefix(2).enumerated()), id: \.offset) { _, advisory in
                Label(advisory, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(isSelected ? RVTheme.accent.opacity(0.2) : Color.white.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: RVTheme.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RVTheme.Radius.control, style: .continuous)
                .strokeBorder(isSelected ? RVTheme.accent : Color.clear, lineWidth: RVTheme.Stroke.selected)
        )
        .contentShape(RoundedRectangle(cornerRadius: RVTheme.Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityValue(isSelected ? L("routes.selected") : "")
    }
}

/// Detailed side-by-side comparison of all options, comparison notes, engine outcomes and the speed-limit legend.
struct RouteComparisonSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let nav = app.navigation
        NavigationStack {
            List {
                Section(L("routes.options")) {
                    let fastest = nav.routeOptions.map(\.expectedTravelTime).min() ?? 0
                    ForEach(nav.routeOptions) { option in
                        comparisonRow(option, facts: nav.facts(for: option), fastest: fastest,
                                      isSelected: option.id == nav.selectedRouteOption?.id)
                            .contentShape(Rectangle())
                            .onTapGesture { nav.selectedRouteID = option.id }
                    }
                }
                if !nav.comparisonNotes.isEmpty {
                    Section(L("routes.notes")) {
                        ForEach(nav.comparisonNotes, id: \.self) { note in
                            Text(note).font(.footnote)
                        }
                    }
                }
                Section {
                    ForEach(nav.engineReports) { report in
                        Label(report.summary, systemImage: report.isSuccess ? "checkmark.circle" : "xmark.circle")
                            .font(.footnote)
                            .foregroundStyle(report.isSuccess ? Color.primary : Color.secondary)
                    }
                } header: {
                    Text(l: "routes.sources")
                } footer: {
                    Text(l: "routes.sources.footer")
                }
                Section(L("nav.speedLimitColors")) {
                    SpeedLimitLegend()
                }
            }
            .navigationTitle(L("routes.comparison"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.done")) { dismiss() }
                }
            }
        }
    }

    private func comparisonRow(_ option: RouteOption, facts: RouteFacts, fastest: Double, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(option.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                if isSelected { Image(systemName: "checkmark.circle.fill").foregroundStyle(RVTheme.accent) }
            }
            HStack(spacing: 5) {
                ForEach(option.sources, id: \.self) { EngineBadge(source: $0) }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                row(L("routes.row.time"), RVFormat.appDuration(option.expectedTravelTime)
                    + (RouteComparison.delayText(option.expectedTravelTime, comparedTo: fastest, language: .app).map { " (\($0))" } ?? ""))
                ForEach(option.alsoFoundBy, id: \.self) { estimate in
                    row("  \(estimate.source.badge)", "≈ \(RVFormat.appDuration(estimate.expectedTravelTime)), "
                        + RVFormat.appDistance(estimate.distance))
                }
                row(L("routes.row.distance"), RVFormat.appDistance(option.distance))
                if let average = facts.averageSpeedKmh { row(L("routes.row.avgSpeed"), L("routes.kmhEstimate", Int(average.rounded()))) }
                row(L("settings.signal.title"), facts.signalCount.map { "\($0)" } ?? L("status.loading"))
                if let maxLimit = facts.maxSpeedLimitKmh { row(L("routes.row.maxLimit"), "\(maxLimit) \(RVFormat.appKmh)") }
                if let avgLimit = facts.averageSpeedLimitKmh {
                    row(L("routes.row.avgLimit"), "≈ \(Int(avgLimit.rounded())) \(RVFormat.appKmh)")
                }
                if let coverage = facts.speedLimitCoverage {
                    row(L("routes.row.limitCoverage"), L("routes.ofLength", Int((coverage * 100).rounded())))
                }
                if let share = facts.primaryRoadShare { row(L("routes.row.mainRoads"), "\(Int((share * 100).rounded()))%") }
                if let unpaved = facts.unpavedShare, unpaved > 0 { row(L("routes.row.unpaved"), "\(Int((unpaved * 100).rounded()))%") }
                row(L("routes.row.maneuvers"), "\(facts.maneuverCount)")
                if facts.tunnelCount > 0 || facts.bridgeCount > 0 {
                    row(L("routes.row.bridges"), "\(facts.bridgeCount) / \(facts.tunnelCount)")
                }
                row(L("routes.row.tollsHighways"), (facts.hasTolls ? L("common.yesLower") : L("common.noLower")) + " / " + (facts.hasHighways ? L("common.yesLower") : L("common.noLower")))
                if let traffic = option.traffic { row(L("routes.row.appleTraffic"), traffic.localizedSummary) }
            }
            .font(.caption)
            ForEach(option.route.advisories, id: \.self) { advisory in
                Label(advisory, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}
