# RoadVis Trainer

Server side of RoadVis continuous learning. It implements the contract in
[`RoadVis/docs/TRAINING_API.md`](../RoadVis/docs/TRAINING_API.md) (sections 3 and 4).

Серверная часть непрерывного обучения RoadVis. Реализует контракт
[`RoadVis/docs/TRAINING_API.md`](../RoadVis/docs/TRAINING_API.md) (разделы 3 и 4).

```
phones ──POST /api/v1/samples──▶ data/incoming ──worker──▶ quality re-check ─▶ dedup ─▶ teacher YOLO11x @1280
                                                     │ rejected → files deleted at once, a reason record is kept
                                                     ▼
                                      data/dataset/{train,val,test} (YOLO; test frozen at 300 images)
                                                     │  GET /api/v1/admin/dataset/export
                                                     ▼
                                Google Colab (GPU, free): fine-tune → POST /api/v1/admin/candidates
                                                     │
                                worker: gate on the frozen test set (CPU) ─▶ accepted? ─▶ Core ML + ONNX
                                                     ▼
phones ◀──GET /api/v1/model/latest + /files/...── data/models/<version>/ (last 3 versions kept)
```

Everything is free and open source: FastAPI, uvicorn, SQLite, Pillow, numpy, Ultralytics (AGPL-3.0), PyTorch CPU,
coremltools, ONNX. Всё бесплатно и с открытым кодом.

---

## 1. Install / Установка

The service runs next to trafficcounter.uz and does **not** touch it: own port (127.0.0.1:8601), own folder, own
nginx `location`. Сервис работает рядом с trafficcounter.uz и **не трогает** его: свой порт, своя папка, свой
`location` в nginx.

### Option A — Docker Compose (recommended / рекомендуется)

```bash
cd RoadVisTrainer
cp .env.example .env
python3 -c "import secrets; print(secrets.token_urlsafe(32))"   # → put into ROADVIS_ADMIN_TOKEN in .env
mkdir -p data && sudo chown 10001:10001 data                     # containers run as non-root uid 10001
docker compose up -d --build
curl http://127.0.0.1:8601/healthz                               # {"status":"ok",...}
docker compose logs -f worker
```

Two containers share `./data`: `api` (uvicorn, 1 CPU) and `worker` (teacher, gate, export; capped at 2 CPUs and
`ROADVIS_WORKER_THREADS=2` threads, lowered priority). On first use the worker downloads `yolo11x.pt` (~110 MB,
teacher) and `yolo11s.pt` (baseline) into `./data`.

Два контейнера с общей папкой `./data`: `api` и `worker` (учитель, проверка качества, экспорт; не больше 2 CPU и
`ROADVIS_WORKER_THREADS=2` потоков, пониженный приоритет), чтобы сайт не тормозил. При первом запуске worker скачает
`yolo11x.pt` (~110 МБ) и `yolo11s.pt` в `./data`.

### Option B — virtualenv + systemd

```bash
sudo useradd --system --create-home --home-dir /opt/roadvis roadvis
sudo -u roadvis -H bash -c '
  cd /opt/roadvis && git clone <this repo> src && cd src/RoadVisTrainer
  python3 -m venv /opt/roadvis/venv
  /opt/roadvis/venv/bin/pip install torch==2.7.1 torchvision==0.22.1 --index-url https://download.pytorch.org/whl/cpu
  /opt/roadvis/venv/bin/pip install .
  cp .env.example /opt/roadvis/.env'          # edit it: ROADVIS_ADMIN_TOKEN, ROADVIS_DATA_DIR=/opt/roadvis/data
```

Install CPU torch **first** (otherwise pip pulls the multi-GB CUDA build). Python 3.11–3.13.
Сначала ставьте CPU-сборку torch, иначе pip скачает CUDA-версию на несколько ГБ.

`/etc/systemd/system/roadvis-trainer-api.service`:

```ini
[Unit]
Description=RoadVis Trainer API
After=network.target

[Service]
User=roadvis
WorkingDirectory=/opt/roadvis
EnvironmentFile=/opt/roadvis/.env
ExecStart=/opt/roadvis/venv/bin/roadvis-trainer serve --host 127.0.0.1 --port 8601
Restart=always
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
```

`/etc/systemd/system/roadvis-trainer-worker.service`:

```ini
[Unit]
Description=RoadVis Trainer worker
After=network.target

[Service]
User=roadvis
WorkingDirectory=/opt/roadvis
EnvironmentFile=/opt/roadvis/.env
ExecStart=/opt/roadvis/venv/bin/roadvis-trainer worker
Restart=always
Nice=10
CPUQuota=200%
MemoryMax=6G
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now roadvis-trainer-api roadvis-trainer-worker
```

