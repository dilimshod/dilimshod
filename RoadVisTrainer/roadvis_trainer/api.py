"""HTTP API (contract section 3) plus admin endpoints.

Public (device bearer token):
    POST /api/v1/samples                         multipart: image (JPEG, <= 2 MB) + meta (JSON)
    GET  /api/v1/model/latest?platform=ios|android
    GET  /api/v1/model/{version}/files/{path}    raw file, Range supported

Admin (``ROADVIS_ADMIN_TOKEN``):
    GET  /api/v1/admin/dataset/export            YOLO zip (data.yaml, train/val, frozen test set in test/)
    GET  /api/v1/admin/model/current             current accepted weights (.pt) — fine-tune base for Colab
    POST /api/v1/admin/candidates                multipart: weights (best.pt) + optional metrics (JSON) → gate
    GET  /api/v1/admin/candidates/{id}           candidate status and gate report
    GET  /api/v1/admin/status                    counts per stage, last runs, current model

    GET  /healthz

Driver cabinet and web dashboard (RoadVis/docs/CABINET_API.md): see :mod:`roadvis_trainer.cabinet_api`.
"""

from __future__ import annotations

import json
import logging
import os
import re
import secrets
import shutil
import uuid
from datetime import datetime, timedelta
from pathlib import Path
from typing import Annotated, Literal

from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import FileResponse, JSONResponse, Response
from pydantic import BaseModel, ConfigDict, Field, ValidationError
from starlette.background import BackgroundTask
from starlette.datastructures import UploadFile
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.formparsers import MultiPartException

from . import __version__, publish
from .config import Settings
from .dataset import TEST_FROZEN_KEY, build_export_zip
from .storage import Store, iso, tokens_equal, utcnow

log = logging.getLogger(__name__)

VERSION_RE = re.compile(r"^\d{4}-\d{2}-\d{2}-\d{1,4}$")
CANDIDATE_RE = re.compile(r"^[0-9a-f]{32}$")


# Meta schema ---------------------------------------------------------------------------------------------------------
Box4 = Annotated[list[Annotated[float, Field(ge=-1.0, le=2.0)]], Field(min_length=4, max_length=4)]


class _Model(BaseModel):
    model_config = ConfigDict(extra="ignore", allow_inf_nan=False)


class ModelInfo(_Model):
    name: str = Field(max_length=200)
    version: str = Field(max_length=200)


class ImageInfo(_Model):
    width: int = Field(gt=0, le=10000)
    height: int = Field(gt=0, le=10000)
    orientation: Literal["landscape", "portrait"]


class DetectionIn(_Model):
    label: str = Field(default="", max_length=100)
    kind: str = Field(default="", max_length=100)
    confidence: float = Field(ge=0.0, le=1.0)
    box: Box4


class TrackIn(_Model):
    id: int
    kind: str = Field(default="", max_length=100)
    confidence: float = Field(default=0.0, ge=0.0, le=1.0)
    hits: int = Field(ge=0)
    missed: int = Field(default=0, ge=0)
    confirmed: bool
    box: Box4


class QualityIn(_Model):
    sharpness: float = Field(ge=0)
    brightness: float = Field(ge=0, le=255)
    dhash: str = Field(pattern=r"^[0-9a-fA-F]{16}$")


class SampleMeta(_Model):
    id: str
    capturedAt: datetime
    platform: Literal["ios", "android"]
    appVersion: str = Field(max_length=50)
    model: ModelInfo
    image: ImageInfo
    reasons: list[Annotated[str, Field(max_length=50)]] = Field(max_length=10)
    speedKmh: float | None = Field(default=None, ge=0, le=500)
    lat: float | None = Field(default=None, ge=-90, le=90)
    lon: float | None = Field(default=None, ge=-180, le=180)
    detections: list[DetectionIn] = Field(default_factory=list, max_length=1000)
    tracks: list[TrackIn] = Field(default_factory=list, max_length=1000)
    quality: QualityIn | None = None


def canonical_uuid(value: str) -> str | None:
    """Lower-case canonical UUID string, or None if ``value`` is not a UUID (also guards file names)."""
    try:
        u = uuid.UUID(value)
    except (ValueError, AttributeError, TypeError):
        return None
    return str(u) if str(u) == value.lower() else None


# Body size limits ----------------------------------------------------------------------------------------------------
class BodyTooLarge(Exception):
    pass


def _capped_request(request: Request, limit: int) -> Request:
    """A copy of ``request`` whose body stream raises :class:`BodyTooLarge` beyond ``limit`` bytes, so an oversized
    upload is refused without reading (or spooling) all of it. A larger ``Content-Length`` is refused up front."""
    cl = request.headers.get("content-length")
    if cl is not None:
        try:
            if int(cl) > limit:
                raise BodyTooLarge
        except ValueError:
            raise HTTPException(400, "bad Content-Length") from None
    receive = request.receive
    total = 0

    async def capped():
        nonlocal total
        message = await receive()
        if message.get("type") == "http.request":
            total += len(message.get("body", b""))
            if total > limit:
                raise BodyTooLarge
        return message

    return Request(request.scope, capped)


