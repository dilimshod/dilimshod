"""Teacher auto-labelling and the consistency check with the phone (contract section 4.2).

Class mapping (the apps' decoders map by *label name*, accepting underscores or spaces, so the dataset/model names
below decode to the same kinds as the stock COCO names):

======== ================== ============ ==========================
dataset  name in data.yaml  COCO id      COCO name
======== ================== ============ ==========================
0        car                2            car
1        truck              7            truck
2        bus                5            bus
3        motorcycle         3            motorcycle
4        bicycle            1            bicycle
5        person             0            person
6        traffic_light      9            traffic light
7        stop_sign          11           stop sign
======== ================== ============ ==========================
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Iterable, Protocol, Sequence

log = logging.getLogger(__name__)

DATASET_NAMES: list[str] = ["car", "truck", "bus", "motorcycle", "bicycle", "person", "traffic_light", "stop_sign"]
COCO_TO_DATASET: dict[int, int] = {2: 0, 7: 1, 5: 2, 3: 3, 1: 4, 0: 5, 9: 6, 11: 7}
TEACHER_COCO_CLASSES: list[int] = sorted(COCO_TO_DATASET)
# Classes whose recall the quality gate protects.
GATE_RECALL_CLASSES: list[str] = ["car", "person", "traffic_light"]


def normalize_label(name: str) -> str:
    """Normalizes a class name the way the apps do: lower case, '_' and '-' become spaces."""
    return " ".join(str(name).lower().replace("_", " ").replace("-", " ").split())


@dataclass(frozen=True)
class Box:
    """Normalized box, origin top-left: x, y, w, h in [0, 1]."""

    x: float
    y: float
    w: float
    h: float

    def iou(self, other: "Box") -> float:
        ax2, ay2 = self.x + self.w, self.y + self.h
        bx2, by2 = other.x + other.w, other.y + other.h
        iw = max(0.0, min(ax2, bx2) - max(self.x, other.x))
        ih = max(0.0, min(ay2, by2) - max(self.y, other.y))
        inter = iw * ih
        union = self.w * self.h + other.w * other.h - inter
        return inter / union if union > 0 else 0.0


@dataclass(frozen=True)
class TeacherBox:
    coco_class: int
    confidence: float
    box: Box


class Teacher(Protocol):
    """Anything that returns COCO-class boxes for an RGB PIL image (the real one wraps Ultralytics)."""

    def predict(self, image) -> list[TeacherBox]: ...


@dataclass
class LabelResult:
    accepted: bool
    reason: str | None = None
    labels: list[tuple[int, Box]] = field(default_factory=list)  # (dataset class id, box)

    def yolo_lines(self) -> str:
        """YOLO label file content: ``cls cx cy w h`` per line (normalized)."""
        lines = []
        for cls, b in self.labels:
            cx, cy = b.x + b.w / 2, b.y + b.h / 2
            lines.append(f"{cls} {cx:.6f} {cy:.6f} {b.w:.6f} {b.h:.6f}")
        return "\n".join(lines) + ("\n" if lines else "")


def _clip_box(b: Box) -> Box | None:
    x1, y1 = max(0.0, b.x), max(0.0, b.y)
    x2, y2 = min(1.0, b.x + b.w), min(1.0, b.y + b.h)
    if x2 <= x1 or y2 <= y1:
        return None
    return Box(x1, y1, x2 - x1, y2 - y1)


def decide_labels(teacher_boxes: Sequence[TeacherBox], phone_tracks: Iterable[dict], *, label_conf: float = 0.50,
                  ambiguous_conf: float = 0.25, min_hits: int = 5, min_iou: float = 0.30) -> LabelResult:
    """Pure decision: turns teacher boxes into labels or rejects the frame as ambiguous.

    * teacher boxes (of the 8 app classes) with confidence >= ``label_conf`` become labels;
    * any teacher box with confidence in [``ambiguous_conf``, ``label_conf``) makes the frame ambiguous (no partial
      labels);
    * a phone track that was confirmed with >= ``min_hits`` hits but overlaps no teacher box with IoU >= ``min_iou``
      makes the frame ambiguous.
    A frame without any confident teacher box is kept as a background image (empty label file).
    """
    relevant = [t for t in teacher_boxes if t.coco_class in COCO_TO_DATASET]
    if any(ambiguous_conf <= t.confidence < label_conf for t in relevant):
        return LabelResult(False, "ambiguousTeacher")
    confident = [t for t in relevant if t.confidence >= label_conf]
    for track in phone_tracks or []:
        try:
            confirmed = bool(track.get("confirmed"))
            hits = int(track.get("hits", 0))
            tb = track.get("box")
            pbox = Box(*(float(v) for v in tb))
        except (TypeError, ValueError, AttributeError):
            continue
        if confirmed and hits >= min_hits and not any(pbox.iou(t.box) >= min_iou for t in confident):
            return LabelResult(False, "phoneTrackUnmatched")
    labels = []
    for t in confident:
        clipped = _clip_box(t.box)
        if clipped is not None:
            labels.append((COCO_TO_DATASET[t.coco_class], clipped))
    return LabelResult(True, None, labels)


class UltralyticsTeacher:
    """YOLO teacher on CPU (default ``yolo11x.pt`` at 1280 px), restricted to the 8 app classes."""

    def __init__(self, model_name: str = "yolo11x.pt", imgsz: int = 1280, conf: float = 0.25):
        from ultralytics import YOLO  # heavy import, only in the worker

        self.model = YOLO(model_name)
        self.imgsz = imgsz
        self.conf = conf
        names = self.model.names  # {id: name}; stock COCO weights expected
        self.coco_ids = {}
        coco_names = {0: "person", 1: "bicycle", 2: "car", 3: "motorcycle", 5: "bus", 7: "truck", 9: "traffic light",
                      11: "stop sign"}
        by_name = {normalize_label(n): i for i, n in names.items()}
        for coco_id, coco_name in coco_names.items():
            if coco_name in by_name:
                self.coco_ids[by_name[coco_name]] = coco_id
        if len(self.coco_ids) != 8:
            log.warning("Teacher %s knows only %d of the 8 app classes", model_name, len(self.coco_ids))

    def predict(self, image) -> list[TeacherBox]:
        res = self.model.predict(image, imgsz=self.imgsz, conf=self.conf, classes=sorted(self.coco_ids),
                                 device="cpu", verbose=False)[0]
        out: list[TeacherBox] = []
        if res.boxes is None or len(res.boxes) == 0:
            return out
        h, w = res.orig_shape
        xyxy = res.boxes.xyxy.cpu().numpy()
        confs = res.boxes.conf.cpu().numpy()
        clss = res.boxes.cls.cpu().numpy().astype(int)
        for (x1, y1, x2, y2), c, k in zip(xyxy, confs, clss):
            if int(k) not in self.coco_ids:
                continue
            out.append(TeacherBox(self.coco_ids[int(k)], float(c),
                                  Box(float(x1) / w, float(y1) / h, float(x2 - x1) / w, float(y2 - y1) / h)))
        return out
