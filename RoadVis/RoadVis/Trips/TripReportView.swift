import Charts
import MapKit
import SwiftUI

/// Report of one trip: map (route, A/B, coloured violation markers), driving score with its formula, numbers,
/// colourful charts (speed vs limit, events by kind, ≈ lead gap vs recommended, time per speed band), the list of all
/// events and the export (PDF + CSV via ShareLink). Works pushed in a NavigationStack (history) or inside
/// `TripReportSheet` (after a recording stops).
struct TripReportView: View {
    let trip: Trip
    @Environment(AppState.self) private var app

    @State private var exportFiles: TripReportExporter.Files?
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var highlightedEventID: UUID?
    @State private var showsFormula = false

    var body: some View {
        let stats = TripStats.compute(trip)
        let score = TripScoring.score(events: trip.events, distanceMeters: stats.distanceMeters)
        let data = TripChartData(trip: trip, stats: stats)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                TripMapView(trip: trip, height: 260, highlightedEventID: highlightedEventID)
                mapLegend
                scoreCard(score)
                TripStatsGrid(trip: trip, stats: stats, columns: 2, compact: false)
                chartCard(title: L("report.speedAndLimit"), systemImage: "speedometer") {
                    TripSpeedChart(data: data)
                    TripSpeedChartLegend()
                    if stats.speedLimitCoverage < 0.999 {
                        Text(l: "report.limitCoverage", Int((stats.speedLimitCoverage * 100).rounded()))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                chartCard(title: L("report.eventsByKind"), systemImage: "chart.bar.fill") {
                    if data.kindCounts.isEmpty {
                        Label(L("report.noEventsGreat"), systemImage: "checkmark.seal.fill")
                            .foregroundStyle(RVTheme.safe)
                    } else {
                        TripEventsByKindChart(data: data)
                    }
                }
                chartCard(title: L("report.leadDistance"), systemImage: "car.2.fill") {
                    if data.hasLeadData {
                        TripLeadDistanceChart(data: data)
                        HStack(spacing: 12) {
                            Label(L("report.legend.lead"), systemImage: "line.diagonal").foregroundStyle(RVTheme.safe)
                            Label(L("report.legend.recommended"), systemImage: "line.diagonal").foregroundStyle(RVTheme.caution)
                        }
                        .font(.caption2)
                        if let share = stats.shareBelowRecommendedGap {
                            Text(l: "report.belowRecommended", Int((share * 100).rounded()))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(l: "report.noLeadDataLong")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                chartCard(title: L("report.timeBySpeed"), systemImage: "chart.pie.fill") {
                    if data.bands.isEmpty {
                        Text(l: "report.noSpeedData").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        TripSpeedBandChart(data: data)
                    }
                }
                eventsList
                exportCard
                Text(l: "report.footer")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 20)
            }
            .padding(.horizontal, RVTheme.Spacing.gutter)
            .padding(.top, 8)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(L("report.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let files = exportFiles {
                    ShareLink(items: files.all) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel(L("report.share"))
                } else {
                    Button {
                        Task { await prepareExport() }
                    } label: {
                        if isExporting { ProgressView() } else { Image(systemName: "square.and.arrow.up") }
                    }
                    .disabled(isExporting)
                    .accessibilityLabel(L("report.prepare.a11y"))
                }
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(TripStyle.title(trip))
                .font(.title3.weight(.bold))
                .lineLimit(3)
            HStack(spacing: 6) {
                Text(TripStyle.dateText(trip))
                if trip.arrived {
                    RVBadge(text: L("report.arrived"), color: RVTheme.safe, systemImage: "flag.checkered")
                } else if trip.endedAt == nil && trip.id != app.tripRecorder.currentTripID {
                    RVBadge(text: L("report.interrupted"), color: RVTheme.caution, systemImage: "exclamationmark.triangle")
                }
                if let source = trip.routeSource {
                    RVBadge(text: source, color: RVTheme.accent, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var mapLegend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                legendDot(RVTheme.accent, L("report.legend.driven"))
                if !trip.routePolyline.isEmpty { legendDot(.gray, L("report.legend.route")) }
                ForEach(DrivingEventKind.allCases.filter { kind in trip.events.contains { $0.kind == kind } }, id: \.self) { kind in
                    legendDot(TripStyle.color(kind), kind.localizedTitle)
                }
            }
            .font(.caption2)
        }
    }

    private func legendDot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
        }
    }

    private func scoreCard(_ score: TripScoring.Result) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                TripScoreRing(score: score.score, size: 92)
                VStack(alignment: .leading, spacing: 4) {
                    Text(l: "report.score")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(TripScoring.localizedGrade(score.score))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(TripStyle.scoreColor(score.score))
                    Text(l: "report.penalty", RVFormat.appDecimal(score.totalPenalty, digits: 1), RVFormat.appDecimal(score.penaltyPerKm, digits: 2))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            DisclosureGroup(L("report.howScored"), isExpanded: $showsFormula) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(TripScoring.localizedFormulaDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(DrivingEventKind.allCases.filter { (score.penaltyByKind[$0] ?? 0) > 0 }, id: \.self) { kind in
                        HStack {
                            Circle().fill(TripStyle.color(kind)).frame(width: 8, height: 8)
                            Text(kind.localizedTitle)
                            Spacer()
                            Text(l: "report.points", RVFormat.appDecimal(score.penaltyByKind[kind] ?? 0, digits: 1))
                                .monospacedDigit()
                        }
                        .font(.caption)
                    }
                }
                .padding(.top, 4)
            }
            .font(.footnote.weight(.semibold))
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: RVTheme.Radius.panel, style: .continuous))
    }

