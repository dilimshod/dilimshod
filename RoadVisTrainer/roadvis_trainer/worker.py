"""Background worker: turns queued samples into dataset frames (or deletes them) and gates candidate models.

Run with ``roadvis-trainer worker`` (loop) or ``roadvis-trainer worker --once``. CPU use is bounded by
``ROADVIS_WORKER_THREADS`` (torch/OpenMP threads, default 2), small batches and a lowered process priority, so the
website on the same server is not starved.
"""

from __future__ import annotations

import io
import json
import logging
import os
import time
from pathlib import Path

from PIL import Image, ImageOps

from . import dataset, quality
from .config import Settings
from .labeling import Teacher, decide_labels
from .storage import Store, iso

log = logging.getLogger(__name__)


def limit_cpu(threads: int) -> None:
    """Caps math-library threads; call before torch is imported for full effect."""
    for var in ("OMP_NUM_THREADS", "MKL_NUM_THREADS", "OPENBLAS_NUM_THREADS", "NUMEXPR_NUM_THREADS"):
        os.environ[var] = str(threads)
    os.environ.setdefault("YOLO_AUTOINSTALL", "false")
    try:
        os.nice(10)
    except (AttributeError, OSError):
        pass
    try:
        import torch

        torch.set_num_threads(threads)
        torch.set_num_interop_threads(1)
    except Exception:  # noqa: BLE001 - torch missing or interop threads already set
        pass


def incoming_paths(settings: Settings, sample_id: str) -> tuple[Path, Path]:
    return settings.incoming_dir / f"{sample_id}.jpg", settings.incoming_dir / f"{sample_id}.json"


def _delete_incoming(settings: Settings, sample_id: str) -> None:
    for p in incoming_paths(settings, sample_id):
        p.unlink(missing_ok=True)


def _upright_jpeg(data: bytes) -> tuple[Image.Image, bytes]:
    """Decodes the JPEG; if it carries an EXIF rotation, bakes it in so labels match the stored pixels."""
    img = Image.open(io.BytesIO(data))
    img.load()
    upright = ImageOps.exif_transpose(img)
    if upright is not img:
        buf = io.BytesIO()
        upright.convert("RGB").save(buf, "JPEG", quality=90)
        data = buf.getvalue()
    return upright.convert("RGB"), data


def process_sample(store: Store, settings: Settings, teacher: Teacher, row: dict) -> str:
    """Processes one queued sample. Returns its final status: ``kept``, ``rejected`` or ``queued`` (retry later)."""
    sid = row["id"]
    img_path, meta_path = incoming_paths(settings, sid)

    def reject(reason: str, **extra) -> str:
        _delete_incoming(settings, sid)
        store.mark_rejected(sid, reason, **extra)
        log.info("sample %s rejected: %s", sid, reason)
        return "rejected"

    try:
        data = img_path.read_bytes()
        meta = json.loads(meta_path.read_text("utf-8"))
    except (OSError, ValueError):
        return reject("missingFiles")
    try:
        image, data = _upright_jpeg(data)
    except Exception:  # noqa: BLE001 - any decoder error
        return reject("badImage")

    q = quality.measure(image)
    extra = {"dhash": q.dhash, "sharpness": q.sharpness, "brightness": q.brightness}
    bad = q.rejection_reason()
    if bad:
        return reject(bad, **extra)
    if quality.is_near_duplicate(q.dhash, store.kept_hashes()):
        return reject("duplicate", **extra)

    try:
        boxes = teacher.predict(image)
    except Exception:  # noqa: BLE001 - keep the sample for a retry, give up after a few attempts
        attempts = store.bump_attempts(sid)
        log.exception("teacher failed on %s (attempt %d)", sid, attempts)
        if attempts >= settings.worker_max_attempts:
            return reject("teacherError", **extra)
        return "queued"

    result = decide_labels(boxes, meta.get("tracks") or [], label_conf=settings.label_conf,
                           ambiguous_conf=settings.ambiguous_conf, min_hits=settings.consistency_min_hits,
                           min_iou=settings.consistency_iou)
    if not result.accepted:
        return reject(result.reason or "ambiguous", **extra)

    split = dataset.choose_split(sid, dataset.is_test_frozen(store, settings))
    dataset.write_sample(settings, split, sid, data, result.yolo_lines())
    store.mark_kept(sid, split, q.dhash, q.sharpness, q.brightness, len(result.labels))
    _delete_incoming(settings, sid)
    log.info("sample %s kept in %s with %d labels", sid, split, len(result.labels))
    return "kept"


def cleanup_stale(store: Store, settings: Settings, max_age_seconds: int = 3600) -> int:
    """Rejects uploads that never finished (server stopped mid-write) and removes leftover temp files."""
    from datetime import timedelta

    from .storage import utcnow

    cutoff = utcnow() - timedelta(seconds=max_age_seconds)
    n = 0
    for sid in store.stale_receiving(iso(cutoff)):
        _delete_incoming(settings, sid)
        store.mark_rejected(sid, "incompleteUpload")
        n += 1
    for part in settings.incoming_dir.glob("*.part-*"):
        try:
            if part.stat().st_mtime < cutoff.timestamp():
                part.unlink(missing_ok=True)
        except OSError:
            pass
    return n


def process_batch(store: Store, settings: Settings, teacher: Teacher, limit: int | None = None) -> dict:
    """Processes up to ``limit`` queued samples, then applies retention. Returns counts per outcome."""
    counts = {"kept": 0, "rejected": 0, "queued": 0}
    for row in store.queued_samples(limit or settings.worker_batch):
        counts[process_sample(store, settings, teacher, row)] += 1
    if counts["kept"]:
        counts["evicted"] = dataset.apply_retention(store, settings)
    return counts


def process_candidates(store: Store, settings: Settings) -> int:
    """Gates (and publishes, if accepted) every pending candidate. Returns how many were handled."""
    from .gate import run_gate

    handled = 0
    for cand in store.pending_candidates():
        run_gate(store, settings, cand["id"])
        handled += 1
    return handled


def run(settings: Settings, once: bool = False, teacher: Teacher | None = None) -> None:
    """Worker loop. ``once`` drains the queue (and pending candidates) once and returns."""
    limit_cpu(settings.worker_threads)
    settings.ensure_dirs()
    store = Store(settings.db_path)
    if teacher is None and store.queued_samples(1):
        teacher = _load_teacher(settings)
    cleanup_stale(store, settings)
    while True:
        store.set_state("worker_heartbeat", iso())
        busy = False
        if store.queued_samples(1):
            if teacher is None:
                teacher = _load_teacher(settings)
            counts = process_batch(store, settings, teacher)
            busy = any(counts.get(k) for k in ("kept", "rejected"))
            if busy:
                log.info("batch: %s", counts)
        if process_candidates(store, settings):
            busy = True
        if once:
            if busy and store.queued_samples(1):
                continue
            store.set_state("worker_last_run", iso())
            return
        store.set_state("worker_last_run", iso())
        if not busy:
            time.sleep(settings.worker_poll_seconds)


def _load_teacher(settings: Settings) -> Teacher:
    from .labeling import UltralyticsTeacher

    log.info("loading teacher %s (imgsz %d, %d threads)", settings.teacher_model, settings.teacher_imgsz,
             settings.worker_threads)
    return UltralyticsTeacher(settings.teacher_model, settings.teacher_imgsz)
