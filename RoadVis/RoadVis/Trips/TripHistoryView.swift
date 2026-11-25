import SwiftUI

/// List of recorded trips (newest first) with score, A → B, distance and events; tap → report, swipe → delete.
/// On top: the running recording (with stop) or a button to start one manually.
struct TripHistoryView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let store = app.trips
        List {
            Section {
                recordingRow
            } footer: {
                Text(l: "history.autoNote")
            }
            if store.trips.isEmpty {
                Section {
                    if store.isLoaded {
                        Text(l: "history.empty")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
            } else {
                Section {
                    ForEach(store.trips) { trip in
                        NavigationLink {
                            TripReportView(trip: trip)
                        } label: {
                            TripHistoryRow(trip: trip, isRecording: trip.id == app.tripRecorder.currentTripID)
                        }
                        .disabled(trip.id == app.tripRecorder.currentTripID)
                    }
                    .onDelete { offsets in
                        store.delete(at: offsets)
                    }
                } header: {
                    Text(l: "history.count", store.trips.count)
                }
            }
            if let error = store.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle(L("history.title"))
        .onAppear { store.load() }
    }

    @ViewBuilder
    private var recordingRow: some View {
        let recorder = app.tripRecorder
        if recorder.isFinishing {
            HStack {
                ProgressView()
                Text(l: "trip.saving")
            }
        } else if recorder.isRecording, let started = recorder.startedAt {
            HStack(spacing: 12) {
                Image(systemName: "record.circle")
                    .font(.title2)
                    .foregroundStyle(RVTheme.recording)
                    .rvPulse(true, minOpacity: 0.4, period: 1.4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(l: "trip.recording")
                        .font(.subheadline.weight(.semibold))
                    HStack(spacing: 4) {
                        Text(started, style: .timer).monospacedDigit()
                        Text(l: "history.live", RVFormat.appDistance(recorder.liveDistanceMeters), recorder.liveEventCount)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("history.stop"), role: .destructive) {
                    app.stopTripRecording()
                }
                .buttonStyle(.bordered)
            }
        } else {
            Button {
                app.startTripRecording()
            } label: {
                Label(L("trip.record.start"), systemImage: "record.circle")
            }
        }
    }
}

struct TripHistoryRow: View {
    let trip: Trip
    var isRecording = false

    var body: some View {
        let stats = TripStats.compute(trip)
        let score = TripScoring.score(events: trip.events, distanceMeters: stats.distanceMeters).score
        HStack(spacing: 12) {
            TripScoreRing(score: score, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(TripStyle.title(trip))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(TripStyle.dateText(trip))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Label(RVFormat.appDistance(stats.distanceMeters), systemImage: "road.lanes")
                    Label(RVFormat.appDuration(stats.duration), systemImage: "clock")
                    if stats.totalEvents > 0 {
                        Label("\(stats.totalEvents)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(RVTheme.caution)
                    }
                    if isRecording {
                        Text(l: "history.recordingLower").foregroundStyle(RVTheme.recording)
                    } else if trip.endedAt == nil {
                        Text(l: "history.interrupted").foregroundStyle(RVTheme.caution)
                    }
                }
                .font(.caption2)
                .labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, 2)
    }
}

/// History in its own sheet (navigator idle screen) with «Готово».
struct TripHistorySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TripHistoryView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("common.done")) { dismiss() }
                            .fontWeight(.semibold)
                    }
                }
        }
        .preferredColorScheme(.dark)
    }
}
