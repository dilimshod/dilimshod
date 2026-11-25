import SwiftUI

/// Settings → «Поездки»: autostart with «Поехали», camera CSV, event thresholds, manual start / stop and the history.
struct TripSettingsSection: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        let recorder = app.tripRecorder
        Section {
            NavigationLink {
                TripHistoryView()
            } label: {
                HStack {
                    Label("История поездок", systemImage: "list.bullet.rectangle.portrait")
                    Spacer()
                    if app.trips.isLoaded {
                        Text("\(app.trips.trips.count)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if recorder.isRecording {
                Button(role: .destructive) {
                    app.stopTripRecording()
                } label: {
                    Label("Остановить запись поездки", systemImage: "stop.circle")
                }
            } else {
                Button {
                    app.startTripRecording()
                } label: {
                    Label("Начать запись поездки", systemImage: "record.circle")
                }
                .disabled(recorder.isFinishing)
            }
            Toggle("Автозапись поездок", isOn: $settings.tripAutoRecord)
            Toggle("Записывать CSV камеры во время поездки", isOn: $settings.tripRecordCameraCSV)
            Stepper(value: $settings.tripSpeedToleranceKmh, in: 0...20, step: 1) {
                valueRow("Допуск превышения", "+\(Int(settings.tripSpeedToleranceKmh)) км/ч")
            }
            Stepper(value: $settings.tripSpeedingMinSeconds, in: 5...30, step: 1) {
                valueRow("Превышение дольше", "\(Int(settings.tripSpeedingMinSeconds)) с")
            }
            Stepper(value: $settings.tripHarshBrakingMps2, in: 2.5...6, step: 0.5) {
                valueRow("Резкое торможение от", "\(RVFormat.decimal(settings.tripHarshBrakingMps2, digits: 1)) м/с²")
            }
            Stepper(value: $settings.tripHarshAccelerationMps2, in: 2...5, step: 0.5) {
                valueRow("Резкий разгон от", "\(RVFormat.decimal(settings.tripHarshAccelerationMps2, digits: 1)) м/с²")
            }
        } header: {
            Text("Поездки")
        } footer: {
            Text("При «Поехали» запись поездки начинается автоматически и заканчивается по прибытии — затем открывается отчёт с картой, оценкой, графиками и списком нарушений (PDF и CSV). Превышение — по скорости GPS и ограничению из OpenStreetMap / Valhalla; резкие торможения и разгоны — по GPS и датчикам движения телефона; события камеры — ≈ оценка. Поездки хранятся только на телефоне. Пороги применяются к новым поездкам.")
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
