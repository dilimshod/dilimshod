"""Training: the Google Colab notebook (GPU, free) and a short local CPU run (contract section 4.3)."""

from __future__ import annotations

import json
import logging
import re
import shutil
import subprocess
import uuid
from pathlib import Path

import yaml

from .config import Settings
from .labeling import DATASET_NAMES
from .storage import Store, iso

log = logging.getLogger(__name__)

DEFAULT_SERVER = "https://trafficcounter.uz/roadvis"
NOTEBOOK_REL = Path("colab") / "RoadVis_train.ipynb"


# Colab notebook -------------------------------------------------------------------------------------------------------
def _md(text: str) -> dict:
    return {"cell_type": "markdown", "metadata": {}, "source": _lines(text)}


def _code(text: str, form: bool = False) -> dict:
    meta = {"cellView": "form"} if form else {}
    return {"cell_type": "code", "execution_count": None, "metadata": meta, "outputs": [], "source": _lines(text)}


def _lines(text: str) -> list[str]:
    text = text.strip("\n")
    lines = text.split("\n")
    return [line + "\n" for line in lines[:-1]] + [lines[-1]]


INTRO = """
# RoadVis — fine-tune the detector on Colab (GPU)

**RU.** Этот блокнот скачивает датасет с вашего сервера RoadVis Trainer, дообучает детектор (YOLO11s, imgsz 960,
rect, до 50 эпох с ранней остановкой) и отправляет `best.pt` обратно на сервер. Сервер сам сравнит новую модель с
текущей на замороженном тестовом наборе и опубликует её, только если она лучше.

1. *Среда выполнения → Сменить среду выполнения → GPU (T4)*.
2. Заполните поля ниже: адрес сервера и admin-токен (`ROADVIS_ADMIN_TOKEN`). Токен можно не вписывать, а сохранить в
   *Secrets* (значок ключа слева) под именем `ROADVIS_ADMIN_TOKEN`.
3. *Среда выполнения → Выполнить все*. Обучение занимает ~0.5–3 ч в зависимости от размера датасета.

**EN.** This notebook downloads the dataset from your RoadVis Trainer server, fine-tunes the detector (YOLO11s,
imgsz 960, rect, up to 50 epochs with early stopping) and uploads `best.pt` back. The server evaluates it against the
current model on the frozen test set and publishes it only if it is better.

1. *Runtime → Change runtime type → GPU (T4)*.
2. Fill in the server URL and the admin token (`ROADVIS_ADMIN_TOKEN`) below, or store the token in Colab *Secrets*
   (key icon on the left) as `ROADVIS_ADMIN_TOKEN`.
3. *Runtime → Run all*. Training takes about 0.5–3 h depending on the dataset size.

Never share a notebook with the token filled in. / Не делитесь блокнотом с вписанным токеном.
"""

PARAMS = """
#@title Settings / Настройки
SERVER_URL = "{server}"  #@param {{type:"string"}}
ADMIN_TOKEN = ""  #@param {{type:"string"}}
START_FROM = "auto"  #@param ["auto", "yolo11s.pt"]
EPOCHS = 50  #@param {{type:"integer"}}
PATIENCE = 10  #@param {{type:"integer"}}
IMGSZ = 960  #@param {{type:"integer"}}
UPLOAD_RESULT = True  #@param {{type:"boolean"}}
"""

SETUP = """
#@title Install / Установка
!nvidia-smi -L || echo "No GPU: Runtime → Change runtime type → GPU"
%pip install -q "ultralytics>=8.4,<9" requests pyyaml
"""

DOWNLOAD = """
#@title Download the dataset / Скачать датасет
import json, os, pathlib, shutil, zipfile
import requests, yaml

if not ADMIN_TOKEN:
    try:
        from google.colab import userdata
        ADMIN_TOKEN = userdata.get("ROADVIS_ADMIN_TOKEN") or ""
    except Exception:
        pass
assert ADMIN_TOKEN, "Set ADMIN_TOKEN (or the Colab secret ROADVIS_ADMIN_TOKEN)"
BASE = SERVER_URL.rstrip("/")
H = {"Authorization": f"Bearer {ADMIN_TOKEN}"}
WORK = pathlib.Path("/content/roadvis")
shutil.rmtree(WORK, ignore_errors=True)
WORK.mkdir(parents=True)

# The frozen test set stays on the server (it is used only by the quality gate).
with requests.get(f"{BASE}/api/v1/admin/dataset/export", params={"include_test": "false"}, headers=H,
                  stream=True, timeout=1800) as r:
    r.raise_for_status()
    with open(WORK / "dataset.zip", "wb") as f:
        for chunk in r.iter_content(1 << 20):
            f.write(chunk)
with zipfile.ZipFile(WORK / "dataset.zip") as z:
    z.extractall(WORK / "dataset")
(WORK / "dataset.zip").unlink()

cfg = yaml.safe_load(open(WORK / "dataset" / "data.yaml"))
cfg["path"] = str(WORK / "dataset")
cfg.pop("test", None)
DATA = WORK / "data.yaml"
yaml.safe_dump(cfg, open(DATA, "w"), sort_keys=False)
N_TRAIN = len(list((WORK / "dataset" / "images" / "train").glob("*.jpg")))
N_VAL = len(list((WORK / "dataset" / "images" / "val").glob("*.jpg")))
print(f"train images: {N_TRAIN}, val images: {N_VAL}, classes: {cfg['names']}")
assert N_TRAIN > 0, "The dataset is empty — let the phones collect frames first."
"""

