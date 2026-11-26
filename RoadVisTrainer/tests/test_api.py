"""Auth, multipart validation, every status code, rate limit, model endpoints, admin endpoints."""

import io
import json
import zipfile

import pytest
from conftest import ADMIN, jpeg_bytes, make_meta, textured_image, upload

from roadvis_trainer.storage import hash_token


# Auth ----------------------------------------------------------------------------------------------------------------
def test_tokens_are_stored_hashed(store, token):
    with store.connect() as db:
        row = db.execute("SELECT token_hash FROM tokens").fetchone()
    assert row["token_hash"] == hash_token(token)
    assert token not in json.dumps(store.list_tokens())


def test_upload_requires_valid_token(client, token):
    assert upload(client, None).status_code == 401
    r = upload(client, "rvt_wrong")
    assert r.status_code == 401
    assert r.headers["www-authenticate"] == "Bearer"
    assert upload(client, token).status_code == 201


def test_revoked_token_is_rejected(client, store, token):
    assert store.revoke_token("test-phone") == 1
    assert upload(client, token).status_code == 401


def test_admin_endpoints_need_admin_token(client, token):
    for path in ("/api/v1/admin/status", "/api/v1/admin/dataset/export", "/api/v1/admin/model/current"):
        assert client.get(path).status_code == 401
        assert client.get(path, headers={"Authorization": f"Bearer {token}"}).status_code == 401
    assert client.get("/api/v1/admin/status", headers={"Authorization": f"Bearer {ADMIN}"}).status_code == 200


def test_admin_disabled_without_admin_token(tmp_path):
    from fastapi.testclient import TestClient

    from roadvis_trainer.api import create_app
    from roadvis_trainer.config import Settings

    app = create_app(Settings(data_dir=tmp_path / "d", admin_token=""))
    with TestClient(app) as c:
        assert c.get("/api/v1/admin/status", headers={"Authorization": "Bearer "}).status_code == 401
        assert c.get("/api/v1/admin/status").status_code == 401


def test_healthz(client):
    r = client.get("/healthz")
    assert r.status_code == 200 and r.json()["status"] == "ok"


# Samples ---------------------------------------------------------------------------------------------------------------
def test_upload_201_stores_files_and_row(client, token, settings, store):
    meta = make_meta()
    r = upload(client, token, meta)
    assert r.status_code == 201
    assert r.json() == {"id": meta["id"], "status": "queued"}
    assert (settings.incoming_dir / f"{meta['id']}.jpg").exists()
    stored = json.loads((settings.incoming_dir / f"{meta['id']}.json").read_text())
    assert stored["tracks"][0]["hits"] == 12
    assert store.queued_samples(10)[0]["id"] == meta["id"]
    assert not list(settings.incoming_dir.glob("*.part-*"))


def test_upload_uppercase_uuid_is_canonicalized(client, token, settings):
    meta = make_meta()
    upper = meta["id"].upper()
    r = upload(client, token, make_meta(upper))
    assert r.status_code == 201
    assert (settings.incoming_dir / f"{meta['id'].lower()}.jpg").exists()
    assert upload(client, token, make_meta(meta["id"].lower())).status_code == 409


def test_upload_409_duplicate(client, token):
    meta = make_meta()
    assert upload(client, token, meta).status_code == 201
    assert upload(client, token, meta).status_code == 409


def test_upload_413_image_too_large(client, token, settings):
    big = b"\xff\xd8\xff\xe0" + b"\0" * (settings.max_image_bytes + 10)
    assert upload(client, token, image=big).status_code == 413


def test_upload_413_by_content_length_before_reading(client, token, settings):
    huge = settings.max_image_bytes * 3
    body = b"x" * 16
    r = client.post("/api/v1/samples", content=body,
                    headers={"Authorization": f"Bearer {token}", "Content-Length": str(huge),
                             "Content-Type": "multipart/form-data; boundary=abc"})
    assert r.status_code == 413


def test_upload_413_streamed_body_without_content_length(app, token, settings):
    """A chunked body is cut off as soon as it exceeds the cap (no Content-Length to trust)."""
    import anyio

    sent = {"chunks": 0}
    chunk = b"a" * (256 * 1024)
    total_chunks = 40  # 10 MB

    async def run():
        boundary = "xyz"
        head = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"image\"; filename=\"a.jpg\"\r\n"
                "Content-Type: image/jpeg\r\n\r\n").encode()
        messages = [head] + [chunk] * total_chunks
        responses = []

        async def receive():
            i = sent["chunks"]
            sent["chunks"] += 1
            if i < len(messages):
                return {"type": "http.request", "body": messages[i], "more_body": True}
            return {"type": "http.request", "body": b"", "more_body": False}

        async def send(message):
            responses.append(message)

        scope = {"type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1", "method": "POST",
                 "scheme": "http", "path": "/api/v1/samples", "raw_path": b"/api/v1/samples", "root_path": "",
                 "query_string": b"", "server": ("test", 80), "client": ("1.2.3.4", 1),
                 "headers": [(b"authorization", f"Bearer {token}".encode()),
                             (b"content-type", f"multipart/form-data; boundary={boundary}".encode()),
                             (b"transfer-encoding", b"chunked")]}
        await app(scope, receive, send)
        return responses

    responses = anyio.run(run)
    start = next(m for m in responses if m["type"] == "http.response.start")
    assert start["status"] == 413
    assert sent["chunks"] < total_chunks  # stopped reading early


