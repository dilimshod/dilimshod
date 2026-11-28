# RoadVis continuous learning — contract (apps ⇄ RoadVis Trainer)

Goal: reduce hallucinations (false positives) and misses of the on-device detector over time **without on-device
training** (Core ML / Android cannot fine-tune a YOLO detector on the phone, and self-training on the phone's own
answers would reinforce its errors). Phones collect *hard frames* with quality gates and auto-deletion; the
**RoadVis Trainer** service (folder `RoadVisTrainer/`, runs on the user's CPU-only server next to trafficcounter.uz,
e.g. `https://trafficcounter.uz/roadvis`) labels them automatically with a large teacher model, keeps only frames
that pass its quality tests, deletes the rest, trains (on Google Colab GPU, triggered with one command) and
publishes a new model **only if it beats the current one on a frozen test set**. The existing trafficcounter.uz site
is not modified.

Everything is opt-in (off by default) and free. Images contain people and number plates: the iOS app blurs faces
before saving (Vision face rectangles); the server stores images only for training and deletes rejected ones at once.

## 1. On-device collection (identical in Swift `RoadVisCore` and Kotlin `uz.roadvis.core`)

`HardExampleSelector` decides per processed frame whether to keep it. Input per frame: timestamp (s), own speed
(km/h, optional), tracks (`TrackedObject`: id, kind, confidence, hits, missed, isConfirmed, box, class-flip flag if
available), raw detections, and the frame-quality metrics below. Reasons (string raw values, several may apply):

