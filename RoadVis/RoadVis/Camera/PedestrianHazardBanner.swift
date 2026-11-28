import SwiftUI

/// Compact warning capsule shown near the top centre of the camera screen while a pedestrian is on / about to enter
/// the roadway ahead: red "Yield to the pedestrian!" (danger) or orange "Caution, pedestrian" (caution), with a walking
/// figure and the ≈ distance. It stays small so the road picture in the centre remains free.
struct PedestrianHazardBanner: View {
    let hazard: PedestrianHazard

    private var isDanger: Bool { hazard.level == .danger }

    private var title: String {
        L(isDanger ? "ped.banner.danger" : "ped.banner.caution")
    }

    private var distanceText: String? {
        guard let d = hazard.distanceMeters, d.isFinite, d > 0 else { return nil }
        return "≈ " + RVFormat.gapMeters(d)
    }

    var body: some View {
        let color = RVTheme.pedestrianColor(hazard.level)
        HStack(spacing: 7) {
            Image(systemName: "figure.walk")
                .font(.system(size: 15, weight: .heavy))
            Text(title)
                .font(RVTheme.font(15, weight: .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let distanceText {
                Text(distanceText)
                    .font(RVTheme.font(13, weight: .bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Color.black.opacity(0.22), in: Capsule())
                    .contentTransition(.numericText())
            }
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(color.opacity(isDanger ? 0.92 : 0.88), in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.45), lineWidth: 1))
        .shadow(color: color.opacity(0.6), radius: 8, x: 0, y: 2)
        .rvPulse(isDanger, minOpacity: 0.75, period: 0.9)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var accessibilityText: String {
        guard let d = hazard.distanceMeters, d.isFinite, d > 0 else { return title }
        return title + ", " + L("common.approxWord") + " " + RVFormat.appSpokenMeters(d) + " (" + L("common.estimate") + ")"
    }
}

/// Tiny red / orange badge with a walking figure (and ≈ distance) for the picture-in-picture camera window.
struct PedestrianHazardBadge: View {
    let hazard: PedestrianHazard

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "figure.walk")
                .font(.system(size: 10, weight: .heavy))
            if let d = hazard.distanceMeters, d.isFinite, d > 0 {
                Text(verbatim: "≈ " + RVFormat.gapMeters(d))
                    .rvNumeric(11, weight: .heavy)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(RVTheme.pedestrianColor(hazard.level), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 0.5))
        .rvPulse(hazard.level == .danger, minOpacity: 0.6, period: 0.8)
        .accessibilityHidden(true)
    }
}

/// Blue (traffic police officer) or orange (road workers) capsule for road staff on / at the roadway — they are on the
/// road deliberately, so no "yield to the pedestrian". The role is a colour heuristic, hence "≈".
struct RoadStaffBanner: View {
    let sighting: RoadStaffSighting

    private var title: String {
        L(sighting.role == .trafficOfficer ? "staff.banner.officer" : "staff.banner.workers")
    }

    var body: some View {
        let color = RVTheme.roleColor(sighting.role) ?? RVTheme.pedestrianCaution
        HStack(spacing: 7) {
            Image(systemName: sighting.role.symbolName)
                .font(.system(size: 15, weight: .heavy))
            Text(verbatim: "≈ " + title)
                .font(RVTheme.font(15, weight: .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let d = sighting.distanceMeters, d.isFinite, d > 0 {
                Text(verbatim: "≈ " + RVFormat.gapMeters(d))
                    .font(RVTheme.font(13, weight: .bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Color.black.opacity(0.22), in: Capsule())
                    .contentTransition(.numericText())
            }
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(color.opacity(0.9), in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.45), lineWidth: 1))
        .shadow(color: color.opacity(0.6), radius: 8, x: 0, y: 2)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title + " (" + L("role.heuristic") + ")")
    }
}

/// Tiny blue / orange badge with the role symbol for the picture-in-picture camera window.
struct RoadStaffBadge: View {
    let sighting: RoadStaffSighting

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: sighting.role.symbolName)
                .font(.system(size: 10, weight: .heavy))
            if let d = sighting.distanceMeters, d.isFinite, d > 0 {
                Text(verbatim: "≈ " + RVFormat.gapMeters(d))
                    .rvNumeric(11, weight: .heavy)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(RVTheme.roleColor(sighting.role) ?? RVTheme.pedestrianCaution, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

#Preview {
    let box = BBox(x: 0.48, y: 0.5, width: 0.05, height: 0.16)
    return VStack(spacing: 12) {
        PedestrianHazardBanner(hazard: PedestrianHazard(trackID: 1, box: box, level: .danger, distanceMeters: 12,
                                                        inOwnLane: true, onRoadway: true, approaching: false))
        PedestrianHazardBanner(hazard: PedestrianHazard(trackID: 2, box: box, level: .caution, distanceMeters: 27,
                                                        inOwnLane: false, onRoadway: true, approaching: true))
        PedestrianHazardBadge(hazard: PedestrianHazard(trackID: 1, box: box, level: .danger, distanceMeters: 12,
                                                       inOwnLane: true, onRoadway: true, approaching: false))
        RoadStaffBanner(sighting: RoadStaffSighting(trackID: 3, role: .trafficOfficer, box: box, distanceMeters: 35,
                                                    onRoadway: true, inOwnLane: false))
        RoadStaffBanner(sighting: RoadStaffSighting(trackID: 4, role: .roadWorker, box: box, distanceMeters: 22,
                                                    onRoadway: false, inOwnLane: false))
    }
    .padding()
    .background(Color(white: 0.25))
}
