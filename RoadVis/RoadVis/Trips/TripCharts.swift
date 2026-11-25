import Charts
import SwiftUI

/// Chart data prepared once per trip (downsampled track, contiguous segments, event counts, speed bands).
struct TripChartData {
    struct SpeedSample: Identifiable {
        let id: Int
        let date: Date
        let speedKmh: Double
    }

    struct SegmentSample: Identifiable {
        let id: Int
        let segment: Int
        let date: Date
        let value: Double
    }

    struct EventMarker: Identifiable {
        let id: UUID
        let date: Date
        let speedKmh: Double
        let kind: DrivingEventKind
    }

    struct KindCount: Identifiable {
        let kind: DrivingEventKind
        let count: Int
        var id: String { kind.rawValue }
    }

    struct BandShare: Identifiable {
        let band: TripSpeedBand
        let seconds: Double
        let share: Double
        var id: String { band.rawValue }
    }

    let speed: [SpeedSample]
    let limits: [SegmentSample]
    let leads: [SegmentSample]
    let recommended: [SegmentSample]
    let markers: [EventMarker]
    let kindCounts: [KindCount]
    let bands: [BandShare]
    let maxSpeed: Double

    /// Maximum number of plotted track samples.
    static let maxSamples = 360

    init(trip: Trip, stats: TripStats) {
        let points = trip.points.sorted { $0.date < $1.date }
        let stride = max(1, Int((Double(points.count) / Double(Self.maxSamples)).rounded(.up)))
        let sampled = Swift.stride(from: 0, to: points.count, by: stride).map { points[$0] }

        speed = sampled.enumerated().map { SpeedSample(id: $0.offset, date: $0.element.date, speedKmh: $0.element.speedKmh ?? 0) }
        limits = Self.segments(sampled) { $0.speedLimitKmh.map(Double.init) }
        leads = Self.segments(sampled) { $0.leadDistanceMeters }
        recommended = Self.segments(sampled) { $0.leadDistanceMeters == nil ? nil : $0.recommendedGapMeters }

        markers = trip.sortedEvents.compactMap { event in
            let speed = event.speedKmh ?? Self.speed(at: event.date, in: points)
            guard let speed else { return nil }
            return EventMarker(id: event.id, date: event.date, speedKmh: speed, kind: event.kind)
        }
        kindCounts = DrivingEventKind.allCases.compactMap { kind in
            let count = stats.eventCounts[kind] ?? 0
            return count > 0 ? KindCount(kind: kind, count: count) : nil
        }
        let total = stats.timeBySpeedBand.values.reduce(0, +)
        bands = TripSpeedBand.allCases.compactMap { band in
            let seconds = stats.timeBySpeedBand[band] ?? 0
            guard seconds > 0, total > 0 else { return nil }
            return BandShare(band: band, seconds: seconds, share: seconds / total)
        }
        let limitMax = limits.map(\.value).max() ?? 0
        maxSpeed = max(stats.maxSpeedKmh, limitMax, 20)
    }

    var hasLeadData: Bool { !leads.isEmpty }

    /// Splits the samples into contiguous runs where `value` is non-nil (a gap breaks the line).
    private static func segments(_ points: [TripPoint], value: (TripPoint) -> Double?) -> [SegmentSample] {
        var result: [SegmentSample] = []
        var segment = 0
        var inRun = false
        for point in points {
            if let v = value(point), v.isFinite {
                if !inRun { segment += 1; inRun = true }
                result.append(SegmentSample(id: result.count, segment: segment, date: point.date, value: v))
            } else {
                inRun = false
            }
        }
        return result
    }

    private static func speed(at date: Date, in points: [TripPoint]) -> Double? {
        points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }?.speedKmh
    }
}

/// Own GPS speed (blue area + line) vs the posted limit (red dashed steps) with violation markers.
struct TripSpeedChart: View {
    let data: TripChartData
    var height: CGFloat = 200

