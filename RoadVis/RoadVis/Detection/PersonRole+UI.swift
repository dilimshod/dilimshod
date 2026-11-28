import UIKit

// Display of the person-role colour heuristic (`PersonRoleClassifier`): names, SF Symbols. The role is always shown
// with "≈" — it is guessed from the vest colour, not recognised by a trained model.
extension PersonRole {
    /// "YHXX xodimi" / "Сотрудник ГАИ (YHXX)" / "Traffic police officer".
    var localizedName: String { L("role.\(rawValue)") }

    /// "≈ YHXX xodimi" — the label of a box (marked as an estimate).
    var approximateName: String { "≈ " + localizedName }

    /// Officer: shield badge (SF Symbols 5 "person.badge.shield.checkmark.fill" when the system has it, else
    /// "shield.fill"); road worker: "hammer.fill"; pedestrian: "figure.walk".
    var symbolName: String {
        switch self {
        case .trafficOfficer: return Self.officerSymbol
        case .roadWorker: return "hammer.fill"
        case .pedestrian: return "figure.walk"
        }
    }

    private static let officerSymbol: String = {
        let preferred = "person.badge.shield.checkmark.fill"
        return UIImage(systemName: preferred) != nil ? preferred : "shield.fill"
    }()
}

extension TrackedObject {
    /// Officer / road worker role of a person track (nil for pedestrians and other classes).
    var roadStaffRole: PersonRole? {
        guard kind == .person, let role = personRole, role.isRoadStaff else { return nil }
        return role
    }
}