BASE_WEIGHTS = """
#@title Starting weights / Начальные веса
INIT, INIT_NAME = "yolo11s.pt", "yolo11s.pt"
if START_FROM == "auto":
    r = requests.get(f"{BASE}/api/v1/admin/model/current", headers=H, timeout=600)
    if r.status_code == 200:
        (WORK / "current.pt").write_bytes(r.content)
        INIT = str(WORK / "current.pt")
        INIT_NAME = "roadvis-" + r.headers.get("X-RoadVis-Version", "current")
    elif r.status_code != 404:
        r.raise_for_status()
print("fine-tuning from", INIT_NAME)
"""

TRAIN = """
#@title Train / Обучение
import torch
from ultralytics import YOLO

model = YOLO(INIT)
results = model.train(data=str(DATA), imgsz=IMGSZ, rect=True, epochs=EPOCHS, patience=PATIENCE, batch=-1,
                      device=0 if torch.cuda.is_available() else "cpu", project=str(WORK / "runs"), name="roadvis",
                      exist_ok=True, plots=False)
RUN_DIR = pathlib.Path(model.trainer.save_dir)
BEST = RUN_DIR / "weights" / "best.pt"
print("best weights:", BEST, f"{BEST.stat().st_size / 1e6:.1f} MB")
"""

UPLOAD = """
#@title Upload the candidate / Отправить кандидата на сервер
import datetime, time
import ultralytics

val = {}
try:
    val = {k: float(v) for k, v in (results.results_dict or {}).items()}
except Exception:
    pass
metrics = {
    "baseModel": "yolo11s",
    "initWeights": INIT_NAME,
    "imgsz": IMGSZ, "epochs": EPOCHS, "patience": PATIENCE,
    "epochsRun": int(getattr(model.trainer, "epoch", -1)) + 1,
    "bestFitness": float(getattr(model.trainer, "best_fitness", 0) or 0),
    "trainImages": N_TRAIN, "valImages": N_VAL,
    "val": val,
    "ultralytics": ultralytics.__version__,
    "trainedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
print(json.dumps(metrics, indent=2))
if UPLOAD_RESULT:
    with open(BEST, "rb") as f:
        r = requests.post(f"{BASE}/api/v1/admin/candidates", headers=H, timeout=3600,
                          files={"weights": ("best.pt", f, "application/octet-stream"),
                                 "metrics": ("metrics.json", json.dumps(metrics), "application/json")})
    print(r.status_code, r.text)
    r.raise_for_status()
    CANDIDATE = r.json()["id"]
    print("Candidate", CANDIDATE, "queued. The server worker now runs the quality gate on CPU.")
"""

WAIT = """
#@title (optional) Wait for the gate result / Дождаться решения сервера
for _ in range(240):
    s = requests.get(f"{BASE}/api/v1/admin/candidates/{CANDIDATE}", headers=H, timeout=60).json()
    if s["status"] not in ("pending", "evaluating"):
        break
    time.sleep(60)
print(s["status"], s.get("message"))
decision = (s.get("report") or {}).get("decision")
if decision:
    for c in decision.get("checks", []):
        print(c)
"""


def notebook_json(server: str = DEFAULT_SERVER) -> dict:
    cells = [_md(INTRO), _code(PARAMS.format(server=server), form=True), _code(SETUP, form=True),
             _code(DOWNLOAD, form=True), _code(BASE_WEIGHTS, form=True), _code(TRAIN, form=True),
             _code(UPLOAD, form=True), _code(WAIT, form=True)]
    return {"nbformat": 4, "nbformat_minor": 0,
            "metadata": {"accelerator": "GPU", "colab": {"provenance": [], "gpuType": "T4"},
                         "kernelspec": {"display_name": "Python 3", "name": "python3"},
                         "language_info": {"name": "python"}},
            "cells": cells}