@pytest.mark.parametrize("mutate", [
    lambda m: m.pop("id"),
    lambda m: m.update(id="not-a-uuid"),
    lambda m: m.update(id="../../etc/passwd"),
    lambda m: m.update(platform="windows"),
    lambda m: m.pop("image"),
    lambda m: m["image"].update(orientation="square"),
    lambda m: m.update(reasons="missedDetection"),
    lambda m: m["detections"][0].update(box=[0.1, 0.2, 0.3]),
    lambda m: m["detections"][0].update(confidence=1.5),
    lambda m: m["tracks"][0].update(hits=-1),
    lambda m: m.update(capturedAt="yesterday"),
    lambda m: m.update(lat=123.0),
    lambda m: m["quality"].update(dhash="xyz"),
])
def test_upload_422_invalid_meta(client, token, mutate):
    meta = make_meta()
    mutate(meta)
    r = upload(client, token, meta)
    assert r.status_code == 422, r.text


def test_upload_422_meta_not_json(client, token):
    assert upload(client, token, "{not json").status_code == 422


def test_upload_422_missing_parts_and_not_multipart(client, token):
    h = {"Authorization": f"Bearer {token}"}
    r = client.post("/api/v1/samples", headers=h, files={"meta": ("m.json", json.dumps(make_meta()), "application/json")})
    assert r.status_code == 422
    r = client.post("/api/v1/samples", headers=h, files={"image": ("a.jpg", jpeg_bytes(), "image/jpeg")})
    assert r.status_code == 422
    r = client.post("/api/v1/samples", headers=h, json=make_meta())
    assert r.status_code == 422


def test_upload_422_image_not_jpeg(client, token):
    buf = io.BytesIO()
    textured_image(64, 64).save(buf, "PNG")
    assert upload(client, token, image=buf.getvalue()).status_code == 422
    assert upload(client, token, image=b"\xff\xd8\xff garbage").status_code == 422


def test_meta_as_plain_field_is_accepted(client, token):
    r = client.post("/api/v1/samples", headers={"Authorization": f"Bearer {token}"},
                    files={"image": ("a.jpg", jpeg_bytes(), "image/jpeg")}, data={"meta": json.dumps(make_meta())})
    assert r.status_code == 201


def test_optional_fields_may_be_omitted(client, token):
    meta = make_meta()
    for k in ("speedKmh", "detections", "tracks", "quality"):
        meta.pop(k)
    meta["extraFieldFromNewerApp"] = {"x": 1}
    assert upload(client, token, meta).status_code == 201


def test_rate_limit_429_per_device_per_day(client, store, settings):
    settings.daily_limit = 3
    t1, t2 = store.create_token("a"), store.create_token("b")
    img = jpeg_bytes(textured_image(160, 90))
    for _ in range(3):
        assert upload(client, t1, image=img).status_code == 201
    r = upload(client, t1, image=img)
    assert r.status_code == 429
    assert int(r.headers["retry-after"]) > 0
    assert upload(client, t2, image=img).status_code == 201  # other device unaffected


def test_rate_limit_default_is_600(settings):
    assert settings.daily_limit == 600
    assert settings.max_image_bytes == 2 * 1024 * 1024


# Models ----------------------------------------------------------------------------------------------------------------
def _fake_version(settings, store, version="2026-12-01-1", ios=True):
    from roadvis_trainer import publish

    vdir = settings.models_dir / version
    (vdir / "RoadVisDetector.mlpackage" / "Data").mkdir(parents=True)
    (vdir / "RoadVisDetectorPortrait.mlpackage").mkdir(parents=True)
    (vdir / "RoadVisDetector.mlpackage" / "Manifest.json").write_text('{"a": 1}')
    (vdir / "RoadVisDetector.mlpackage" / "Data" / "model.bin").write_bytes(bytes(range(256)) * 4)
    (vdir / "RoadVisDetectorPortrait.mlpackage" / "Manifest.json").write_text('{"b": 2}')
    (vdir / "yolo-roadvis.onnx").write_bytes(b"onnx" * 100)
    (vdir / "weights.pt").write_bytes(b"PK\x03\x04weights")
    (settings.models_dir / "secret.txt").write_text("nope")
    m = publish.build_manifest(version=version, created_at="2026-12-01T00:00:00Z", base_model="yolo11s",
                               metrics={"testImages": 3, "map50": 0.7, "precision": 0.8, "recall": 0.6,
                                        "previous": {"map50": 0.6}},
                               version_dir=vdir, ios_ok=ios, android_ok=True)
    store.insert_version(version, m, None)
    return m


