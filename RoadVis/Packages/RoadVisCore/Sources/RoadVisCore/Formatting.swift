import Foundation

/// Russian formatting helpers for distances, durations and speeds.
public enum RVFormat {
    /// "350 м", "1,2 км", "12 км".
    public static func distance(_ meters: Double) -> String {
        guard meters.isFinite else { return "—" }
        let m = max(0, meters)
        if m < 1000 {
            let rounded = m < 100 ? (m / 10).rounded() * 10 : (m / 50).rounded() * 50
            if rounded >= 1000 { return "1 км" }
            return "\(Int(rounded)) м"
        }
        if m < 10_000 {
            return decimal(m / 1000, digits: 1) + " км"
        }
        return "\(Int((m / 1000).rounded())) км"
    }

    /// "через 400 метров", "через 1,5 километра", "через 2 километра".
    public static func spokenDistance(_ meters: Double) -> String {
        let m = max(0, meters)
        if m < 1000 {
            let rounded = m < 100 ? max(10, (m / 10).rounded() * 10) : (m / 50).rounded() * 50
            if rounded < 1000 {
                let n = Int(rounded)
                return "через \(n) \(plural(n, "метр", "метра", "метров"))"
            }
        }
        let km = (m / 100).rounded() / 10
        if km == km.rounded() {
            let n = Int(km)
            return "через \(n) \(plural(n, "километр", "километра", "километров"))"
        }
        return "через \(decimal(km, digits: 1)) километра"
    }

    /// "45 с", "12 мин", "1 ч 05 мин".
    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "—" }
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s) с" }
        let totalMinutes = Int((Double(s) / 60).rounded())
        if totalMinutes < 60 { return "\(totalMinutes) мин" }
        let h = totalMinutes / 60, m = totalMinutes % 60
        return String(format: "%d ч %02d мин", h, m)
    }

    /// Integer km/h as text ("54"); "—" when unknown.
    public static func speed(_ kmh: Double) -> String {
        guard kmh.isFinite else { return "—" }
        return "\(Int(max(0, kmh).rounded()))"
    }

    /// "14:35".
    public static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// Russian plural form for an integer: 1 метр, 2 метра, 5 метров, 21 метр, 11 метров.
    public static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let n10 = abs(n) % 10, n100 = abs(n) % 100
        if n10 == 1 && n100 != 11 { return one }
        if (2...4).contains(n10) && !(12...14).contains(n100) { return few }
        return many
    }

    /// Decimal with a comma separator, e.g. 1.25 → "1,3" (digits = 1).
    public static func decimal(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
    }
}
