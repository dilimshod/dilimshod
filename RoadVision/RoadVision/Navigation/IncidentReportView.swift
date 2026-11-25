import SwiftUI
import UIKit

/// Sheet for reporting a road event (accident, road works, jam …) at the current position or at a map point.
/// Reports are stored only on this phone (`IncidentStore`) and expire after the lifetime set in Settings.
struct IncidentReportView: View {
    /// Where the event is; nil = the current GPS position.
    var coordinate: GeoPoint?

    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label(locationText, systemImage: coordinate == nil ? "location.fill" : "mappin.and.ellipse")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(RoadIncidentKind.allCases, id: \.self) { kind in
                            Button {
                                report(kind)
                            } label: {
                                VStack(spacing: 8) {
                                    Image(systemName: kind.symbolName)
                                        .font(.system(size: 30, weight: .semibold))
                                        .foregroundStyle(color(for: kind))
                                    Text(kind.displayName)
                                        .font(.headline)
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2)
                                        .minimumScaleFactor(0.8)
                                }
                                .frame(maxWidth: .infinity, minHeight: 96)
                                .padding(.horizontal, 6)
                                .background(Color.white.opacity(0.08),
                                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(targetCoordinate == nil)
                        }
                    }

                    Text("Отметка сохраняется только на этом телефоне и исчезнет через "
                         + "\(Int(app.settings.incidentLifetimeMinutes.rounded())) мин. "
                         + "Это ваши заметки, а не данные дорожных служб; навигатор предупредит о них на маршруте.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
            .navigationTitle("Сообщить о событии")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
    }

    private var targetCoordinate: GeoPoint? {
        if let coordinate, coordinate.isValid { return coordinate }
        return app.location.coordinate
    }

    private var locationText: String {
        if coordinate != nil { return "Точка, выбранная на карте" }
        return app.location.coordinate == nil
            ? "Нет данных о местоположении — отметка недоступна"
            : "Ваше текущее местоположение"
    }

    private func report(_ kind: RoadIncidentKind) {
        guard let point = targetCoordinate else { return }
        app.incidents.report(kind, at: point)
        app.navigation.refreshIncidents()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }

    private func color(for kind: RoadIncidentKind) -> Color {
        switch kind {
        case .accident, .closure: return .red
        case .roadWork, .hazard: return .orange
        case .jam: return .yellow
        case .police: return .blue
        case .pothole: return .brown
        }
    }
}