    var body: some View {
        Chart {
            ForEach(data.speed) { sample in
                AreaMark(x: .value("Время", sample.date), y: .value("Скорость", sample.speedKmh))
                    .foregroundStyle(LinearGradient(colors: [RVTheme.accent.opacity(0.35), RVTheme.accent.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Время", sample.date), y: .value("Скорость", sample.speedKmh),
                         series: .value("Ряд", "speed"))
                    .foregroundStyle(RVTheme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
            }
            ForEach(data.limits) { sample in
                LineMark(x: .value("Время", sample.date), y: .value("Лимит", sample.value),
                         series: .value("Ряд", "limit-\(sample.segment)"))
                    .foregroundStyle(RVTheme.danger)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    .interpolationMethod(.stepEnd)
            }
            ForEach(data.markers) { marker in
                PointMark(x: .value("Время", marker.date), y: .value("Скорость", marker.speedKmh))
                    .foregroundStyle(TripStyle.color(marker.kind))
                    .symbolSize(70)
                    .symbol(.circle)
            }
        }
        .chartYScale(domain: 0...(data.maxSpeed * 1.1))
        .chartYAxisLabel("км/ч")
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .frame(height: height)
    }
}

/// Number of events per kind (horizontal bars in the kind colours).
struct TripEventsByKindChart: View {
    let data: TripChartData

    var body: some View {
        Chart(data.kindCounts) { item in
            BarMark(x: .value("Количество", item.count), y: .value("Вид", item.kind.tripReportTitle))
                .foregroundStyle(TripStyle.color(item.kind).gradient)
                .cornerRadius(5)
                .annotation(position: .trailing) {
                    Text("\(item.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
        }
        .chartXAxis(.hidden)
        .frame(height: CGFloat(max(1, data.kindCounts.count)) * 32 + 10)
    }
}

/// ≈ Camera gap to the lead vehicle vs the recommended gap.
struct TripLeadDistanceChart: View {
    let data: TripChartData
    var height: CGFloat = 170

    var body: some View {
        Chart {
            ForEach(data.recommended) { sample in
                LineMark(x: .value("Время", sample.date), y: .value("Норма", sample.value),
                         series: .value("Ряд", "norm-\(sample.segment)"))
                    .foregroundStyle(RVTheme.caution)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            ForEach(data.leads) { sample in
                LineMark(x: .value("Время", sample.date), y: .value("Дистанция", sample.value),
                         series: .value("Ряд", "lead-\(sample.segment)"))
                    .foregroundStyle(RVTheme.safe)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
            }
        }
        .chartYAxisLabel("м (≈)")
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .frame(height: height)
    }
}

/// Share of driving time per speed band (donut + legend).
struct TripSpeedBandChart: View {
    let data: TripChartData

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Chart(data.bands) { item in
                SectorMark(angle: .value("Время", item.seconds), innerRadius: .ratio(0.58), angularInset: 1.5)
                    .foregroundStyle(TripStyle.bandColor(item.band))
                    .cornerRadius(3)
            }
            .frame(width: 130, height: 130)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(data.bands) { item in
                    HStack(spacing: 6) {
                        Circle().fill(TripStyle.bandColor(item.band)).frame(width: 9, height: 9)
                        Text(item.band.title)
                            .font(.caption)
                        Spacer(minLength: 4)
                        Text("\(Int((item.share * 100).rounded()))% · \(RVFormat.duration(item.seconds))")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }
                }
            }
        }
    }
}

/// Legend of the speed chart.
struct TripSpeedChartLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            legendItem(color: RVTheme.accent, text: "Скорость (GPS)")
            legendItem(color: RVTheme.danger, text: "Лимит", dashed: true)
            legendItem(color: TripStyle.color(.speeding), text: "События", dot: true)
        }
        .font(.caption2)
    }

    private func legendItem(color: Color, text: String, dashed: Bool = false, dot: Bool = false) -> some View {
        HStack(spacing: 4) {
            if dot {
                Circle().fill(color).frame(width: 8, height: 8)
            } else {
                Capsule()
                    .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [3, 2] : []))
                    .frame(width: 16, height: 2)
            }
            Text(text)
        }
    }
}
