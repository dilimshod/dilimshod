import SwiftUI

/// Colours and texts of the trip report (shared by the live report, the PDF and the history).
enum TripStyle {
    static func color(_ kind: DrivingEventKind) -> Color {
        switch kind {
        case .speeding: return Color(red: 1.0, green: 0.27, blue: 0.27)
        case .tailgating: return Color(red: 1.0, green: 0.62, blue: 0.1)
        case .collisionRisk: return Color(red: 0.93, green: 0.1, blue: 0.45)
        case .laneDeparture: return Color(red: 0.98, green: 0.85, blue: 0.2)
        case .redLightRunning: return Color(red: 0.8, green: 0.05, blue: 0.1)
        case .stopSignIgnored: return Color(red: 0.75, green: 0.35, blue: 1.0)
        case .harshBraking: return Color(red: 0.2, green: 0.6, blue: 1.0)
        case .harshAcceleration: return Color(red: 0.2, green: 0.85, blue: 0.85)
        }
    }

    static func scoreColor(_ score: Int) -> Color {
        switch score {
        case 90...: return RVTheme.safe
        case 75..<90: return Color(red: 0.55, green: 0.85, blue: 0.3)
        case 55..<75: return RVTheme.caution
        default: return RVTheme.danger
        }
    }

    static func bandColor(_ band: TripSpeedBand) -> Color {
        switch band {
        case .standing: return Color(white: 0.6)
        case .slow: return Color(red: 0.35, green: 0.75, blue: 1.0)
        case .urban: return RVTheme.safe
        case .fast: return RVTheme.caution
        case .highway: return Color(red: 1.0, green: 0.45, blue: 0.3)
        }
    }

    /// "Дом → Работа".
    static func title(_ trip: Trip) -> String {
        let a = trip.origin.name ?? "Старт"
        let b = trip.destination?.name ?? "Финиш"
        return "\(a) → \(b)"
    }

    /// "25 нояб. 2026 г., 14:35".
    static func dateText(_ trip: Trip) -> String {
        trip.startedAt.formatted(date: .abbreviated, time: .shortened)
    }

    static func timeText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    /// Measured value of an event in words, estimates marked with ≈.
    static func valueText(_ event: DrivingEvent) -> String {
        func n(_ v: Double, _ digits: Int = 0) -> String { RVFormat.decimal(v, digits: digits) }
        switch event.kind {
        case .speeding:
            var text = event.value.map { "+\(n($0)) км/ч" } ?? "превышение"
            if let limit = event.limit { text += " при лимите \(n(limit))" }
            if event.duration > 0 { text += " · \(RVFormat.duration(event.duration))" }
            return text
        case .tailgating:
            var text = event.value.map { "≈ \(n($0)) м" } ?? "≈ мало"
            if let limit = event.limit { text += " при норме ≥ \(n(limit)) м" }
            return text + " (оценка)"
        case .collisionRisk:
            return (event.value.map { "≈ \(n($0, 1)) с до столкновения" } ?? "≈ опасное сближение") + " (оценка)"
        case .harshBraking, .harshAcceleration:
            var text = event.value.map { "\(n($0, 1)) м/с²" } ?? "—"
            if let limit = event.limit { text += " (порог \(n(limit, 1)))" }
            return text
        case .laneDeparture, .redLightRunning, .stopSignIgnored:
            let speed = event.speedKmh.map { " на \(n($0)) км/ч" } ?? ""
            return "≈ оценка камеры" + speed
        }
    }

    /// "41.31110, 69.27970".
    static func coordinateText(_ point: GeoPoint?) -> String {
        guard let point else { return "—" }
        return String(format: "%.5f, %.5f", point.latitude, point.longitude)
    }
}
