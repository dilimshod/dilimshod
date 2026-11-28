"""Quality gate (contract section 4.4).

The candidate and the current model (or, before the first accepted model, the stock ``yolo11s.pt``) are evaluated
on the frozen test set with Ultralytics ``val`` on CPU at imgsz 960. The candidate is accepted only if

* mAP50 >= current mAP50 + 0.005, AND
* per-class recall of car, person and traffic light does not drop by more than 0.01, AND
* precision does not drop by more than 0.01.

The decision itself is the pure function :func:`decide`. Rejected candidates are deleted; the JSON report is kept.
"""

from __future__ import annotations

import json
import logging
import shutil
import traceback
from dataclasses import asdict, dataclass, field
from pathlib import Path

from .config import Settings
from .labeling import GATE_RECALL_CLASSES
from .storage import Store, iso

log = logging.getLogger(__name__)

MAP50_MIN_GAIN = 0.005
MAX_RECALL_DROP = 0.01
MAX_PRECISION_DROP = 0.01
_EPS = 1e-9


@dataclass
class EvalMetrics:
    """Metrics of one model on the frozen test set. ``per_class`` maps dataset class name → {precision, recall,
    map50, instances}; classes without test instances are absent."""

    map50: float
    precision: float
    recall: float
    per_class: dict[str, dict] = field(default_factory=dict)
    test_images: int = 0
    model: str = ""

    @classmethod
    def from_dict(cls, d: dict) -> "EvalMetrics":
        return cls(map50=float(d["map50"]), precision=float(d["precision"]), recall=float(d["recall"]),
                   per_class=dict(d.get("per_class") or {}), test_images=int(d.get("test_images", 0)),
                   model=str(d.get("model", "")))


@dataclass
class GateDecision:
    accepted: bool
    checks: list[dict]
    reasons: list[str]


def decide(candidate: EvalMetrics, current: EvalMetrics) -> GateDecision:
    """Applies the acceptance rule. A protected class that has no test instances for the current model is skipped;
    if the current model has instances but the candidate reports none, the candidate's recall counts as 0."""
    checks: list[dict] = []

    need = current.map50 + MAP50_MIN_GAIN
    checks.append({"check": "map50", "candidate": candidate.map50, "current": current.map50, "required": need,
                   "passed": candidate.map50 + _EPS >= need})
    for name in GATE_RECALL_CLASSES:
        cur = current.per_class.get(name)
        if cur is None:
            checks.append({"check": f"recall[{name}]", "skipped": True, "passed": True,
                           "note": "no test instances"})
            continue
        cand_recall = float((candidate.per_class.get(name) or {}).get("recall", 0.0))
        need_r = float(cur["recall"]) - MAX_RECALL_DROP
        checks.append({"check": f"recall[{name}]", "candidate": cand_recall, "current": float(cur["recall"]),
                       "required": need_r, "passed": cand_recall + _EPS >= need_r})
    need_p = current.precision - MAX_PRECISION_DROP
    checks.append({"check": "precision", "candidate": candidate.precision, "current": current.precision,
                   "required": need_p, "passed": candidate.precision + _EPS >= need_p})
    reasons = [c["check"] for c in checks if not c["passed"]]
    return GateDecision(accepted=not reasons, checks=checks, reasons=reasons)


def evaluate(settings: Settings, weights: str | Path, label: str) -> EvalMetrics:
    """Runs Ultralytics val of ``weights`` on the frozen test set (CPU, imgsz ``eval_imgsz``, rect batches)."""
    from ultralytics import YOLO

    from .dataset import build_eval_view

    model = YOLO(str(weights))
    work = settings.tmp_dir / f"eval-{label}"
    data_yaml, model_to_name, class_ids = build_eval_view(settings, model.names, work)
    n_images = sum(1 for _ in (work / "images" / "test").glob("*.jpg"))
    metrics = model.val(data=str(data_yaml), split="val", imgsz=settings.eval_imgsz, batch=4, device="cpu",
                        workers=0, rect=True, plots=False, save_json=False, verbose=False,
                        classes=class_ids, project=str(work / "runs"), name="val", exist_ok=True)
    box = metrics.box
    per_class: dict[str, dict] = {}
    nt = getattr(metrics, "nt_per_class", None)
    for i, cls_id in enumerate(box.ap_class_index):
        name = model_to_name.get(int(cls_id))
        if name is None:
            continue
        p, r, ap50, _ = box.class_result(i)
        entry = {"precision": float(p), "recall": float(r), "map50": float(ap50)}
        if nt is not None and int(cls_id) < len(nt):
            entry["instances"] = int(nt[int(cls_id)])
        per_class[name] = entry
    shutil.rmtree(work, ignore_errors=True)
    return EvalMetrics(map50=float(box.map50), precision=float(box.mp), recall=float(box.mr), per_class=per_class,
                       test_images=n_images, model=str(weights))