    private func chartCard<Content: View>(title: String, systemImage: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: RVTheme.Radius.panel, style: .continuous))
    }

    private var eventsList: some View {
        chartCard(title: L("report.allEvents", trip.events.count), systemImage: "list.bullet.rectangle") {
            if trip.events.isEmpty {
                Text(l: "report.noEventsTrip")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(trip.sortedEvents) { event in
                    Button {
                        withAnimation(RVTheme.snappy) {
                            highlightedEventID = highlightedEventID == event.id ? nil : event.id
                        }
                    } label: {
                        TripEventRow(event: event, isHighlighted: event.id == highlightedEventID)
                    }
                    .buttonStyle(.plain)
                    if event.id != trip.sortedEvents.last?.id { Divider() }
                }
            }
        }
    }

    private var exportCard: some View {
        chartCard(title: L("report.share"), systemImage: "square.and.arrow.up") {
            Text(l: "report.shareDetail")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let files = exportFiles {
                ShareLink(items: files.all) {
                    Label(L("report.sendFiles"), systemImage: "square.and.arrow.up.on.square")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                HStack {
                    ShareLink(item: files.pdf) { Label("PDF", systemImage: "doc.richtext") }
                    Spacer()
                    ShareLink(item: files.eventsCSV) { Label(L("report.eventsCSV"), systemImage: "tablecells") }
                    Spacer()
                    ShareLink(item: files.pointsCSV) { Label(L("report.trackCSV"), systemImage: "point.3.connected.trianglepath.dotted") }
                }
                .font(.caption.weight(.semibold))
            } else {
                Button {
                    Task { await prepareExport() }
                } label: {
                    HStack {
                        if isExporting { ProgressView() }
                        Text(verbatim: isExporting ? L("report.preparing") : L("report.prepare"))
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isExporting)
            }
            if let exportError {
                Text(exportError).font(.caption).foregroundStyle(RVTheme.danger)
            }
            if !trip.cameraCSVFiles.isEmpty {
                Text(l: "report.cameraCSV", trip.cameraCSVFiles.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func prepareExport() async {
        guard !isExporting else { return }
        isExporting = true
        exportError = nil
        defer { isExporting = false }
        do {
            exportFiles = try await TripReportExporter.export(trip)
        } catch {
            exportError = L("report.exportFailed", error.localizedDescription)
        }
    }
}

/// One event in the report list: icon, title, time, value, place.
struct TripEventRow: View {
    let event: DrivingEvent
    var isHighlighted = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.kind.symbolName)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(TripStyle.color(event.kind), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(event.kind.localizedTitle)
                        .font(.subheadline.weight(.semibold))
                    if event.severity == .violation {
                        RVBadge(text: L("report.violation"), color: RVTheme.danger)
                    }
                    Spacer(minLength: 4)
                    Text(TripStyle.timeText(event.date))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text(TripStyle.valueText(event))
                    .font(.caption)
                Text(placeText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, isHighlighted ? 6 : 0)
        .background(isHighlighted ? TripStyle.color(event.kind).opacity(0.15) : .clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var placeText: String {
        var parts: [String] = []
        if let note = event.note, !note.isEmpty {
            // Notes written by the GPS / motion detectors ("GPS", "GPS + <motion sensors>") are shown localized.
            parts.append(note.hasPrefix("GPS +") ? L("trip.note.gpsSensors") : note)
        }
        parts.append(TripStyle.coordinateText(event.coordinate))
        return parts.joined(separator: " · ")
    }
}

/// Circular score gauge 0…100 in the score colour.
struct TripScoreRing: View {
    let score: Int
    var size: CGFloat = 90

    var body: some View {
        let color = TripStyle.scoreColor(score)
        ZStack {
            Circle()
                .stroke(color.opacity(0.18), lineWidth: size * 0.1)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(100, score))) / 100)
                .stroke(AngularGradient(colors: [color.opacity(0.6), color], center: .center),
                        style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(score)")
                    .font(.system(size: size * 0.34, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                Text(l: "report.of100")
                    .font(.system(size: size * 0.11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("report.score.a11y", score))
    }
}

/// Tiles with the trip numbers.
struct TripStatsGrid: View {
    let trip: Trip
    let stats: TripStats
    var columns: Int = 2
    var compact = false

    private struct Tile: Identifiable {
        let title: String
        let value: String
        let symbol: String
        let color: Color
        var id: String { title }
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
            ForEach(tiles) { tile in
                VStack(alignment: .leading, spacing: 3) {
                    Label(tile.title, systemImage: tile.symbol)
                        .font(.system(size: compact ? 8 : 11, weight: .semibold))
                        .foregroundStyle(tile.color)
                        .lineLimit(1)
                    Text(tile.value)
                        .font(.system(size: compact ? 13 : 18, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .padding(compact ? 7 : 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tile.color.opacity(compact ? 0.08 : 0.12),
                            in: RoundedRectangle(cornerRadius: compact ? 8 : 12, style: .continuous))
            }
        }
    }

    private var tiles: [Tile] {
        var result = [
            Tile(title: L("routes.row.distance"), value: RVFormat.appDistance(stats.distanceMeters), symbol: "road.lanes", color: RVTheme.accent),
            Tile(title: L("report.tile.duration"), value: RVFormat.appDuration(stats.duration), symbol: "clock", color: .purple),
            Tile(title: L("routes.row.avgSpeed"), value: "\(RVFormat.speed(stats.averageSpeedKmh)) \(RVFormat.appKmh)", symbol: "gauge.with.dots.needle.33percent", color: .teal),
            Tile(title: L("report.tile.maxSpeed"), value: "\(RVFormat.speed(stats.maxSpeedKmh)) \(RVFormat.appKmh)", symbol: "gauge.with.dots.needle.100percent", color: .orange),
            Tile(title: L("report.tile.overLimit"), value: RVFormat.appDuration(stats.timeOverLimit), symbol: "exclamationmark.triangle", color: RVTheme.danger),
            Tile(title: L("report.tile.eventsPer100"), value: RVFormat.appDecimal(stats.eventsPer100km, digits: 1), symbol: "chart.bar", color: RVTheme.caution),
        ]
        if let lead = stats.averageLeadDistanceMeters {
            result.append(Tile(title: L("report.tile.avgLead"), value: "≈ \(RVFormat.appDecimal(lead, digits: 0)) \(RVFormat.appMeters)",
                               symbol: "car.2", color: RVTheme.safe))
        }
        result.append(Tile(title: L("norms.moving"), value: RVFormat.appDuration(stats.movingDuration), symbol: "car", color: .mint))
        return result
    }
}

/// Report in a sheet with «Готово» (shown when a recording stops).
struct TripReportSheet: View {
    let trip: Trip
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TripReportView(trip: trip)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(L("common.done")) { dismiss() }
                            .fontWeight(.semibold)
                    }
                }
        }
        .preferredColorScheme(.dark)
    }
}
