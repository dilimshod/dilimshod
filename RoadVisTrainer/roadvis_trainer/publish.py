"""Publishing accepted weights (contract section 4.5) and the manifest served by ``GET /api/v1/model/latest``.

Each version lives in ``data/models/<version>/``::

    weights.pt                                  accepted PyTorch weights (admin download, next fine-tune base)
    RoadVisDetector.mlpackage/...               Core ML, landscape input 960x544 (WxH), NMS pipeline
    RoadVisDetectorPortrait.mlpackage/...       Core ML, portrait input 544x960, NMS pipeline
    yolo-roadvis.onnx                           ONNX with dynamic axes (Android)
    manifest.json

Served file paths (``GET /api/v1/model/{version}/files/{path}``) are relative to that folder, e.g.
``RoadVisDetector.mlpackage/Manifest.json`` or ``yolo-roadvis.onnx``. Inside the manifest, iOS file paths are
relative to the package (``Manifest.json``, ``Data/com.apple.CoreML/model.mlmodel``...) exactly as the contract
shows, so a client downloads ``files/<name>.mlpackage/<path>`` and writes it to ``<name>.mlpackage/<path>``.
"""

from __future__ import annotations

import hashlib
import json
import logging
import shutil
from pathlib import Path

from .config import Settings
from .storage import Store, iso, utcnow

log = logging.getLogger(__name__)

IOS_VARIANTS = (("landscape", "RoadVisDetector", (544, 960)), ("portrait", "RoadVisDetectorPortrait", (960, 544)))
ONNX_NAME = "yolo-roadvis.onnx"
ANDROID_INPUTS = [[544, 960], [960, 544], [384, 640], [640, 384]]


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def file_entry(path: Path, rel: str) -> dict:
    return {"path": rel, "sha256": sha256_file(path), "size": path.stat().st_size}


def package_files(package: Path) -> list[dict]:
    """All files of an ``.mlpackage`` directory with paths relative to the package, sorted."""
    return [file_entry(p, p.relative_to(package).as_posix())
            for p in sorted(package.rglob("*")) if p.is_file()]


def build_manifest(*, version: str, created_at: str, base_model: str, metrics: dict, version_dir: Path,
                   ios_ok: bool, android_ok: bool) -> dict:
    """The manifest exactly as in contract section 3. A platform whose export failed is ``null``."""
    ios = None
    if ios_ok:
        ios = {}
        for orientation, name, _ in IOS_VARIANTS:
            ios[orientation] = {"name": name, "files": package_files(version_dir / f"{name}.mlpackage")}
    android = None
    if android_ok:
        android = {"file": file_entry(version_dir / ONNX_NAME, ONNX_NAME), "inputs": ANDROID_INPUTS}
    return {"version": version, "createdAt": created_at, "baseModel": base_model, "metrics": metrics,
            "ios": ios, "android": android}


def served_paths(manifest: dict) -> set[str]:
    """Every path (relative to the version folder) that the file endpoint may serve for this manifest."""
    paths: set[str] = set()
    ios = manifest.get("ios") or {}
    for variant in ios.values():
        for f in variant.get("files", []):
            paths.add(f"{variant['name']}.mlpackage/{f['path']}")
    android = manifest.get("android")
    if android:
        paths.add(android["file"]["path"])
    return paths


def next_version(store: Store) -> str:
    day = utcnow().strftime("%Y-%m-%d")
    used = set(store.version_names_for_day(day))
    n = 1
    while f"{day}-{n}" in used:
        n += 1
    return f"{day}-{n}"


def _yolo(weights: Path):
    from ultralytics import YOLO

    return YOLO(str(weights))


def export_coreml(weights: Path, work: Path, out_dir: Path) -> None:
    """Exports the two Core ML packages (NMS pipeline, FP16). Raises on failure."""
    from ultralytics.cfg import DEFAULT_CFG_DICT

    for _, name, (h, w) in IOS_VARIANTS:
        sub = work / name
        sub.mkdir(parents=True, exist_ok=True)
        local = sub / "weights.pt"
        shutil.copy2(weights, local)
        kwargs = dict(format="coreml", imgsz=(h, w), nms=True, device="cpu")
        if "quantize" in DEFAULT_CFG_DICT:
            kwargs["quantize"] = 16
        else:
            kwargs["half"] = True
        produced = Path(_yolo(local).export(**kwargs))
        if not produced.exists():
            raise RuntimeError(f"Core ML exporter did not produce {produced}")
        make_threshold_inputs_optional(produced)
        dest = out_dir / f"{name}.mlpackage"
        if dest.exists():
            shutil.rmtree(dest)
        shutil.move(str(produced), str(dest))


def make_threshold_inputs_optional(package: Path) -> None:
    """Marks ``iouThreshold`` / ``confidenceThreshold`` optional (like Create ML detectors), same as
    ``RoadVis/tools/export_yolo_coreml.py``, so Vision can run the pipeline without feeding them."""
    import coremltools as ct

    model = ct.models.MLModel(str(package), skip_model_load=True)
    spec = model.get_spec()
    if spec.WhichOneof("Type") != "pipeline":
        return
    changed = False
    for feature in spec.description.input:
        if feature.name in ("iouThreshold", "confidenceThreshold") and not feature.type.isOptional:
            feature.type.isOptional = True
            changed = True
    if not changed:
        return
    tmp = package.with_name(package.stem + "_optional.mlpackage")
    if tmp.exists():
        shutil.rmtree(tmp)
    ct.models.MLModel(spec, weights_dir=model.weights_dir, skip_model_load=True).save(str(tmp))
    shutil.rmtree(package)
    shutil.move(str(tmp), str(package))


