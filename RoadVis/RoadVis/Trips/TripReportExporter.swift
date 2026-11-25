import MapKit
import SwiftUI
import UIKit

/// Builds the shareable files of a trip report: a multi-page PDF (map snapshot with A/B and violations, score,
/// numbers, charts, the table of events) and two CSV files (events, track points), in a temporary folder.
@MainActor
enum TripReportExporter {
    /// A4 in points.
    static let pageSize = CGSize(width: 595, height: 842)
    static let rowsPerPage = 24

    struct Files {
        let pdf: URL
        let eventsCSV: URL
        let pointsCSV: URL
        var all: [URL] { [pdf, eventsCSV, pointsCSV] }
    }

    static func export(_ trip: Trip) async throws -> Files {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TripExport", isDirectory: true)
            .appendingPathComponent(trip.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = TripExport.baseFileName(trip)

        let eventsURL = directory.appendingPathComponent("\(base)_events.csv")
        let pointsURL = directory.appendingPathComponent("\(base)_track.csv")
        // UTF-8 BOM so spreadsheet apps detect the Cyrillic text.
        try (Data([0xEF, 0xBB, 0xBF]) + Data(TripExport.eventsCSV(trip, title: { $0.localizedTitle }).utf8)).write(to: eventsURL, options: .atomic)
        try (Data([0xEF, 0xBB, 0xBF]) + Data(TripExport.pointsCSV(trip).utf8)).write(to: pointsURL, options: .atomic)

        let snapshot = await mapSnapshot(trip, size: CGSize(width: 545, height: 300))
        let pdfURL = directory.appendingPathComponent("\(base)_report.pdf")
        try renderPDF(trip, mapImage: snapshot, to: pdfURL)
        return Files(pdf: pdfURL, eventsCSV: eventsURL, pointsCSV: pointsURL)
    }

    // MARK: - Map snapshot

    /// MKMapSnapshotter image with the route, track, A/B pins and event dots; nil when the map cannot load.
    static func mapSnapshot(_ trip: Trip, size: CGSize) async -> UIImage? {
        let options = MKMapSnapshotter.Options()
        options.mapRect = TripMapView.mapRect(for: trip)
        options.size = size
        options.scale = 2
        options.traitCollection = UITraitCollection(userInterfaceStyle: .light)
        options.pointOfInterestFilter = .excludingAll
        let snapshotter = MKMapSnapshotter(options: options)
        guard let snapshot = try? await snapshotter.start() else { return nil }

        let renderer = UIGraphicsImageRenderer(size: size, format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            return format
        }())
        return renderer.image { context in
            snapshot.image.draw(at: .zero)
            let cg = context.cgContext
            func path(_ points: [GeoPoint]) -> CGPath? {
                guard points.count >= 2 else { return nil }
                let path = CGMutablePath()
                path.move(to: snapshot.point(for: points[0].coordinate))
                for p in points.dropFirst() { path.addLine(to: snapshot.point(for: p.coordinate)) }
                return path
            }
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            if let route = path(trip.routePolyline) {
                cg.addPath(route)
                cg.setStrokeColor(UIColor.gray.withAlphaComponent(0.7).cgColor)
                cg.setLineWidth(5)
                cg.setLineDash(phase: 0, lengths: [6, 6])
                cg.strokePath()
                cg.setLineDash(phase: 0, lengths: [])
            }
            if let track = path(trip.points.map(\.coordinate)) {
                cg.addPath(track)
                cg.setStrokeColor(UIColor(RVTheme.accent).cgColor)
                cg.setLineWidth(4)
                cg.strokePath()
            }
            for event in trip.events {
                guard let c = event.coordinate else { continue }
                let p = snapshot.point(for: c.coordinate)
                let rect = CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)
                cg.setFillColor(UIColor(TripStyle.color(event.kind)).cgColor)
                cg.fillEllipse(in: rect)
                cg.setStrokeColor(UIColor.white.cgColor)
                cg.setLineWidth(1.5)
                cg.strokeEllipse(in: rect)
            }
            func pin(_ point: GeoPoint?, letter: String, color: UIColor) {
                guard let point else { return }
                let p = snapshot.point(for: point.coordinate)
                let rect = CGRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22)
                cg.setFillColor(color.cgColor)
                cg.fillEllipse(in: rect)
                cg.setStrokeColor(UIColor.white.cgColor)
                cg.setLineWidth(2)
                cg.strokeEllipse(in: rect)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 12, weight: .heavy), .foregroundColor: UIColor.white,
                ]
                let text = NSAttributedString(string: letter, attributes: attributes)
                let textSize = text.size()
                text.draw(at: CGPoint(x: p.x - textSize.width / 2, y: p.y - textSize.height / 2))
            }
            pin(trip.origin.coordinate ?? trip.points.first?.coordinate, letter: "A", color: UIColor(RVTheme.safe))
            pin(trip.destination?.coordinate ?? trip.points.last?.coordinate, letter: "B", color: UIColor(RVTheme.danger))
        }
    }

    // MARK: - PDF

    static func renderPDF(_ trip: Trip, mapImage: UIImage?, to url: URL) throws {
        let stats = TripStats.compute(trip)
        let score = TripScoring.score(events: trip.events, distanceMeters: stats.distanceMeters)
        let chartData = TripChartData(trip: trip, stats: stats)
        let events = trip.sortedEvents
        let eventPages = stride(from: 0, to: max(events.count, 1), by: rowsPerPage).map {
            Array(events[min($0, events.count)..<min($0 + rowsPerPage, events.count)])
        }
        let pageCount = 2 + eventPages.count

        var pages: [AnyView] = [
            AnyView(TripPDFSummaryPage(trip: trip, stats: stats, score: score, mapImage: mapImage,
                                       page: 1, pageCount: pageCount)),
            AnyView(TripPDFChartsPage(trip: trip, data: chartData, stats: stats, page: 2, pageCount: pageCount)),
        ]
        for (index, rows) in eventPages.enumerated() {
            pages.append(AnyView(TripPDFEventsPage(trip: trip, rows: rows, firstIndex: index * rowsPerPage,
                                                   page: 3 + index, pageCount: pageCount)))
        }

        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, [
                  kCGPDFContextTitle as String: L("report.pdfTitle"),
                  kCGPDFContextCreator as String: "RoadVis",
              ] as CFDictionary) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for page in pages {
            let renderer = ImageRenderer(content:
                page
                    .frame(width: pageSize.width, height: pageSize.height)
                    .background(Color.white)
                    .environment(\.colorScheme, .light)
            )
            renderer.proposedSize = ProposedViewSize(pageSize)
            renderer.render { _, draw in
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
            }
        }
        context.closePDF()
    }
}

