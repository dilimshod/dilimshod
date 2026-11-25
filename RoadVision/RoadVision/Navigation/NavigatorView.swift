import CoreLocation
import MapKit
import SwiftUI

/// Full-screen navigator: `MKMapView` map below everything, guidance banner + lanes + road strip on top, the live
/// camera window (or a camera button) in the top-left corner, map / app buttons on the right, and a state-dependent
/// bottom panel (search → planning → route options → trip info → arrival).
struct NavigatorView: View {
    @Environment(AppState.self) private var app

    @State private var isFollowing = true
    @State private var showSearch = false
    @State private var incidentTarget: IncidentReportTarget?
    @State private var longPressCoordinate: CLLocationCoordinate2D?
    @State private var showLongPressDialog = false
    @State private var topInset: CGFloat = 0
    @State private var bottomInset: CGFloat = 0

    private static let fixTheMapURL = URL(string: "https://www.openstreetmap.org/fixthemap")!

    var body: some View {
        let nav = app.navigation
        ZStack(alignment: .top) {
            mapLayer(nav)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                topSection(nav)
                    .background(heightReader($topInset))
                cornerRow(nav)
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .frame(maxHeight: .infinity, alignment: .top)

            VStack(spacing: 8) {
                if let error = nav.errorMessage {
                    errorBanner(error, nav: nav)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                bottomSection(nav)
                attributionFooter(nav)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 2)
            .background(heightReader($bottomInset))
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .animation(.easeInOut(duration: 0.25), value: nav.state)
        .animation(.easeInOut(duration: 0.2), value: nav.errorMessage)
        .sheet(isPresented: $showSearch) {
            SearchView(search: nav.placeSearch, userLocation: app.location.coordinate) { item in
                startPlanning(to: item, rememberAsRecent: true)
            }
        }
        .sheet(item: $incidentTarget) { target in
            IncidentReportView(coordinate: target.coordinate)
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog("Точка на карте", isPresented: $showLongPressDialog, titleVisibility: .visible,
                            presenting: longPressCoordinate) { coordinate in
            Button("Маршрут сюда") {
                let item = PlaceSearchService.mapItem(coordinate: GeoPoint(coordinate), name: "Точка на карте")
                startPlanning(to: item, rememberAsRecent: false)
            }
            Button("Сообщить о событии здесь") {
                incidentTarget = IncidentReportTarget(coordinate: GeoPoint(coordinate))
            }
            Button("Отмена", role: .cancel) {}
        }
        .onChange(of: nav.state) { _, newState in
            if newState == .previewing || newState == .navigating {
                isFollowing = true
            }
        }
    }

    // MARK: - Map

    private func mapLayer(_ nav: NavigationService) -> some View {
        let isGuiding = nav.state == .navigating || nav.state == .arrived
        let routes: [RouteOption]
        if isGuiding {
            routes = nav.selectedRouteOption.map { [$0] } ?? []
        } else {
            routes = nav.routeOptions
        }
        return NavigationMapView(
            routes: routes,
            selectedRouteID: nav.selectedRouteOption?.id,
            destination: nav.destination.map { GeoPoint($0.placemark.coordinate) },
            destinationTitle: nav.destinationName,
            features: nav.state == .idle ? [] : app.roadInfo.routeFeatures,
            incidents: app.incidents.incidents,
            cameraMode: cameraMode(nav.state),
            showsTraffic: app.settings.showTrafficOnMap,
            trafficTileTemplate: app.settings.trafficTileTemplate,
            allowsRouteSelection: nav.state == .previewing,
            mapInsets: UIEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0),
            isFollowing: $isFollowing,
            onSelectRoute: { id in
                nav.selectedRouteID = id
            },
            onLongPress: { coordinate in
                longPressCoordinate = coordinate
                showLongPressDialog = true
            }
        )
    }

    private func cameraMode(_ state: NavigationService.State) -> NavigationMapView.CameraMode {
        switch state {
        case .idle, .planning, .arrived: return .idle
        case .previewing: return .overview
        case .navigating: return .navigating
        }
    }

    // MARK: - Top

    @ViewBuilder
    private func topSection(_ nav: NavigationService) -> some View {
        VStack(spacing: 8) {
            if nav.state == .navigating, let progress = nav.progress {
                ManeuverBannerView(progress: progress, isRerouting: nav.isRecalculating)
                laneGuidance(nav, progress: progress)
            }
            if hasRoadInfo(nav) {
                roadStrip(nav)
            }
            if nav.state == .navigating, let progress = nav.progress {
                hazardChip(nav, progress: progress)
            }
        }
    }

    @ViewBuilder
    private func laneGuidance(_ nav: NavigationService, progress: RouteProgress) -> some View {
        let distance = progress.distanceToNextManeuver ?? .infinity
        if !progress.isOffRoute {
            if !progress.nextLanes.isEmpty, distance <= 1_500 {
                LaneGuidanceView(lanes: progress.nextLanes, recommended: progress.nextActiveLanes)
            } else if let info = app.roadInfo.currentRoad?.laneInfo, !info.lanes.isEmpty, distance <= 600 {
                LaneGuidanceView(laneInfo: info, maneuver: progress.nextManeuver)
            }
        }
    }

    private func hasRoadInfo(_ nav: NavigationService) -> Bool {
        app.roadInfo.currentRoad != nil || nav.currentEdge != nil
    }

    private func speedLimit(_ nav: NavigationService) -> Int? {
        nav.currentEdge?.speedLimitKmh ?? app.roadInfo.currentRoad?.speedLimit?.kmh
    }

    private func roadName(_ nav: NavigationService) -> String {
        if let road = app.roadInfo.currentRoad { return road.displayName }
        if let name = nav.currentEdge?.names.first, !name.isEmpty { return name }
        return "Дорога"
    }

    /// "Полос: 3 из 6", "Полос: ≈2". Valhalla's per-direction count is preferred; a Valhalla value of 1 may mean
    /// "not tagged", so then the OSM count (when it is not itself a guess) wins and a remaining 1 is marked "≈".
    private func laneText(_ nav: NavigationService) -> String? {
        let osm = app.roadInfo.currentRoad?.laneInfo
        let osmCount = osm?.lanesInDirection
        let osmEstimated = osm?.isEstimated ?? true
        var count: Int?
        var estimated = false
        if let valhalla = nav.currentEdge?.laneCount, valhalla > 1 || osmCount == nil || osmEstimated {
            count = valhalla
            estimated = valhalla == 1
        } else if let osmCount {
            count = osmCount
            estimated = osmEstimated
        }
        guard let count else { return nil }
        var text = "Полос: " + (estimated ? "≈" : "") + "\(count)"
        if let total = osm?.totalLanes, total > count {
            text += " из \(total)"
        }
        return text
    }

    private func roadStrip(_ nav: NavigationService) -> some View {
        let limit = speedLimit(nav)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(roadName(nav))
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                HStack(spacing: 6) {
                    if let lanes = laneText(nav) {
                        Label(lanes, systemImage: "road.lanes")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    Text("OSM")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay(Capsule().stroke(Color.white.opacity(0.5), lineWidth: 1))
                        .foregroundStyle(.white.opacity(0.7))
                        .accessibilityLabel("Данные OpenStreetMap")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Shows the speed and, when known, the limit sign (`SpeedLimitSignView`); turns red above
            // limit + tolerance when the speed warning is enabled.
            SpeedometerView(speedKmh: app.location.speedKmh,
                            limitKmh: limit,
                            warningTolerance: app.settings.speedWarningTolerance,
                            compact: true,
                            warningEnabled: app.settings.speedWarningEnabled)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Nearest hazard (not a signal) inside its warning distance, shown as a glanceable chip.
    @ViewBuilder
    private func hazardChip(_ nav: NavigationService, progress: RouteProgress) -> some View {
        let hazard = nav.upcomingFeatures.first { feature in
            let ahead = feature.distanceAlongRoute - progress.distanceAlong
            return feature.kind != .trafficSignals && ahead >= 0 && ahead <= feature.kind.alertDistance
        }
        if let hazard {
            HStack(spacing: 8) {
                Image(systemName: hazard.kind.symbolName)
                    .font(.headline)
                Text(hazard.kind.displayName)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                Text(RVFormat.distance(max(0, hazard.distanceAlongRoute - progress.distanceAlong)))
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(hazardTint(hazard.kind), in: Capsule())
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    private func hazardTint(_ kind: RouteFeatureKind) -> Color {
        switch kind {
        case .speedCamera: return .purple
        case .school, .kindergarten: return Color(red: 0.75, green: 0.55, blue: 0)
        case .railwayCrossing: return .gray
        case .pedestrianCrossing: return .blue
        default: return .orange
        }
    }

    // MARK: - Corner row (camera, buttons)

    private func cornerRow(_ nav: NavigationService) -> some View {
        HStack(alignment: .top, spacing: 12) {
            cameraCorner
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                if !hasRoadInfo(nav) {
                    SpeedometerView(speedKmh: app.location.speedKmh, limitKmh: nil, compact: true)
                }
                if !isFollowing {
                    GlassIconButton(systemName: "location.fill", label: "Центр", tint: .blue) {
                        isFollowing = true
                    }
                }
                GlassIconButton(systemName: app.settings.showTrafficOnMap ? "car.2.fill" : "car.2",
                                label: "Пробки",
                                tint: app.settings.showTrafficOnMap ? .orange : .white) {
                    app.settings.showTrafficOnMap.toggle()
                }
                GlassIconButton(systemName: "exclamationmark.bubble.fill", label: "Сообщить") {
                    incidentTarget = IncidentReportTarget(coordinate: nil)
                }
                GlassIconButton(systemName: "gearshape.fill", label: "Настройки") {
                    app.showSettings = true
                }
                AssistantButton()
            }
        }
    }

    @ViewBuilder
    private var cameraCorner: some View {
        if app.settings.showCameraPiP {
            // Live camera with recognition boxes; it sizes and styles itself and returns to the camera on tap.
            CameraPiPView(pipeline: app.recognition)
        } else {
            GlassIconButton(systemName: "camera.fill", label: "Камера") {
                app.switchTo(.camera)
            }
        }
    }

    // MARK: - Bottom

    @ViewBuilder
    private func bottomSection(_ nav: NavigationService) -> some View {
        switch nav.state {
        case .idle:
            idlePanel(nav)
        case .planning:
            planningPanel(nav)
        case .previewing:
            RouteOptionsView()
        case .navigating:
            TripInfoPanel()
        case .arrived:
            arrivedPanel(nav)
        }
    }

    private func idlePanel(_ nav: NavigationService) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let recents = Array(nav.placeSearch.recents.prefix(4))
            if !recents.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(recents) { recent in
                            Button {
                                startPlanning(to: nav.placeSearch.mapItem(for: recent), rememberAsRecent: true)
                            } label: {
                                Label(recent.name, systemImage: "clock.arrow.circlepath")
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                    .padding(.horizontal, 16)
                                    .frame(minHeight: 52)
                                    .background(.regularMaterial, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Button {
                showSearch = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.title3.weight(.semibold))
                    Text("Куда едем?")
                        .font(.title3.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, minHeight: 60)
                .background(.regularMaterial, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
        }
    }

    private func planningPanel(_ nav: NavigationService) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            VStack(alignment: .leading, spacing: 2) {
                Text("Строю маршрут…")
                    .font(.headline)
                if let name = nav.destinationName {
                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func arrivedPanel(_ nav: NavigationService) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "flag.checkered")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Вы прибыли")
                        .font(.title2.weight(.bold))
                    if let name = nav.destinationName {
                        Text(name)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            Button {
                nav.stopNavigation()
            } label: {
                Text("Готово")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .buttonBorderShape(.roundedRectangle(radius: 18))
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func errorBanner(_ message: String, nav: NavigationService) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.yellow)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                nav.dismissError()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .accessibilityLabel("Закрыть сообщение")
        }
        .padding(.leading, 14)
        .background(Color(red: 0.45, green: 0.12, blue: 0.08).opacity(0.92),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Attribution

    @ViewBuilder
    private func attributionFooter(_ nav: NavigationService) -> some View {
        let showsOSM = nav.routeOptions.contains { $0.source == .valhalla } || !nav.routeEdges.isEmpty
            || app.roadInfo.currentRoad != nil || !app.roadInfo.routeFeatures.isEmpty
        let showsWeather = nav.state == .navigating && app.weather.current != nil
        if showsOSM || showsWeather {
            HStack(spacing: 12) {
                if showsOSM {
                    Link("© участники OpenStreetMap", destination: Self.fixTheMapURL)
                }
                if showsWeather {
                    Text("Погода: Open-Meteo")
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.75))
            .tint(Color.white.opacity(0.85))
            .padding(.horizontal, 6)
        }
    }

    // MARK: - Helpers

    private func startPlanning(to item: MKMapItem, rememberAsRecent: Bool) {
        let nav = app.navigation
        if rememberAsRecent {
            nav.placeSearch.addRecent(item)
        }
        showSearch = false
        Task {
            await nav.planRoutes(to: item)
        }
    }

    /// Writes the height of the view it is attached to (as a background) into `height`.
    private func heightReader(_ height: Binding<CGFloat>) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { height.wrappedValue = proxy.size.height }
                .onChange(of: proxy.size.height) { _, newHeight in
                    height.wrappedValue = newHeight
                }
        }
    }
}

/// Target of the incident report sheet (nil coordinate = current position).
struct IncidentReportTarget: Identifiable {
    let id = UUID()
    let coordinate: GeoPoint?
}
