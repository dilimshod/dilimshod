import SwiftUI

/// Compact card shown when a box is tapped: class, make + уверенность, ≈ distance, ≈ speed, track age,
/// "передний автомобиль" badge for the lead vehicle, colour for traffic lights.
/// All distances/speeds are monocular estimates ("≈ … (оценка)"); percentages are model confidence ("уверенность").
struct TrackDetailCard: View {
    let track: TrackedObject
    /// Non-nil when this track is the current lead vehicle (its fused distance is shown instead of the track's).
    let lead: LeadVehicle?
    /// Assessment of the gap to the lead (only meaningful together with `lead`).
    let assessment: FollowingDistanceAssessment?
    let onClose: () -> Void

    /// Card size used to place it next to its box.
    static let estimatedSize = CGSize(width: 236, height: 180)

    private var kindColor: Color { RVTheme.kindColor(track.kind) }
    private var leadColor: Color { RVTheme.statusColor(assessment?.status ?? .unknown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            if lead != nil {
                RVBadge(text: "передний автомобиль", color: leadColor, systemImage: "car.rear.fill")
            }
            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(height: 1)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                if track.kind == .trafficLight {
                    GridRow {
                        rowTitle("Цвет")
                        HStack(spacing: 6) {
                            TrafficLightDotView(color: track.lightColor ?? .unknown, size: 10)
                            Text((track.lightColor ?? .unknown).displayName + " (оценка)")
                        }
                        .font(RVTheme.font(12, weight: .semibold))
                    }
                }
                GridRow {
                    rowTitle("Уверенность")
                    rowValue("\(DetectionOverlayView.confidencePercent(for: track))%")
                }
                if let distance = distanceText {
                    GridRow {
                        rowTitle("Расстояние")
                        rowValue(distance, color: lead != nil ? leadColor : .white)
                    }
                }
                if let lead {
                    GridRow {
                        rowTitle("По признакам")
                        rowValue(lead.method)
                    }
                }
                if let speed = track.estimatedSpeedKmh, speed.isFinite, speed >= 0 {
                    GridRow {
                        rowTitle("Скорость")
                        rowValue("≈ \(Int(speed.rounded())) км/ч (оценка)")
                    }
                }
                if let motion = FollowingDistanceText.relativeMotion(relativeSpeedKmh: lead?.relativeSpeedKmh ?? track.relativeSpeedKmh) {
                    GridRow {
                        rowTitle("Относительно вас")
                        rowValue("≈ " + motion)
                    }
                }
                if let assessment, lead != nil, let ttc = FollowingDistanceText.timeToCollision(assessment) {
                    GridRow {
                        rowTitle("До столкновения")
                        rowValue(ttc, color: RVTheme.danger)
                    }
                }
                GridRow {
                    rowTitle("В кадре")
                    rowValue(ageText)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(11)
        .frame(width: Self.estimatedSize.width, alignment: .leading)
        .rvGlass(cornerRadius: RVTheme.Radius.panel, tint: lead != nil ? leadColor : kindColor.opacity(0.6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Подробности объекта")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if track.kind == .trafficLight {
                    TrafficLightDotView(color: track.lightColor ?? .unknown, size: 14)
                } else {
                    Image(systemName: track.kind.symbolName)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(kindColor)
                }
            }
            .frame(width: 30, height: 30)
            .background(kindColor.opacity(0.18), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(track.kind.displayName)
                    .font(RVTheme.font(15, weight: .bold))
                if let make = track.make, let confidence = track.makeConfidence {
                    Text("\(make) · уверенность \(Int((min(max(confidence, 0), 1) * 100).rounded()))%")
                        .font(RVTheme.font(11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .monospacedDigit()
                        .lineLimit(2)
                } else if track.kind.isVehicle && track.kind != .bicycle {
                    Text("Марка не определена")
                        .font(RVTheme.font(11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.14), in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(RVPressableButtonStyle())
            .padding(.top, -9)
            .padding(.trailing, -9)
            .accessibilityLabel("Закрыть")
        }
    }

    private var distanceText: String? {
        let meters = lead?.distanceMeters ?? track.distanceMeters
        guard let meters, meters.isFinite, meters > 0 else { return nil }
        return FollowingDistanceText.gap(meters) + " (оценка)"
    }

    private var ageText: String {
        let age = max(0, track.lastSeen - track.firstSeen)
        return age < 60 ? RVFormat.gapSeconds(age) : RVFormat.duration(age)
    }

    private func rowTitle(_ text: String) -> some View {
        Text(text)
            .font(RVTheme.font(11, weight: .medium))
            .foregroundStyle(.white.opacity(0.65))
    }

    private func rowValue(_ text: String, color: Color = .white) -> some View {
        Text(text)
            .font(RVTheme.font(12, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    /// Centre of the card next to its box (below it when the box is in the upper half, else above), kept on screen.
    static func position(for rect: CGRect, in size: CGSize, safeArea: EdgeInsets) -> CGPoint {
        let w = estimatedSize.width, h = estimatedSize.height
        let minX = RVTheme.Spacing.gutter + w / 2, maxX = size.width - RVTheme.Spacing.gutter - w / 2
        let x = minX <= maxX ? min(max(rect.midX, minX), maxX) : size.width / 2
        let below = rect.midY < size.height * 0.5
        let preferredY = below ? rect.maxY + 14 + h / 2 : rect.minY - 14 - h / 2
        let minY = safeArea.top + 56 + h / 2, maxY = size.height - safeArea.bottom - 72 - h / 2
        let y = minY <= maxY ? min(max(preferredY, minY), maxY) : size.height / 2
        return CGPoint(x: x, y: y)
    }
}

#Preview {
    let track = TrackedObject(id: 7, kind: .car, label: "car", box: BBox(x: 0.3, y: 0.5, width: 0.3, height: 0.16),
                              confidence: 0.81, hits: 30, firstSeen: 0, lastSeen: 4.2, isConfirmed: true,
                              make: "Chevrolet", makeConfidence: 0.64, distanceMeters: 21, relativeSpeedKmh: -8,
                              estimatedSpeedKmh: 46)
    let lead = LeadVehicle(trackID: 7, kind: .car, box: track.box, distanceMeters: 18.4, relativeSpeedKmh: -8,
                           method: "ширина+высота")
    let assessment = FollowingDistanceCalculator.assess(distanceMeters: 18.4, ownSpeedKmh: 54, relativeSpeedKmh: -8,
                                                        policy: FollowingDistancePolicy(), condition: .dry)
    return ZStack {
        Color(white: 0.25).ignoresSafeArea()
        TrackDetailCard(track: track, lead: lead, assessment: assessment) {}
    }
    .preferredColorScheme(.dark)
}
