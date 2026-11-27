# RoadVis — Android

Kotlin + Jetpack Compose port of the iOS app (`../RoadVis`). Same features and settings keys, uz/ru/en (Uzbek default).

- `core/` — pure Kotlin logic ported from `RoadVisCore` (tracking, YOLO decoding, distance, lanes, pedestrians,
  coach, trips, Valhalla/OSRM/Overpass/Open-Meteo parsing…), JUnit tests: `./gradlew :core:test`.
- `app/` — CameraX + ONNX Runtime (`assets/yolo11n.onnx`, see “Detector model” below), MapLibre Native with free OpenFreeMap vector tiles (no API key; CARTO Dark raster fallback), TextToSpeech + natural voice clips.

## Build
JDK 17+ and the Android SDK (API 35). `./gradlew :app:assembleRelease` →
`app/build/outputs/apk/release/app-release.apk` (signed with the debug key, for sideloading).
CI (`.github/workflows/roadvis-android.yml`) builds the same APK and uploads it as an artifact.

## Install on a phone (Android 8+)
1. Copy `app-release.apk` to the phone (Telegram “Saved messages”, USB, Google Drive).
2. Open it → allow “Install unknown apps” for that app → Install.
3. Grant camera and location (“While using the app”) on first launch.
Or with USB debugging: `adb install -r app-release.apk`.

## Detector model
`app/src/main/assets/yolo11n.onnx` (10.9 MB) is YOLO11n (COCO) exported with **dynamic** `batch` / `height` / `width`
dimensions. `YoloDetector` creates one ONNX Runtime session per input size with fixed free-dimension overrides
(`setSymbolicDimensionValue`), lazily, and picks it per frame:

| Frame | LITE input (W×H) | FULL input (W×H) |
|---|---|---|
| landscape 1280×720 | 640×384 | 960×544 |
| portrait 720×1280 | 384×640 | 544×960 |

The inputs are rectangular 16:9, so the frame fills the model input (12 px / 2 px letterbox bars instead of the 44 %
padding of the old square 640×640 input). The app starts at LITE and `DetectorQualityGovernor` (core) moves to FULL
when the mean inference time at LITE is below 30 ms, and back when FULL exceeds 70 ms or the thermal status is
“severe”. The status sheet shows the input in use (`yolo11n 640×384`).

Measured while choosing this (not on a phone): ONNX Runtime on an x86 CPU, 1 thread, relative to the old 640×640
input — 384×640 ×0.58 with the same detections on 240 of 248 boxes, 544×960 ×1.29; BDD100K val (300 US dashcam frames,
zero-shot COCO weights) mAP50 27.5 → 37.0 from 384×640 to 544×960. Nothing was timed on an Android device, and
`setSymbolicDimensionValue` + XNNPACK was only exercised through the Python API — the plain CPU provider and the
LITE size are the fallbacks; a model with a fixed input shape is used at its own shape.

Re-export / verify (Python 3.10–3.13, `pip install ultralytics onnx onnxruntime onnxslim`):

```bash
python tools/export_yolo_onnx.py --force              # yolo11n.pt → app/src/main/assets/yolo11n.onnx
python tools/export_yolo_onnx.py --verify photo.jpg   # runs the asset at all four input sizes with onnxruntime
```

Confidence: the settings slider (default 35 %) is the threshold of cars / trucks / buses; motorcycles and bicycles
+5 points, pedestrians +10, stop signs +25, traffic lights +0 (`DetectionThresholds`; a light drives the indicator /
coach only with a stable known colour, `TrafficLightSelection`). Ultralytics weights are AGPL-3.0.

Recognition pipeline (mirror of the iOS worker, same order and constants): one horizon per frame (manual setting or
the lane vanishing-point estimate, `LaneHorizonEstimator`, toggle "auto horizon") → lanes (adaptive thresholds,
3-frame accumulation) → detector → light colour (`TrafficLightColorClassifier` v2) / person role → tracker
(two-stage low-score association, 3 coasted frames, timed colour vote) → distance / speed → lead vehicle
(aspect-aware corridor) → pedestrians vs roadway → own-lane traffic light. The Kotlin core is covered by the same
unit tests as the Swift core (including the 292-crop classifier parity fixture); nothing of this was run on a phone
or on real video.

