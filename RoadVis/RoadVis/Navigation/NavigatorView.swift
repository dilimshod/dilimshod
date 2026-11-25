import CoreLocation
import MapKit
import SwiftUI

/// Full-screen navigator: `MKMapView` map below everything; on top the guidance banner (with lanes and "затем"),
/// the collapsible current-road card and a hazard chip; the live camera window (or a camera button) in the top-left
/// corner; map buttons on the right (layers: Схема / Спутник / Гибрид, 3D, Apple traffic; recentre; report;
/// settings); and a state-dependent bottom panel (search → planning → route options → trip info → arrival).
/// Panels stay at the edges so the map centre (the car) is never covered.
struct NavigatorView: View {
    @Environment(AppState.self) private var app

    @State private var isFollowing = true
    @State private var showSearch = false
    @State private var incidentTarget: IncidentReportTarget?
    @State private var longPressCoordinate: CLLocationCoordinate2D?
    @State private var showLongPressDialog = false
    @State private var topInset: CGFloat = 0
    @State private var bottomInset: CGFloat = 0
    @AppStorage(NavigatorSettingsKeys.mapStyle) private var mapStyleRaw = NavigatorMapStyle.standard.rawValue
    @AppStorage(NavigatorSettingsKeys.map3D) private var is3D = true

    private static let fixTheMapURL = URL(string: "https://www.openstreetmap.org/fixthemap")!

