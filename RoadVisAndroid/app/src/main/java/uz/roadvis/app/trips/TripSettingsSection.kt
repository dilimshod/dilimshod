package uz.roadvis.app.trips

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ListAlt
import androidx.compose.material.icons.filled.FiberManualRecord
import androidx.compose.material.icons.filled.StopCircle
import androidx.compose.runtime.Composable
import uz.roadvis.app.app.AppState
import uz.roadvis.app.l10n.L
import uz.roadvis.app.settings.ButtonRow
import uz.roadvis.app.settings.FormSection
import uz.roadvis.app.settings.NavRow
import uz.roadvis.app.settings.RowDivider
import uz.roadvis.app.settings.SheetNav
import uz.roadvis.app.settings.SheetRoute
import uz.roadvis.app.settings.StepperRow
import uz.roadvis.app.settings.TextRow
import uz.roadvis.app.settings.ToggleRow

/**
 * Settings → «Поездки»: the switch of the silent background trip recording, the history, manual start / stop, camera
 * CSV and event thresholds. The only place where recording is controlled (no on-screen buttons). Port of iOS
 * `TripSettingsSection`.
 */
@Composable
fun TripSettingsSection(app: AppState, nav: SheetNav) {
    val s = app.settings
    val controller = TripsFeature.get(app)
    val recorder = controller.recorder
    FormSection(header = L("common.trips"), footer = L("tripset.footer")) {
        ToggleRow(L("tripset.auto"), s.tripAutoRecord, { s.tripAutoRecord = it }, subtitle = L("tripset.auto.detail"))
        RowDivider()
        NavRow(L("history.title"), Icons.AutoMirrored.Filled.ListAlt,
            trailing = if (controller.store.isLoaded) "${controller.store.trips.size}" else null) { nav.push(SheetRoute.History) }
        RowDivider()
        if (recorder.isRecording) {
            TextRow(L("tripset.recordingNow"), secondary = true)
            ButtonRow(L("trip.record.stop"), Icons.Filled.StopCircle, destructive = true) { controller.stopTripRecording() }
        } else {
            ButtonRow(L("trip.record.start"), Icons.Filled.FiberManualRecord, enabled = !recorder.isFinishing) { controller.startTripRecording() }
        }
        RowDivider()
        ToggleRow(L("tripset.cameraCSV"), s.tripRecordCameraCSV, { s.tripRecordCameraCSV = it })
        RowDivider()
        StepperRow(L("tripset.tolerance"), s.tripSpeedToleranceKmh, 0.0..20.0, 1.0,
            "+${s.tripSpeedToleranceKmh.toInt()} ${AppFormat.kmh}", { s.tripSpeedToleranceKmh = it })
        StepperRow(L("tripset.speedingLonger"), s.tripSpeedingMinSeconds, 5.0..30.0, 1.0,
            "${s.tripSpeedingMinSeconds.toInt()} ${AppFormat.seconds}", { s.tripSpeedingMinSeconds = it })
        StepperRow(L("tripset.braking"), s.tripHarshBrakingMps2, 2.5..6.0, 0.5,
            "${AppFormat.decimal(s.tripHarshBrakingMps2, 1)} ${L("event.unit.harshBraking")}", { s.tripHarshBrakingMps2 = it })
        StepperRow(L("tripset.acceleration"), s.tripHarshAccelerationMps2, 2.0..5.0, 0.5,
            "${AppFormat.decimal(s.tripHarshAccelerationMps2, 1)} ${L("event.unit.harshAcceleration")}", { s.tripHarshAccelerationMps2 = it })
    }
}
