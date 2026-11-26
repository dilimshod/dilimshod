# RoadVis — Android

Kotlin + Jetpack Compose port of the iOS app (`../RoadVis`). Same features and settings keys, uz/ru/en (Uzbek default).

- `core/` — pure Kotlin logic ported from `RoadVisCore` (tracking, YOLO decoding, distance, lanes, pedestrians,
  coach, trips, Valhalla/OSRM/Overpass/Open-Meteo parsing…), JUnit tests: `./gradlew :core:test`.
- `app/` — CameraX + ONNX Runtime (`assets/yolo11n.onnx`), MapLibre Native with free OpenFreeMap vector tiles (no API key; CARTO Dark raster fallback), TextToSpeech + natural voice clips.

## Build
JDK 17+ and the Android SDK (API 35). `./gradlew :app:assembleRelease` →
`app/build/outputs/apk/release/app-release.apk` (signed with the debug key, for sideloading).
CI (`.github/workflows/roadvis-android.yml`) builds the same APK and uploads it as an artifact.

## Install on a phone (Android 8+)
1. Copy `app-release.apk` to the phone (Telegram “Saved messages”, USB, Google Drive).
2. Open it → allow “Install unknown apps” for that app → Install.
3. Grant camera and location (“While using the app”) on first launch.
Or with USB debugging: `adb install -r app-release.apk`.

## Natural voice (optional)
Generate the Microsoft Edge clips on a Mac (see `../RoadVis/tools/VOICE_CLIPS.md`), then copy them:
`cp ../RoadVis/RoadVis/VoiceClips/*.m4a app/src/main/assets/voice/` and rebuild. Without clips the system
TextToSpeech is used. The clips are for personal testing only (not redistributable).

## Background
Android requires a foreground service for background GPS: while a trip is recording a silent, minimal
notification is shown (no on-screen recording icon).
