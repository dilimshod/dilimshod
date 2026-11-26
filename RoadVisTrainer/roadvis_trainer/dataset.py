"""YOLO dataset on disk: split, frozen test set, retention, export zip (contract sections 4.2 and 4.6).

Layout under ``data/dataset``: ``images/{train,val,test}/<id>.jpg`` and ``labels/{train,val,test}/<id>.txt``.
"""

from __future__ import annotations

import hashlib
import logging
import os
import shutil
import zipfile
from pathlib import Path

import yaml

from .config import Settings
from .labeling import DATASET_NAMES
from .storage import Store

log = logging.getLogger(__name__)

SPLITS = ("train", "val", "test")
TEST_FROZEN_KEY = "test_frozen"


def split_bucket(sample_id: str) -> int:
    """``sha1(id) % 10``: the SHA-1 of the UTF-8 id read as a big-endian integer, modulo 10."""
    return int(hashlib.sha1(sample_id.encode("utf-8")).hexdigest(), 16) % 10


def choose_split(sample_id: str, test_frozen: bool) -> str:
    """0 → test, 1 → val, else train. Once the test set is frozen, bucket-0 frames are re-split by the next decimal
    digit of the hash (``sha1 // 10 % 10``: 1 → val, else train), so they never enter test."""
    value = int(hashlib.sha1(sample_id.encode("utf-8")).hexdigest(), 16)
    bucket = value % 10
    if bucket == 0:
        if not test_frozen:
            return "test"
        bucket = (value // 10) % 10
        return "val" if bucket == 1 else "train"
    return "val" if bucket == 1 else "train"


def is_test_frozen(store: Store, settings: Settings) -> bool:
    """The test set freezes permanently once it holds ``test_freeze_at`` (300) images."""
    if store.get_state(TEST_FROZEN_KEY) == "1":
        return True
    if store.split_count("test") >= settings.test_freeze_at:
        store.set_state(TEST_FROZEN_KEY, "1")
        return True
    return False


def image_path(settings: Settings, split: str, sample_id: str) -> Path:
    return settings.dataset_dir / "images" / split / f"{sample_id}.jpg"


def label_path(settings: Settings, split: str, sample_id: str) -> Path:
    return settings.dataset_dir / "labels" / split / f"{sample_id}.txt"


def write_sample(settings: Settings, split: str, sample_id: str, jpeg: bytes, yolo_labels: str) -> None:
    img, lbl = image_path(settings, split, sample_id), label_path(settings, split, sample_id)
    img.parent.mkdir(parents=True, exist_ok=True)
    lbl.parent.mkdir(parents=True, exist_ok=True)
    _atomic_write(lbl, yolo_labels.encode("utf-8"))
    _atomic_write(img, jpeg)


def _atomic_write(path: Path, data: bytes) -> None:
    tmp = path.with_name(path.name + ".part")
    tmp.write_bytes(data)
    os.replace(tmp, path)


def delete_sample_files(settings: Settings, split: str, sample_id: str) -> None:
    for p in (image_path(settings, split, sample_id), label_path(settings, split, sample_id)):
        p.unlink(missing_ok=True)


def apply_retention(store: Store, settings: Settings) -> int:
    """Keeps the dataset at most ``dataset_cap`` images: deletes the oldest train images first, then val, never test.
    Returns the number of evicted images."""
    excess = store.kept_count() - settings.dataset_cap
    evicted = 0
    for split in ("train", "val"):
        if excess <= 0:
            break
        for row in store.oldest_kept(split, excess):
            delete_sample_files(settings, split, row["id"])
            store.mark_evicted(row["id"])
            evicted += 1
            excess -= 1
    if evicted:
        log.info("Retention: evicted %d images (cap %d)", evicted, settings.dataset_cap)
    return evicted


def _count_images(d: Path) -> int:
    return sum(1 for p in d.glob("*.jpg")) if d.is_dir() else 0


def data_yaml(train: str, val: str, test: str | None) -> str:
    doc = {"path": ".", "train": train, "val": val}
    if test:
        doc["test"] = test
    doc["nc"] = len(DATASET_NAMES)
    doc["names"] = {i: n for i, n in enumerate(DATASET_NAMES)}
    header = ("# RoadVis dataset (YOLO format). Class names decode to the apps' kinds by name.\n"
              "# Frozen test set: test/images + test/labels (never used for training).\n")
    return header + yaml.safe_dump(doc, sort_keys=False, allow_unicode=True)


def build_export_zip(settings: Settings, out_path: Path, include_test: bool = True) -> dict:
    """Writes the dataset as a zip: ``data.yaml``, ``images|labels/{train,val}``, frozen test set in ``test/``.

    JPEGs are already compressed, so entries are stored (no deflate) to keep the server CPU free.
    If val is still empty, ``data.yaml`` validates on train (noted in the file)."""
    ds = settings.dataset_dir
    counts = {s: _count_images(ds / "images" / s) for s in SPLITS}
    val_rel = "images/val" if counts["val"] else "images/train"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(out_path, "w", compression=zipfile.ZIP_STORED, allowZip64=True) as zf:
        text = data_yaml("images/train", val_rel, "test/images" if include_test else None)
        if not counts["val"]:
            text += "# val split is empty: validating on train for now\n"
        zf.writestr("data.yaml", text)
        for split in SPLITS:
            if split == "test" and not include_test:
                continue
            prefix = "test/" if split == "test" else ""
            for kind in ("images", "labels"):
                d = ds / kind / split
                arc_dir = f"{prefix}{kind}" if split == "test" else f"{kind}/{split}"
                zf.writestr(arc_dir + "/", "")
                if not d.is_dir():
                    continue
                for f in sorted(d.iterdir()):
                    if f.is_file() and not f.name.endswith(".part"):
                        zf.write(f, f"{arc_dir}/{f.name}")
    return counts


def build_eval_view(settings: Settings, model_names: dict[int, str], work_dir: Path) -> tuple[Path, dict[int, str], list[int]]:
    """Prepares the frozen test set for evaluating a model whose class ids may differ from the dataset's.

    Returns ``(data_yaml_path, model_id_to_dataset_name, model_class_ids)``. Labels are rewritten with the model's
    class ids (matched by normalized name, e.g. COCO "traffic light" ↔ "traffic_light"); images are symlinked.
    """
    from .labeling import normalize_label

    by_name = {normalize_label(n): int(i) for i, n in model_names.items()}
    ds_to_model: dict[int, int] = {}
    for ds_id, name in enumerate(DATASET_NAMES):
        mid = by_name.get(normalize_label(name))
        if mid is not None:
            ds_to_model[ds_id] = mid
    missing = [DATASET_NAMES[i] for i in range(len(DATASET_NAMES)) if i not in ds_to_model]
    if missing:
        log.warning("Model lacks classes %s; their labels are dropped for this evaluation", missing)

    if work_dir.exists():
        shutil.rmtree(work_dir)
    img_out, lbl_out = work_dir / "images" / "test", work_dir / "labels" / "test"
    img_out.mkdir(parents=True)
    lbl_out.mkdir(parents=True)
    src_img, src_lbl = settings.dataset_dir / "images" / "test", settings.dataset_dir / "labels" / "test"
    for img in sorted(src_img.glob("*.jpg")):
        (img_out / img.name).symlink_to(img.resolve())
        lines = []
        lbl = src_lbl / (img.stem + ".txt")
        if lbl.exists():
            for line in lbl.read_text().splitlines():
                parts = line.split()
                if len(parts) == 5 and int(parts[0]) in ds_to_model:
                    lines.append(" ".join([str(ds_to_model[int(parts[0])])] + parts[1:]))
        (lbl_out / (img.stem + ".txt")).write_text("\n".join(lines) + ("\n" if lines else ""))
    names_list = {int(i): str(n) for i, n in model_names.items()}
    doc = {"path": str(work_dir.resolve()), "train": "images/test", "val": "images/test", "names": names_list}
    yaml_path = work_dir / "data.yaml"
    yaml_path.write_text(yaml.safe_dump(doc, sort_keys=False))
    model_to_name = {mid: DATASET_NAMES[ds] for ds, mid in ds_to_model.items()}
    return yaml_path, model_to_name, sorted(model_to_name)