def current_weights(store: Store, settings: Settings) -> tuple[str, str | None]:
    """Weights of the current accepted model, or the stock baseline. Returns ``(path_or_name, version)``."""
    for v in store.published_versions():
        p = settings.models_dir / v["version"] / "weights.pt"
        if p.exists():
            return str(p), v["version"]
    return settings.baseline_model, None


def run_gate(store: Store, settings: Settings, cand_id: str, evaluator=None, publisher=None) -> dict:
    """Evaluates candidate ``cand_id``; publishes it if accepted, deletes its weights if rejected.

    ``evaluator(settings, weights, label) -> EvalMetrics`` and ``publisher(store, settings, cand_id, weights,
    report) -> version`` are injectable for tests. Returns the report (also written to ``data/reports``)."""
    from . import publish

    evaluator = evaluator or evaluate
    publisher = publisher or publish.publish_candidate
    cand = store.get_candidate(cand_id)
    if cand is None:
        raise KeyError(cand_id)
    weights = Path(cand["weights_path"])
    report: dict = {"candidate": cand_id, "startedAt": iso(), "rule": {
        "map50_min_gain": MAP50_MIN_GAIN, "max_recall_drop": MAX_RECALL_DROP, "recall_classes": GATE_RECALL_CLASSES,
        "max_precision_drop": MAX_PRECISION_DROP, "imgsz": settings.eval_imgsz}}
    if cand.get("training_metrics"):
        report["training"] = json.loads(cand["training_metrics"])
    store.update_candidate(cand_id, status="evaluating")
    report_path = settings.reports_dir / f"{cand_id}.json"
    status, version, message = "rejected", None, ""
    try:
        test_images = store.split_count("test")
        report["testImages"] = test_images
        if test_images < max(1, settings.gate_min_test_images):
            message = f"frozen test set too small ({test_images} < {settings.gate_min_test_images} images)"
            report["decision"] = {"accepted": False, "reasons": ["testSetTooSmall"], "checks": []}
        else:
            cur_path, cur_version = current_weights(store, settings)
            report["current"] = {"version": cur_version, "weights": Path(cur_path).name}
            cand_m = evaluator(settings, weights, f"cand-{cand_id}")
            cur_m = evaluator(settings, cur_path, f"cur-{cand_id}")
            report["metrics"] = {"candidate": asdict(cand_m), "current": asdict(cur_m)}
            decision = decide(cand_m, cur_m)
            report["decision"] = asdict(decision)
            if decision.accepted:
                version = publisher(store, settings, cand_id, weights, report)
                status, message = "accepted", f"published {version}"
                report["publishedVersion"] = version
            else:
                message = "failed: " + ", ".join(decision.reasons)
    except Exception as exc:  # noqa: BLE001 - keep the error in the report
        log.exception("gate failed for candidate %s", cand_id)
        status, message = "error", f"{type(exc).__name__}: {exc}"
        report["error"] = traceback.format_exc(limit=5)
    report["finishedAt"] = iso()
    report["status"] = status
    settings.reports_dir.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2, default=str))
    # Rejected or failed candidates are deleted; accepted weights were copied into the published version.
    weights.unlink(missing_ok=True)
    if weights.parent.parent == settings.candidates_dir:
        shutil.rmtree(weights.parent, ignore_errors=True)
    store.update_candidate(cand_id, status=status, report_path=str(report_path), version=version, message=message,
                           finished_at=iso())
    log.info("candidate %s: %s (%s)", cand_id, status, message)
    return report
