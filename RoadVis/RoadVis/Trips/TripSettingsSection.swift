import SwiftUI

/// Settings → «Поездки»: the on/off switch of the silent background trip recording, the history, manual start / stop,
/// camera CSV and event thresholds. This is the only place where recording is controlled (no on-screen buttons).
struct TripSettingsSection: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        let recorder = app.tripRecorder
        Section {
            Toggle(isOn: $settings.tripAutoRecord) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(l: "tripset.auto")
                    Text(l: "tripset.auto.detail")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            NavigationLink {
                TripHistoryView()
            } label: {
                HStack {
                    Label(L("history.title"), systemImage: "list.bullet.rectangle.portrait")
                    Spacer()
                    if app.trips.isLoaded {
                        Text("\(app.trips.trips.count)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if recorder.isRecording {
                Label(L("tripset.recordingNow"), systemImage: "record.circle")
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    app.stopTripRecording()
                } label: {
                    Label(L("trip.record.stop"), systemImage: "stop.circle")
                }
            } else {
                Button {
                    app.startTripRecording()
                } label: {
                    Label(L("trip.record.start"), systemImage: "record.circle")
                }
                .disabled(recorder.isFinishing)
            }
            Toggle(L("tripset.cameraCSV"), isOn: $settings.tripRecordCameraCSV)
                .onChange(of: settings.tripRecordCameraCSV) { _, _ in
                    recorder.syncCameraCSV()
                }
            Stepper(value: $settings.tripSpeedToleranceKmh, in: 0...20, step: 1) {
                valueRow(L("tripset.tolerance"), "+\(Int(settings.tripSpeedToleranceKmh)) \(RVFormat.appKmh)")
            }
            Stepper(value: $settings.tripSpeedingMinSeconds, in: 5...30, step: 1) {
                valueRow(L("tripset.speedingLonger"), "\(Int(settings.tripSpeedingMinSeconds)) \(RVFormat.appSeconds)")
            }
            Stepper(value: $settings.tripHarshBrakingMps2, in: 2.5...6, step: 0.5) {
                valueRow(L("tripset.braking"), "\(RVFormat.appDecimal(settings.tripHarshBrakingMps2, digits: 1)) \(L("event.unit.harshBraking"))")
            }
            Stepper(value: $settings.tripHarshAccelerationMps2, in: 2...5, step: 0.5) {
                valueRow(L("tripset.acceleration"), "\(RVFormat.appDecimal(settings.tripHarshAccelerationMps2, digits: 1)) \(L("event.unit.harshAcceleration"))")
            }
        } header: {
            Text(l: "common.trips")
        } footer: {
            Text(l: "tripset.footer")
        }
    }

    private func valueRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
