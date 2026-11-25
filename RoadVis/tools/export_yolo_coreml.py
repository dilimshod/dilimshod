#!/usr/bin/env python3
"""Export an Ultralytics YOLO detector to Core ML for the RoadVis iOS app.

The app looks for a model named ``RoadVisDetector`` (then ``yolo26n``, ``yolo11n``, ``yolov8n``) inside the
app bundle. Xcode compiles every ``*.mlpackage`` placed in ``RoadVis/RoadVis/Models/`` (a synchronized
folder) into ``<name>.mlmodelc`` automatically, so exporting to the default ``--out`` path is all that is needed.

Two output layouts are supported by the app:

* ``--nms`` (default): a Core ML *pipeline* (detector + Apple NonMaximumSuppression). Vision returns
  ``VNRecognizedObjectObservation`` objects with labels and normalized boxes — fastest path on iOS.
* ``--no-nms``: the raw tensor. YOLO11/YOLOv8 output ``[1, 84, 8400]`` (decoded and NMS-ed in the app by
  ``YOLODecoder``); YOLO26 is end-to-end and outputs ``[1, 300, 6]`` boxes without NMS.

Examples (macOS or Linux, Python 3.10–3.13)::

    python3 -m venv .venv && source .venv/bin/activate
    pip install -r tools/requirements.txt
    python tools/export_yolo_coreml.py                           # yolo11n.pt, 640 px, NMS, FP16
    python tools/export_yolo_coreml.py --weights yolo26n.pt      # newest Ultralytics model
    python tools/export_yolo_coreml.py --quantize 8              # ~2x smaller, slightly less accurate

Licence: Ultralytics code and pretrained weights are AGPL-3.0 (or an Ultralytics Enterprise licence).
Distributing an app that embeds these weights has licence implications — read Models/README.md.
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

REPO_APP_DIR = Path(__file__).resolve().parent.parent  # .../RoadVis
DEFAULT_OUT = REPO_APP_DIR / "RoadVis" / "Models" / "RoadVisDetector.mlpackage"


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """Builds the command-line interface."""
    p = argparse.ArgumentParser(
        description="Export a YOLO detector (COCO classes) to a Core ML .mlpackage for RoadVis.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument("--weights", default="yolo11n.pt",
                   help="Ultralytics weights: yolo11n.pt, yolo26n.pt, yolo11s.pt, or a path to your own best.pt "
                        "(official weights are downloaded automatically)")
    p.add_argument("--imgsz", type=int, default=640, help="square input size in pixels (multiple of 32)")
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
    return p.parse_args(argv)


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

    export_kwargs = dict(format="coreml", imgsz=args.imgsz, nms=args.nms, conf=args.conf, iou=args.iou)
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


def main(argv: list[str] | None = None) -> int:
    """Entry point."""
    args = parse_args(argv)
    path = export(args)
    describe(path)
    print("\nDone. Open RoadVis.xcodeproj — Xcode picks up Models/*.mlpackage automatically.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
