import Foundation

// Text for the following-distance UI (HUD, distance line label, detail card, norms sheet, PiP badge).
// Text follows the app language (`L(_:)`, `RVFormat.app…`): decimals use a comma in uz / ru ("1,4 s") and a point in
// English; estimates carry "≈".

extension RVFormat {
    /// Gap in metres with a precision that suits the value: "1,6 м", "18 м", "125 м"; "—" when unknown.
    static func gapMeters(_ meters: Double?) -> String {
        guard let meters, meters.isFinite else { return "—" }
        let m = max(0, meters)
        if m < 10 { return appDecimal(m, digits: 1) + " " + appMeters }
        if m < 100 { return "\(Int(m.rounded())) " + appMeters }
        return "\(Int((m / 5).rounded() * 5)) " + appMeters
    }

    /// Seconds with one decimal below 10 s: "1,4 с", "12 с"; "—" when unknown.
    static func gapSeconds(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "—" }
        let s = max(0, seconds)
        return s < 10 ? appDecimal(s, digits: 1) + " " + appSeconds : "\(Int(s.rounded())) " + appSeconds
    }

    /// A recommended / threshold gap: like `gapMeters` but without a trailing ",0" ("2 м", "2,5 м", "33 м").
    static func normMeters(_ meters: Double) -> String {
        guard meters.isFinite else { return "—" }
        return meters < 10 ? compactNumber(max(0, meters)) + " " + appMeters : gapMeters(meters)
    }

    /// Spoken quantity with the right Russian form: 12 → "12 метров", 1 → "1 метр", 1,6 → "1,6 метра".
    static func spokenQuantity(_ value: Double, digits: Int = 1, one: String, few: String, many: String) -> String {
        guard value.isFinite else { return "—" }
        let v = max(0, value)
        let factor = pow(10, Double(digits))
        let rounded = (v * factor).rounded() / factor
        if rounded == rounded.rounded() {
            let n = Int(rounded)
            return "\(n) " + plural(n, one, few, many)
        }
        return decimal(rounded, digits: digits) + " " + few   // fractions take the genitive singular: "1,6 метра"
    }

    /// Number without a trailing ",0": 2 → "2", 1.5 → "1,5" ("1.5" in English), 2.25 → "2,3".
    static func compactNumber(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return "\(Int(rounded))" }
        return appDecimal(rounded, digits: 1)
    }

    /// Spoken metres in the app language: "12 metr" / "12 метров" / "12 metres" (1 decimal below 10).
    static func appSpokenMeters(_ value: Double) -> String { appSpokenQuantity(value, unit: "meter") }

    /// Spoken seconds in the app language: "2 soniya" / "2 секунды" / "2 seconds".
    static func appSpokenSeconds(_ value: Double) -> String { appSpokenQuantity(value, unit: "second") }

    /// Quantity with the unit word in the right form (`unit.<unit>.one/few/many` in the string tables).
    private static func appSpokenQuantity(_ value: Double, unit: String) -> String {
        let digits = value < 10 ? 1 : 0
        let one = L("unit.\(unit).one"), few = L("unit.\(unit).few"), many = L("unit.\(unit).many")
        if RVLang.app == .ru {
            return spokenQuantity(value, digits: digits, one: one, few: few, many: many)
        }
        let number = spokenNumber(value, digits: digits)
        return number + " " + (number == "1" ? one : many)
    }

    /// Number rounded to `digits` without a trailing ",0", with the app language's separator.
    private static func spokenNumber(_ value: Double, digits: Int) -> String {
        guard value.isFinite else { return "—" }
        let factor = pow(10, Double(digits))
        let rounded = (max(0, value) * factor).rounded() / factor
        if rounded == rounded.rounded() { return "\(Int(rounded))" }
        return appDecimal(rounded, digits: digits)
    }
}

