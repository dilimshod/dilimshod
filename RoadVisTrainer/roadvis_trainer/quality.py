"""Frame quality metrics, identical in meaning to the apps' ``FrameQuality`` (contract section 1).

All metrics are computed on a grayscale copy resized to 160 px wide (0–255 gray):

* sharpness  = variance of the 4-neighbour Laplacian (interior pixels), keep if >= ``MIN_SHARPNESS``;
* brightness = mean gray value, keep if in [``MIN_BRIGHTNESS``, ``MAX_BRIGHTNESS``];
* dHash      = 64-bit difference hash: resize to 9x8, for each row compare left > right (8 bits per row), bits in
  row-major order, most significant bit first, written as 16 lowercase hex digits. Near-duplicate if the Hamming
  distance is <= ``MAX_DUPLICATE_HAMMING``.

The server recomputes everything itself (it never trusts the phone's values) and dedups only against hashes it
computed, so tiny resampling differences between platforms do not matter.
"""

from __future__ import annotations

import io
from dataclasses import dataclass
from typing import Iterable

import numpy as np
from PIL import Image

ANALYSIS_WIDTH = 160
MIN_SHARPNESS = 60.0
MIN_BRIGHTNESS = 35.0
MAX_BRIGHTNESS = 225.0
MAX_DUPLICATE_HAMMING = 6


@dataclass(frozen=True)
class FrameQuality:
    sharpness: float
    brightness: float
    dhash: str

    def rejection_reason(self) -> str | None:
        """None if the frame passes the quality gate, else a short reason."""
        if self.sharpness < MIN_SHARPNESS:
            return "blurry"
        if self.brightness < MIN_BRIGHTNESS:
            return "tooDark"
        if self.brightness > MAX_BRIGHTNESS:
            return "tooBright"
        return None


def analysis_gray(img: Image.Image) -> np.ndarray:
    """Grayscale float array of ``img`` resized to 160 px wide (aspect kept)."""
    gray = img.convert("L")
    w, h = gray.size
    if w != ANALYSIS_WIDTH:
        new_h = max(1, round(h * ANALYSIS_WIDTH / w))
        gray = gray.resize((ANALYSIS_WIDTH, new_h), Image.Resampling.BILINEAR)
    return np.asarray(gray, dtype=np.float64)


def sharpness(gray: np.ndarray) -> float:
    """Variance of the 4-neighbour Laplacian over interior pixels (0 for images smaller than 3x3)."""
    if gray.shape[0] < 3 or gray.shape[1] < 3:
        return 0.0
    c = gray[1:-1, 1:-1]
    lap = gray[:-2, 1:-1] + gray[2:, 1:-1] + gray[1:-1, :-2] + gray[1:-1, 2:] - 4.0 * c
    return float(lap.var())


def brightness(gray: np.ndarray) -> float:
    return float(gray.mean()) if gray.size else 0.0


def dhash(gray: np.ndarray) -> str:
    """64-bit dHash as 16 hex digits (9x8 resize, row-wise left > right)."""
    small = Image.fromarray(np.clip(gray, 0, 255).astype(np.uint8), mode="L").resize((9, 8), Image.Resampling.BILINEAR)
    px = np.asarray(small, dtype=np.int16)
    bits = (px[:, :8] > px[:, 1:]).flatten()
    value = 0
    for b in bits:
        value = (value << 1) | int(b)
    return f"{value:016x}"


def hamming(a: str, b: str) -> int:
    return (int(a, 16) ^ int(b, 16)).bit_count()


def min_hamming(h: str, others: Iterable[str]) -> int:
    """Smallest Hamming distance between ``h`` and any hash in ``others`` (65 if ``others`` is empty)."""
    arr = np.fromiter((int(o, 16) for o in others), dtype=np.uint64)
    if arr.size == 0:
        return 65
    x = np.bitwise_xor(arr, np.uint64(int(h, 16)))
    if hasattr(np, "bitwise_count"):
        return int(np.bitwise_count(x).min())
    return int(np.unpackbits(x.view(np.uint8).reshape(-1, 8), axis=1).sum(axis=1).min())


def is_near_duplicate(h: str, kept: Iterable[str]) -> bool:
    return min_hamming(h, kept) <= MAX_DUPLICATE_HAMMING


def measure(img: Image.Image) -> FrameQuality:
    gray = analysis_gray(img)
    return FrameQuality(sharpness=sharpness(gray), brightness=brightness(gray), dhash=dhash(gray))


def measure_bytes(data: bytes) -> FrameQuality:
    with Image.open(io.BytesIO(data)) as img:
        img.load()
        return measure(img)