def test_model_latest_204_then_200(client, token, settings, store):
    h = {"Authorization": f"Bearer {token}"}
    assert client.get("/api/v1/model/latest?platform=ios", headers=h).status_code == 204
    assert client.get("/api/v1/model/latest?platform=ios").status_code == 401
    assert client.get("/api/v1/model/latest?platform=windows", headers=h).status_code == 422
    m = _fake_version(settings, store)
    r = client.get("/api/v1/model/latest?platform=android", headers=h)
    assert r.status_code == 200 and r.json() == m


def test_model_latest_skips_versions_without_platform(client, token, settings, store):
    h = {"Authorization": f"Bearer {token}"}
    _fake_version(settings, store, "2026-12-01-1", ios=True)
    _fake_version(settings, store, "2026-12-02-1", ios=False)
    assert client.get("/api/v1/model/latest?platform=android", headers=h).json()["version"] == "2026-12-02-1"
    assert client.get("/api/v1/model/latest?platform=ios", headers=h).json()["version"] == "2026-12-01-1"


def test_model_files_served_with_range(client, token, settings, store):
    h = {"Authorization": f"Bearer {token}"}
    _fake_version(settings, store)
    base = "/api/v1/model/2026-12-01-1/files/"
    r = client.get(base + "RoadVisDetector.mlpackage/Manifest.json", headers=h)
    assert r.status_code == 200 and r.content == b'{"a": 1}'
    assert r.headers.get("accept-ranges") == "bytes"
    r = client.get(base + "RoadVisDetector.mlpackage/Data/model.bin", headers={**h, "Range": "bytes=10-19"})
    assert r.status_code == 206
    assert r.content == bytes(range(10, 20))
    assert r.headers["content-range"].startswith("bytes 10-19/1024")
    assert client.get(base + "yolo-roadvis.onnx", headers=h).content == b"onnx" * 100
    assert client.get(base + "yolo-roadvis.onnx").status_code == 401