def export_onnx(weights: Path, work: Path, out_dir: Path) -> None:
    """Exports ONNX with dynamic axes (batch, height, width). Raises on failure."""
    import importlib.util

    sub = work / "onnx"
    sub.mkdir(parents=True, exist_ok=True)
    local = sub / "weights.pt"
    shutil.copy2(weights, local)
    # Graph simplification needs onnxslim + onnxruntime; use it only if they are installed (no auto-install).
    simplify = all(importlib.util.find_spec(m) for m in ("onnxslim", "onnxruntime"))
    produced = Path(_yolo(local).export(format="onnx", dynamic=True, imgsz=(544, 960), simplify=simplify,
                                        device="cpu"))
    if not produced.exists():
        raise RuntimeError(f"ONNX exporter did not produce {produced}")
    shutil.move(str(produced), str(out_dir / ONNX_NAME))


def publish_weights(store: Store, settings: Settings, weights: Path, *, metrics: dict, base_model: str,
                    candidate_id: str | None = None, coreml_exporter=None, onnx_exporter=None) -> str:
    """Exports ``weights``, writes the manifest, records the version and prunes old versions. Returns the version.

    If the Core ML export fails, the version is published for Android only (``"ios": null``) and the failure is
    logged; likewise ``"android": null`` if only ONNX fails. If both fail, nothing is published."""
    coreml_exporter = coreml_exporter or export_coreml
    onnx_exporter = onnx_exporter or export_onnx
    version = next_version(store)
    vdir = settings.models_dir / version
    work = settings.tmp_dir / f"publish-{version}"
    shutil.rmtree(vdir, ignore_errors=True)
    shutil.rmtree(work, ignore_errors=True)
    vdir.mkdir(parents=True)
    work.mkdir(parents=True)
    try:
        shutil.copy2(weights, vdir / "weights.pt")
        ios_ok = android_ok = True
        try:
            coreml_exporter(vdir / "weights.pt", work, vdir)
        except Exception:  # noqa: BLE001
            ios_ok = False
            log.exception("Core ML export failed for %s: publishing without iOS models", version)
            for _, name, _ in IOS_VARIANTS:
                shutil.rmtree(vdir / f"{name}.mlpackage", ignore_errors=True)
        try:
            onnx_exporter(vdir / "weights.pt", work, vdir)
        except Exception:  # noqa: BLE001
            android_ok = False
            log.exception("ONNX export failed for %s: publishing without the Android model", version)
            (vdir / ONNX_NAME).unlink(missing_ok=True)
        if not (ios_ok or android_ok):
            raise RuntimeError("both Core ML and ONNX exports failed")
        manifest = build_manifest(version=version, created_at=iso(), base_model=base_model, metrics=metrics,
                                  version_dir=vdir, ios_ok=ios_ok, android_ok=android_ok)
        (vdir / "manifest.json").write_text(json.dumps(manifest, indent=2))
        store.insert_version(version, manifest, candidate_id)
    except Exception:
        shutil.rmtree(vdir, ignore_errors=True)
        raise
    finally:
        shutil.rmtree(work, ignore_errors=True)
    prune_versions(store, settings)
    log.info("published %s (ios=%s, android=%s)", version, ios_ok, android_ok)
    return version


def prune_versions(store: Store, settings: Settings) -> list[str]:
    """Keeps the newest ``keep_versions`` (3) published versions, deletes older folders."""
    removed = []
    for v in store.published_versions()[settings.keep_versions:]:
        shutil.rmtree(settings.models_dir / v["version"], ignore_errors=True)
        store.mark_version_deleted(v["version"])
        removed.append(v["version"])
    return removed


def manifest_metrics(report: dict) -> dict:
    m = report["metrics"]
    cand, cur = m["candidate"], m["current"]
    return {"testImages": int(report.get("testImages", cand.get("test_images", 0))),
            "map50": round(float(cand["map50"]), 4), "precision": round(float(cand["precision"]), 4),
            "recall": round(float(cand["recall"]), 4), "previous": {"map50": round(float(cur["map50"]), 4)}}


def base_model_name(report: dict) -> str:
    training = report.get("training") or {}
    base = str(training.get("baseModel") or training.get("base_model") or "yolo11s")
    name = Path(base).name
    return name[:-3] if name.endswith(".pt") else name


def publish_candidate(store: Store, settings: Settings, cand_id: str, weights: Path, report: dict) -> str:
    """Gate callback: publishes an accepted candidate."""
    return publish_weights(store, settings, weights, metrics=manifest_metrics(report),
                           base_model=base_model_name(report), candidate_id=cand_id)


def find_latest(store: Store, platform: str | None) -> dict | None:
    """Manifest of the newest published version that has a model for ``platform`` (any platform if None)."""
    for v in store.published_versions():
        m = v["manifest"]
        if platform is None or m.get(platform):
            return m
    return None
