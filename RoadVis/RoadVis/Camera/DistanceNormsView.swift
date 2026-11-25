import SwiftUI

/// «Требования к дистанции»: what the Uzbek traffic rules say (norms), recommendations with sources, the thresholds the
/// app currently uses (from Settings) and an example table of gaps / stopping distances.
///
/// Used as a sheet from the camera HUD (`showsDoneButton: true`, wrap in a `NavigationStack`) and pushed from the
/// «Дистанция» section of Settings.
struct DistanceNormsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var showsDoneButton = false

    private static let exampleSpeeds: [Double] = [20, 40, 60, 90, 110]

    var body: some View {
        let policy = app.settings.followingDistancePolicy
        let surface = app.recognition.roadSurface
        let source = app.recognition.roadSurfaceSource
        List {
            currentSection(policy: policy, surface: surface, source: source)
            timeGapSection(policy: policy, surface: surface)
            exampleSection(policy: policy, surface: surface)

            Section {
                Text(FollowingDistanceNorms.rulesDocument)
                    .font(RVTheme.font(14, weight: .regular))
            } header: {
                Text("Документ")
            }

            Section {
                ForEach(FollowingDistanceNorms.items) { item in
                    NormItemRow(item: item)
                }
            } header: {
                Text("Требования и рекомендации")
            }

            Section {
                Label {
                    Text(FollowingDistanceNorms.disclaimer)
                        .font(RVTheme.font(13, weight: .regular))
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "exclamationmark.bubble.fill")
                        .foregroundStyle(RVTheme.caution)
                }
            }
        }
        .navigationTitle("Требования к дистанции")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Sections

    private func currentSection(policy: FollowingDistancePolicy, surface: RoadSurfaceCondition,
                                source: RoadSurfaceSource) -> some View {
        Section {
            LabeledContent {
                Text("\(surface.displayName) · \(source.displayName)")
            } label: {
                Label("Покрытие дороги", systemImage: surface.symbolName)
            }
            LabeledContent {
                Text("≥ \(RVFormat.compactNumber(policy.timeGap(for: surface))) с")
                    .monospacedDigit()
            } label: {
                Label("В движении", systemImage: "speedometer")
            }
            LabeledContent {
                Text("≥ \(RVFormat.compactNumber(policy.stoppedGapMeters)) м")
                    .monospacedDigit()
            } label: {
                Label("При остановке", systemImage: "hand.raised.fill")
            }
            LabeledContent {
                Text("\(RVFormat.compactNumber(policy.reactionTimeSeconds)) с")
                    .monospacedDigit()
            } label: {
                Label("Время реакции", systemImage: "bolt.fill")
            }
            LabeledContent {
                Text("< \(RVFormat.compactNumber(policy.collisionWarningSeconds)) с до столкновения")
                    .monospacedDigit()
            } label: {
                Label("Предупреждение", systemImage: "exclamationmark.triangle.fill")
            }
            LabeledContent {
                Text("< \(RVFormat.compactNumber(policy.stoppedSpeedKmh)) км/ч")
                    .monospacedDigit()
            } label: {
                Label("«Стоим», если скорость", systemImage: "car.rear.fill")
            }
        } header: {
            Text("Пороги приложения сейчас")
        } footer: {
            Text("Меняются в Настройках → «Дистанция». Покрытие «авто» определяется по погоде Open-Meteo.")
        }
    }

    private func timeGapSection(policy: FollowingDistancePolicy, surface: RoadSurfaceCondition) -> some View {
        Section {
            ForEach(RoadSurfaceCondition.allCases, id: \.self) { condition in
                LabeledContent {
                    Text("≥ \(RVFormat.compactNumber(policy.timeGap(for: condition))) с")
                        .monospacedDigit()
                        .fontWeight(condition == surface ? .bold : .regular)
                } label: {
                    HStack(spacing: 8) {
                        Label(condition.displayName, systemImage: condition.symbolName)
                        if condition == surface {
                            RVBadge(text: "сейчас", color: RVTheme.safe)
                        }
                    }
                }
            }
        } header: {
            Text("Интервал до впереди идущего (в движении)")
        } footer: {
            Text("Мокро ×2, снег ×3, гололёд ×5 от сухого интервала (UK Highway Code, правило 126: на мокрой дороге минимум вдвое больше, на льду — до 10 раз).")
        }
    }

    private func exampleSection(policy: FollowingDistancePolicy, surface: RoadSurfaceCondition) -> some View {
        Section {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("Скорость")
                    Text("Интервал")
                    Text("Остановочный путь")
                }
                .font(RVTheme.font(12, weight: .semibold))
                .foregroundStyle(.secondary)
                ForEach(Self.exampleSpeeds, id: \.self) { speed in
                    let gap = FollowingDistanceCalculator.recommendedDistance(speedKmh: speed, policy: policy,
                                                                             condition: surface)
                    let stopping = FollowingDistanceCalculator.stoppingDistance(
                        speedKmh: speed, reactionTime: policy.reactionTimeSeconds, friction: surface.frictionCoefficient)
                    GridRow {
                        Text("\(Int(speed)) км/ч")
                        Text("≈ " + RVFormat.gapMeters(gap))
                        Text("≈ " + RVFormat.gapMeters(stopping))
                    }
                    .font(RVTheme.font(14, weight: .medium))
                    .monospacedDigit()
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Пример: \(surface.displayName.lowercased())")
        } footer: {
            Text("Остановочный путь S = v·t + v²/(2·μ·g) — инженерная оценка (μ: сухо 0,7, мокро 0,35, снег 0,2, лёд 0,1), а не измерение.")
        }
    }
}

/// One norm / recommendation with its status badge, text, source and an optional link.
private struct NormItemRow: View {
    let item: FollowingDistanceNorms.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RVBadge(text: item.status.rawValue, color: RVTheme.normColor(item.status), systemImage: symbol)
            Text(item.title)
                .font(RVTheme.font(16, weight: .bold))
            Text(item.text)
                .font(RVTheme.font(14, weight: .regular))
                .fixedSize(horizontal: false, vertical: true)
            Text("Источник: \(item.source)")
                .font(RVTheme.font(12, weight: .medium))
                .foregroundStyle(.secondary)
            if let urlString = item.url, let url = URL(string: urlString) {
                Link(destination: url) {
                    Label("Открыть источник", systemImage: "arrow.up.right.square")
                        .font(RVTheme.font(14, weight: .semibold))
                }
                .tint(RVTheme.accent)
            }
        }
        .padding(.vertical, 4)
    }

    private var symbol: String {
        switch item.status {
        case .norm: return "building.columns.fill"
        case .recommendation: return "hand.thumbsup.fill"
        case .appSetting: return "slider.horizontal.3"
        }
    }
}

/// The norms view as a sheet with its own navigation bar and "Готово".
struct DistanceNormsSheet: View {
    var body: some View {
        NavigationStack {
            DistanceNormsView(showsDoneButton: true)
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }
}