@pytest.mark.parametrize("path", [
    "weights.pt", "manifest.json", "../secret.txt", "..%2Fsecret.txt", "RoadVisDetector.mlpackage/../../secret.txt",
    "%2e%2e/secret.txt", "/etc/passwd", "RoadVisDetector.mlpackage//Manifest.json", "nope.bin",
])
def test_model_files_no_traversal(client, token, settings, store, path):
    _fake_version(settings, store)
    r = client.get(f"/api/v1/model/2026-12-01-1/files/{path}", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 404
    assert b"nope" not in r.content


def test_model_files_bad_version(client, token, settings, store):
    _fake_version(settings, store)
    h = {"Authorization": f"Bearer {token}"}
    assert client.get("/api/v1/model/..%2F..%2Fx/files/yolo-roadvis.onnx", headers=h).status_code == 404
    assert client.get("/api/v1/model/2026-12-09-1/files/yolo-roadvis.onnx", headers=h).status_code == 404


def test_root_path_behind_proxy(settings, token):
    """With ROOT_PATH=/roadvis both nginx styles work: prefix stripped or forwarded unchanged."""
    from fastapi.testclient import TestClient

    from roadvis_trainer.api import create_app

    settings.root_path = "/roadvis"
    with TestClient(create_app(settings)) as c:
        assert c.get("/healthz").status_code == 200
        assert c.get("/roadvis/healthz").status_code == 200
        r = c.get("/roadvis/api/v1/model/latest", headers={"Authorization": f"Bearer {token}"})
        assert r.status_code == 204


def test_root_path_from_env(monkeypatch):
    from roadvis_trainer.config import Settings

    monkeypatch.setenv("ROOT_PATH", "roadvis/")
    assert Settings.from_env().root_path == "/roadvis"
    monkeypatch.setenv("ROADVIS_ROOT_PATH", "/rv")
    assert Settings.from_env().root_path == "/rv"


# Admin -----------------------------------------------------------------------------------------------------------------
ADMIN_H = {"Authorization": f"Bearer {ADMIN}"}


def _kept(settings, store, sid, split, labels="0 0.5 0.5 0.2 0.2\n"):
    from roadvis_trainer import dataset

    store.insert_sample(sample_id=sid, device_id=1, meta={"platform": "ios"}, width=160, height=90)
    dataset.write_sample(settings, split, sid, jpeg_bytes(textured_image(160, 90)), labels)
    store.mark_kept(sid, split, "0" * 16, 100.0, 100.0, 1)


def test_admin_export_zip_layout(client, settings, store):
    _kept(settings, store, "a1", "train")
    _kept(settings, store, "b2", "val")
    _kept(settings, store, "c3", "test")
    r = client.get("/api/v1/admin/dataset/export", headers=ADMIN_H)
    assert r.status_code == 200 and r.headers["content-type"] == "application/zip"
    z = zipfile.ZipFile(io.BytesIO(r.content))
    names = set(z.namelist())
    assert {"data.yaml", "images/train/a1.jpg", "labels/train/a1.txt", "images/val/b2.jpg", "labels/val/b2.txt",
            "test/images/c3.jpg", "test/labels/c3.txt"} <= names
    import yaml

    cfg = yaml.safe_load(z.read("data.yaml"))
    assert cfg["train"] == "images/train" and cfg["val"] == "images/val" and cfg["test"] == "test/images"
    assert cfg["names"] == {0: "car", 1: "truck", 2: "bus", 3: "motorcycle", 4: "bicycle", 5: "person",
                            6: "traffic_light", 7: "stop_sign"}
    r = client.get("/api/v1/admin/dataset/export?include_test=false", headers=ADMIN_H)
    names = set(zipfile.ZipFile(io.BytesIO(r.content)).namelist())
    assert not any(n.startswith("test/") for n in names)
    assert not list(settings.tmp_dir.glob("export-*.zip"))  # temp zip removed after sending


def test_admin_candidate_upload_and_status(client, settings, store):
    files = {"weights": ("best.pt", b"PK\x03\x04" + b"\0" * 100, "application/octet-stream"),
             "metrics": ("metrics.json", json.dumps({"baseModel": "yolo11s", "epochs": 50}), "application/json")}
    r = client.post("/api/v1/admin/candidates", headers=ADMIN_H, files=files)
    assert r.status_code == 202
    cid = r.json()["id"]
    assert r.json()["status"] == "pending"
    cand = store.get_candidate(cid)
    assert cand["status"] == "pending" and json.loads(cand["training_metrics"])["epochs"] == 50
    s = client.get(f"/api/v1/admin/candidates/{cid}", headers=ADMIN_H).json()
    assert s["status"] == "pending"
    status = client.get("/api/v1/admin/status", headers=ADMIN_H).json()
    assert status["candidates"][0]["id"] == cid
    assert status["currentModel"] is None


def test_admin_candidate_validation(client, settings):
    assert client.post("/api/v1/admin/candidates", headers=ADMIN_H,
                       files={"metrics": ("m.json", "{}", "application/json")}).status_code == 422
    assert client.post("/api/v1/admin/candidates", headers=ADMIN_H,
                       files={"weights": ("best.pt", b"not a zip", "application/octet-stream")}).status_code == 422
    assert client.post("/api/v1/admin/candidates", headers=ADMIN_H,
                       files={"weights": ("best.pt", b"PK..", "application/octet-stream"),
                              "metrics": ("m.json", "[1,2]", "application/json")}).status_code == 422
    assert not any(settings.candidates_dir.iterdir())
    settings.max_candidate_bytes = 10
    big = {"weights": ("best.pt", b"PK" + b"\0" * (2 * 1024 * 1024), "application/octet-stream")}
    assert client.post("/api/v1/admin/candidates", headers=ADMIN_H, files=big).status_code == 413


def test_admin_current_model(client, settings, store):
    assert client.get("/api/v1/admin/model/current", headers=ADMIN_H).status_code == 404
    _fake_version(settings, store)
    r = client.get("/api/v1/admin/model/current", headers=ADMIN_H)
    assert r.status_code == 200 and r.content.startswith(b"PK")
    assert r.headers["x-roadvis-version"] == "2026-12-01-1"


def test_admin_status_counts(client, settings, store, token):
    upload(client, token)
    _kept(settings, store, "k1", "test")
    store.insert_sample(sample_id="r1", device_id=1, meta={}, width=1, height=1)
    store.mark_rejected("r1", "blurry")
    s = client.get("/api/v1/admin/status", headers=ADMIN_H).json()
    assert s["samples"] == {"queued": 1, "kept": 1, "rejected": 1}
    assert s["dataset"]["test"] == 1 and s["dataset"]["testFrozen"] is False
    assert s["rejectedByReason"] == {"blurry": 1}


def test_tokens_never_logged(client, token, caplog):
    import logging

    caplog.set_level(logging.DEBUG)
    upload(client, token)
    upload(client, "rvt_bad_token_value")
    client.get("/api/v1/admin/status", headers=ADMIN_H)
    text = caplog.text
    assert token not in text and "rvt_bad_token_value" not in text and ADMIN not in text
