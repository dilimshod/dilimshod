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
+5 points, pedestrians +10, traffic lights +20, stop signs +25 (`DetectionThresholds`). Ultralytics weights are
AGPL-3.0.

## Natural voice (optional)
Generate the Microsoft Edge clips on a Mac (see `../RoadVis/tools/VOICE_CLIPS.md`), then copy them:
`cp ../RoadVis/RoadVis/VoiceClips/*.m4a app/src/main/assets/voice/` and rebuild. Without clips the system
TextToSpeech is used. The clips are for personal testing only (not redistributable).

## Background
Android requires a foreground service for background GPS: while a trip is recording a silent, minimal
notification is shown (no on-screen recording icon).
