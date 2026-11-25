import Foundation

// Text for the following-distance UI (HUD, distance line label, detail card, norms sheet, PiP badge).
// Foundation only, so it can be checked outside Xcode. Decimals use a comma ("1,4 с"); estimates carry "≈".

extension RVFormat {
    /// Gap in metres with a precision that suits the value: "1,6 м", "18 м", "125 м"; "—" when unknown.
    static func gapMeters(_ meters: Double?) -> String {
        guard let meters, meters.isFinite else { return "—" }
        let m = max(0, meters)
        if m < 10 { return decimal(m, digits: 1) + " м" }
        if m < 100 { return "\(Int(m.rounded())) м" }
        return "\(Int((m / 5).rounded() * 5)) м"
    }

    /// Seconds with one decimal below 10 s: "1,4 с", "12 с"; "—" when unknown.
    static func gapSeconds(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "—" }
        let s = max(0, seconds)
        return s < 10 ? decimal(s, digits: 1) + " с" : "\(Int(s.rounded())) с"
    }

    /// Number without a trailing ",0": 2 → "2", 1.5 → "1,5", 2.25 → "2,3".
    static func compactNumber(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return "\(Int(rounded))" }
        return decimal(rounded, digits: 1)
    }
}

/// Russian strings built from a `FollowingDistanceAssessment` and the active `FollowingDistancePolicy`.
enum FollowingDistanceText {
    /// "≈ 18 м" / "≈ 1,6 м"; "—" when there is no estimate.
    static func gap(_ meters: Double?) -> String {
        guard let meters, meters.isFinite, meters > 0 else { return "—" }
        return "≈ " + RVFormat.gapMeters(meters)
    }

    /// Recommended gap, e.g. "≥ 33 м".
    static func recommended(_ assessment: FollowingDistanceAssessment) -> String {
        "≥ " + RVFormat.gapMeters(assessment.recommendedDistanceMeters)
    }

    /// Caption under the distance on the animated line: "1,4 с · норма ≥ 33 м" (moving) or "норма ≥ 2 м" (standing).
    static func lineCaption(_ assessment: FollowingDistanceAssessment) -> String {
        let norm = "норма " + recommended(assessment)
        if !assessment.isStopped, let headway = assessment.timeHeadwaySeconds {
            return RVFormat.gapSeconds(headway) + " · " + norm
        }
        return norm
    }

    /// Moving requirement: "≥ 2 с ≈ 33 м (сухо)" while moving, "≥ 2 с (сухо)" when standing (the metres depend on speed).
    static func movingNorm(_ assessment: FollowingDistanceAssessment, policy: FollowingDistancePolicy) -> String {
        let gap = policy.timeGap(for: assessment.condition)
        let surface = assessment.condition.displayName.lowercased()
        if !assessment.isStopped {
            return "≥ \(RVFormat.compactNumber(gap)) с ≈ \(RVFormat.gapMeters(assessment.recommendedDistanceMeters)) (\(surface))"
        }
        return "≥ \(RVFormat.compactNumber(gap)) с (\(surface))"
    }

    /// Standing requirement: "≥ 2 м".
    static func stoppedNorm(policy: FollowingDistancePolicy) -> String {
        "≥ \(RVFormat.compactNumber(policy.stoppedGapMeters)) м"
    }

    /// One line with both requirements for the compact HUD.
    static func compactNorms(_ assessment: FollowingDistanceAssessment, policy: FollowingDistancePolicy) -> String {
        if assessment.isStopped {
            return "Стоя \(stoppedNorm(policy: policy)) · в движении ≥ \(RVFormat.compactNumber(policy.timeGap(for: assessment.condition))) с"
        }
        return "Норма \(recommended(assessment)) · стоя \(stoppedNorm(policy: policy))"
    }

    /// "≈ 37 м" (moving only).
    static func stoppingDistance(_ assessment: FollowingDistanceAssessment) -> String? {
        guard let d = assessment.stoppingDistanceMeters, d.isFinite else { return nil }
        return "≈ " + RVFormat.gapMeters(d)
    }

    /// "≈ 2,1 с" (only while the gap is closing).
    static func timeToCollision(_ assessment: FollowingDistanceAssessment) -> String? {
        guard let t = assessment.timeToCollisionSeconds, t.isFinite else { return nil }
        return "≈ " + RVFormat.gapSeconds(t)
    }

    /// Closing / opening speed: "сближение 12 км/ч", "отдаляется 5 км/ч"; nil below 2 km/h or when unknown.
    static func relativeMotion(relativeSpeedKmh: Double?) -> String? {
        guard let rel = relativeSpeedKmh, rel.isFinite, abs(rel) >= 2 else { return nil }
        let value = Int(abs(rel).rounded())
        return rel < 0 ? "сближение \(value) км/ч" : "отдаляется \(value) км/ч"
    }

    /// Spoken/VoiceOver summary of the HUD.
    static func accessibilitySummary(_ assessment: FollowingDistanceAssessment, policy: FollowingDistancePolicy,
                                     hasLead: Bool) -> String {
        var parts: [String] = []
        if hasLead, let d = assessment.distanceMeters {
            parts.append("До машины впереди примерно \(RVFormat.gapMeters(d).replacingOccurrences(of: " м", with: " метров")) (оценка)")
            parts.append(assessment.status.displayName)
        } else {
            parts.append("Машина впереди не найдена")
        }
        if assessment.isStopped {
            parts.append("При остановке рекомендуется не меньше \(RVFormat.compactNumber(policy.stoppedGapMeters)) метров")
        } else {
            parts.append("Рекомендуемая дистанция не меньше \(RVFormat.gapMeters(assessment.recommendedDistanceMeters).replacingOccurrences(of: " м", with: " метров"))")
        }
        if let ttc = assessment.timeToCollisionSeconds {
            parts.append("До столкновения около \(RVFormat.gapSeconds(ttc).replacingOccurrences(of: " с", with: " секунд"))")
        }
        return parts.joined(separator: ". ")
    }
}