---

## 2. Reverse proxy (nginx) / Обратный прокси

Add a `location` to the existing `server { ... }` block of trafficcounter.uz (nothing else changes), then
`sudo nginx -t && sudo systemctl reload nginx`. Добавьте `location` в существующий блок `server` сайта
trafficcounter.uz (больше ничего не меняется), затем `sudo nginx -t && sudo systemctl reload nginx`.

```nginx
# RoadVis Trainer → https://trafficcounter.uz/roadvis/
location /roadvis/ {
    proxy_pass http://127.0.0.1:8601/;        # trailing slash: nginx strips the /roadvis prefix
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    client_max_body_size 650m;                 # samples are <= 2 MB; Colab uploads best.pt (~20 MB)
    proxy_request_buffering off;               # stream uploads, the app enforces its own limits
    proxy_read_timeout 900s;                   # dataset export can take a while
    proxy_send_timeout 900s;
    proxy_buffering off;                       # stream model files and exports (Range is supported)
}
```

`ROADVIS_ROOT_PATH=/roadvis` (alias `ROOT_PATH`) tells the app its public prefix. Requests work whether nginx strips
the prefix (as above) or forwards it unchanged. The phones use the base URL `https://trafficcounter.uz/roadvis`.

---

## 3. Device tokens / Токены устройств

```bash
roadvis-trainer token create --name "iphone-alisher"     # prints the token ONCE — paste it into the app settings
roadvis-trainer token list                               # names, dates, active/revoked (never the token)
roadvis-trainer token revoke iphone-alisher              # by name or numeric id
# Docker: docker compose exec api roadvis-trainer token create --name pixel-7
```

Tokens are stored only as sha256 hashes; a lost token cannot be recovered — create a new one. The admin token
(`ROADVIS_ADMIN_TOKEN`) is separate and guards `/api/v1/admin/*`; whoever has it can upload model weights (PyTorch
`.pt` files are pickles, i.e. code execution on the server), so keep it private.

Токены хранятся только как sha256-хэши; потерянный токен восстановить нельзя — создайте новый. Admin-токен
(`ROADVIS_ADMIN_TOKEN`) отдельный и защищает `/api/v1/admin/*`. Владелец admin-токена может загружать веса модели
(файлы `.pt` — это pickle, т.е. выполнение кода на сервере), поэтому никому его не передавайте.

---

## 4. Pipeline / Конвейер (contract section 4)

1. **Ingest** — `POST /api/v1/samples` validates and stores `data/incoming/<id>.jpg|json`, row `queued` in SQLite.
2. **Worker** (`roadvis-trainer worker`, small batches, `ROADVIS_WORKER_THREADS` CPU threads):
   - quality re-check at 160 px wide: sharpness (4-neighbour Laplacian variance) ≥ 60, brightness in [35, 225];
   - near-duplicate: dHash Hamming distance ≤ 6 against **all kept frames** → deleted;
   - teacher (`ROADVIS_TEACHER_MODEL`, default `yolo11x.pt` at `ROADVIS_TEACHER_IMGSZ=1280`, 8 app classes):
     boxes ≥ 0.50 become labels; any box in [0.25, 0.50) → frame ambiguous → deleted;
   - consistency: a phone track confirmed with ≥ 5 hits without a teacher box of IoU ≥ 0.3 → deleted;
   - accepted frames → `data/dataset/images|labels/{train,val,test}`, split `sha1(id) % 10`: 0 → test,
     1 → val, else train (`id` = the lower-case UUID; SHA-1 hex read as an integer). Once test holds 300 images it is
     **frozen forever**; later bucket-0 frames go by the next hash digit (`sha1 // 10 % 10`: 1 → val, else train);
   - frames without any confident box are kept as background images (empty label file);
   - retention: at most `ROADVIS_DATASET_CAP=50000` images, oldest train first (then val), test never.
   - Rejected samples: files deleted immediately, only a small record (`id`, reason, metrics) stays in the DB.
     Reasons: `blurry`, `tooDark`, `tooBright`, `duplicate`, `ambiguousTeacher`, `phoneTrackUnmatched`, `badImage`,
     `missingFiles`, `teacherError`, `incompleteUpload`.
3. **Train** on Colab (section 5) or `roadvis-trainer train --local`.
4. **Gate** — the worker evaluates the candidate and the current model (before the first accepted model: stock
   `yolo11s.pt`, so the first model must beat it) on the frozen test set with Ultralytics `val`, CPU, imgsz 960.
   Accepted only if mAP50 ≥ current + 0.005 **and** recall of car, person, traffic light each drops ≤ 0.01 **and**
   precision drops ≤ 0.01. Precondition: the test set has ≥ `ROADVIS_GATE_MIN_TEST_IMAGES` (100) images, otherwise
   the candidate is rejected as `testSetTooSmall`. Report: `data/reports/<candidate>.json`. Rejected weights are
   deleted.
