import Foundation

/// Facts about the current trip that the assistant may use in its answers.
public struct DrivingContext: Sendable, Hashable {
    public var localTime: Date?
    public var speedKmh: Double?
    public var roadName: String?
    public var speedLimitKmh: Int?
    public var lanesInDirection: Int?
    public var totalLanes: Int?
    public var destinationName: String?
    public var remainingDistanceMeters: Double?
    public var remainingTimeSeconds: Double?
    public var nextInstruction: String?
    public var trafficDelaySeconds: Double?
    public var signalsAhead: Int?
    public var expectedSignalWaitSeconds: Double?
    public var weatherSummary: String?
    public var vehiclesInView: [VehicleKind: Int]
    public var uniqueVehiclesCounted: Int?

    public init() {
        vehiclesInView = [:]
    }

    /// Russian lines describing only the known facts.
    public var summaryLines: [String] {
        var lines: [String] = []
        if let t = localTime { lines.append("Местное время: \(RVFormat.clock(t))") }
        if let s = speedKmh { lines.append("Скорость автомобиля (GPS): \(RVFormat.speed(s)) км/ч") }
        if let r = roadName, !r.isEmpty { lines.append("Текущая дорога: \(r)") }
        if let l = speedLimitKmh { lines.append("Ограничение скорости (OpenStreetMap): \(l) км/ч") }
        if let d = lanesInDirection {
            var text = "Полос в направлении движения (OpenStreetMap): \(d)"
            if let t = totalLanes { text += ", всего \(t)" }
            lines.append(text)
        } else if let t = totalLanes {
            lines.append("Всего полос на дороге (OpenStreetMap): \(t)")
        }
        if let dest = destinationName, !dest.isEmpty { lines.append("Пункт назначения: \(dest)") }
        if let rd = remainingDistanceMeters {
            var text = "Осталось ехать: \(RVFormat.distance(rd))"
            if let rt = remainingTimeSeconds { text += ", примерно \(RVFormat.duration(rt))" }
            lines.append(text)
        }
        if let n = nextInstruction, !n.isEmpty { lines.append("Следующий манёвр: \(n)") }
        if let delay = trafficDelaySeconds, delay >= 60 {
            lines.append("Задержка из-за пробок: около \(RVFormat.duration(delay)) (оценка Apple Maps)")
        }
        if let n = signalsAhead, n > 0 {
            var text = "Светофоров впереди по маршруту: \(n)"
            if let w = expectedSignalWaitSeconds { text += ", ожидаемое ожидание ≈ \(RVFormat.duration(w)) (оценка)" }
            lines.append(text)
        }
        if let w = weatherSummary, !w.isEmpty { lines.append("Погода: \(w)") }
        let visible = vehiclesInView.filter { $0.value > 0 }.sorted { $0.key.rawValue < $1.key.rawValue }
        if !visible.isEmpty {
            let parts = visible.map { "\($0.key.displayName.lowercased()): \($0.value)" }
            lines.append("Сейчас в кадре камеры: " + parts.joined(separator: ", "))
        }
        if let u = uniqueVehiclesCounted, u > 0 { lines.append("Уникальных ТС насчитано за сессию: \(u)") }
        return lines
    }
}

public enum AssistantPrompt {
    /// System prompt for the in-car voice companion.
    public static func systemPrompt(languageCode: String, context: DrivingContext?, includeContext: Bool) -> String {
        let languageRule: String
        switch languageCode.lowercased() {
        case "uz":
            languageRule = "Always answer in Uzbek (Latin script), unless the user clearly writes in another language."
        case "en":
            languageRule = "Always answer in English, unless the user clearly writes in another language."
        default:
            languageRule = "Always answer in Russian, unless the user clearly writes in another language."
        }
        var prompt = """
        You are RoadVis, a friendly voice companion inside a car app (road-safety and traffic topics are welcome, \
        but casual small talk is fine too).
        \(languageRule)
        Your replies are read aloud by text-to-speech while the user is driving, so:
        - keep answers short and conversational: at most 2–3 sentences unless the user asks for details;
        - no markdown, no lists, no emojis, no URLs;
        - never ask the user to look at or type on the phone while driving; suggest pulling over for anything long;
        - if the user seems tired or distracted, gently suggest a break.
        For facts about the current trip use ONLY the data block below; if something is not there, say you do not know.
        Estimated values (traffic delay, traffic-light waiting) are approximations — say so when you mention them.
        """
        if includeContext, let context {
            let lines = context.summaryLines
            if !lines.isEmpty {
                prompt += "\n\nCurrent trip data:\n" + lines.map { "- " + $0 }.joined(separator: "\n")
            }
        }
        return prompt
    }
}
