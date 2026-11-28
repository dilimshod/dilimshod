#!/usr/bin/env python3
"""Export the YOLO detector of the RoadVis Android app to ONNX and verify it.

The app (``app/.../detection/YoloDetector.kt``) loads ``app/src/main/assets/yolo11n.onnx``: ONE file with dynamic
``batch`` / ``height`` / ``width`` dimensions. ONNX Runtime sessions are created with fixed free-dimension overrides
(``setSymbolicDimensionValue``) for the rectangular inputs the app uses:

    landscape frames: 384x640 (lite) and 544x960 (full)   — HEIGHT x WIDTH
    portrait frames:  640x384 (lite) and 960x544 (full)

Usage (Python 3.10-3.13; ``pip install ultralytics onnx onnxruntime onnxslim``)::

    python tools/export_yolo_onnx.py --force                 # yolo11n.pt -> app/src/main/assets/yolo11n.onnx
    python tools/export_yolo_onnx.py --verify photo.jpg      # no export: run the asset at all four sizes on a photo

Licence: Ultralytics code and weights are AGPL-3.0 (or Ultralytics Enterprise).
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

ANDROID_DIR = Path(__file__).resolve().parent.parent
DEFAULT_OUT = ANDROID_DIR / "app" / "src" / "main" / "assets" / "yolo11n.onnx"
# (height, width) of every input the app creates a session for — keep in sync with YoloDetector.kt.
INPUT_SIZES = [(384, 640), (544, 960), (640, 384), (960, 544)]
COCO_APP_CLASSES = {0: "person", 1: "bicycle", 2: "car", 3: "motorcycle", 5: "bus", 7: "truck", 9: "traffic light",
                    11: "stop sign"}


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    p.add_argument("--weights", default="yolo11n.pt", help="Ultralytics detection weights (COCO classes)")
    p.add_argument("--opset", type=int, default=18, help="ONNX opset")
    p.add_argument("--out", type=Path, default=DEFAULT_OUT, help="destination .onnx path")
    p.add_argument("--force", action="store_true", help="overwrite --out if it already exists")
    p.add_argument("--verify", type=Path, metavar="IMAGE",
                   help="do not export: run --out on IMAGE at every app input size with onnxruntime")
    p.add_argument("--conf", type=float, default=0.3, help="confidence threshold used by --verify")
    return p.parse_args(argv)


def export(args: argparse.Namespace) -> Path:
    """Exports ``args.weights`` with dynamic axes and moves the file to ``args.out``."""
    from ultralytics import YOLO

    out: Path = args.out
    if out.exists() and not args.force:
        sys.exit(f"{out} already exists — pass --force to overwrite it")
    model = YOLO(args.weights)
    if model.task != "detect":
        sys.exit(f"{args.weights} is a '{model.task}' model; a detection model is required")
    # nms stays off: the app decodes the raw [1, 84, N] tensor with the core YOLODecoder.
    produced = Path(model.export(format="onnx", dynamic=True, simplify=True, opset=args.opset, imgsz=(544, 960)))
    out.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(produced), str(out))
    print(f"Saved {out} ({out.stat().st_size / 1e6:.2f} MB)")
    return out


def letterbox(image, height: int, width: int):
    """Aspect-preserving resize into ``width x height`` with centred grey (114) padding — the app's ``Letterbox``."""
    import numpy as np
    from PIL import Image

    gain = min(width / image.width, height / image.height)
    scaled_w = max(1, min(width, round(image.width * gain)))
    scaled_h = max(1, min(height, round(image.height * gain)))
    canvas = Image.new("RGB", (width, height), (114, 114, 114))
    pad_x, pad_y = (width - scaled_w) // 2, (height - scaled_h) // 2
    canvas.paste(image.resize((scaled_w, scaled_h), Image.BILINEAR), (pad_x, pad_y))
    tensor = np.asarray(canvas, dtype=np.float32).transpose(2, 0, 1)[None] / 255.0
    return tensor, gain, (width - image.width * gain) / 2, (height - image.height * gain) / 2


def verify(path: Path, image_path: Path, conf: float) -> bool:
    """Runs the model at every app input size (fixed free dimensions, like the app) and prints the detections."""
    import numpy as np
    import onnx
    import onnxruntime as ort
    from PIL import Image

    graph_input = onnx.load(str(path), load_external_data=False).graph.input[0]
    dims = [d.dim_param or d.dim_value for d in graph_input.type.tensor_type.shape.dim]
    print(f"{path.name}: input '{graph_input.name}' dims {dims}")
    if dims[0] != "batch" or dims[2] != "height" or dims[3] != "width":
        print("  expected symbolic dims batch / height / width — YoloDetector.kt relies on these names")
        return False
    source = Image.open(image_path).convert("RGB")
    ok = True
    for height, width in INPUT_SIZES:
        # A landscape photo is rotated for the portrait inputs so that every size sees a sensible frame.
        image = source if (width >= height) == (source.width >= source.height) else source.rotate(90, expand=True)
        options = ort.SessionOptions()
        for name, value in (("batch", 1), ("height", height), ("width", width)):
            options.add_free_dimension_override_by_name(name, value)
        session = ort.InferenceSession(str(path), options, providers=["CPUExecutionProvider"])
        tensor, gain, pad_x, pad_y = letterbox(image, height, width)
        output = session.run(None, {graph_input.name: tensor})[0]
        anchors = (height // 8) * (width // 8) + (height // 16) * (width // 16) + (height // 32) * (width // 32)
        shape_ok = output.shape == (1, 84, anchors)
        rows = output[0].T
        scores = rows[:, 4:]
        cls, best = scores.argmax(1), scores.max(1)
        kept = []
        for i in np.argsort(-best):
            if best[i] < conf:
                break
            cx, cy, w, h = rows[i, :4]
            box = ((cx - w / 2 - pad_x) / gain / image.width, (cy - h / 2 - pad_y) / gain / image.height,
                   (cx + w / 2 - pad_x) / gain / image.width, (cy + h / 2 - pad_y) / gain / image.height)
            if all(cls[i] != k[0] or _iou(box, k[2]) <= 0.45 for k in kept):
                kept.append((int(cls[i]), float(best[i]), box))
        print(f"  {height}x{width}: output {output.shape} {'OK' if shape_ok else 'UNEXPECTED'}, "
              f"{len(kept)} detections at conf >= {conf}")
        for c, score, box in kept[:12]:
            label = COCO_APP_CLASSES.get(c, f"coco{c}")
            print(f"    {label:14s} {score:.2f}  x1={box[0]:.3f} y1={box[1]:.3f} x2={box[2]:.3f} y2={box[3]:.3f}")
        ok = ok and shape_ok and all(-0.05 <= v <= 1.05 for _, _, b in kept for v in b)
    return ok


def _iou(a, b) -> float:
    inter = max(0.0, min(a[2], b[2]) - max(a[0], b[0])) * max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / union if union > 0 else 0.0


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.verify is not None:
        return 0 if verify(args.out, args.verify, args.conf) else 1
    export(args)
    print("Verify with: python tools/export_yolo_onnx.py --verify <photo.jpg>")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
