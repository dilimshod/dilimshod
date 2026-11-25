import SwiftUI

/// Route preview panel: one card per alternative (time, distance, arrival, source, signals, tolls / highways,
/// traffic estimate, advisories), the routing notice, "Поехали" and "Отмена".
struct RouteOptionsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let nav = app.navigation
        VStack(alignment: .leading, spacing: 10) {
            header(nav)

            if let notice = nav.routingNotice {
                Label(notice, systemImage: "info.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(nav.routeOptions) { option in
                        RouteOptionCard(option: option, isSelected: option.id == nav.selectedRouteOption?.id)
                            .onTapGesture {
                                nav.selectedRouteID = option.id
                            }
                            .accessibilityAddTraits(.isButton)
                    }
                }
            }
            .frame(maxHeight: nav.routeOptions.count > 2 ? 290 : nil)
            .fixedSize(horizontal: false, vertical: nav.routeOptions.count <= 2)

            dataStatus(nav)

            Button {
                nav.startNavigation()
            } label: {
                Label("Поехали", systemImage: "location.north.line.fill")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 58)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .buttonBorderShape(.roundedRectangle(radius: 18))
            .disabled(nav.selectedRouteOption == nil)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }

    private func header(_ nav: NavigationService) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Маршрут")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(nav.destinationName ?? "Пункт назначения")
                    .font(.headline)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                nav.stopNavigation()
            } label: {
                Text("Отмена")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
        }
    }

    @ViewBuilder
    private func dataStatus(_ nav: NavigationService) -> some View {
        if nav.isLoadingRouteAttributes || app.roadInfo.isLoadingRouteFeatures {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Загружаю светофоры, полосы и опасности по маршруту…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let problem = nav.routeAttributesError {
            Label(problem, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
    }
}

/// One alternative in `RouteOptionsView`.
private struct RouteOptionCard: View {
    let option: RouteOption
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(RVFormat.duration(option.expectedTravelTime))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(RVFormat.distance(option.distance))
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text("прибытие \(RVFormat.clock(Date().addingTimeInterval(option.expectedTravelTime)))")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
                Text(option.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)

                badges

                if let traffic = option.traffic {
                    Label("Apple Maps: \(traffic.summary)", systemImage: "car.2.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(trafficColor(traffic.level))
                } else if option.source == .valhalla {
                    Text("Время по данным OSM, без учёта пробок")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(option.route.advisories.prefix(2).enumerated()), id: \.offset) { _, advisory in
                    Label(advisory, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .lineLimit(2)
                }
            }
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(isSelected ? Color.blue : Color.secondary)
                .frame(width: 32)
        }
        .padding(12)
        .frame(minHeight: 64)
        .background(isSelected ? Color.blue.opacity(0.22) : Color.white.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isSelected ? Color.blue : Color.clear, lineWidth: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityValue(isSelected ? "выбран" : "")
    }

    private var badges: some View {
        HStack(spacing: 6) {
            RouteBadge(text: option.source == .apple ? "Apple Maps" : "OSM",
                       systemImage: option.source == .apple ? "map.fill" : "globe",
                       tint: option.source == .apple ? .blue : .green)
            if let signals = option.signalCount {
                RouteBadge(text: "\(signals)", systemImage: "light.beacon.max", tint: .orange)
                    .accessibilityLabel("Светофоров: \(signals)")
            }
            if option.route.hasTolls {
                RouteBadge(text: "Платная", systemImage: "dollarsign.circle", tint: .yellow)
            }
            if option.route.hasHighways {
                RouteBadge(text: "Магистрали", systemImage: "road.lanes", tint: .teal)
            }
        }
    }

    private func trafficColor(_ level: CongestionLevel) -> Color {
        switch level {
        case .free: return .green
        case .light: return .yellow
        case .moderate: return .orange
        case .heavy, .severe: return .red
        }
    }
}

/// Small capsule badge with an icon.
private struct RouteBadge: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.bold))
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(tint.opacity(0.16), in: Capsule())
    }
}
