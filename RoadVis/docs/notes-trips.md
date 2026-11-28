# Trips slice — notes (navigator «Поехали» → camera, trip recording, trip report)

## Flow
- «Поехали» (`RouteOptionsView`) → `AppState.startDrive()`: `navigation.startNavigation()`, auto-starts
  `TripRecorder` when `settings.tripAutoRecord` (default ON), then `switchTo(.camera)`. Guidance continues by voice;
  the camera screen shows `NavigationMiniBanner` (top-left, under the speedometer row).
- Arrival (`NavigationService.onStateChange` → `.arrived`) or cancelled guidance (`.navigating → .idle`) stops a
  recording that «Поехали» started and presents `TripReportSheet` (`AppState.presentedTrip`). Manual recordings
  (`AppState.startTripRecording()` / `stopTripRecording()`) keep running until stopped.
- Entry points (shell has no tabs): navigator idle screen (Поездки / Записать поездку / ⓘ About), Settings →
  «Поездки» (history, start/stop, toggles, thresholds), Settings → «О приложении» → `AboutHubView`.

## Core (Foundation only, tested in `TripTests`)
- `TripModels.swift`: `TripEndpoint`, `TripPoint`, `TripThresholds`, `Trip` (Codable, JSON), `TripSpeedBand`,
  `TripStats.compute(_:)`, `TripScoring` (formula below), `DrivingEventKind.tripReportTitle/isCameraBased/tripValueUnit`,
  `TripExport.eventsCSV/pointsCSV/baseFileName`.
- `TripEventDetectors.swift`: `SpeedingDetector` (GPS speed > limit + tolerance for ≥ 5 s), `HarshMotionDetector`
  (GPS Δv/Δt over ≤ 2 s; ≤ −3.5 m/s² braking, ≥ 3.0 m/s² acceleration; motion-sensor magnitude confirms at ≥ 75 %).
- Score: penalty = weight(kind) × severity (0.5/1/1.5) × (1 + min(duration/30 s, 2));
  score = clamp(100 − 10 × Σpenalty / max(km, 1), 0, 100). Weights: red light 8, STOP 5, collision 5, speeding 3,
  tailgating 2, harsh braking 2, harsh acceleration 1.5, lane departure 1.5.

## App (Trips/)
- `TripStore` — `Application Support/RoadVis/Trips/<uuid>.json`, async load/write.
- `TripRecorder` — location listener (≈ 1 point/s, accuracy ≤ 65 m), limit = `navigation.currentEdge` (guidance) else
  `roadInfo.currentRoad`, ≈ lead gap from `recognition.leadVehicle` / `followingAssessment`, CMMotionManager
  deviceMotion (no permission), `DrivingEventDebouncer`, camera events via `ingest(_:)` (wired in `AppState` to
  `recognition.onDrivingEvent`), optional camera CSV (`settings.tripRecordCameraCSV`), autosave every 60 s,
  background location while recording. Trips with < 2 points are discarded.
- `TripReportView` / `TripReportSheet`, `TripMapView` (SwiftUI Map), `TripCharts` (Swift Charts),
  `TripReportExporter` (MKMapSnapshotter + ImageRenderer → multi-page A4 PDF, CSV with BOM, ShareLink),
  `TripHistoryView` / `TripHistorySheet`, `TripSettingsSection`, `TripStyle`, `NavigationMiniBanner`.
- Settings keys: `rv.tripAutoRecord`, `rv.tripRecordCameraCSV`, `rv.tripSpeedToleranceKmh`, `rv.tripSpeedingMinSeconds`,
  `rv.tripHarshBrakingMps2`, `rv.tripHarshAccelerationMps2`.
- Voice: the closest maneuver prompt (≤ 150 m) becomes «через 100 метров поверните направо, будьте осторожны[, снизьте
  скорость]» (speed > 40 km/h); phrases in `Navigation/NavigationPhrases.swift` (for localization).

## Integration still needed (file owned by the camera slice)
`Camera/RecognitionView.swift`, in `hud(pipeline:)`, inside the leading `VStack(alignment: .leading, spacing: 4)` right
after the `HStack { SpeedHUD(); RoadLine(...) }` row (before the `FollowingDistanceSlot`):

    NavigationMiniBanner()
