import SwiftUI

/// Bottom panel during guidance. Always visible (compact): arrival time, remaining time & distance, "Завершить",
/// the route strip and one line of chips (signals ahead with ≈ wait, live congestion estimate, weather).
/// Expanded (tap the header): the "Впереди" timeline (next 10 events with distance and ETA offset, expandable to the
/// whole route), the next signal with its estimated wait and source, congestion details, weather at the current
/// position / midpoint / destination with road warnings, and data-source notes. Estimates are labelled "≈ … (оценка)".
struct TripInfoPanel: View {
    @Environment(AppState.self) private var app
    @AppStorage("rv.tripPanelExpanded") private var isExpanded = false
    @State private var showsWholeRoute = false

    var body: some View {
        let nav = app.navigation
        VStack(alignment: .leading, spacing: 6) {
            header(nav)
            if nav.progress != nil {
                RouteStripView(totalDistance: nav.routeLength, distanceAlong: nav.distanceAlong,
                               segments: nav.speedLimitSegments, events: nav.timeline)
                chips(nav)
            }
            if isExpanded, let progress = nav.progress {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        timelineSection(nav)
                        signalSection(nav, progress: progress)
                        congestionSection(nav)
                        weatherSection(nav)
                        notesSection(nav)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .rvGlass(cornerRadius: RVTheme.Radius.card)
        .animation(RVTheme.snappy, value: isExpanded)
    }

    // MARK: Header

    private func header(_ nav: NavigationService) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                withAnimation(RVTheme.snappy) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let progress = nav.progress {
                        Text(RVFormat.clock(Date().addingTimeInterval(progress.remainingTimeSeconds)))
                            .font(RVTheme.font(20, weight: .bold))
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
                            ProgressView().controlSize(.small)
                            Text("Ожидание GPS…").font(.subheadline.weight(.semibold))
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

    // MARK: Chips

    private func chips(_ nav: NavigationService) -> some View {
        let summary = signalSummary(nav, along: nav.distanceAlong)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if summary.count > 0 {
                    chip(symbol: "light.beacon.max", tint: .orange,
                         text: "\(summary.count) · ≈ \(RVFormat.duration(summary.seconds))")
                        .accessibilityLabel("Светофоров впереди \(summary.count), ожидание примерно \(RVFormat.duration(summary.seconds)), оценка")
                }
                if let level = nav.congestion {
                    chip(symbol: "car.2.fill", tint: NavigatorStyle.congestionColor(level), text: level.displayName + " ≈")
                } else if nav.isWaitingAtSignal {
                    chip(symbol: "pause.circle", tint: .secondary, text: "у светофора")
                }
                let cameras = nav.upcomingEvents().filter { $0.kind == .feature(.speedCamera) }
                if let camera = cameras.first {
                    chip(symbol: "camera.fill", tint: .purple,
                         text: RVFormat.distance(max(0, camera.distanceAlongRoute - nav.distanceAlong)))
                        .accessibilityLabel("Камера через \(RVFormat.distance(camera.distanceAlongRoute - nav.distanceAlong))")
                }
                if let weather = app.weather.current {
                    chip(symbol: weather.symbolName, tint: weather.roadWarnings.isEmpty ? .secondary : .orange,
                         text: weather.temperatureC.map { "\(Int($0.rounded()))°" } ?? weather.conditionDescription)
                }
                if let destination = nav.routeWeather.points.last?.snapshot, let t = destination.temperatureC {
                    chip(symbol: "flag.checkered", tint: destination.roadWarnings.isEmpty ? .secondary : .orange,
                         text: "\(Int(t.rounded()))°")
                        .accessibilityLabel("Погода в пункте назначения \(Int(t.rounded())) градусов")
                }
            }
        }
    }

    private func chip(symbol: String, tint: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
                .symbolRenderingMode(.multicolor)
            Text(text)
                .font(RVTheme.font(11, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Color.white.opacity(0.08), in: Capsule())
    }

    // MARK: Timeline

    @ViewBuilder
    private func timelineSection(_ nav: NavigationService) -> some View {
        let all = nav.upcomingEvents()
        let shown = showsWholeRoute ? all : Array(all.prefix(10))
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Впереди", trailing: all.isEmpty ? nil : "\(all.count) событий")
            if shown.isEmpty {
                Text(nav.isLoadingRouteAttributes || app.roadInfo.isLoadingRouteFeatures
                     ? "Загружаю данные о маршруте…" : "Событий впереди нет")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(shown) { event in
                TimelineRow(event: event,
                            distanceAhead: max(0, event.distanceAlongRoute - nav.distanceAlong),
                            timeAhead: nav.timeUntil(event))
            }
            if all.count > 10 {
                Button(showsWholeRoute ? "Только ближайшие" : "Весь маршрут (\(all.count))") {
                    withAnimation(RVTheme.snappy) { showsWholeRoute.toggle() }
                }
                .font(.caption.weight(.semibold))
                .frame(minHeight: 32)
            }
        }
    }

    // MARK: Signals

    @ViewBuilder
    private func signalSection(_ nav: NavigationService, progress: RouteProgress) -> some View {
        let along = progress.distanceAlong
        let summary = signalSummary(nav, along: along)
        if summary.count > 0 || nav.distanceToNextSignal != nil {
            VStack(alignment: .leading, spacing: 4) {
                sectionTitle("Светофоры", trailing: nil)
                if summary.count > 0 {
                    Text("Впереди: \(summary.count) · суммарное ожидание ≈ \(RVFormat.duration(summary.seconds)) (оценка)")
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                }
                nextSignalRow(nav, along: along)
                Text(TrafficSignalService.estimateDisclaimer)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Count and summed expected wait of signals ahead: route signals from `TrafficSignalService`,
    /// else Valhalla's signal list with the fixed-time model.
    private func signalSummary(_ nav: NavigationService, along: Double) -> (count: Int, seconds: Double) {
        let fromService = app.signals.totalExpectedWait(fromDistance: along)
        if fromService.count > 0 { return fromService }
        let count = nav.edgeSignalDistances.filter { $0 >= along - 10 }.count
        guard count > 0 else { return (0, 0) }
        let model = SignalWaitModel.estimate(app.settings.signalAssumptions)
        return (count, Double(count) * model.expectedWaitSeconds)
    }

    /// "по вашим поездкам" only for learned estimates, "частично по поездкам" when blended, else "модель".
    static func signalSourceText(_ source: SignalWaitEstimate.Source) -> String {
        switch source {
        case .learned: return "по вашим поездкам"
        case .blended: return "частично по поездкам"
        case .model: return "модель"
        }
    }

    @ViewBuilder
    private func nextSignalRow(_ nav: NavigationService, along: Double) -> some View {
        if let next = app.signals.upcoming(fromDistance: along, limit: 1).first {
            signalRow(distance: next.distanceAhead,
                      waitText: "≈ \(RVFormat.duration(next.estimate.expectedWaitSeconds)) (оценка)",
                      sourceText: Self.signalSourceText(next.estimate.source),
                      stopProbability: next.estimate.stopProbability)
        } else if let distance = nav.distanceToNextSignal {
            let model = SignalWaitModel.estimate(app.settings.signalAssumptions)
            signalRow(distance: distance,
                      waitText: "≈ \(RVFormat.duration(model.expectedWaitSeconds)) (оценка)",
                      sourceText: Self.signalSourceText(.model),
                      stopProbability: model.stopProbability)
        }
    }

    private func signalRow(distance: Double, waitText: String, sourceText: String, stopProbability: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Ближайший через \(RVFormat.distance(distance)) · ожидание \(waitText)")
                .font(.footnote)
                .monospacedDigit()
            HStack(spacing: 6) {
                Text("Источник: \(sourceText) · вероятность остановки ≈ \(Int((stopProbability * 100).rounded()))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let color = app.recognition.currentLightColor, color != .unknown, distance < 150 {
                    HStack(spacing: 4) {
                        TrafficLightDotView(color: color, size: 10)
                        Text("камера: \(color.displayName.lowercased())")
                    }
                    .font(.caption2.weight(.semibold))
                }
            }
        }
    }

    // MARK: Congestion

    private func congestionSection(_ nav: NavigationService) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Загруженность", trailing: nil)
            if let level = nav.congestion {
                HStack(spacing: 8) {
                    Circle().fill(NavigatorStyle.congestionColor(level)).frame(width: 10, height: 10)
                    Text("\(level.displayName) · по вашей скорости (оценка)")
                        .font(.footnote.weight(.semibold))
                }
                if let own = nav.averageSpeedKmh, let typical = nav.currentEdge?.typicalSpeedKmh {
                    Text("Ваша средняя ≈ \(Int(own.rounded())) км/ч, типичная для участка ≈ \(Int(typical.rounded())) км/ч")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if nav.isWaitingAtSignal {
                Label("Стоим у светофора — оценка приостановлена", systemImage: "pause.circle")
                    .font(.footnote)
            } else {
                Label("Недостаточно данных для оценки", systemImage: "speedometer")
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
        return "Бесплатных данных о пробках в реальном времени для этого региона нет. Загруженность оценивается "
            + "по вашей скорости относительно типичной скорости участка (Valhalla/OSM) — один автомобиль, не данные о трафике."
    }

    // MARK: Weather

    @ViewBuilder
    private func weatherSection(_ nav: NavigationService) -> some View {
        let route = nav.routeWeather.points
        if app.weather.current != nil || !route.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                sectionTitle("Погода", trailing: "Open-Meteo")
                if let weather = app.weather.current {
                    WeatherLine(label: "Здесь", snapshot: weather, error: nil)
                }
                ForEach(route) { point in
                    WeatherLine(label: point.label, snapshot: point.snapshot, error: point.error)
                }
            }
        }
    }

    // MARK: Notes

    @ViewBuilder
    private func notesSection(_ nav: NavigationService) -> some View {
        let notes = [nav.routeAttributesError, app.roadInfo.routeFeaturesCoverageNote].compactMap { $0 }
        if !notes.isEmpty || nav.selectedRouteOption != nil {
            VStack(alignment: .leading, spacing: 3) {
                sectionTitle("Источники", trailing: nil)
                if let option = nav.selectedRouteOption {
                    Text("Маршрут: \(option.sources.map(\.badge).joined(separator: ", ")). Ограничения и полосы: "
                         + "Valhalla (OSM). Объекты на маршруте: OpenStreetMap (Overpass).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(notes, id: \.self) { note in
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func sectionTitle(_ title: String, trailing: String?) -> some View {
        HStack {
            Text(title.uppercased())
                .font(RVTheme.font(10, weight: .bold))
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(RVTheme.font(10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One event of the "Впереди" list.
struct TimelineRow: View {
    let event: RouteTimelineEvent
    let distanceAhead: Double
    let timeAhead: Double?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: event.symbolName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(NavigatorStyle.eventColor(event.kind), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(event.title)
                    .font(RVTheme.font(12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                HStack(spacing: 4) {
                    if let detail = event.detail, !detail.isEmpty {
                        Text(detail).lineLimit(1)
                    }
                    SourceTag(text: event.source, color: .secondary)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 0) {
                Text(RVFormat.distance(distanceAhead))
                    .font(RVTheme.font(12, weight: .bold))
                    .monospacedDigit()
                if let timeAhead, timeAhead >= 30 {
                    Text("≈ \(RVFormat.duration(timeAhead))")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Пункт назначения: +12°, дождь …" with the first road warning.
struct WeatherLine: View {
    let label: String
    let snapshot: WeatherSnapshot?
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: snapshot?.symbolName ?? "cloud")
                    .symbolRenderingMode(.multicolor)
                    .frame(width: 18)
                Text(label + ": ")
                    .font(.footnote.weight(.semibold))
                + Text(snapshot?.summary ?? error.map { "нет данных (\($0))" } ?? "загрузка…")
                    .font(.footnote)
            }
            .lineLimit(2)
            ForEach(snapshot?.roadWarnings.prefix(2).map { $0 } ?? [], id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
    }
}