def write_notebook(out: Path, server: str = DEFAULT_SERVER) -> Path:
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(notebook_json(server), indent=1, ensure_ascii=False) + "\n", "utf-8")
    return out


def github_colab_url(notebook: Path) -> str | None:
    """One-click Colab link if the notebook is in a GitHub checkout (``origin`` on github.com)."""
    try:
        root = Path(subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=notebook.parent, check=True,
                                   capture_output=True, text=True).stdout.strip())
        remote = subprocess.run(["git", "remote", "get-url", "origin"], cwd=root, check=True, capture_output=True,
                                text=True).stdout.strip()
        branch = subprocess.run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=root, check=True,
                                capture_output=True, text=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None
    m = re.search(r"github\.com[:/]+([^/]+)/([^/]+?)(?:\.git)?$", remote)
    if not m:
        return None
    rel = notebook.resolve().relative_to(root).as_posix()
    return f"https://colab.research.google.com/github/{m.group(1)}/{m.group(2)}/blob/{branch}/{rel}"


COLAB_INSTRUCTIONS = """
Colab notebook: {path}
{link}
RU: откройте блокнот в Google Colab (ссылка выше или colab.research.google.com → «Загрузить» → этот файл),
    включите GPU, впишите адрес сервера и ROADVIS_ADMIN_TOKEN, «Выполнить все». Готовый best.pt сам отправится на
    сервер; воркер проверит его на замороженном тесте и опубликует, если он лучше текущей модели.
EN: open the notebook in Google Colab (link above, or colab.research.google.com → Upload → this file), select a GPU
    runtime, fill in the server URL and ROADVIS_ADMIN_TOKEN, Run all. best.pt is uploaded automatically; the worker
    gates it on the frozen test set and publishes it only if it beats the current model.
Status: curl -H "Authorization: Bearer $ROADVIS_ADMIN_TOKEN" {server}/api/v1/admin/status
"""


# Local CPU training ---------------------------------------------------------------------------------------------------
def local_data_yaml(settings: Settings, work: Path) -> Path:
    ds = settings.dataset_dir
    has_val = any((ds / "images" / "val").glob("*.jpg"))
    doc = {"path": str(ds.resolve()), "train": "images/train", "val": "images/val" if has_val else "images/train",
           "names": {i: n for i, n in enumerate(DATASET_NAMES)}}
    work.mkdir(parents=True, exist_ok=True)
    p = work / "data.yaml"
    p.write_text(yaml.safe_dump(doc, sort_keys=False))
    return p


def train_local(settings: Settings, *, epochs: int = 10, imgsz: int = 640, batch: int = 8, max_images: int = 3000,
                submit: bool = True, force: bool = False, init: str | None = None) -> Path:
    """Short CPU fine-tune on the server (small datasets only). Submits ``best.pt`` as a candidate (the worker then
    gates it) unless ``submit`` is False. Returns the path of ``best.pt``."""
    from .gate import current_weights
    from .worker import limit_cpu

    limit_cpu(settings.worker_threads)
    store = Store(settings.db_path)
    n_train = store.split_count("train")
    if n_train == 0:
        raise SystemExit("The train split is empty — nothing to train on yet.")
    if n_train > max_images and not force:
        raise SystemExit(f"{n_train} train images: too many for CPU training (> {max_images}). Use the Colab notebook "
                         "(roadvis-trainer train --colab) or pass --force.")
    from ultralytics import YOLO

    work = settings.tmp_dir / "local-train"
    shutil.rmtree(work, ignore_errors=True)
    data = local_data_yaml(settings, work)
    init_path, init_version = (init, None) if init else current_weights(store, settings)
    model = YOLO(init_path)
    model.train(data=str(data), epochs=epochs, imgsz=imgsz, batch=batch, rect=True, patience=max(3, epochs // 3),
                device="cpu", workers=0, project=str(work / "runs"), name="local", exist_ok=True, plots=False,
                amp=False)
    best = Path(model.trainer.save_dir) / "weights" / "best.pt"
    if not submit:
        out = settings.tmp_dir / "local-best.pt"
        shutil.copy2(best, out)
        return out
    cand_id = uuid.uuid4().hex
    cdir = settings.candidates_dir / cand_id
    cdir.mkdir(parents=True)
    dest = cdir / "best.pt"
    shutil.copy2(best, dest)
    metrics = {"baseModel": "yolo11s", "initWeights": f"roadvis-{init_version}" if init_version else Path(init_path).name,
               "imgsz": imgsz, "epochs": epochs, "trainImages": n_train, "local": True, "trainedAt": iso()}
    store.insert_candidate(cand_id, str(dest), metrics)
    shutil.rmtree(work, ignore_errors=True)
    log.info("local candidate %s submitted; the worker will gate it", cand_id)
    return dest
