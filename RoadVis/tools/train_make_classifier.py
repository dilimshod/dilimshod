#!/usr/bin/env python3
"""Train the RoadVis vehicle-MAKE classifier and export it to Core ML.

Pipeline
  1. Download the Hugging Face dataset ``tanganke/stanford_cars`` (Stanford Cars, Krause et al., 2013):
     train = 8 144 images, test = 8 041 images, 196 classes of the form "<Make> <Model> <Body> <Year>".
  2. Collapse the 196 model-level labels to the MAKE (manufacturer brand) — 48 classes after merging
     "AM General" into "Hummer"; multi-word makes such as "Aston Martin" and "Land Rover" are handled.
  3. Write an ImageFolder tree:  <data>/train/<Make>/*.jpg, <data>/val/<Make>/*.jpg (stratified split of the
     official TRAIN split) and <data>/test/<Make>/*.jpg (the official TEST split, never used for training or
     model selection).
  4. Fine-tune ``yolo11n-cls.pt`` (ImageNet-pretrained) at 224 px with Ultralytics.
  5. Report top-1 / top-5 accuracy on the held-out TEST split (clearly separated from validation numbers).
  6. Export to Core ML as an image classifier (Vision returns ``VNClassificationObservation``) at
     ``RoadVis/RoadVis/Models/VehicleMakeClassifier.mlpackage`` — the app picks it up automatically.

IMPORTANT LIMITATIONS
  * Licence: Stanford Cars is provided for NON-COMMERCIAL RESEARCH PURPOSES ONLY (the images come from the web
    and are subject to their owners' copyright). A model trained on it must not be shipped commercially.
    Ultralytics code and pretrained weights are AGPL-3.0.
  * Domain gap: Stanford Cars contains US-market cars of model years up to 2012. The typical fleet in
    Uzbekistan — Chevrolet Cobalt / Nexia / Spark / Damas / Gentra / Lacetti / Malibu / Tracker, Ravon,
    Daewoo Matiz, Lada, BYD, Chery, Haval, Kia K5, Hyundai, Tesla — is mostly NOT represented (only some
    Chevrolet/Hyundai/Toyota models of that era). Expect poor results on Tashkent streets. For usable accuracy,
    collect and label a local dataset (e.g. photos/video frames labelled in Roboflow or Label Studio, exported as
    an ImageFolder classification dataset) and run this script with ``--local-data <folder>`` instead of, or in
    addition to, Stanford Cars.
  * The classifier sees crops of detected cars produced by the app; train/test images here are full photos, so
    accuracy on crops from a dash-mounted phone will differ. Confidence values are model scores, not accuracy.

Usage (Mac with Apple Silicon: add ``--device mps``; Python 3.10–3.13):
    pip install -r tools/requirements.txt
    python tools/train_make_classifier.py --epochs 30 --device mps
    python tools/train_make_classifier.py --prepare-only                    # only build the ImageFolder tree
    python tools/train_make_classifier.py --local-data ~/datasets/uz_makes  # add your own labelled makes
"""

from __future__ import annotations

import argparse
import json
import random
import shutil
import sys
from collections import Counter, defaultdict
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
APP_DIR = TOOLS_DIR.parent  # .../RoadVis
DEFAULT_DATA = TOOLS_DIR / "datasets" / "stanford_cars_makes"   # git-ignored (".gitignore: datasets/")
DEFAULT_RUNS = TOOLS_DIR / "runs"                                 # git-ignored (".gitignore: runs/")
DEFAULT_OUT = APP_DIR / "RoadVis" / "Models" / "VehicleMakeClassifier.mlpackage"
HF_DATASET = "tanganke/stanford_cars"

# Makes whose name has more than one word in Stanford Cars labels (checked against all 196 class names).
MULTI_WORD_MAKES = ("AM General", "Aston Martin", "Land Rover")