async def _parse_form(request: Request, limit: int, max_part: int, too_large: str):
    """Parses a multipart body with a hard byte cap: 413 when too large, 422 when malformed or not multipart."""
    ctype = request.headers.get("content-type", "")
    if not ctype.lower().startswith("multipart/form-data"):
        raise HTTPException(422, "expected multipart/form-data")
    try:
        capped = _capped_request(request, limit)
        return await capped.form(max_files=4, max_fields=8, max_part_size=max_part)
    except BodyTooLarge:
        raise HTTPException(413, too_large) from None
    except (MultiPartException, StarletteHTTPException) as exc:
        detail = getattr(exc, "message", None) or getattr(exc, "detail", "")
        if "maximum size" in str(detail):
            raise HTTPException(413, f"part too large: {detail}") from None
        raise HTTPException(422, f"invalid multipart body: {detail}") from None


async def _read_part(value, limit: int) -> bytes | None:
    """Bytes of a multipart part (file or text field); None if larger than ``limit``."""
    if isinstance(value, UploadFile):
        data = await value.read(limit + 1)
        return None if len(data) > limit else data
    data = str(value).encode("utf-8")
    return None if len(data) > limit else data


class RootPathMiddleware:
    """Sets the ASGI ``root_path`` (public prefix such as ``/roadvis``) so requests work whether the reverse proxy
    strips the prefix (``proxy_pass http://127.0.0.1:8601/;``) or forwards it unchanged; Starlette routing removes a
    leading ``root_path`` itself. (uvicorn's ``--root-path`` would also prepend it to the path, so it is not used.)"""

    def __init__(self, app, root_path: str):
        self.app = app
        self.root_path = root_path

    async def __call__(self, scope, receive, send):
        if scope["type"] in ("http", "websocket") and not scope.get("root_path"):
            scope = dict(scope, root_path=self.root_path)
            # ASGI: ``path`` includes ``root_path``. When nginx stripped the prefix, put it back so mounted apps
            # (static files) and URL building see the public path; routing strips it again.
            path = scope.get("path", "")
            if path != self.root_path and not path.startswith(self.root_path + "/"):
                scope["path"] = self.root_path + path
                raw = scope.get("raw_path")
                if raw is not None:
                    scope["raw_path"] = self.root_path.encode() + raw
        await self.app(scope, receive, send)


