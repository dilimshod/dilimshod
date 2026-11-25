import SwiftUI

/// Bottom panel during guidance (collapsible, collapsed by default to one line): arrival time, remaining time & distance, live congestion estimate,
/// traffic signals ahead with estimated waits, the next signal, upcoming hazards, reported incidents, weather and
/// the "Завершить" button. Every estimated value is labelled "≈ … (оценка)".
struct TripInfoPanel: View {
    @Environment(AppState.self) private var app
    @AppStorage("rv.tripPanelExpanded") private var isExpanded = false

    var body: some View {
        let nav = app.navigation
        VStack(alignment: .leading, spacing: 6) {
            header(nav)

            if isExpanded, let progress = nav.progress {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 8) {
                        congestionSection(nav)
                        signalSection(nav, progress: progress)
                        hazardSection(nav, progress: progress)
                        incidentSection(nav, progress: progress)
                        weatherSection
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
                .font(.footnote)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        .animation(.easeInOut(duration: 0.25), value: isExpanded)
    }

    // MARK: Header

    private func header(_ nav: NavigationService) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let progress = nav.progress {
                        Text(RVFormat.clock(Date().addingTimeInterval(progress.remainingTimeSeconds)))
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text(RVFormat.duration(progress.remainingTimeSeconds))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                        Text(RVFormat.distance(progress.remainingDistance))
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Ожидание GPS…")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(headerAccessibilityText(nav))
            .accessibilityHint(isExpanded ? "Свернуть подробности" : "Показать подробности")

            Button(role: .destructive) {
                nav.stopNavigation()
            } label: {
                Text("Завершить")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 4)
                    .frame(minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .buttonBorderShape(.capsule)
            .frame(minHeight: 44)
        }
    }

    private func headerAccessibilityText(_ nav: NavigationService) -> String {
        guard let progress = nav.progress else { return "Ожидание GPS" }
        let arrival = RVFormat.clock(Date().addingTimeInterval(progress.remainingTimeSeconds))
        return "Прибытие в \(arrival), осталось \(RVFormat.duration(progress.remainingTimeSeconds)), "
            + RVFormat.distance(progress.remainingDistance)
    }

    // MARK: Congestion

    @ViewBuilder
    private func congestionSection(_ nav: NavigationService) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let level = nav.congestion {
                HStack(spacing: 8) {
                    Circle()
                        .fill(color(for: level))
                        .frame(width: 12, height: 12)
                    Text("\(level.displayName) · по вашей скорости (оценка)")
                        .font(.footnote.weight(.semibold))
                }
            } else if nav.isWaitingAtSignal {
                Label("Стоим у светофора — оценка загруженности приостановлена", systemImage: "pause.circle")
                    .font(.footnote)
            } else {
                Label("Загруженность: недостаточно данных для оценки", systemImage: "speedometer")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(trafficNote(nav))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func trafficNote(_ nav: NavigationService) -> String {
        guard let option = nav.selectedRouteOption else { return "" }
        if let traffic = option.traffic {
            return "Apple Maps: \(traffic.summary)."
        }
        if option.source == .valhalla {
            return "Данные о пробках в реальном времени для этого региона недоступны (слой пробок Apple здесь пуст). "
                + "Загруженность оценивается по вашей скорости относительно типичной для участка."
        }
        return "Задержку из-за пробок по данным Apple определить не удалось."
    }

    // MARK: Signals

    @ViewBuilder
    private func signalSection(_ nav: NavigationService, progress: RouteProgress) -> some View {
        let along = progress.distanceAlong
        let summary = signalSummary(nav, along: along)
        if summary.count > 0 || nav.distanceToNextSignal != nil {
            VStack(alignment: .leading, spacing: 4) {
                if summary.count > 0 {
                    Label {
                        Text("Светофоров впереди: \(summary.count) · ожидание ≈ \(RVFormat.duration(summary.seconds)) (оценка)")
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "light.beacon.max")
                            .foregroundStyle(.orange)
                    }
                    .font(.footnote.weight(.semibold))
                }
                nextSignalRow(nav, along: along)
            }
        }
    }

    /// Count and summed expected wait of signals ahead: learned/route signals from `TrafficSignalService`,
    /// else Valhalla's signal list with the fixed-time model.
    private func signalSummary(_ nav: NavigationService, along: Double) -> (count: Int, seconds: Double) {
        let fromService = app.signals.totalExpectedWait(fromDistance: along)
        if fromService.count > 0 { return fromService }
        let count = nav.edgeSignalDistances.filter { $0 >= along - 10 }.count
        guard count > 0 else { return (0, 0) }
        let model = SignalWaitModel.estimate(app.settings.signalAssumptions)
        return (count, Double(count) * model.expectedWaitSeconds)
    }

    @ViewBuilder
    private func nextSignalRow(_ nav: NavigationService, along: Double) -> some View {
        if let next = app.signals.upcoming(fromDistance: along, limit: 1).first {
            signalRow(distance: next.distanceAhead,
                      waitText: "≈ \(RVFormat.duration(next.estimate.expectedWaitSeconds)) (оценка)",
                      sourceText: next.estimate.source == .model ? "модель" : "по вашим поездкам",
                      stopProbability: next.estimate.stopProbability)
        } else if let distance = nav.distanceToNextSignal {
            let model = SignalWaitModel.estimate(app.settings.signalAssumptions)
            signalRow(distance: distance,
                      waitText: "≈ \(RVFormat.duration(model.expectedWaitSeconds)) (оценка)",
                      sourceText: "модель",
                      stopProbability: model.stopProbability)
        }
    }

    private func signalRow(distance: Double, waitText: String, sourceText: String, stopProbability: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Ближайший через \(RVFormat.distance(distance))")
                    .monospacedDigit()
                Text("·")
                Text("ожидание \(waitText)")
                    .monospacedDigit()
            }
            .font(.footnote)
            HStack(spacing: 6) {
                Text("Источник: \(sourceText) · вероятность остановки ≈ \(Int((stopProbability * 100).rounded()))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let color = app.recognition.currentLightColor, color != .unknown, distance < 150 {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(lightColor(color))
                            .frame(width: 10, height: 10)
                        Text("камера: \(color.displayName.lowercased())")
                    }
                    .font(.caption2.weight(.semibold))
                }
            }
        }
    }

    // MARK: Hazards & incidents

    @ViewBuilder
    private func hazardSection(_ nav: NavigationService, progress: RouteProgress) -> some View {
        let hazards = Array(nav.upcomingFeatures.filter { $0.kind != .trafficSignals }.prefix(3))
        if !hazards.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(hazards) { feature in
                    HStack(spacing: 10) {
                        Image(systemName: feature.kind.symbolName)
                            .font(.subheadline)
                            .foregroundStyle(hazardColor(feature.kind))
                            .frame(width: 22)
                        Text(feature.name.map { "\(feature.kind.displayName) · \($0)" } ?? feature.kind.displayName)
                            .font(.footnote)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(RVFormat.distance(max(0, feature.distanceAlongRoute - progress.distanceAlong)))
                            .font(.footnote.weight(.semibold))
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func incidentSection(_ nav: NavigationService, progress: RouteProgress) -> some View {
        let ahead = Array(nav.incidentsOnRoute.filter { $0.distanceAlongRoute >= progress.distanceAlong - 20 }.prefix(3))
        if !ahead.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(ahead) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.incident.kind.symbolName)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.incident.kind.displayName)
                                .font(.footnote.weight(.semibold))
                            Text("ваша отметка, \(RVFormat.clock(item.incident.date))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Text(RVFormat.distance(max(0, item.distanceAlongRoute - progress.distanceAlong)))
                            .font(.footnote.weight(.semibold))
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    // MARK: Weather

    @ViewBuilder
    private var weatherSection: some View {
        if let weather = app.weather.current {
            VStack(alignment: .leading, spacing: 2) {
                Label(weather.summary, systemImage: weather.symbolName)
                    .font(.footnote)
                    .symbolRenderingMode(.multicolor)
                if let warning = weather.roadWarnings.first {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: Colours

    private func color(for level: CongestionLevel) -> Color {
        switch level {
        case .free: return .green
        case .light: return .yellow
        case .moderate: return .orange
        case .heavy: return .red
        case .severe: return Color(red: 0.6, green: 0, blue: 0)
        }
    }

    private func lightColor(_ color: TrafficLightColor) -> Color {
        switch color {
        case .red: return .red
        case .yellow: return .yellow
        case .green: return .green
        case .unknown: return .gray
        }
    }

    private func hazardColor(_ kind: RouteFeatureKind) -> Color {
        switch kind {
        case .speedCamera: return .purple
        case .school, .kindergarten: return .yellow
        case .pedestrianCrossing: return .blue
        case .railwayCrossing: return .gray
        case .construction, .trafficSignals: return .orange
        case .trafficCalming: return .brown
        case .stopSign, .giveWay: return .red
        }
    }
}
