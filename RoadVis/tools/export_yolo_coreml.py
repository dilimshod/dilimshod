#!/usr/bin/env python3
"""Export an Ultralytics YOLO detector to Core ML for the RoadVis iOS app.

The app bundles four detector packages (``VehicleDetector.swift`` picks one per frame orientation and load tier):

* ``RoadVisDetector``             — YOLO11s, 544x960 (HxW), landscape camera frames 1920x1080
* ``RoadVisDetectorPortrait``     — YOLO11s, 960x544, portrait camera frames 1080x1920
* ``RoadVisDetectorLite``         — YOLO11n, 544x960, used while inference is too slow / the phone is hot
* ``RoadVisDetectorLitePortrait`` — YOLO11n, 960x544

``--bundle`` exports all four in one go. The input is rectangular 16:9 on purpose: the camera frame fills the whole
model input (Vision ``.scaleFill``, 0.7 % stretch), nothing is spent on letterbox padding. Legacy single square
models (``yolo26n``, ``yolo11n``, ``yolov8n`` or a square ``RoadVisDetector``) still load as a fallback.

Xcode compiles every ``*.mlpackage`` placed in ``RoadVis/RoadVis/Models/`` (a synchronized folder) into
``<name>.mlmodelc`` automatically, so exporting to the default ``--out`` path is all that is needed.

Two output layouts are supported by the app:

* ``--nms`` (default): a Core ML *pipeline* (detector + Apple NonMaximumSuppression). Vision returns
  ``VNRecognizedObjectObservation`` objects with labels and normalized boxes — fastest path on iOS.
* ``--no-nms``: the raw tensor. YOLO11/YOLOv8 output ``[1, 84, 8400]`` (decoded and NMS-ed in the app by
  ``YOLODecoder``); YOLO26 is end-to-end and outputs ``[1, 300, 6]`` boxes without NMS.

Examples (macOS or Linux, Python 3.10–3.13)::

    python3 -m venv .venv && source .venv/bin/activate
    pip install -r tools/requirements.txt
    python tools/export_yolo_coreml.py --bundle --force          # the four packages shipped in the repo
    python tools/export_yolo_coreml.py --weights yolo11s.pt --imgsz 544 960 --force      # one package (H W)
    python tools/export_yolo_coreml.py --weights yolo26s.pt --imgsz 544 960 --force      # newest Ultralytics model
    python tools/export_yolo_coreml.py --imgsz 640               # legacy square yolo11n (letterboxed by the app)
    python tools/export_yolo_coreml.py --bundle --quantize 8     # ~2x smaller, slightly less accurate
    python tools/export_yolo_coreml.py --check photo.jpg --out RoadVis/Models/RoadVisDetector.mlpackage
        # no export: runs the detector stage of an existing package on a photo (macOS only — Core ML
        # prediction does not exist on Linux; there only the spec printed after the export can be checked)

Licence: Ultralytics code and pretrained weights are AGPL-3.0 (or an Ultralytics Enterprise licence).
Distributing an app that embeds these weights has licence implications — read Models/README.md.
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

REPO_APP_DIR = Path(__file__).resolve().parent.parent  # .../RoadVis
MODELS_DIR = REPO_APP_DIR / "RoadVis" / "Models"
DEFAULT_OUT = MODELS_DIR / "RoadVisDetector.mlpackage"

# (package name, weights, (height, width)) of the detectors shipped with the app, see VehicleDetector.swift.
BUNDLE = [
    ("RoadVisDetector", "yolo11s.pt", (544, 960)),
    ("RoadVisDetectorPortrait", "yolo11s.pt", (960, 544)),
    ("RoadVisDetectorLite", "yolo11n.pt", (544, 960)),
    ("RoadVisDetectorLitePortrait", "yolo11n.pt", (960, 544)),
]


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """Builds the command-line interface."""
    p = argparse.ArgumentParser(
        description="Export a YOLO detector (COCO classes) to a Core ML .mlpackage for RoadVis.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument("--weights", default="yolo11n.pt",
                   help="Ultralytics weights: yolo11n.pt, yolo26n.pt, yolo11s.pt, or a path to your own best.pt "
                        "(official weights are downloaded automatically)")
    p.add_argument("--imgsz", type=int, nargs="+", default=[544, 960], metavar="PX",
                   help="input size: one value = square, two values = HEIGHT WIDTH (multiples of 32). "
                        "544 960 for landscape 16:9 frames, 960 544 for portrait")
    p.add_argument("--bundle", action="store_true",
                   help="export the four packages the app ships (s + n, landscape + portrait) into Models/; "
                        "--weights, --imgsz and --out are ignored")
    p.add_argument("--check", type=Path, metavar="IMAGE",
                   help="do not export: run the detector stage of the existing --out package on IMAGE and print "
                        "the boxes (sanity check; macOS only, Core ML cannot predict on Linux)")
    nms = p.add_mutually_exclusive_group()
    nms.add_argument("--nms", dest="nms", action="store_true", default=True,
                     help="embed Apple NMS so Vision returns VNRecognizedObjectObservation")
    nms.add_argument("--no-nms", dest="nms", action="store_false",
                     help="export the raw output tensor (decoded by YOLODecoder in the app)")
    p.add_argument("--quantize", type=int, choices=(16, 8), default=16,
                   help="weight precision: 16 = FP16 (recommended), 8 = 8-bit palettized weights")
    p.add_argument("--conf", type=float, default=0.25,
                   help="default confidence threshold stored in the NMS stage (the app overrides it)")
    p.add_argument("--iou", type=float, default=0.45, help="default IoU threshold stored in the NMS stage")
    p.add_argument("--out", type=Path, default=DEFAULT_OUT, help="destination .mlpackage path")
    p.add_argument("--force", action="store_true", help="overwrite --out if it already exists")
    args = p.parse_args(argv)
    if len(args.imgsz) not in (1, 2) or any(v <= 0 or v % 32 for v in args.imgsz):
        p.error("--imgsz takes one or two positive multiples of 32 (HEIGHT WIDTH)")
    return args


def image_size(imgsz: list[int]) -> tuple[int, int]:
    """(height, width) from the --imgsz values."""
    return (imgsz[0], imgsz[0]) if len(imgsz) == 1 else (imgsz[0], imgsz[1])


def export(args: argparse.Namespace) -> Path:
    """Runs the Ultralytics Core ML exporter and moves the result to ``args.out``."""
    try:
        from ultralytics import YOLO
        from ultralytics.cfg import DEFAULT_CFG_DICT
    except ImportError:
        sys.exit("ultralytics is not installed: pip install -r tools/requirements.txt")

    out: Path = args.out
    if out.suffix != ".mlpackage":
        sys.exit(f"--out must end with .mlpackage (got {out})")
    if out.exists() and not args.force:
        sys.exit(f"{out} already exists — pass --force to overwrite it")

    model = YOLO(args.weights)
    if model.task != "detect":
        sys.exit(f"{args.weights} is a '{model.task}' model; a detection model is required")

    # Ultralytics takes imgsz=(height, width); the Core ML image input then is width x height.
    export_kwargs = dict(format="coreml", imgsz=image_size(args.imgsz), nms=args.nms, conf=args.conf, iou=args.iou)
    # Ultralytics ≥ 8.4 uses a unified `quantize` argument; older releases used half/int8.
    if "quantize" in DEFAULT_CFG_DICT:
        export_kwargs["quantize"] = args.quantize
    elif args.quantize == 8:
        export_kwargs["int8"] = True
    else:
        export_kwargs["half"] = True

    print(f"Exporting {args.weights} → Core ML with {export_kwargs} …", flush=True)
    produced = Path(model.export(**export_kwargs))
    if not produced.exists():
        sys.exit(f"Exporter reported {produced}, but it does not exist")

    if args.nms:
        make_threshold_inputs_optional(produced)

    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        shutil.rmtree(out)
    shutil.move(str(produced), str(out))
    return out


def make_threshold_inputs_optional(package: Path) -> None:
    """Marks the pipeline inputs ``iouThreshold`` / ``confidenceThreshold`` as optional.

    Ultralytics declares them as required inputs. Create ML object detectors declare the same inputs as optional,
    so Core ML falls back to the thresholds stored in the NonMaximumSuppression stage when the caller (Vision)
    does not provide them. The app may still override them through ``VNCoreMLModel.featureProvider``.
    """
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
    print("Marked iouThreshold / confidenceThreshold as optional inputs (defaults come from the NMS stage).")


def directory_size(path: Path) -> int:
    """Total size of all files below ``path`` in bytes."""
    return sum(f.stat().st_size for f in path.rglob("*") if f.is_file())


def describe(path: Path) -> None:
    """Prints the inputs/outputs of the exported model (works on Linux; prediction needs macOS)."""
    import coremltools as ct

    mlmodel = ct.models.MLModel(str(path), skip_model_load=True)
    spec = mlmodel.get_spec()
    kind = spec.WhichOneof("Type")
    print(f"\nSaved {path}  ({directory_size(path) / 1e6:.1f} MB)")
    print(f"Spec version {spec.specificationVersion}, top-level type: {kind}")
    if kind == "pipeline":
        stages = [m.WhichOneof("Type") for m in spec.pipeline.models]
        print(f"Pipeline stages: {stages}")

    print("Inputs:")
    for feature in spec.description.input:
        t = feature.type
        which = t.WhichOneof("Type")
        if which == "imageType":
            detail = f"image {t.imageType.width}x{t.imageType.height}"
        elif which == "multiArrayType":
            detail = f"multiArray shape={list(t.multiArrayType.shape)}"
        else:
            detail = which
        optional = " (optional)" if t.isOptional else ""
        print(f"  - {feature.name}: {detail}{optional}  {feature.shortDescription}")

    print("Outputs:")
    for feature in spec.description.output:
        t = feature.type
        which = t.WhichOneof("Type")
        if which == "multiArrayType":
            ranges = [(r.lowerBound, r.upperBound) for r in t.multiArrayType.shapeRange.sizeRanges]
            detail = f"multiArray shape={list(t.multiArrayType.shape)} ranges={ranges}"
        else:
            detail = which
        print(f"  - {feature.name}: {detail}  {feature.shortDescription}")

    meta = dict(spec.description.metadata.userDefined)
    names = meta.get("names", "")
    print(f"Metadata keys: {sorted(meta)}")
    if names:
        print(f"Class names: {names[:160]}{'…' if len(names) > 160 else ''}")


def check(package: Path, image_path: Path, conf: float, iou: float) -> int:
    """Runs the ML Program stage of ``package`` on ``image_path`` and prints the detections.

    macOS only: coremltools cannot run predictions on Linux (there the export can only be verified structurally,
    see ``describe``). The image is stretched to the model input exactly like Vision ``.scaleFill`` does in the app,
    the raw ``[N, 80]`` scores / ``[N, 4]`` normalized boxes of the first stage are thresholded and NMS-ed here with
    numpy. Returns the number of detections.
    """
    import tempfile

    if sys.platform != "darwin":
        sys.exit("--check needs macOS: Core ML models cannot be executed on this platform")

    import coremltools as ct
    import numpy as np
    from PIL import Image

    model = ct.models.MLModel(str(package), skip_model_load=True)
    spec = model.get_spec()
    names = _class_names(spec)
    if spec.WhichOneof("Type") == "pipeline":
        stage = spec.pipeline.models[0]
    else:
        stage = spec
    image_input = next(f for f in stage.description.input if f.type.WhichOneof("Type") == "imageType")
    width, height = image_input.type.imageType.width, image_input.type.imageType.height
    with tempfile.TemporaryDirectory() as tmp:
        stage_path = Path(tmp) / "stage.mlpackage"
        ct.models.MLModel(stage, weights_dir=model.weights_dir, skip_model_load=True).save(str(stage_path))
        runnable = ct.models.MLModel(str(stage_path), compute_units=ct.ComputeUnit.CPU_ONLY)
        source = Image.open(image_path).convert("RGB")
        result = runnable.predict({image_input.name: source.resize((width, height), Image.BILINEAR)})
    arrays = sorted((np.asarray(v) for v in result.values()), key=lambda a: a.shape[-1])
    if len(arrays) != 2 or arrays[0].shape[-1] != 4:
        print(f"Unexpected outputs {[a.shape for a in arrays]} — raw (--no-nms) packages are not checked here")
        return 0
    boxes, scores = arrays[0].reshape(-1, 4), arrays[1].reshape(arrays[0].reshape(-1, 4).shape[0], -1)
    cls = scores.argmax(1)
    best = scores.max(1)
    order = [i for i in np.argsort(-best) if best[i] >= conf]
    kept: list[int] = []
    for i in order:  # per-class greedy NMS on normalized (cx, cy, w, h)
        if all(cls[i] != cls[k] or _iou(boxes[i], boxes[k]) <= iou for k in kept):
            kept.append(i)
    print(f"{package.name}: input {width}x{height}, image {source.width}x{source.height}, "
          f"{len(kept)} detections at conf >= {conf}")
    for i in kept[:40]:
        cx, cy, w, h = (float(v) for v in boxes[i])
        label = names[cls[i]] if cls[i] < len(names) else f"class{cls[i]}"
        print(f"  {label:14s} {best[i]:.2f}  x={cx - w / 2:.3f} y={cy - h / 2:.3f} w={w:.3f} h={h:.3f}")
    return len(kept)


def _iou(a, b) -> float:
    """IoU of two (cx, cy, w, h) boxes."""
    ax1, ay1, ax2, ay2 = a[0] - a[2] / 2, a[1] - a[3] / 2, a[0] + a[2] / 2, a[1] + a[3] / 2
    bx1, by1, bx2, by2 = b[0] - b[2] / 2, b[1] - b[3] / 2, b[0] + b[2] / 2, b[1] + b[3] / 2
    inter = max(0.0, min(ax2, bx2) - max(ax1, bx1)) * max(0.0, min(ay2, by2) - max(ay1, by1))
    union = a[2] * a[3] + b[2] * b[3] - inter
    return float(inter / union) if union > 0 else 0.0


def _class_names(spec) -> list[str]:
    """Class names from the Ultralytics ``names`` metadata (``{0: 'person', …}``)."""
    import ast

    literal = dict(spec.description.metadata.userDefined).get("names", "")
    try:
        parsed = ast.literal_eval(literal)
        return [str(parsed[i]) for i in sorted(parsed)]
    except (ValueError, SyntaxError, TypeError):
        return []


def main(argv: list[str] | None = None) -> int:
    """Entry point."""
    args = parse_args(argv)
    if args.check is not None:
        if args.bundle:
            total = [check(MODELS_DIR / f"{name}.mlpackage", args.check, args.conf, args.iou) for name, _, _ in BUNDLE]
            return 0 if all(total) else 1
        return 0 if check(args.out, args.check, args.conf, args.iou) else 1
    if args.bundle:
        for name, weights, (height, width) in BUNDLE:
            args.weights, args.imgsz, args.out = weights, [height, width], MODELS_DIR / f"{name}.mlpackage"
            describe(export(args))
        print("\nDone. Open RoadVis.xcodeproj — Xcode picks up Models/*.mlpackage automatically.")
        return 0
    path = export(args)
    describe(path)
    print("\nDone. Open RoadVis.xcodeproj — Xcode picks up Models/*.mlpackage automatically.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