    var body: some View {
        let nav = app.navigation
        ZStack(alignment: .top) {
            mapLayer(nav)
                .ignoresSafeArea()

            VStack(spacing: 8) {
                topSection(nav)
                    .background(heightReader($topInset))
                cornerRow(nav)
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .frame(maxHeight: .infinity, alignment: .top)

            VStack(spacing: 6) {
                if let error = nav.errorMessage {
                    errorBanner(error, nav: nav)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                bottomSection(nav)
                attributionFooter(nav)
            }
            .padding(.horizontal, 10)
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
            events: nav.state == .idle ? [] : nav.timeline,
            speedLimitSegments: nav.state == .idle ? [] : nav.speedLimitSegments,
            incidents: app.incidents.incidents,
            mapStyle: NavigatorMapStyle(rawValue: mapStyleRaw) ?? .standard,
            is3D: is3D,
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
        VStack(spacing: 6) {
            if nav.state == .navigating, let progress = nav.progress {
                let lanes = laneGuidance(nav, progress: progress)
                ManeuverBannerView(progress: progress, isRerouting: nav.isRecalculating,
                                   lanes: lanes.lanes, recommendedLanes: lanes.recommended, laneSource: lanes.source)
            }
            if hasRoadInfo(nav) {
                CurrentRoadCard(nextManeuver: nav.state == .navigating ? nav.progress?.nextManeuver : nil)
            }
            if nav.state == .navigating, let progress = nav.progress {
                hazardChip(nav, progress: progress)
            }
        }
    }

    /// Lanes for the banner: the routing engine's lanes at the next maneuver (≤ 1.5 km), else OSM `turn:lanes` of
    /// the current road (≤ 600 m) with recommendations derived from the maneuver.
    private func laneGuidance(_ nav: NavigationService, progress: RouteProgress)
        -> (lanes: [Lane], recommended: [Bool], source: String?) {
        let distance = progress.distanceToNextManeuver ?? .infinity
        guard !progress.isOffRoute else { return ([], [], nil) }
        if !progress.nextLanes.isEmpty, distance <= 1_500 {
            return (progress.nextLanes, progress.nextActiveLanes, nav.selectedRouteOption?.source.badge)
        }
        if let info = app.roadInfo.currentRoad?.laneInfo, !info.lanes.isEmpty, distance <= 600 {
            return (info.lanes, LaneGuidance.recommendedLanes(info.lanes, for: progress.nextManeuver), "OSM")
        }
        return ([], [], nil)
    }

    private func hasRoadInfo(_ nav: NavigationService) -> Bool {
        app.roadInfo.currentRoad != nil || nav.currentEdge != nil
    }

    /// Nearest hazard (not a signal) inside its warning distance, shown as a glanceable chip.
    @ViewBuilder
    private func hazardChip(_ nav: NavigationService, progress: RouteProgress) -> some View {
        let hazard = nav.upcomingFeatures.first { feature in
            let ahead = feature.distanceAlongRoute - progress.distanceAlong
            return feature.kind != .trafficSignals && !feature.kind.isPointOfInterest
                && ahead >= 0 && ahead <= feature.kind.alertDistance
        }
        if let hazard {
            HStack(spacing: 6) {
                Image(systemName: hazard.kind.symbolName)
                    .font(.footnote.weight(.bold))
                Text(hazard.kind.localizedName)
                    .font(.footnote.weight(.bold))
                    .lineLimit(1)
                Text(RVFormat.appDistance(max(0, hazard.distanceAlongRoute - progress.distanceAlong)))
                    .font(.footnote.weight(.bold))
                    .monospacedDigit()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(Color(uiColor: NavigatorStyle.featureUIColor(hazard.kind)).opacity(0.9), in: Capsule())
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Corner row (camera, buttons)

    private func cornerRow(_ nav: NavigationService) -> some View {
        HStack(alignment: .top, spacing: 10) {
            cameraCorner
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                if !hasRoadInfo(nav) {
                    SpeedometerView(speedKmh: app.location.speedKmh, limitKmh: nil, compact: true)
                }
                if !isFollowing {
                    GlassIconButton(systemName: "location.fill", label: "Центр", size: RVTheme.HUD.button, tint: .blue) {
                        isFollowing = true
                    }
                }
                layersMenu
                GlassIconButton(systemName: "exclamationmark.bubble.fill", label: "Сообщить", size: RVTheme.HUD.button) {
                    incidentTarget = IncidentReportTarget(coordinate: nil)
                }
                GlassIconButton(systemName: "gearshape.fill", label: "Настройки", size: RVTheme.HUD.button) {
                    app.showSettings = true
                }
            }
        }
    }

    /// Map layer switcher: Схема / Спутник / Гибрид, 3D, Apple traffic layer.
    private var layersMenu: some View {
        @Bindable var settings = app.settings
        let style = NavigatorMapStyle(rawValue: mapStyleRaw) ?? .standard
        return Menu {
            Picker("Слой карты", selection: $mapStyleRaw) {
                ForEach(NavigatorMapStyle.allCases) { option in
                    Label(option.displayName, systemImage: option.symbolName).tag(option.rawValue)
                }
            }
            Toggle(isOn: $is3D) {
                Label("3D (рельеф, наклон)", systemImage: "view.3d")
            }
            Toggle(isOn: $settings.showTrafficOnMap) {
                Label("Пробки Apple (где есть данные)", systemImage: "car.2.fill")
            }
        } label: {
            Image(systemName: style.symbolName)
                .font(.system(size: RVTheme.HUD.button * 0.42, weight: .semibold, design: .rounded))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .frame(width: RVTheme.HUD.button, height: RVTheme.HUD.button)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 2)
                .frame(width: GlassIconButton.minimumHitSize, height: GlassIconButton.minimumHitSize)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Слои карты: \(style.displayName)\(is3D ? ", 3D" : "")")
    }

    @ViewBuilder
    private var cameraCorner: some View {
        if app.settings.showCameraPiP {
            // Live camera with recognition boxes; it sizes and styles itself and returns to the camera on tap.
            CameraPiPView(pipeline: app.recognition)
        } else {
            GlassIconButton(systemName: "camera.fill", label: "Камера", size: RVTheme.HUD.button) {
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
                                    .font(.footnote.weight(.semibold))
                                    .lineLimit(1)
                                    .padding(.horizontal, 14)
                                    .frame(minHeight: 44)
                                    .background(.regularMaterial, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            idleShortcuts
            Button {
                showSearch = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.headline)
                    Text("Куда едем?")
                        .font(.headline)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(.regularMaterial, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        }
    }

    /// Trip history and manual trip recording (the shell has no tabs; these are the entry points of the idle screen).
    private var idleShortcuts: some View {
        let recorder = app.tripRecorder
        return HStack(spacing: 8) {
            Button {
                app.showTripHistory = true
            } label: {
                Label("Поездки", systemImage: "list.bullet.rectangle.portrait")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            Button {
                if recorder.isRecording {
                    app.stopTripRecording()
                } else {
                    app.startTripRecording()
                }
            } label: {
                Group {
                    if recorder.isRecording, let started = recorder.startedAt {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill")
                            Text(started, style: .timer).monospacedDigit()
                        }
                        .foregroundStyle(RVTheme.recording)
                    } else {
                        Label("Записать поездку", systemImage: "record.circle")
                    }
                }
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(recorder.isFinishing)
            .accessibilityLabel(recorder.isRecording ? "Остановить запись поездки" : "Начать запись поездки")
            Spacer(minLength: 0)
            Button {
                app.showAbout = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("О приложении")
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
        let showsOSM = nav.routeOptions.contains { $0.sources.contains(where: \.usesOpenStreetMap) }
            || !nav.routeEdges.isEmpty || app.roadInfo.currentRoad != nil || !app.roadInfo.routeFeatures.isEmpty
        let showsWeather = (nav.state == .navigating && app.weather.current != nil) || !nav.routeWeather.points.isEmpty
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
