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
                Text(verbatim: FollowingDistanceNorms.localizedRulesDocument)
                    .font(RVTheme.font(14, weight: .regular))
            } header: {
                Text(l: "norms.document")
            }

            Section {
                ForEach(FollowingDistanceNorms.items) { item in
                    NormItemRow(item: item)
                }
            } header: {
                Text(l: "norms.items.header")
            }

            Section {
                Label {
                    Text(verbatim: FollowingDistanceNorms.localizedDisclaimer)
                        .font(RVTheme.font(13, weight: .regular))
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "exclamationmark.bubble.fill")
                        .foregroundStyle(RVTheme.caution)
                }
            }
        }
        .navigationTitle(L("fd.norms.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.done")) { dismiss() }
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
                Text("\(surface.localizedName) · \(source.localizedName)")
            } label: {
                Label(L("settings.fd.surface"), systemImage: surface.symbolName)
            }
            LabeledContent {
                Text(verbatim: "≥ \(RVFormat.compactNumber(policy.timeGap(for: surface))) \(RVFormat.appSeconds)")
                    .monospacedDigit()
            } label: {
                Label(L("norms.moving"), systemImage: "speedometer")
            }
            LabeledContent {
                Text(verbatim: "≥ \(RVFormat.compactNumber(policy.stoppedGapMeters)) \(RVFormat.appMeters)")
                    .monospacedDigit()
            } label: {
                Label(L("norms.stopped"), systemImage: "hand.raised.fill")
            }
            LabeledContent {
                Text(verbatim: "\(RVFormat.compactNumber(policy.reactionTimeSeconds)) \(RVFormat.appSeconds)")
                    .monospacedDigit()
            } label: {
                Label(L("settings.fd.reaction"), systemImage: "bolt.fill")
            }
            LabeledContent {
                Text(l: "norms.ttcThreshold", RVFormat.compactNumber(policy.collisionWarningSeconds))
                    .monospacedDigit()
            } label: {
                Label(L("norms.warning"), systemImage: "exclamationmark.triangle.fill")
            }
            LabeledContent {
                Text(verbatim: "< \(RVFormat.compactNumber(policy.stoppedSpeedKmh)) \(RVFormat.appKmh)")
                    .monospacedDigit()
            } label: {
                Label(L("norms.standingIf"), systemImage: "car.rear.fill")
            }
        } header: {
            Text(l: "norms.current.header")
        } footer: {
            Text(l: "norms.current.footer")
        }
    }

    private func timeGapSection(policy: FollowingDistancePolicy, surface: RoadSurfaceCondition) -> some View {
        Section {
            ForEach(RoadSurfaceCondition.allCases, id: \.self) { condition in
                LabeledContent {
                    Text(verbatim: "≥ \(RVFormat.compactNumber(policy.timeGap(for: condition))) \(RVFormat.appSeconds)")
                        .monospacedDigit()
                        .fontWeight(condition == surface ? .bold : .regular)
                } label: {
                    HStack(spacing: 8) {
                        Label(condition.localizedName, systemImage: condition.symbolName)
                        if condition == surface {
                            RVBadge(text: L("norms.now"), color: RVTheme.safe)
                        }
                    }
                }
            }
        } header: {
            Text(l: "norms.gap.header")
        } footer: {
            Text(l: "norms.gap.footer")
        }
    }

    private func exampleSection(policy: FollowingDistancePolicy, surface: RoadSurfaceCondition) -> some View {
        Section {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text(l: "norms.col.speed")
                    Text(l: "norms.col.gap")
                    Text(l: "fd.row.stopping")
                }
                .font(RVTheme.font(12, weight: .semibold))
                .foregroundStyle(.secondary)
                ForEach(Self.exampleSpeeds, id: \.self) { speed in
                    let gap = FollowingDistanceCalculator.recommendedDistance(speedKmh: speed, policy: policy,
                                                                             condition: surface)
                    let stopping = FollowingDistanceCalculator.stoppingDistance(
                        speedKmh: speed, reactionTime: policy.reactionTimeSeconds, friction: surface.frictionCoefficient)
                    GridRow {
                        Text(verbatim: "\(Int(speed)) \(RVFormat.appKmh)")
                        Text("≈ " + RVFormat.gapMeters(gap))
                        Text("≈ " + RVFormat.gapMeters(stopping))
                    }
                    .font(RVTheme.font(14, weight: .medium))
                    .monospacedDigit()
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text(l: "norms.example", surface.localizedName.lowercased())
        } footer: {
            Text(l: "norms.example.footer")
        }
    }
}

/// One norm / recommendation with its status badge, text, source and an optional link.
private struct NormItemRow: View {
    let item: FollowingDistanceNorms.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RVBadge(text: item.status.localizedName, color: RVTheme.normColor(item.status), systemImage: symbol)
            Text(verbatim: item.localizedTitle)
                .font(RVTheme.font(16, weight: .bold))
            Text(verbatim: item.localizedText)
                .font(RVTheme.font(14, weight: .regular))
                .fixedSize(horizontal: false, vertical: true)
            Text(l: "norms.source", item.localizedSource)
                .font(RVTheme.font(12, weight: .medium))
                .foregroundStyle(.secondary)
            if let urlString = item.url, let url = URL(string: urlString) {
                Link(destination: url) {
                    Label(L("norms.openSource"), systemImage: "arrow.up.right.square")
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