# App -----------------------------------------------------------------------------------------------------------------
def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    settings.ensure_dirs()
    store = Store(settings.db_path)

    app = FastAPI(title="RoadVis Trainer", version=__version__,
                  docs_url="/docs" if settings.enable_docs else None, redoc_url=None,
                  openapi_url="/openapi.json" if settings.enable_docs else None)
    app.state.settings = settings
    app.state.store = store
    if settings.root_path:
        app.add_middleware(RootPathMiddleware, root_path=settings.root_path)

    def bearer(request: Request) -> str:
        header = request.headers.get("authorization", "")
        scheme, _, value = header.partition(" ")
        return value.strip() if scheme.lower() == "bearer" else ""

    def unauthorized(detail: str = "invalid or missing token") -> HTTPException:
        return HTTPException(401, detail, headers={"WWW-Authenticate": "Bearer"})

    def is_admin(token: str) -> bool:
        return bool(settings.admin_token) and bool(token) and tokens_equal(token, settings.admin_token)

    def require_device(request: Request) -> dict:
        token = bearer(request)
        device = store.device_for_token(token)
        if device is not None:
            return device
        if is_admin(token):
            return {"id": 0, "name": "admin"}
        raise unauthorized()

    def require_admin(request: Request) -> None:
        if not is_admin(bearer(request)):
            raise unauthorized()

    # Health -----------------------------------------------------------------------------------------------------------
    @app.get("/healthz")
    def healthz():
        store.get_state("worker_heartbeat")  # touches the database
        return {"status": "ok", "version": __version__}

    # Samples ----------------------------------------------------------------------------------------------------------
    @app.post("/api/v1/samples", status_code=201)
    async def upload_sample(request: Request):
        device = require_device(request)
        limit = settings.max_image_bytes + settings.max_meta_bytes + 64 * 1024
        form = await _parse_form(request, limit, settings.max_meta_bytes,
                                 f"request too large (image max {settings.max_image_bytes} bytes)")
        try:
            image_part, meta_part = form.get("image"), form.get("meta")
            if image_part is None or meta_part is None:
                raise HTTPException(422, "parts 'image' and 'meta' are required")
            if not isinstance(image_part, UploadFile):
                raise HTTPException(422, "'image' must be a file part (with a filename)")
            image = await _read_part(image_part, settings.max_image_bytes)
            if image is None:
                raise HTTPException(413, f"image too large (max {settings.max_image_bytes} bytes)")
            meta_raw = await _read_part(meta_part, settings.max_meta_bytes)
            if meta_raw is None:
                raise HTTPException(413, "meta too large")
        finally:
            await form.close()

        try:
            meta = SampleMeta.model_validate_json(meta_raw)
        except ValidationError as exc:
            errors = [{"loc": e["loc"], "msg": e["msg"]} for e in exc.errors()[:10]]
            return JSONResponse({"detail": "invalid meta", "errors": json.loads(json.dumps(errors, default=str))},
                                status_code=422)
        sample_id = canonical_uuid(meta.id)
        if sample_id is None:
            raise HTTPException(422, "invalid meta: id must be a UUID")
        if len(image) < 4 or image[:3] != b"\xff\xd8\xff":
            raise HTTPException(422, "image must be a JPEG")
        width, height = _jpeg_size(image)
        if width is None:
            raise HTTPException(422, "image is not a decodable JPEG")

        if store.sample_exists(sample_id):
            raise HTTPException(409, "duplicate id")
        now = utcnow()
        if device["id"] and store.uploads_today(device["id"], now.strftime("%Y-%m-%d")) >= settings.daily_limit:
            tomorrow = (now + timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
            raise HTTPException(429, f"rate limit: max {settings.daily_limit} samples per device per day",
                                headers={"Retry-After": str(int((tomorrow - now).total_seconds()) + 1)})

        meta_dict = meta.model_dump(mode="json")
        meta_dict["id"] = sample_id
        img_path = settings.incoming_dir / f"{sample_id}.jpg"
        meta_path = settings.incoming_dir / f"{sample_id}.json"
        suffix = ".part-" + secrets.token_hex(4)
        tmp_img, tmp_meta = img_path.with_name(img_path.name + suffix), meta_path.with_name(meta_path.name + suffix)
        try:
            store.insert_sample(sample_id=sample_id, device_id=device["id"], meta=meta_dict, width=width,
                                height=height, now=now, status="receiving")
        except Exception as exc:  # sqlite3.IntegrityError: concurrent upload of the same id
            if "UNIQUE" in str(exc) or "PRIMARY KEY" in str(exc):
                raise HTTPException(409, "duplicate id") from None
            raise
        try:
            tmp_img.write_bytes(image)
            tmp_meta.write_text(json.dumps(meta_dict), "utf-8")
            os.replace(tmp_img, img_path)
            os.replace(tmp_meta, meta_path)
        except OSError:
            for p in (tmp_img, tmp_meta, img_path, meta_path):
                p.unlink(missing_ok=True)
            store.delete_sample_row(sample_id)
            log.exception("could not store sample %s", sample_id)
            raise HTTPException(500, "could not store sample") from None
        store.set_sample_status(sample_id, "queued")
        return JSONResponse({"id": meta.id, "status": "queued"}, status_code=201)

    # Models -----------------------------------------------------------------------------------------------------------
    @app.get("/api/v1/model/latest")
    def model_latest(request: Request, platform: Literal["ios", "android"] | None = Query(default=None)):
        require_device(request)
        manifest = publish.find_latest(store, platform)
        if manifest is None:
            return Response(status_code=204)
        return JSONResponse(manifest, headers={"Cache-Control": "no-cache"})

    @app.get("/api/v1/model/{version}/files/{path:path}")
    def model_file(request: Request, version: str, path: str):
        require_device(request)
        if not VERSION_RE.match(version) or not _safe_relpath(path):
            raise HTTPException(404, "not found")
        row = store.get_version(version)
        if row is None or row["status"] != "published" or path not in publish.served_paths(row["manifest"]):
            raise HTTPException(404, "not found")
        vdir = (settings.models_dir / version).resolve()
        target = (vdir / path).resolve()
        if not target.is_relative_to(vdir) or not target.is_file():
            raise HTTPException(404, "not found")
        return FileResponse(target, media_type="application/octet-stream",
                            headers={"Cache-Control": "public, max-age=31536000, immutable"})

    # Admin ------------------------------------------------------------------------------------------------------------
    @app.get("/api/v1/admin/dataset/export")
    def admin_export(request: Request, include_test: bool = True):
        require_admin(request)
        out = settings.tmp_dir / f"export-{secrets.token_hex(6)}.zip"
        try:
            build_export_zip(settings, out, include_test=include_test)
        except Exception:
            out.unlink(missing_ok=True)
            raise
        name = f"roadvis-dataset-{utcnow().strftime('%Y%m%d-%H%M%S')}.zip"
        return FileResponse(out, media_type="application/zip", filename=name,
                            background=BackgroundTask(out.unlink, missing_ok=True))

    @app.get("/api/v1/admin/model/current")
    def admin_current_model(request: Request):
        require_admin(request)
        for v in store.published_versions():
            p = settings.models_dir / v["version"] / "weights.pt"
            if p.is_file():
                return FileResponse(p, media_type="application/octet-stream", filename=f"roadvis-{v['version']}.pt",
                                    headers={"X-RoadVis-Version": v["version"]})
        raise HTTPException(404, "no accepted model yet")

    @app.post("/api/v1/admin/candidates", status_code=202)
    async def admin_candidate(request: Request):
        require_admin(request)
        form = await _parse_form(request, settings.max_candidate_bytes + 1024 * 1024, 4 * 1024 * 1024,
                                 "candidate too large")
        cand_id = uuid.uuid4().hex
        cdir = settings.candidates_dir / cand_id
        try:
            weights = form.get("weights")
            if not isinstance(weights, UploadFile):
                raise HTTPException(422, "file part 'weights' (best.pt) is required")
            metrics = None
            raw = form.get("metrics")
            if raw is not None:
                data = await _read_part(raw, 4 * 1024 * 1024)
                try:
                    metrics = json.loads(data or b"null")
                except ValueError:
                    raise HTTPException(422, "metrics must be JSON") from None
                if metrics is not None and not isinstance(metrics, dict):
                    raise HTTPException(422, "metrics must be a JSON object")
            cdir.mkdir(parents=True)
            dest = cdir / "best.pt"
            size = 0
            with dest.open("wb") as f:
                while chunk := await weights.read(1 << 20):
                    size += len(chunk)
                    f.write(chunk)
            with dest.open("rb") as f:
                head = f.read(4)
            if size == 0 or head[:2] != b"PK":
                raise HTTPException(422, "weights must be a PyTorch .pt file")
        except HTTPException:
            shutil.rmtree(cdir, ignore_errors=True)
            raise
        finally:
            await form.close()
        store.insert_candidate(cand_id, str(dest), metrics)
        log.info("candidate %s received (%d bytes)", cand_id, size)
        return JSONResponse({"id": cand_id, "status": "pending"}, status_code=202)

    @app.get("/api/v1/admin/candidates/{cand_id}")
    def admin_candidate_status(request: Request, cand_id: str):
        require_admin(request)
        if not CANDIDATE_RE.match(cand_id):
            raise HTTPException(404, "not found")
        cand = store.get_candidate(cand_id)
        if cand is None:
            raise HTTPException(404, "not found")
        report = None
        if cand.get("report_path") and Path(cand["report_path"]).is_file():
            report = json.loads(Path(cand["report_path"]).read_text())
        return {"id": cand_id, "status": cand["status"], "createdAt": cand["created_at"],
                "finishedAt": cand["finished_at"], "version": cand["version"], "message": cand["message"],
                "report": report}

    @app.get("/api/v1/admin/status")
    def admin_status(request: Request):
        require_admin(request)
        counts = store.status_counts()
        versions = store.published_versions()
        current = None
        if versions:
            m = versions[0]["manifest"]
            current = {"version": m["version"], "createdAt": m["createdAt"], "metrics": m["metrics"],
                       "ios": m.get("ios") is not None, "android": m.get("android") is not None}
        return {
            "samples": counts["by_status"],
            "dataset": {**{s: counts["by_split"].get(s, 0) for s in ("train", "val", "test")},
                        "cap": settings.dataset_cap, "testFrozen": store.get_state(TEST_FROZEN_KEY) == "1",
                        "testFreezeAt": settings.test_freeze_at},
            "rejectedByReason": counts["rejected_by_reason"],
            "worker": {"heartbeat": store.get_state("worker_heartbeat"),
                       "lastRun": store.get_state("worker_last_run")},
            "candidates": store.recent_candidates(5),
            "currentModel": current,
            "versions": [v["version"] for v in versions],
            "serverTime": iso(),
        }

    from .cabinet_api import register_cabinet

    register_cabinet(app, settings, store)
    return app


def _safe_relpath(path: str) -> bool:
    """Rejects absolute paths, backslashes, NULs, empty and dot segments (defence in depth; the file endpoint also
    serves only paths listed in the manifest and checks the resolved location)."""
    if not path or len(path) > 512 or path.startswith("/") or "\\" in path or "\x00" in path:
        return False
    return all(seg not in ("", ".", "..") for seg in path.split("/"))


def _jpeg_size(data: bytes) -> tuple[int | None, int | None]:
    import io

    from PIL import Image

    try:
        with Image.open(io.BytesIO(data)) as img:
            if img.format != "JPEG":
                return None, None
            img.verify()
            return img.size
    except Exception:  # noqa: BLE001
        return None, None