/// Localized strings built from a `FollowingDistanceAssessment` and the active `FollowingDistancePolicy`.
enum FollowingDistanceText {
    /// "≈ 18 м" / "≈ 1,6 м"; "—" when there is no estimate.
    static func gap(_ meters: Double?) -> String {
        guard let meters, meters.isFinite, meters > 0 else { return "—" }
        return "≈ " + RVFormat.gapMeters(meters)
    }

    /// Recommended gap, e.g. "≥ 33 м"; "—" while the own speed is unknown (no GPS fix: the norm cannot be computed,
    /// and the assessment is no longer treated as "standing still").
    static func recommended(_ assessment: FollowingDistanceAssessment) -> String {
        guard assessment.ownSpeedKmh != nil else { return "—" }
        return "≥ " + RVFormat.normMeters(assessment.recommendedDistanceMeters)
    }

    /// Caption under the distance on the animated line: "1,4 с · норма ≥ 33 м" (moving) or "норма ≥ 2 м" (standing).
    static func lineCaption(_ assessment: FollowingDistanceAssessment) -> String {
        let norm = L("fd.norm", recommended(assessment))
        if !assessment.isStopped, let headway = assessment.timeHeadwaySeconds {
            return RVFormat.gapSeconds(headway) + " · " + norm
        }
        return norm
    }

    /// Moving requirement: "≥ 2 с ≈ 33 м (сухо)" while moving, "≥ 2 с (сухо)" when standing (the metres depend on speed).
    static func movingNorm(_ assessment: FollowingDistanceAssessment, policy: FollowingDistancePolicy) -> String {
        let gap = policy.timeGap(for: assessment.condition)
        let surface = assessment.condition.localizedName.lowercased()
        // Unknown own speed (no GPS fix): the metres are not known, only the time gap is shown.
        if !assessment.isStopped, assessment.ownSpeedKmh != nil {
            return "≥ \(RVFormat.compactNumber(gap)) \(RVFormat.appSeconds) ≈ \(RVFormat.normMeters(assessment.recommendedDistanceMeters)) (\(surface))"
        }
        return "≥ \(RVFormat.compactNumber(gap)) \(RVFormat.appSeconds) (\(surface))"
    }

    /// Standing requirement: "≥ 2 м".
    static func stoppedNorm(policy: FollowingDistancePolicy) -> String {
        "≥ " + RVFormat.normMeters(policy.stoppedGapMeters)
    }

    /// One line with both requirements for the compact HUD.
    static func compactNorms(_ assessment: FollowingDistanceAssessment, policy: FollowingDistancePolicy) -> String {
        if assessment.isStopped {
            return L("fd.compact.stopped", stoppedNorm(policy: policy),
                     RVFormat.compactNumber(policy.timeGap(for: assessment.condition)) + " " + RVFormat.appSeconds)
        }
        return L("fd.compact.moving", recommended(assessment), stoppedNorm(policy: policy))
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
        return rel < 0 ? L("fd.closing", value) : L("fd.opening", value)
    }

    /// Spoken/VoiceOver summary of the HUD.
    static func accessibilitySummary(_ assessment: FollowingDistanceAssessment, policy: FollowingDistancePolicy,
                                     hasLead: Bool) -> String {
        func meters(_ value: Double) -> String { RVFormat.appSpokenMeters(value) }
        var parts: [String] = []
        if hasLead, let d = assessment.distanceMeters {
            parts.append(L("fd.a11y.lead", meters(d)))
            parts.append(assessment.status.localizedName)
        } else {
            parts.append(L("fd.a11y.noLead"))
        }
        if assessment.isStopped {
            parts.append(L("fd.a11y.stopped", meters(policy.stoppedGapMeters)))
        } else if assessment.ownSpeedKmh != nil {
            parts.append(L("fd.a11y.moving", meters(assessment.recommendedDistanceMeters)))
        }
        if let ttc = assessment.timeToCollisionSeconds {
            parts.append(L("fd.a11y.ttc", RVFormat.appSpokenSeconds(ttc)))
        }
        return parts.joined(separator: ". ")
    }
}
