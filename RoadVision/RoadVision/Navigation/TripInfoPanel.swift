import SwiftUI

/// Bottom panel during guidance (collapsible): arrival time, remaining time & distance, live congestion estimate,
/// traffic signals ahead with estimated waits, the next signal, upcoming hazards, reported incidents, weather and
/// the "Завершить" button. Every estimated value is labelled "≈ … (оценка)".
struct TripInfoPanel: View {
    @Environment(AppState.self) private var app
    @State private var isExpanded = true

    var body: some View {
        let nav = app.navigation
        VStack(alignment: .leading, spacing: 10) {
            Capsule()
                .fill(Color.white.opacity(0.35))
                .frame(width: 38, height: 5)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)

            header(nav)

            if isExpanded, let progress = nav.progress {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        congestionSection(nav)
                        signalSection(nav, progress: progress)
                        hazardSection(nav, progress: progress)
                        incidentSection(nav, progress: progress)
                        weatherSection
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 250)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .animation(.easeInOut(duration: 0.25), value: isExpanded)
    }

    // MARK: Header

    private func header(_ nav: NavigationService) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(alignment: .center, spacing: 14) {
                    if let progress = nav.progress {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(RVFormat.clock(Date().addingTimeInterval(progress.remainingTimeSeconds)))
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text("прибытие")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(RVFormat.duration(progress.remainingTimeSeconds))
                                .font(.headline)
                                .monospacedDigit()
                            Text(RVFormat.distance(progress.remainingDistance))
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Ожидание GPS…")
                                .font(.headline)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(headerAccessibilityText(nav))
            .accessibilityHint(isExpanded ? "Свернуть подробности" : "Показать подробности")

            Button(role: .destructive) {
                nav.stopNavigation()
            } label: {
                Text("Завершить")
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .buttonBorderShape(.capsule)
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
                        .font(.subheadline.weight(.semibold))
                }
            } else if nav.isWaitingAtSignal {
                Label("Стоим у светофора — оценка загруженности приостановлена", systemImage: "pause.circle")
                    .font(.subheadline)
            } else {
                Label("Загруженность: недостаточно данных для оценки", systemImage: "gauge.with.dots.needle.33percent")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(trafficNote(nav))
                .font(.caption)
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
                    .font(.subheadline.weight(.semibold))
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
            .font(.subheadline)
            HStack(spacing: 6) {
                Text("Источник: \(sourceText) · вероятность остановки ≈ \(Int((stopProbability * 100).rounded()))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let color = app.recognition.currentLightColor, color != .unknown, distance < 150 {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(lightColor(color))
                            .frame(width: 10, height: 10)
                        Text("камера: \(color.displayName.lowercased())")
                    }
                    .font(.caption.weight(.semibold))
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
                            .font(.headline)
                            .foregroundStyle(hazardColor(feature.kind))
                            .frame(width: 26)
                        Text(feature.name.map { "\(feature.kind.displayName) · \($0)" } ?? feature.kind.displayName)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(RVFormat.distance(max(0, feature.distanceAlongRoute - progress.distanceAlong)))
                            .font(.subheadline.weight(.semibold))
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
                            .font(.headline)
                            .foregroundStyle(.red)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.incident.kind.displayName)
                                .font(.subheadline.weight(.semibold))
                            Text("ваша отметка, \(RVFormat.clock(item.incident.date))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Text(RVFormat.distance(max(0, item.distanceAlongRoute - progress.distanceAlong)))
                            .font(.subheadline.weight(.semibold))
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
                    .font(.subheadline)
                    .symbolRenderingMode(.multicolor)
                if let warning = weather.roadWarnings.first {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
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