5. **Publish** — Core ML `RoadVisDetector.mlpackage` (input 960×544, landscape) and `RoadVisDetectorPortrait.mlpackage`
   (544×960), NMS pipeline, FP16, optional threshold inputs; ONNX `yolo-roadvis.onnx` with dynamic axes; manifest; the
   last 3 versions are kept. If the Core ML export fails, the version is published with `"ios": null` (Android only)
   and the error is logged.

### Class mapping / Соответствие классов

The apps decode by **label name** (lower-case, `_`/`-` = space), so these names map to the same kinds as COCO names.
Приложения сопоставляют классы **по имени** (`traffic_light` = `traffic light`).

| dataset id | name (data.yaml, model) | COCO id (teacher) | app kind |
|---|---|---|---|
| 0 | `car` | 2 | car |
| 1 | `truck` | 7 | truck |
| 2 | `bus` | 5 | bus |
| 3 | `motorcycle` | 3 | motorcycle |
| 4 | `bicycle` | 1 | bicycle |
| 5 | `person` | 0 | person |
| 6 | `traffic_light` | 9 | trafficLight |
| 7 | `stop_sign` | 11 | stopSign |

The published models therefore output 8 classes (Core ML pipeline labels / ONNX metadata `names`); the stock model
has 80. During the gate, a COCO model is evaluated by remapping test labels to its class ids by name.

---

## 5. Training on Google Colab / Обучение в Google Colab

```bash
roadvis-trainer train --colab        # writes colab/RoadVis_train.ipynb and prints a one-click Colab link
```

The notebook is committed: [`colab/RoadVis_train.ipynb`](colab/RoadVis_train.ipynb). Flow:

1. Open it in Colab (GitHub link printed by the command, or *File → Upload notebook*), *Runtime → Change runtime
   type → T4 GPU*.
2. Fill the form: `SERVER_URL` (`https://trafficcounter.uz/roadvis`), `ADMIN_TOKEN` (or the Colab secret
   `ROADVIS_ADMIN_TOKEN`). *Runtime → Run all*.
3. It downloads `GET /api/v1/admin/dataset/export?include_test=false` (the frozen test set stays on the server),
   fetches the current accepted weights (`GET /api/v1/admin/model/current`, else `yolo11s.pt`), trains with
   `imgsz=960, rect=True, epochs=50, patience=10, batch=-1` (auto), and uploads `best.pt` + `metrics.json` to
   `POST /api/v1/admin/candidates`.
4. The server worker gates and publishes it; the last cell polls `GET /api/v1/admin/candidates/<id>`.

Порядок: откройте блокнот в Colab, выберите GPU T4, впишите адрес сервера и admin-токен (или секрет
`ROADVIS_ADMIN_TOKEN`), «Выполнить все». Блокнот скачает датасет (без тестового набора), дообучит текущую
принятую модель (или `yolo11s.pt`) и отправит `best.pt` на сервер; сервер сам проверит и опубликует её, только если
она лучше. Последняя ячейка ждёт решения сервера.

`roadvis-trainer train --local [--epochs 10 --imgsz 640]` trains on the server CPU — only for small datasets
(refuses > 3000 train images without `--force`) — and submits the result as a candidate.
Локальное обучение на CPU сервера — только для маленьких датасетов.

---

## 6. API

All requests: `Authorization: Bearer <token>`. Errors: JSON `{"detail": ...}`.

| method & path | auth | responses |
|---|---|---|
| `POST /api/v1/samples` (multipart: `image` JPEG file part ≤ 2 MB, `meta` JSON) | device | `201 {"id","status":"queued"}`, `401`, `409` duplicate id, `413` > 2 MB, `422` invalid meta / not JPEG / not multipart, `429` > 600 per device per UTC day (`Retry-After`) |
| `GET /api/v1/model/latest?platform=ios\|android` | device | `200` manifest (newest version that has the platform), `204` none yet |
| `GET /api/v1/model/{version}/files/{path}` | device | raw file, `Range` → `206`; `404` for anything not listed in that manifest |
| `GET /api/v1/admin/dataset/export[?include_test=false]` | admin | zip: `data.yaml`, `images|labels/{train,val}`, frozen test set in `test/images|labels` |
| `GET /api/v1/admin/model/current` | admin | current accepted `weights.pt` (`X-RoadVis-Version`), `404` none |
| `POST /api/v1/admin/candidates` (multipart: `weights` file, optional `metrics` JSON) | admin | `202 {"id","status":"pending"}` — the worker gates it |
| `GET /api/v1/admin/candidates/{id}` | admin | status + gate report |
| `GET /api/v1/admin/status` | admin | counts per stage/split/reason, worker heartbeat, last candidates, current model |
| `GET /healthz` | none | `{"status":"ok"}` |

