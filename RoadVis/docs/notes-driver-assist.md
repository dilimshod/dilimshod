# Driver assistant (beginner-driver coach): API notes

The assistant gives voice warnings about following distance, traffic lights, lane departure and road signs. Everything runs on the device, and every camera-based part is a heuristic.

## Core (Packages/RoadVisCore, Foundation only, tested in `DriverAssistTests.swift`)

| File | API |
|---|---|
| `LaneDetector.swift` | `LaneImage` (8-bit single channel; `fromBGRA(base:width:height:bytesPerRow:targetWidth:roiTop:)` builds a "marking brightness" channel in which yellow counts as bright). `LaneDetector` (`process(_:timestamp:) -> LaneEstimate`, `Config`, `reset()`). `LaneEstimate { left/right: LaneLine?, left/rightConfidence, laneCenterX, egoOffset (−1 left line … 0 … +1 right line), confidence, referenceY, timestamp }`. `LaneLine` (normalized, top-left origin, `x(atY:)`). `LaneSide`. `LaneDepartureDetector` (`update(_:speedKmh:timestamp:) -> LaneSide?`, `activeSide`): triggers at ≥ 40 km/h when \|offset\| ≥ 0.6 holds for ≥ 0.4 s next to a line with confidence ≥ 0.45. It has a 5 s cooldown and re-arms once \|offset\| < 0.4. |
| `RoadSignEvents.swift` | `FeatureAhead.from(features:distanceAlong:)`. `SignAnnouncer`: OSM features are announced at about 100 m in town and about 200 m on faster roads; speed cameras, railway crossings and schools are announced earlier. Each feature id is announced once. Other inputs: the current speed limit (it must stay unchanged for 3 s), upcoming speed-limit changes from `RouteEdgeAttributes`, and `cameraStopSign(trackID:)`. Output is `RoadSignEvent`. |
| `CoachRules.swift` | `CoachMessage` (parameters only, no text), `CoachCategory` (priority order: collision > redLight > laneDeparture > tailgating > sign > greenLight), `CoachUrgency`. `CoachRules` (offer/next): 3 s global gap that a collision bypasses, per-category cooldowns, and a time-to-live for each message. `TrafficLightCoach`: says "red ahead" above 20 km/h. Says "green, go" only after waiting at a red light, while below 3 km/h, after green has shown for ≥ 1 s, and with no lead vehicle closer than 4 m. `DriverCoachEngine` combines these with the distance voice rules taken over from `DistanceWarningController`. |
| `CameraDrivingEvents.swift` | `RedLightRunningDetector`: a confirmed red light in the upper centre leaves through the top edge while speed is > 15 km/h. `StopSignComplianceMonitor`: a STOP sign comes within 30 m, estimated from a 0.7 m sign width, and the minimum speed while passing stays ≥ 5 km/h. `CameraDrivingEventMonitor`: tailgating (< 0.5× the recommended gap for ≥ 2 s while moving), collision risk, lane departure, red-light running and STOP ignored. Repeats are collapsed by `DrivingEventDebouncer`. Heuristic events have `note = "heuristic"`. |

## App

- `RecognitionWorker` runs lane detection at about 5 Hz on a 160 px wide copy of the locked BGRA buffer. It reports the result in `Output.laneEstimate`.
- `RecognitionPipeline` exposes:
  - `laneEstimate: LaneEstimate?`
  - `laneDepartureSide: LaneSide?`
  - `var onDrivingEvent: ((DrivingEvent) -> Void)?`: main actor, new events only, with coordinate and speed.
  - `var onAssistFrame: ((DriverAssistFrame) -> Void)?`: used by the coach.
  - `var voiceWarningsHandledByCoach: Bool`: `DriverCoach` sets this. Haptics and the alert tone stay in `DistanceWarningController`.
- `Camera/LaneOverlay.swift` draws thin, low-opacity lane lines. The line on the departure side turns red. The overlay sits in `RecognitionView`'s `LiveDetectionLayer`.
- `Detection/DriverCoach.swift`: `@MainActor @Observable final class DriverCoach`. Init: `DriverCoach(recognition:location:speech:roadInfo:navigation:settings:)`. It reads OSM features only while navigating and voice guidance is off, because otherwise `NavigationService.announceHazard` already speaks them; override `navigationAnnouncesRouteFeatures` to change this. Speed-limit changes are always announced.
- `Detection/CoachPhrases.swift`: `coachText(_ message: CoachMessage, language: String) -> String` (uz/ru/en) and `currentCoachLanguage()` (UserDefaults "rv.appLanguage", default "uz").
- `Detection/DriverAssistSettings.swift`: `DriverAssistSettings.shared`, with these keys:
  - `rv.coachVoiceEnabled`
  - `rv.laneDepartureWarnings`
  - `rv.showLaneOverlay`
  - `rv.signAnnouncements`
  - `rv.trafficLightHints`
  - `rv.laneWarningMinSpeedKmh`

  It also provides `struct DriverAssistSettingsSection: View`, which returns two `Section`s to embed in a `Form`. The distance voice keeps its existing switch, `AppSettings.distanceWarningsEnabled`.

## Integration (AppState)

```swift
let coach: DriverCoach                       // stored property
// at the end of init(), after all services are assigned:
self.coach = DriverCoach(recognition: recognition, location: location, speech: speech,
                         roadInfo: roadInfo, navigation: navigation, settings: settings)
recognition.onDrivingEvent = { [weak tripRecorder] event in tripRecorder?.record(event) }
```

In `SettingsView`'s `Form`, add `DriverAssistSettingsSection()`.

## Limits

- Lane detection works on clear daytime markings only. It has no turn-signal input, so a deliberate lane change is also reported once.
- The red-light and STOP checks depend on detector confidence and monocular size estimates.
- Speed-limit OCR is not implemented.