// MARK: - PDF pages (light, print layout)

private struct TripPDFPageFrame<Content: View>: View {
    let trip: Trip
    let page: Int
    let pageCount: Int
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(l: "report.pageHeader")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(TripStyle.dateText(trip))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            content
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                Text(l: "report.pdfFooter")
                    .font(.system(size: 7))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Text(l: "report.page", page, pageCount)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(25)
        .foregroundStyle(.black)
    }
}

private struct TripPDFSummaryPage: View {
    let trip: Trip
    let stats: TripStats
    let score: TripScoring.Result
    let mapImage: UIImage?
    let page: Int
    let pageCount: Int

    var body: some View {
        TripPDFPageFrame(trip: trip, page: page, pageCount: pageCount) {
            Text(TripStyle.title(trip))
                .font(.system(size: 20, weight: .bold))
                .lineLimit(2)
            Group {
                if let mapImage {
                    Image(uiImage: mapImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.15))
                        .overlay(Text(l: "report.noMap").font(.caption).foregroundStyle(.secondary))
                        .frame(height: 300)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack(alignment: .center, spacing: 18) {
                TripScoreRing(score: score.score, size: 96)
                VStack(alignment: .leading, spacing: 4) {
                    Text(TripScoring.localizedGrade(score.score))
                        .font(.system(size: 16, weight: .bold))
                    Text(l: "report.penaltyPdf", RVFormat.appDecimal(score.totalPenalty, digits: 1), RVFormat.appDecimal(score.penaltyPerKm, digits: 2))
                        .font(.system(size: 10))
                    Text(TripScoring.localizedFormulaDescription)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            TripStatsGrid(trip: trip, stats: stats, columns: 3, compact: true)
        }
    }
}

private struct TripPDFChartsPage: View {
    let trip: Trip
    let data: TripChartData
    let stats: TripStats
    let page: Int
    let pageCount: Int

    var body: some View {
        TripPDFPageFrame(trip: trip, page: page, pageCount: pageCount) {
            Text(l: "report.speedAndLimit").font(.system(size: 13, weight: .bold))
            TripSpeedChart(data: data, height: 190)
            TripSpeedChartLegend()
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(l: "report.eventsByKind").font(.system(size: 13, weight: .bold))
                    if data.kindCounts.isEmpty {
                        Text(l: "report.noEvents").font(.caption).foregroundStyle(.secondary)
                    } else {
                        TripEventsByKindChart(data: data)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(l: "report.timeBySpeed").font(.system(size: 13, weight: .bold))
                    TripSpeedBandChart(data: data)
                }
            }
            Text(l: "report.leadDistanceCamera").font(.system(size: 13, weight: .bold))
            if data.hasLeadData {
                TripLeadDistanceChart(data: data, height: 150)
            } else {
                Text(l: "report.noLeadData").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct TripPDFEventsPage: View {
    let trip: Trip
    let rows: [DrivingEvent]
    let firstIndex: Int
    let page: Int
    let pageCount: Int

    var body: some View {
        TripPDFPageFrame(trip: trip, page: page, pageCount: pageCount) {
            Text(l: "report.violations", trip.events.count).font(.system(size: 13, weight: .bold))
            if rows.isEmpty {
                Text(l: "report.noEventsTrip").font(.system(size: 11))
            } else {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
                    GridRow {
                        Text(l: "report.col.number"); Text(l: "report.col.time"); Text(l: "report.col.event"); Text(l: "report.col.value"); Text(l: "report.col.place")
                    }
                    .font(.system(size: 9, weight: .bold))
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.element.id) { offset, event in
                        GridRow {
                            Text("\(firstIndex + offset + 1)")
                            Text(TripStyle.timeText(event.date)).monospacedDigit()
                            HStack(spacing: 4) {
                                Circle().fill(TripStyle.color(event.kind)).frame(width: 7, height: 7)
                                Text(event.kind.localizedTitle)
                            }
                            Text(TripStyle.valueText(event))
                            Text(event.note.flatMap { $0 == "GPS" || $0.hasPrefix("GPS +") ? nil : $0 }
                                 ?? TripStyle.coordinateText(event.coordinate))
                                .monospacedDigit()
                        }
                        .font(.system(size: 9))
                    }
                }
            }
        }
    }
}
