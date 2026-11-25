import SwiftUI

/// Compact card about the road the user is on: name (OSM `name:ru` preferred), road class, lanes in the travel
/// direction / total with the turn arrows, speed (with the limit sign), and — when expanded — surface, lighting,
/// one-way, typical speed and the data source of every value (OSM via Overpass, Valhalla trace attributes).
struct CurrentRoadCard: View {
    @Environment(AppState.self) private var app
    @AppStorage("rv.roadCardExpanded") private var isExpanded = false
    /// Next maneuver (highlights matching lane arrows); nil without guidance.
    var nextManeuver: ManeuverType?

    var body: some View {
        let nav = app.navigation
        let road = app.roadInfo.currentRoad
        let edge = nav.currentEdge
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(RVTheme.snappy) { isExpanded.toggle() }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(roadName(road: road, edge: edge))
                                .font(RVTheme.font(15, weight: .bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            if let ref = road?.ref, ref != road?.name {
                                Text(ref)
                                    .font(RVTheme.font(10, weight: .heavy))
                                    .padding(.horizontal, 4)
                                    .background(Color.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
                            }
                        }
                        HStack(spacing: 6) {
                            if let roadClass = roadClass(road: road, edge: edge) {
                                Text(roadClass)
                                    .font(RVTheme.font(11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.75))
                                    .lineLimit(1)
                            }
                            if let lanes = laneText(road: road, edge: edge) {
                                Label(lanes, systemImage: "road.lanes")
                                    .font(RVTheme.font(11, weight: .semibold))
                                    .monospacedDigit()
                                    .lineLimit(1)
                            }
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(isExpanded ? "Свернуть сведения о дороге" : "Подробнее о дороге")

                SpeedometerView(speedKmh: app.location.speedKmh,
                                limitKmh: speedLimit(road: road, edge: edge),
                                warningTolerance: app.settings.speedWarningTolerance,
                                compact: true,
                                warningEnabled: app.settings.speedWarningEnabled)
            }
            if isExpanded {
                details(road: road, edge: edge)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .rvGlass(cornerRadius: RVTheme.Radius.panel)
    }

    // MARK: Details

    @ViewBuilder
    private func details(road: RoadSegmentInfo?, edge: RouteEdgeAttributes?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let road, !road.laneInfo.lanes.isEmpty {
                HStack(spacing: 6) {
                    LaneGuidanceView(laneInfo: road.laneInfo, maneuver: nextManeuver ?? .straight)
                        .scaleEffect(0.8, anchor: .leading)
                        .frame(height: 38)
                    SourceTag(text: "OSM turn:lanes")
                }
            }
            FlowRows(items: facts(road: road, edge: edge))
        }
        .padding(.trailing, 8)
        .padding(.bottom, 4)
    }

    private struct Fact: Hashable {
        let symbol: String
        let text: String
        let source: String
    }

    private func facts(road: RoadSegmentInfo?, edge: RouteEdgeAttributes?) -> [Fact] {
        var result: [Fact] = []
        if let limit = road?.speedLimit {
            let text = limit.isImplicit ? "Лимит \(limit.kmh) км/ч (по типу зоны)" : "Лимит \(limit.kmh) км/ч"
            result.append(Fact(symbol: "speedometer", text: text, source: "OSM"))
        }
        if let limit = edge?.speedLimitKmh, limit != road?.speedLimit?.kmh {
            result.append(Fact(symbol: "speedometer", text: "Лимит \(limit) км/ч", source: "Valhalla"))
        }
        if let info = road?.laneInfo {
            var parts: [String] = []
            if let mine = info.lanesInDirection { parts.append("в моём направлении \(info.isEstimated ? "≈" : "")\(mine)") }
            if let opposite = info.lanesOpposite, opposite > 0 { parts.append("встречных \(opposite)") }
            if let total = info.totalLanes { parts.append("всего \(total)") }
            if !parts.isEmpty {
                result.append(Fact(symbol: "road.lanes", text: "Полосы: " + parts.joined(separator: ", "),
                                   source: info.isEstimated ? "оценка по классу" : "OSM"))
            }
            result.append(Fact(symbol: info.isOneway ? "arrow.up" : "arrow.up.arrow.down",
                               text: info.isOneway ? "Одностороннее" : "Двустороннее", source: "OSM"))
        }
        if let lanes = edge?.laneCount, lanes > 1 {
            result.append(Fact(symbol: "road.lanes", text: "Полос по ходу: \(lanes)", source: "Valhalla"))
        }
        if let surface = road?.surfaceDisplayName {
            result.append(Fact(symbol: "square.grid.3x3.fill", text: surface, source: "OSM"))
        } else if let surface = RouteEdgeAttributes.surfaceDisplayName(edge?.surface) {
            result.append(Fact(symbol: "square.grid.3x3.fill", text: surface, source: "Valhalla"))
        }
        if let lit = road?.lit {
            result.append(Fact(symbol: lit ? "lightbulb.fill" : "lightbulb.slash",
                               text: lit ? "Освещение есть" : "Без освещения", source: "OSM"))
        }
        if let typical = edge?.typicalSpeedKmh, typical > 0 {
            result.append(Fact(symbol: "gauge.with.dots.needle.50percent",
                               text: "Типичная скорость ≈ \(Int(typical.rounded())) км/ч (оценка)", source: "Valhalla"))
        }
        if edge?.isTunnel == true { result.append(Fact(symbol: "road.lanes", text: "Тоннель", source: "Valhalla")) }
        if edge?.isBridge == true { result.append(Fact(symbol: "road.lanes", text: "Мост", source: "Valhalla")) }
        if edge?.isToll == true { result.append(Fact(symbol: "dollarsign.circle", text: "Платный участок", source: "Valhalla")) }
        if result.isEmpty {
            result.append(Fact(symbol: "questionmark.circle", text: "Нет данных OSM о дороге", source: "OSM"))
        }
        return result
    }

    // MARK: Values

    private func roadName(road: RoadSegmentInfo?, edge: RouteEdgeAttributes?) -> String {
        if let road { return road.displayName }
        if let name = edge?.names.first, !name.isEmpty { return name }
        return "Дорога"
    }

    private func roadClass(road: RoadSegmentInfo?, edge: RouteEdgeAttributes?) -> String? {
        road?.roadClassName ?? RouteEdgeAttributes.roadClassDisplayName(edge?.roadClass)
    }

    private func speedLimit(road: RoadSegmentInfo?, edge: RouteEdgeAttributes?) -> Int? {
        edge?.speedLimitKmh ?? road?.speedLimit?.kmh
    }

    /// "3 из 6", "≈2". Valhalla's per-direction count is preferred; a Valhalla value of 1 may mean "not tagged",
    /// so then the OSM count (when it is not itself a guess) wins and a remaining 1 is marked "≈".
    private func laneText(road: RoadSegmentInfo?, edge: RouteEdgeAttributes?) -> String? {
        let osm = road?.laneInfo
        let osmCount = osm?.lanesInDirection
        let osmEstimated = osm?.isEstimated ?? true
        var count: Int?
        var estimated = false
        if let valhalla = edge?.laneCount, valhalla > 1 || osmCount == nil || osmEstimated {
            count = valhalla
            estimated = valhalla == 1
        } else if let osmCount {
            count = osmCount
            estimated = osmEstimated
        }
        guard let count else { return nil }
        var text = (estimated ? "≈" : "") + "\(count)"
        if let total = osm?.totalLanes, total > count { text += " из \(total)" }
        return text
    }

    /// Wrapping rows of small facts with their sources.
    private struct FlowRows: View {
        let items: [Fact]

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items, id: \.self) { fact in
                    HStack(spacing: 5) {
                        Image(systemName: fact.symbol)
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 14)
                        Text(fact.text)
                            .font(RVTheme.font(11, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        SourceTag(text: fact.source)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}
