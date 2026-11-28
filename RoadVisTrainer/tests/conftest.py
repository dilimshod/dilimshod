from __future__ import annotations

import io
import json
import uuid

import numpy as np
import pytest
from PIL import Image

from roadvis_trainer.config import Settings
from roadvis_trainer.storage import Store

ADMIN = "admin-secret-for-tests"


@pytest.fixture
def settings(tmp_path) -> Settings:
    s = Settings(data_dir=tmp_path / "data", admin_token=ADMIN, gate_min_test_images=1)
    s.ensure_dirs()
    return s


@pytest.fixture
def store(settings) -> Store:
    return Store(settings.db_path)


@pytest.fixture
def app(settings):
    from roadvis_trainer.api import create_app

    return create_app(settings)


@pytest.fixture
def client(app):
    from fastapi.testclient import TestClient

    with TestClient(app) as c:
        yield c


@pytest.fixture
def token(store) -> str:
    return store.create_token("test-phone")


def textured_image(width: int = 960, height: int = 540, seed: int = 0, brightness: float = 120.0) -> Image.Image:
    """A sharp, mid-brightness RGB image with random structure (distinct per seed → distinct dHash)."""
    rng = np.random.default_rng(seed)
    coarse = rng.uniform(-80, 80, size=(height // 60 + 1, width // 60 + 1))
    base = np.kron(coarse, np.ones((60, 60)))[:height, :width]
    noise = rng.uniform(-40, 40, size=(height, width))
    gray = np.clip(brightness + base + noise, 0, 255).astype(np.uint8)
    return Image.fromarray(np.stack([gray] * 3, axis=-1), "RGB")


def jpeg_bytes(img: Image.Image | None = None, quality: int = 85, **kw) -> bytes:
    buf = io.BytesIO()
    (img or textured_image(**kw)).save(buf, "JPEG", quality=quality)
    return buf.getvalue()


def make_meta(sample_id: str | None = None, **over) -> dict:
    meta = {
        "id": sample_id or str(uuid.uuid4()),
        "capturedAt": "2026-11-26T10:00:00Z",
        "platform": "ios",
        "appVersion": "1.3",
        "model": {"name": "RoadVisDetector", "version": "bundled-yolo11s-960x544"},
        "image": {"width": 960, "height": 540, "orientation": "landscape"},
        "reasons": ["missedDetection"],
        "speedKmh": 42.0,
        "detections": [{"label": "car", "kind": "car", "confidence": 0.62, "box": [0.1, 0.2, 0.3, 0.2]}],
        "tracks": [{"id": 7, "kind": "car", "confidence": 0.71, "hits": 12, "missed": 1, "confirmed": True,
                    "box": [0.1, 0.2, 0.3, 0.2]}],
        "quality": {"sharpness": 140.2, "brightness": 96.0, "dhash": "f0e1d2c3b4a59687"},
    }
    meta.update(over)
    return meta


def upload(client, token: str | None, meta: dict | str | None = None, image: bytes | None = None, **kw):
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    meta_text = meta if isinstance(meta, str) else json.dumps(meta if meta is not None else make_meta())
    files = {"image": ("frame.jpg", image if image is not None else jpeg_bytes(), "image/jpeg"),
             "meta": ("meta.json", meta_text, "application/json")}
    return client.post("/api/v1/samples", headers=headers, files=files, **kw)