Check order for samples: 401 → 413 → 422 → 409 → 429. The meta `id` must be a UUID (any case; stored lower-case);
unknown extra meta fields are ignored; `speedKmh`, `lat`, `lon`, `detections`, `tracks`, `quality` are optional.
The upload size is enforced while streaming (Content-Length checked first), the body is never read past the cap.

**Client notes (iOS/Android).** Manifest file paths of iOS packages are relative to the `.mlpackage`
(e.g. `Manifest.json`, `Data/com.apple.CoreML/model.mlmodel`), as in the contract. Download URL:
`/api/v1/model/{version}/files/{name}.mlpackage/{path}` (e.g. `.../files/RoadVisDetector.mlpackage/Manifest.json`);
write the file to `<name>.mlpackage/<path>`. Android: `/api/v1/model/{version}/files/yolo-roadvis.onnx`. The image
part must be sent as a file part (with a `filename`); `meta` may be a file part or a plain text field.

---

## 7. Backup / Резервное копирование

Everything lives in the data folder (`./data` with Docker, `ROADVIS_DATA_DIR` otherwise):
`roadvis.sqlite3` (tokens, sample records, candidates, versions), `dataset/` (the valuable part — labelled frames
and the frozen test set), `models/` (published versions), `reports/`. `incoming/`, `candidates/`, `tmp/` and the
`*.pt` downloads can be skipped.

Всё хранится в папке данных. Ценное: `roadvis.sqlite3`, `dataset/` (размеченные кадры и замороженный тест),
`models/`, `reports/`. Папки `incoming/`, `candidates/`, `tmp/` и скачанные `*.pt` можно не копировать.

```bash
# consistent SQLite snapshot while running (WAL mode), then the files
sqlite3 data/roadvis.sqlite3 ".backup 'data/backup.sqlite3'"
tar czf roadvis-backup-$(date +%F).tgz -C data backup.sqlite3 dataset models reports
# restore: stop the services, unpack into data/, rename backup.sqlite3 → roadvis.sqlite3, start again
```

Without the `sqlite3` CLI: `python3 -c "import sqlite3; s=sqlite3.connect('data/roadvis.sqlite3');
d=sqlite3.connect('data/backup.sqlite3'); s.backup(d)"`. Keep the frozen test set — if it is lost, model comparisons
start from scratch.

---

## 8. Configuration / Настройки

See [`.env.example`](.env.example). Main variables: `ROADVIS_ADMIN_TOKEN`, `ROADVIS_ROOT_PATH` (`ROOT_PATH`),
`ROADVIS_DATA_DIR`, `ROADVIS_TEACHER_MODEL` (`yolo11x.pt`), `ROADVIS_TEACHER_IMGSZ` (1280),
`ROADVIS_WORKER_THREADS` (2), `ROADVIS_WORKER_BATCH` (4), `ROADVIS_DAILY_LIMIT` (600), `ROADVIS_MAX_IMAGE_BYTES`
(2 MB), `ROADVIS_TEST_FREEZE_AT` (300), `ROADVIS_DATASET_CAP` (50000), `ROADVIS_EVAL_IMGSZ` (960),
`ROADVIS_BASELINE_MODEL` (`yolo11s.pt`), `ROADVIS_GATE_MIN_TEST_IMAGES` (100), `ROADVIS_KEEP_VERSIONS` (3).
On a server without internet access put `yolo11x.pt` and `yolo11s.pt` into the data folder (Docker working
directory) or set the variables to absolute paths.

---

## 9. Development / Разработка

```bash
python3 -m venv .venv && . .venv/bin/activate
pip install torch==2.7.1 torchvision==0.22.1 --index-url https://download.pytorch.org/whl/cpu
pip install -e ".[dev]"
pytest -q                      # the teacher and exporters are mocked: no network, no model downloads
roadvis-trainer train --colab  # regenerate the committed notebook after editing training.py (a test checks it)
```

CI: `.github/workflows/roadvis-trainer.yml` runs the tests on pull requests touching `RoadVisTrainer/**`.

Licence: AGPL-3.0 (Ultralytics). Лицензия: AGPL-3.0 (из-за Ultralytics).