# Display names used as class labels in the exported model (brand spelling as seen on cars).
MAKE_ALIASES = {
    "AM General": "Hummer",   # the only AM General class is the "Hummer SUV 2000" (H1)
    "HUMMER": "Hummer",
    "FIAT": "Fiat",
    "MINI": "Mini",
    "smart": "Smart",
}


def make_from_label(label: str) -> str:
    """Returns the make (brand) for a Stanford Cars class name, e.g. 'Land Rover LR2 SUV 2012' → 'Land Rover'."""
    label = label.strip()
    for make in MULTI_WORD_MAKES:
        if label == make or label.startswith(make + " "):
            return MAKE_ALIASES.get(make, make)
    first = label.split(" ", 1)[0]
    return MAKE_ALIASES.get(first, first)


def safe_dirname(name: str) -> str:
    """Folder name for a class (Ultralytics uses folder names as class labels, so keep them readable)."""
    return name.replace("/", "-").strip()


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """Builds the command-line interface."""
    p = argparse.ArgumentParser(description="Train a vehicle-make classifier (Stanford Cars → makes) and export "
                                            "it to Core ML for RoadVis.",
                                formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    p.add_argument("--data", type=Path, default=DEFAULT_DATA, help="ImageFolder output directory")
    p.add_argument("--local-data", type=Path, default=None,
                   help="optional extra ImageFolder (<Make>/*.jpg) with your own labelled cars; split 80/10/10 "
                        "into train/val/test and merged with Stanford Cars")
    p.add_argument("--no-stanford", action="store_true", help="use only --local-data (no Stanford Cars)")
    p.add_argument("--val-fraction", type=float, default=0.1, help="part of the official TRAIN split used for val")
    p.add_argument("--seed", type=int, default=0)
    p.add_argument("--model", default="yolo11n-cls.pt", help="Ultralytics classification weights to fine-tune")
    p.add_argument("--imgsz", type=int, default=224)
    p.add_argument("--epochs", type=int, default=30)
    p.add_argument("--batch", type=int, default=64, help="lower it (e.g. 32) on a Mac with 8 GB of memory")
    p.add_argument("--device", default=None, help="'mps' (Apple Silicon), '0' (CUDA GPU) or 'cpu'; default: auto")
    p.add_argument("--workers", type=int, default=4)
    p.add_argument("--quantize", type=int, choices=(16, 8), default=16, help="Core ML weight precision")
    p.add_argument("--out", type=Path, default=DEFAULT_OUT, help="destination .mlpackage")
    p.add_argument("--prepare-only", action="store_true", help="build the dataset folders and stop")
    p.add_argument("--force", action="store_true", help="rebuild --data and overwrite --out")
    return p.parse_args(argv)


def write_split(images, labels: list[str], root: Path, split: str) -> Counter:
    """Saves PIL images as JPEG files into root/split/<label>/ and returns per-class counts."""
    counts: Counter = Counter()
    for i, (image, label) in enumerate(zip(images, labels)):
        folder = root / split / safe_dirname(label)
        folder.mkdir(parents=True, exist_ok=True)
        image.convert("RGB").save(folder / f"{split}_{i:05d}.jpg", quality=92)
        counts[label] += 1
    return counts


def stratified_split(indices_by_class: dict[str, list[int]], fraction: float, rng: random.Random):
    """Splits indices per class: returns (train_idx, val_idx); every class keeps ≥ 1 training sample."""
    train_idx, val_idx = [], []
    for _, idx in sorted(indices_by_class.items()):
        idx = idx[:]
        rng.shuffle(idx)
        n_val = int(round(len(idx) * fraction))
        n_val = min(n_val, max(0, len(idx) - 1))
        val_idx.extend(idx[:n_val])
        train_idx.extend(idx[n_val:])
    return train_idx, val_idx


def prepare_stanford(root: Path, val_fraction: float, rng: random.Random) -> dict[str, Counter]:
    """Downloads Stanford Cars from Hugging Face and writes train/val/test ImageFolder splits by make."""
    try:
        from datasets import load_dataset
    except ImportError:
        sys.exit("The 'datasets' package is missing: pip install -r tools/requirements.txt")

    print(f"Downloading {HF_DATASET} (≈ 1.9 GB on first run, cached by Hugging Face)…", flush=True)
    train = load_dataset(HF_DATASET, split="train")
    test = load_dataset(HF_DATASET, split="test")
    names = train.features["label"].names
    makes = sorted({make_from_label(n) for n in names})
    print(f"{len(names)} model classes → {len(makes)} makes: {', '.join(makes)}")

    train_labels = [make_from_label(names[i]) for i in train["label"]]
    by_class: dict[str, list[int]] = defaultdict(list)
    for i, make in enumerate(train_labels):
        by_class[make].append(i)
    train_idx, val_idx = stratified_split(by_class, val_fraction, rng)

    counts = {
        "train": write_split((train[i]["image"] for i in train_idx), [train_labels[i] for i in train_idx], root,
                             "train"),
        "val": write_split((train[i]["image"] for i in val_idx), [train_labels[i] for i in val_idx], root, "val"),
    }
    test_labels = [make_from_label(names[i]) for i in test["label"]]
    counts["test"] = write_split((row["image"] for row in test), test_labels, root, "test")
    return counts


def prepare_local(root: Path, local: Path, rng: random.Random) -> dict[str, Counter]:
    """Copies a user ImageFolder (<Make>/*.jpg|png) into train/val/test (80/10/10 per class)."""
    from PIL import Image

    counts = {"train": Counter(), "val": Counter(), "test": Counter()}
    for class_dir in sorted(p for p in local.iterdir() if p.is_dir()):
        files = sorted(f for f in class_dir.iterdir() if f.suffix.lower() in {".jpg", ".jpeg", ".png", ".webp"})
        if len(files) < 3:
            print(f"  skipping '{class_dir.name}': needs at least 3 images, has {len(files)}")
            continue
        rng.shuffle(files)
        n_test = max(1, len(files) // 10)
        n_val = max(1, len(files) // 10)
        parts = {"test": files[:n_test], "val": files[n_test:n_test + n_val], "train": files[n_test + n_val:]}
        for split, split_files in parts.items():
            folder = root / split / safe_dirname(class_dir.name)
            folder.mkdir(parents=True, exist_ok=True)
            for f in split_files:
                Image.open(f).convert("RGB").save(folder / f"local_{f.stem}.jpg", quality=92)
                counts[split][class_dir.name] += 1
    return counts


def print_counts(counts: dict[str, Counter]) -> None:
    """Prints per-split totals and the rarest classes (class imbalance matters for accuracy)."""
    for split in ("train", "val", "test"):
        c = counts.get(split, Counter())
        rare = ", ".join(f"{k}={v}" for k, v in sorted(c.items(), key=lambda kv: kv[1])[:5])
        print(f"  {split:5s}: {sum(c.values()):6d} images, {len(c)} classes (rarest: {rare})")


def train_and_evaluate(args: argparse.Namespace) -> Path:
    """Fine-tunes the classifier, evaluates on the TEST split and returns the best weights path."""
    from ultralytics import YOLO

    model = YOLO(args.model)
    results = model.train(data=str(args.data), imgsz=args.imgsz, epochs=args.epochs, batch=args.batch,
                          device=args.device, workers=args.workers, seed=args.seed, deterministic=True,
                          project=str(DEFAULT_RUNS), name="make_classifier", exist_ok=True, plots=True)
    del results  # metrics of the last epoch; the best checkpoint is re-evaluated below
    save_dir = Path(model.trainer.save_dir)
    best = save_dir / "weights" / "best.pt"
    if not best.exists():
        sys.exit(f"Training finished but {best} is missing")

    best_model = YOLO(str(best))
    val_metrics = best_model.val(data=str(args.data), split="val", imgsz=args.imgsz, batch=args.batch,
                                 device=args.device, plots=False)
    test_metrics = best_model.val(data=str(args.data), split="test", imgsz=args.imgsz, batch=args.batch,
                                  device=args.device, plots=True)
    report = {
        "model": args.model, "imgsz": args.imgsz, "epochs": args.epochs, "classes": len(best_model.names),
        "validation (from TRAIN split, used for model selection)": {
            "top1": round(float(val_metrics.top1), 4), "top5": round(float(val_metrics.top5), 4)},
        "TEST (official held-out split, never used for training)": {
            "top1": round(float(test_metrics.top1), 4), "top5": round(float(test_metrics.top5), 4)},
        "note": "Stanford Cars makes ≠ Uzbekistan fleet; scores are not representative of Tashkent traffic.",
    }
    (save_dir / "test_metrics.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print("\n================ RESULTS ================")
    print(f"Validation  top-1 {report['validation (from TRAIN split, used for model selection)']['top1']:.3f}  "
          f"top-5 {report['validation (from TRAIN split, used for model selection)']['top5']:.3f}   (model selection)")
    print(f"TEST        top-1 {report['TEST (official held-out split, never used for training)']['top1']:.3f}  "
          f"top-5 {report['TEST (official held-out split, never used for training)']['top5']:.3f}   (held-out)")
    print(f"Saved {save_dir / 'test_metrics.json'}")
    return best


def export_coreml(best: Path, args: argparse.Namespace) -> Path:
    """Exports the classifier to Core ML (classifier spec → Vision returns VNClassificationObservation)."""
    from ultralytics import YOLO
    from ultralytics.cfg import DEFAULT_CFG_DICT

    kwargs = dict(format="coreml", imgsz=args.imgsz, nms=False)
    if "quantize" in DEFAULT_CFG_DICT:
        kwargs["quantize"] = args.quantize
    elif args.quantize == 8:
        kwargs["int8"] = True
    else:
        kwargs["half"] = True
    produced = Path(YOLO(str(best)).export(**kwargs))
    out: Path = args.out
    if out.exists():
        if not args.force:
            sys.exit(f"{out} exists — pass --force to overwrite (exported model kept at {produced})")
        shutil.rmtree(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(produced), str(out))

    import coremltools as ct

    spec = ct.models.MLModel(str(out), skip_model_load=True).get_spec()
    names = dict(spec.description.metadata.userDefined).get("names", "")
    print(f"\nExported {out}")
    print("Inputs: ", [f.name for f in spec.description.input])
    print("Outputs:", [f.name for f in spec.description.output],
          f"(predictedFeatureName={spec.description.predictedFeatureName!r})")
    if names:
        print(f"Class labels (metadata 'names'): {names[:400]}{'…' if len(names) > 400 else ''}")
    return out


def main(argv: list[str] | None = None) -> int:
    """Entry point."""
    args = parse_args(argv)
    rng = random.Random(args.seed)
    if args.no_stanford and args.local_data is None:
        sys.exit("--no-stanford requires --local-data")

    if args.data.exists() and any(args.data.iterdir()):
        if args.force:
            shutil.rmtree(args.data)
        else:
            print(f"Using existing dataset at {args.data} (pass --force to rebuild)")
    if not args.data.exists() or not any(args.data.iterdir()):
        args.data.mkdir(parents=True, exist_ok=True)
        merged: dict[str, Counter] = {"train": Counter(), "val": Counter(), "test": Counter()}
        if not args.no_stanford:
            for split, c in prepare_stanford(args.data, args.val_fraction, rng).items():
                merged[split].update(c)
        if args.local_data is not None:
            for split, c in prepare_local(args.data, args.local_data.expanduser(), rng).items():
                merged[split].update(c)
        print("Dataset written:")
        print_counts(merged)

    if args.prepare_only:
        print(f"Dataset ready at {args.data}")
        return 0
    best = train_and_evaluate(args)
    export_coreml(best, args)
    print("\nDone. Rebuild the app in Xcode — Models/VehicleMakeClassifier.mlpackage is compiled automatically.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