## Continuous learning (opt-in)
Settings → “Improve recognition” implements the client side of `../RoadVis/docs/TRAINING_API.md` (same contract as
iOS and the RoadVis Trainer server). Off by default; nothing is collected or sent until the switch is on.

- **Collection** (`core`: `HardExampleSelector`, `FrameQuality`; app: `learning/LearningCollector`): per processed
  frame the selector looks for `missedDetection`, `shortLived`, `lowConfidence`, `classFlip` and the 1 % `random`
  sample, gated by 2 s between kept frames, 300 per trip (reset on «Поехали»), own speed ≥ 5 km/h or unknown, and —
  computed only for such candidates, at most every 0.5 s — sharpness ≥ 60, brightness 35–225 and a dHash distance > 6
  to the last kept frame (160-px gray copy). The selector decides about the previous frame, so a short-lived track is
  saved on the frame where it was last detected; the worker double-buffers the frame bytes for this while collection
  is on. A kept frame is encoded on a low-priority thread: 960-px long side, JPEG 80, `filesDir/learning/pending/
  <uuid>.jpg` + `<uuid>.json`, then the retention rules (14 days, 100 / 300 / 1000 MB cap, oldest first).
- **Privacy**: Android has no free on-device face detector without new dependencies, so the upper third of every
  person box at least 12 % of the frame tall is blurred instead (no exact face boxes; small persons are not blurred).
  Collection is paused while pedestrian detection is off, because the blur needs the person boxes. Location is added
  only with “Send location” on (and stripped at upload time if it was switched off later).
- **Upload** (`learning/LearningUploader`, WorkManager `androidx.work:work-runtime-ktx`): hourly periodic work (and
  “Upload now”) on an unmetered network while “Wi-Fi only” is on, battery not low, never while the camera screen is
  processing frames; up to 20 samples per run as multipart `image` + `meta` to `POST /api/v1/samples` with
  `Authorization: Bearer <device token>` and `User-Agent: RoadVis-Android/<version>`. 201 / 409 delete the sample,
  413 / 422 delete it as rejected, 401 stops, anything else backs off 1, 2, 4 … 60 min (one-time retry work). The
  device token is stored in the app's private SharedPreferences (`rv.learning.token`): the project has no
  `androidx.security` dependency for EncryptedSharedPreferences.
- **Model updates** (`learning/ModelUpdateService`): with “Download improved models” on, a daily check on Wi-Fi of
  `GET /api/v1/model/latest?platform=android`; a new version is downloaded to a temp folder, its size and sha256 are
  verified, an ONNX Runtime session is opened and run once on a zero image, and only then it is moved to
  `filesDir/models/<version>/yolo-roadvis.onnx` and activated. `YoloDetector` prefers that file over the bundled
  `yolo11n.onnx` (same dynamic-axes handling, four input sizes); if it fails to load or yields no boxes for 30 s of
  driving while frames arrive (`ModelHealthMonitor`), the detector reverts to the bundled model and the version is
  remembered as bad. The status rows show the current model (bundled, or version · date · test mAP50).

Settings keys: `rv.learning.*` in the `roadvis` SharedPreferences. Nothing of this was run against a live server or on
a phone; the selector, quality metrics, metadata keys, storage policy, manifest parsing and switch / revert rules are
covered by `ContinuousLearningTest` (core).

## Natural voice (optional)
Generate the Microsoft Edge clips on a Mac (see `../RoadVis/tools/VOICE_CLIPS.md`), then copy them:
`cp ../RoadVis/RoadVis/VoiceClips/*.m4a app/src/main/assets/voice/` and rebuild. Without clips the system
TextToSpeech is used. The clips are for personal testing only (not redistributable).

## Background
Android requires a foreground service for background GPS: while a trip is recording a silent, minimal
notification is shown (no on-screen recording icon).