| reason | rule |
|---|---|
| `missedDetection` | a confirmed track is coasting (`missed >= 1`) while its predicted box is fully inside the frame and its box height ≥ 0.04 |
| `shortLived` | a track that died after `hits <= 2` without being confirmed (likely hallucination); report on the frame where it was last detected (keep the selector's 1-frame memory) |
| `lowConfidence` | any detection with confidence in [0.25, threshold of its class) — i.e. below the app's per-class threshold but ≥ 0.25 |
| `classFlip` | a confirmed track whose class vote changed this frame |
| `random` | deterministic 1 % sample: `frameIndex % 100 == 37` |

Gating (all must pass, constants as named defaults):
- `minIntervalSeconds = 2.0` between kept frames; `maxPerTrip = 300`; only while own speed ≥ 5 km/h or unknown speed (no
  parked-car floods).
- Frame quality (`FrameQuality`, computed on a 160-px-wide grayscale copy):
  - sharpness = variance of the 4-neighbour Laplacian; keep if ≥ `minSharpness = 60` (at 160 px wide, 0–255 gray);
  - mean brightness in [`minBrightness = 35`, `maxBrightness = 225`];
  - near-duplicate: 64-bit dHash (9×8 resize, row-wise left>right comparison); drop if Hamming distance to the
    last kept frame's hash ≤ `maxDuplicateHamming = 6`.
- Output: `HardExampleDecision { keep: Bool, reasons: [String] }`.

Unit tests (both cores): each reason fires on a minimal synthetic track list; interval / per-trip caps; dHash of
identical gray images = distance 0, of an image and its horizontal mirror > 6 for a gradient image; sharpness of a
flat image = 0 and of a checkerboard ≥ 60; brightness gate.

## 2. Local storage and auto-deletion (apps)

Folder `Application Support/RoadVisLearning/pending` (iOS) / `filesDir/learning/pending` (Android). Each sample =
`<uuid>.jpg` (long side 960 px, JPEG quality 0.8, upright orientation; iOS: faces blurred) + `<uuid>.json`
(metadata below). Rules:
- total size cap (setting, default 300 MB, choices 100/300/1000): when exceeded delete oldest samples first;
- samples older than 14 days are deleted;
- after a successful upload (HTTP 201 or 409 duplicate) the sample is deleted at once;
- upload only when the setting allows (default Wi-Fi only), not while the camera screen is active, batched (max 20
  per run), exponential back-off on errors (1, 2, 4 … 60 min), never on cellular if Wi-Fi-only;
- "Delete all collected frames" button.

## 3. HTTP API (base URL from settings, default `https://trafficcounter.uz/roadvis`)

All requests: `Authorization: Bearer <device token>` (tokens are issued on the server with `roadvis-trainer
token create --name <device>`), `User-Agent: RoadVis-iOS/<ver>` or `RoadVis-Android/<ver>`.

### POST `/api/v1/samples` — multipart/form-data
Parts: `image` (image/jpeg), `meta` (application/json):
```json
{
  "id": "uuid", "capturedAt": "2026-11-26T10:00:00Z", "platform": "ios|android", "appVersion": "1.3",
  "model": {"name": "RoadVisDetector", "version": "bundled-yolo11s-960x544"},
  "image": {"width": 960, "height": 540, "orientation": "landscape|portrait"},
  "reasons": ["missedDetection"],
  "speedKmh": 42.0, "lat": 41.31, "lon": 69.28,
  "detections": [{"label": "car", "kind": "car", "confidence": 0.62, "box": [x, y, w, h]}],
  "tracks": [{"id": 7, "kind": "car", "confidence": 0.71, "hits": 12, "missed": 1, "confirmed": true, "box": [x, y, w, h]}],
  "quality": {"sharpness": 140.2, "brightness": 96.0, "dhash": "f0e1d2c3b4a59687"}
}
```
Boxes are normalized `[x, y, w, h]`, origin top-left. `lat`/`lon` are optional (setting "send location", default
off → omitted). Responses: `201 {"id": "...", "status": "queued"}`, `409` duplicate id, `401` bad token, `413` too
large (max 2 MB), `422` invalid meta, `429` rate limit (max 600 samples per device per day).

### GET `/api/v1/model/latest?platform=ios|android`
`200`:
```json
{
  "version": "2026-12-01-1", "createdAt": "...", "baseModel": "yolo11s",
  "metrics": {"testImages": 812, "map50": 0.71, "precision": 0.80, "recall": 0.66, "previous": {"map50": 0.68}},
  "ios":     {"landscape": {"name": "RoadVisDetector", "files": [{"path": "Manifest.json", "sha256": "...", "size": 617}, ...]},
              "portrait":  {"name": "RoadVisDetectorPortrait", "files": [...]}},
  "android": {"file": {"path": "yolo-roadvis.onnx", "sha256": "...", "size": 11000000}, "inputs": [[544, 960], [960, 544], [384, 640], [640, 384]]}
}
```
`204` when no trained model has been accepted yet. iOS model files are the files of the `.mlpackage` directory
(relative paths) so the app can rebuild the package without unzipping, then `MLModel.compileModel(at:)`.

### GET `/api/v1/model/{version}/files/{path}` — raw file (supports `Range`), sha256 must match the manifest.

### App model update rules
- Check at most once per day on Wi-Fi when the setting "download improved models" is on (default on when
  learning is on); download into a temp folder, verify sha256 of every file, compile (iOS) / open an ORT session
  (Android); only then atomically switch to it. Keep the bundled model as permanent fallback: if the downloaded
  model fails to load or produces no output for 30 s of driving, revert to the bundled model and remember the bad
  version.
- Settings show: current model (bundled / downloaded version + date + test mAP50 from the manifest).

## 4. Server-side pipeline (RoadVis Trainer)
1. **Ingest**: validate, store under `data/incoming/`, record in SQLite.
2. **Auto-label** (CPU worker, YOLO11x teacher at 1280 px, classes = the app's 8 COCO classes):
   - boxes with teacher confidence ≥ 0.50 become labels;
   - if any teacher box has confidence in [0.25, 0.50) the frame is **ambiguous → deleted** (no partial labels);
   - consistency check with the phone: a phone track that was confirmed with ≥ 5 hits but has no teacher box with
     IoU ≥ 0.3 marks the frame ambiguous → deleted;
   - server re-checks quality (sharpness/brightness at 160 px, same constants) and near-duplicates across ALL kept
     frames (dHash ≤ 6) → deleted;
   - accepted frames go to `data/dataset/images|labels/{train,val,test}` in YOLO format, split by
     `sha1(id) % 10`: 0 → test, 1 → val, else train. The **test set is frozen**: once it holds ≥ 300 images new
     frames never enter test (they go to val/train), so model comparisons stay fair.
3. **Train** (`roadvis-trainer train --colab` prints a one-click Colab link/notebook; the notebook downloads the
   dataset export with an admin token, fine-tunes from the current accepted weights (or yolo11s.pt) at imgsz 960,
   rect, ~50 epochs with early stopping, and uploads `best.pt` back via `POST /api/v1/admin/candidates`).
   `--local` trains on the server CPU (slow; small runs only).
4. **Quality gate** (server CPU): evaluate the candidate and the current model on the frozen test set at the app's
   input size. Accept only if mAP50 ≥ current + 0.005 AND per-class recall for car, person, traffic light does not
   drop by more than 0.01 AND precision does not drop by more than 0.01. Rejected candidates are deleted; the report
   is kept.
5. **Publish**: export accepted weights to Core ML (landscape 960×544 + portrait 544×960, nms=True) and ONNX (dynamic
   axes), write the manifest, keep the last 3 versions, delete older ones.
6. **Retention**: dataset cap (default 50 000 images, delete oldest train images first, never test), incoming files
   that fail any step are deleted immediately.
