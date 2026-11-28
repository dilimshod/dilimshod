"""Driver cabinet API and web dashboard (RoadVis/docs/CABINET_API.md).

Device bearer token (the app):
    POST   /api/v1/devices/register          no auth, 10 per IP per hour → 201 {deviceToken, driverId, driverName}
    GET    /api/v1/me                         also web session
    PATCH  /api/v1/me                         also web session
    DELETE /api/v1/me                         also web session → 204, deletes profile, trips, sessions, tokens
    GET    /api/v1/me/devices                 also web session: devices and web sessions of the driver
    POST   /api/v1/trips                      idempotent by id: 201 created / 200 replaced / 413 / 422 / 429
    GET    /api/v1/trips?limit=&before=       also web session: JSON array of trip summaries (no track)
    GET    /api/v1/trips/{id}                 also web session: full trip
    DELETE /api/v1/trips/{id}                 also web session → 204
    POST   /api/v1/auth/qr/approve            {challengeId, nonce} → 200 {ok} / 404 / 409 / 401
    POST   /api/v1/auth/logout-all            also web session: deletes all web sessions of the driver

Website:
    POST   /api/v1/auth/qr                    → {challengeId, qr, expiresAt}; binds polling to this browser
    GET    /api/v1/auth/qr/{challengeId}      → {status: pending|approved|expired|denied}; sets rv_session once
    POST   /api/v1/auth/logout                deletes the current web session
    GET    /api/v1/dashboard/summary?days=30|90|365
    GET    /api/v1/dashboard/charts?days=30|90|365
    POST   /api/v1/admin/login                {token} → admin session cookie (rv_admin)
    POST   /api/v1/admin/logout
    GET    /api/v1/admin/overview             drivers with totals (admin session or admin bearer token)
    GET    /, /login, /trips, /trips/{id}, /profile, /admin, /qr   → the single-page app (index.html)
    GET    /static/...                        assets (vendored MapLibre GL JS, ECharts, qrcode-generator, fonts)

CSRF: cookie-authenticated POST/PATCH/PUT/DELETE requests must carry ``X-RoadVis: 1`` (plus SameSite=Lax cookies).
"""

from __future__ import annotations

import hashlib
import html
import ipaddress
import json
import logging
import re
import secrets
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Annotated, Literal

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator, model_validator
from starlette.datastructures import Headers, MutableHeaders

from . import __version__, cabinet
from .config import Settings
from .storage import Store, hash_token, iso, tokens_equal, utcnow

log = logging.getLogger(__name__)

WEB_DIR = Path(__file__).parent / "web"
STATIC_DIR = WEB_DIR / "static"

SESSION_COOKIE = "rv_session"
ADMIN_COOKIE = "rv_admin"
QR_COOKIE = "rv_qr"
CSRF_HEADER = "x-roadvis"
UNSAFE_METHODS = frozenset({"POST", "PATCH", "PUT", "DELETE"})

MAP_HOST = "https://tiles.openfreemap.org"
CSP = ("default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
       f"img-src 'self' data: blob: {MAP_HOST}; font-src 'self'; connect-src 'self' {MAP_HOST}; "
       "worker-src 'self' blob:; child-src 'self' blob:; frame-ancestors 'none'; base-uri 'self'; "
       "form-action 'self'; object-src 'none'")

SPA_ROUTES = ("/", "/login", "/trips", "/trips/{trip_id}", "/profile", "/admin", "/qr")


# Client IP behind Cloudflare + nginx ---------------------------------------------------------------------------------
Network = ipaddress.IPv4Network | ipaddress.IPv6Network


def parse_networks(spec: str) -> list[Network]:
    nets: list[Network] = []
    for part in (spec or "").split(","):
        part = part.strip()
        if part and part != "*":
            nets.append(ipaddress.ip_network(part, strict=False))
    return nets


def _ip(value: str | None):
    if not value:
        return None
    try:
        return ipaddress.ip_address(value.strip().strip("[]"))
    except ValueError:
        return None


def _trusted(addr, nets: list[Network]) -> bool:
    if addr is None:
        return False
    if getattr(addr, "ipv4_mapped", None):
        addr = addr.ipv4_mapped
    return any(addr.version == n.version and addr in n for n in nets)


def client_ip(peer: str | None, headers, trusted: list[Network]) -> str:
    """The client address for rate limits. Proxy headers count only when the TCP peer is the local reverse proxy:
    ``CF-Connecting-IP`` first (Cloudflare), then the right-most untrusted ``X-Forwarded-For`` entry."""
    peer_ip = _ip(peer)
    if not _trusted(peer_ip, trusted):
        return str(peer_ip) if peer_ip else (peer or "unknown")
    cf = _ip(headers.get("cf-connecting-ip"))
    if cf is not None:
        return str(cf)
    chain = [_ip(p) for p in (headers.get("x-forwarded-for") or "").split(",")]
    chain = [a for a in chain if a is not None]
    for addr in reversed(chain):
        if not _trusted(addr, trusted):
            return str(addr)
    return str(chain[0]) if chain else str(peer_ip)


class ProxyHeadersMiddleware:
    """Replaces uvicorn's proxy-header handling: honours X-Forwarded-Proto / CF-Visitor and stores the client IP in
    ``request.state.client_ip`` — only for requests whose TCP peer is a trusted (local) proxy."""

    def __init__(self, app, trusted: list[Network]):
        self.app = app
        self.trusted = trusted

    async def __call__(self, scope, receive, send):
        if scope["type"] in ("http", "websocket"):
            client = scope.get("client")
            peer = client[0] if client else None
            headers = Headers(scope=scope)
            scope = dict(scope)
            if _trusted(_ip(peer), self.trusted):
                proto = (headers.get("x-forwarded-proto") or "").split(",")[0].strip().lower()
                if '"https"' in (headers.get("cf-visitor") or ""):
                    proto = "https"
                if proto in ("http", "https") and scope["type"] == "http":
                    scope["scheme"] = proto
            state = dict(scope.get("state") or {})
            state["client_ip"] = client_ip(peer, headers, self.trusted)
            scope["state"] = state
        await self.app(scope, receive, send)


class SecurityHeadersMiddleware:
    """nosniff + Referrer-Policy everywhere; CSP and frame denial for HTML; no-store for API responses."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        path = scope.get("path", "")

        async def send_wrapper(message):
            if message["type"] == "http.response.start":
                h = MutableHeaders(scope=message)
                if "x-content-type-options" not in h:
                    h["X-Content-Type-Options"] = "nosniff"
                if "referrer-policy" not in h:
                    h["Referrer-Policy"] = "same-origin"
                if h.get("content-type", "").startswith("text/html"):
                    h["Content-Security-Policy"] = CSP
                    h["X-Frame-Options"] = "DENY"
                    h["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()"
                if "/api/" in path and "cache-control" not in h:
                    h["Cache-Control"] = "no-store"
            await send(message)

        await self.app(scope, receive, send_wrapper)


class CachedStaticFiles(StaticFiles):
    """Vendored libraries, fonts and images are immutable per release; app code revalidates (ETag)."""

    def file_response(self, *args, **kwargs):
        resp = super().file_response(*args, **kwargs)
        path = str(args[0]) if args else ""
        if any(f"/{d}/" in path.replace("\\", "/") for d in ("vendor", "fonts", "img")):
            resp.headers["Cache-Control"] = "public, max-age=2592000"
        else:
            resp.headers["Cache-Control"] = "no-cache"
        return resp


# Request schemas -----------------------------------------------------------------------------------------------------
class _In(BaseModel):
    model_config = ConfigDict(extra="ignore", allow_inf_nan=False)


_CTRL = re.compile(r"[\x00-\x1f\x7f​-‏ -‮⁦-⁩]")


def clean_name(value: str | None, max_len: int = 60) -> str:
    value = _CTRL.sub("", value or "")
    return " ".join(value.split())[:max_len].strip()


class RegisterIn(_In):
    platform: Literal["ios", "android"]
    appVersion: str | None = Field(default=None, max_length=50)
    deviceName: str | None = Field(default=None, max_length=200)
    driverName: str | None = Field(default=None, max_length=200)
    language: str | None = Field(default=None, max_length=20)


class MePatch(_In):
    driverName: str = Field(max_length=200)


class Place(_In):
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)
    name: str | None = Field(default=None, max_length=300)


class TripEvent(_In):
    kind: str = Field(pattern=r"^[A-Za-z][A-Za-z0-9_]{0,49}$")
    severity: Literal["info", "warning", "violation"]
    at: datetime
    lat: float | None = Field(default=None, ge=-90, le=90)
    lon: float | None = Field(default=None, ge=-180, le=180)
    speedKmh: float | None = Field(default=None, ge=0, le=500)
    value: float | None = None
    limit: float | None = None
    durationSeconds: float | None = Field(default=None, ge=0, le=86400)


TrackRow = Annotated[list[float | None], Field(min_length=3, max_length=5)]


def _aware(dt: datetime) -> datetime:
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


class TripIn(_In):
    id: str
    platform: Literal["ios", "android"] | None = None
    appVersion: str | None = Field(default=None, max_length=50)
    startedAt: datetime
    endedAt: datetime
    distanceMeters: float = Field(ge=0, le=5_000_000)
    durationSeconds: float = Field(ge=0, le=7 * 86400)
    movingSeconds: float | None = Field(default=None, ge=0, le=7 * 86400)
    avgSpeedKmh: float | None = Field(default=None, ge=0, le=500)
    maxSpeedKmh: float | None = Field(default=None, ge=0, le=500)
    timeOverLimitSeconds: float | None = Field(default=None, ge=0, le=7 * 86400)
    score: float = Field(ge=0, le=100)
    arrived: bool | None = None
    startedWithNavigation: bool | None = None
    origin: Place | None = None
    destination: Place | None = None
    eventCounts: dict[Annotated[str, Field(max_length=50)], Annotated[int, Field(ge=0, le=1_000_000)]] = \
        Field(default_factory=dict, max_length=64)
    speedBands: dict[Annotated[str, Field(max_length=20)], Annotated[float, Field(ge=0, le=7 * 86400)]] = \
        Field(default_factory=dict, max_length=32)
    avgLeadDistanceMeters: float | None = Field(default=None, ge=0, le=10_000)
    shareBelowRecommendedGap: float | None = Field(default=None, ge=0, le=1)
    track: list[TrackRow] = Field(default_factory=list)
    events: list[TripEvent] = Field(default_factory=list)

    @field_validator("startedAt", "endedAt")
    @classmethod
    def _tz(cls, v: datetime) -> datetime:
        return _aware(v)

    @field_validator("track")
    @classmethod
    def _track(cls, rows: list[list[float | None]]) -> list[list[float | None]]:
        out = []
        for i, r in enumerate(rows):
            lat, lon, t = r[0], r[1], r[2]
            speed = r[3] if len(r) > 3 else None
            limit = r[4] if len(r) > 4 else None
            if lat is None or lon is None or t is None or not (-90 <= lat <= 90) or not (-180 <= lon <= 180) \
                    or not (0 <= t <= 7 * 86400):
                raise ValueError(f"track[{i}]: expected [lat, lon, secondsFromStart, speedKmh|null, limit|null]")
            if speed is not None and not (0 <= speed <= 500):
                raise ValueError(f"track[{i}]: speedKmh out of range")
            if limit is not None and not (0 <= limit <= 300):
                raise ValueError(f"track[{i}]: speedLimitKmh out of range")
            out.append([round(lat, 6), round(lon, 6), round(t, 1), speed if speed is None else round(speed, 1),
                        limit if limit is None else round(limit)])
        return out

    @model_validator(mode="after")
    def _order(self):
        if self.endedAt < self.startedAt:
            raise ValueError("endedAt must not be before startedAt")
        return self


class ApproveIn(_In):
    challengeId: str = Field(max_length=64)
    nonce: str = Field(max_length=128)


class AdminLoginIn(_In):
    token: str = Field(max_length=500)


def canonical_uuid(value: str) -> str | None:
    import uuid

    try:
        u = uuid.UUID(value)
    except (ValueError, AttributeError, TypeError):
        return None
    return str(u) if str(u) == value.lower() else None


def _validation_response(exc: ValidationError, detail: str) -> JSONResponse:
    errors = [{"loc": e["loc"], "msg": e["msg"]} for e in exc.errors()[:10]]
    return JSONResponse({"detail": detail, "errors": json.loads(json.dumps(errors, default=str))}, status_code=422)


async def read_body(request: Request, limit: int) -> bytes:
    """Request body with a hard byte cap (413 beyond ``limit``), without buffering an oversized upload."""
    cl = request.headers.get("content-length")
    if cl is not None:
        try:
            if int(cl) > limit:
                raise HTTPException(413, f"request too large (max {limit} bytes)")
        except ValueError:
            raise HTTPException(400, "bad Content-Length") from None
    chunks, total = [], 0
    async for chunk in request.stream():
        total += len(chunk)
        if total > limit:
            raise HTTPException(413, f"request too large (max {limit} bytes)")
        chunks.append(chunk)
    return b"".join(chunks)


@dataclass
class Principal:
    driver_id: str
    via: str                      # "bearer" | "session"
    token_id: int | None = None
    session_hash: str | None = None


def _iphash(ip: str) -> str:
    return hashlib.sha256(("roadvis-ip:" + ip).encode()).hexdigest()[:32]


def save_trip(store: Store, driver_id: str, trip_id: str, trip: TripIn, now: datetime | None = None) -> tuple[bool, int]:
    """Normalizes a validated trip, computes its points and upserts it; returns ``(created, points)``."""
    data = trip.model_dump(mode="json")
    events = data.pop("events")
    track = data.pop("track")
    data["id"] = trip_id
    data["startedAt"] = cabinet.iso_z(trip.startedAt)
    data["endedAt"] = cabinet.iso_z(trip.endedAt)
    for e, src in zip(events, trip.events):
        e["at"] = cabinet.iso_z(_aware(src.at))
    if not data["eventCounts"] and events:
        counts: dict[str, int] = {}
        for e in events:
            counts[e["kind"]] = counts.get(e["kind"], 0) + 1
        data["eventCounts"] = counts
    score = cabinet.round_half_up(trip.score)
    data["score"] = score
    violation = cabinet.trip_has_violation(events)
    points = cabinet.trip_points(score, trip.distanceMeters, violation)
    created = store.upsert_trip(driver_id, trip_id, started_at=data["startedAt"], ended_at=data["endedAt"],
                                distance_m=trip.distanceMeters, score=score, has_violation=violation, points=points,
                                summary=data, detail={"track": track, "events": events}, now=now)
    return created, points


# Routes --------------------------------------------------------------------------------------------------------------
def register_cabinet(app: FastAPI, settings: Settings, store: Store) -> None:
    trusted = parse_networks(settings.trusted_proxies)
    index_template = (WEB_DIR / "index.html").read_text("utf-8")

    # Helpers ----------------------------------------------------------------------------------------------------------
    def bearer(request: Request) -> str:
        scheme, _, value = request.headers.get("authorization", "").partition(" ")
        return value.strip() if scheme.lower() == "bearer" else ""

    def unauthorized(detail: str = "invalid or missing token") -> HTTPException:
        return HTTPException(401, detail, headers={"WWW-Authenticate": "Bearer"})

    def ip_of(request: Request) -> str:
        return getattr(request.state, "client_ip", None) or (request.client.host if request.client else "unknown")

    def rate_limit(request: Request, name: str, limit: int, window: float) -> None:
        wait = store.rate_hit(f"{name}:{_iphash(ip_of(request))}", limit, window)
        if wait is not None:
            raise HTTPException(429, f"rate limit: max {limit} per {int(window // 60)} min",
                                headers={"Retry-After": str(int(wait) + 1)})

    def check_csrf(request: Request) -> None:
        if request.method in UNSAFE_METHODS and request.headers.get(CSRF_HEADER) != "1":
            raise HTTPException(403, "missing X-RoadVis: 1 header")

    def principal(request: Request, allow_session: bool = True) -> Principal:
        if request.headers.get("authorization"):
            p = store.token_principal(bearer(request))
            if p is None:
                raise unauthorized()
            return Principal(p["driver_id"], "bearer", token_id=p["token_id"])
        if allow_session:
            cookie = request.cookies.get(SESSION_COOKIE)
            s = store.session_driver(cookie) if cookie else None
            if s is not None:
                check_csrf(request)
                return Principal(s["driver_id"], "session", session_hash=s["token_hash"])
        raise unauthorized()

    def is_admin_token(token: str) -> bool:
        return bool(settings.admin_token) and bool(token) and tokens_equal(token, settings.admin_token)

    def require_admin_web(request: Request) -> None:
        if request.headers.get("authorization"):
            if is_admin_token(bearer(request)):
                return
            raise unauthorized()
        cookie = request.cookies.get(ADMIN_COOKIE)
        if cookie and store.admin_session_valid(cookie):
            check_csrf(request)
            return
        raise unauthorized("admin login required")

    def set_cookie(resp: Response, name: str, value: str, max_age: int) -> None:
        resp.set_cookie(name, value, max_age=max_age, path=settings.cookie_path, secure=settings.cookie_secure,
                        httponly=True, samesite="lax")

    def clear_cookie(resp: Response, name: str) -> None:
        resp.delete_cookie(name, path=settings.cookie_path, secure=settings.cookie_secure, httponly=True,
                           samesite="lax")

    def me_payload(driver_id: str) -> dict:
        d = store.get_driver(driver_id)
        if d is None:
            raise unauthorized()
        totals = store.driver_totals(driver_id)
        return {"driverId": d["id"], "driverName": d["name"], "createdAt": d["created_at"],
                "tripCount": totals["trip_count"], "points": totals["points"],
                "level": cabinet.level_for(totals["points"])}

    async def parse_json(request: Request, model, limit: int, detail: str):
        raw = await read_body(request, limit)
        try:
            return model.model_validate_json(raw or b"{}")
        except ValidationError as exc:
            raise _ValidationFailed(_validation_response(exc, detail)) from None

    # Registration -----------------------------------------------------------------------------------------------------
    @app.post("/api/v1/devices/register", status_code=201)
    async def register_device(request: Request):
        body = await parse_json(request, RegisterIn, 64 * 1024, "invalid registration")
        rate_limit(request, "register", settings.register_per_ip_hour, 3600)
        lang = (body.language or "uz")[:2].lower()
        lang = lang if lang in ("uz", "ru", "en") else "uz"
        device = clean_name(body.deviceName, 100) or None
        name = clean_name(body.driverName) or clean_name(device) or "RoadVis"
        driver, token = store.create_driver(name, language=lang, platform=body.platform,
                                            app_version=clean_name(body.appVersion, 50) or None, device_name=device)
        log.info("registered driver %s (%s)", driver["id"], body.platform)
        return JSONResponse({"deviceToken": token, "driverId": driver["id"], "driverName": driver["name"]},
                            status_code=201)

    # Me ---------------------------------------------------------------------------------------------------------------
    @app.get("/api/v1/me")
    def get_me(request: Request):
        return me_payload(principal(request).driver_id)

    @app.patch("/api/v1/me")
    async def patch_me(request: Request):
        p = principal(request)
        body = await parse_json(request, MePatch, 16 * 1024, "invalid profile")
        name = clean_name(body.driverName)
        if not name:
            raise HTTPException(422, "driverName must not be empty")
        store.rename_driver(p.driver_id, name)
        return me_payload(p.driver_id)

    @app.delete("/api/v1/me", status_code=204)
    def delete_me(request: Request):
        p = principal(request)
        store.delete_driver(p.driver_id)
        log.info("driver %s deleted their data", p.driver_id)
        resp = Response(status_code=204)
        clear_cookie(resp, SESSION_COOKIE)
        return resp

    @app.get("/api/v1/me/devices")
    def my_devices(request: Request):
        p = principal(request)
        devices = [{"id": d["id"], "name": d["device_name"] or d["name"], "platform": d["platform"],
                    "appVersion": d["app_version"], "createdAt": d["created_at"], "lastUsedAt": d["last_used_at"],
                    "current": d["id"] == p.token_id} for d in store.driver_devices(p.driver_id)]
        sessions = [{"id": s["token_hash"][:12], "createdAt": s["created_at"], "lastSeenAt": s["last_seen_at"],
                     "userAgent": s["user_agent"], "current": s["token_hash"] == p.session_hash}
                    for s in store.driver_sessions(p.driver_id)]
        return {"devices": devices, "sessions": sessions}

    # Trips ------------------------------------------------------------------------------------------------------------
    @app.post("/api/v1/trips")
    async def upload_trip(request: Request):
        p = principal(request, allow_session=False)
        trip = await parse_json(request, TripIn, settings.max_trip_bytes, "invalid trip")
        trip_id = canonical_uuid(trip.id)
        if trip_id is None:
            raise HTTPException(422, "invalid trip: id must be a UUID")
        if len(trip.track) > settings.max_track_points:
            raise HTTPException(422, f"invalid trip: track has more than {settings.max_track_points} points")
        if len(trip.events) > settings.max_trip_events:
            raise HTTPException(422, f"invalid trip: more than {settings.max_trip_events} events")
        now = utcnow()
        if trip.startedAt > now + timedelta(days=1):
            raise HTTPException(422, "invalid trip: startedAt is in the future")
        if not store.trip_exists(p.driver_id, trip_id) and \
                store.trips_created_on(p.driver_id, now.strftime("%Y-%m-%d")) >= settings.trips_per_day:
            tomorrow = (now + timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
            raise HTTPException(429, f"rate limit: max {settings.trips_per_day} trips per day",
                                headers={"Retry-After": str(int((tomorrow - now).total_seconds()) + 1)})

        created, points = save_trip(store, p.driver_id, trip_id, trip, now)
        return JSONResponse({"id": trip_id, "status": "created" if created else "replaced", "points": points},
                            status_code=201 if created else 200)

    @app.get("/api/v1/trips")
    def list_trips(request: Request, limit: int = 50, before: str | None = None):
        p = principal(request)
        if not 1 <= limit <= 200:
            raise HTTPException(422, "limit must be 1..200")
        cursor = None
        if before:
            try:
                cursor = cabinet.iso_z(cabinet.parse_time(before))
            except ValueError:
                raise HTTPException(422, "before must be an ISO 8601 timestamp") from None
        return store.list_trips(p.driver_id, limit=limit, before=cursor)

    @app.get("/api/v1/trips/{trip_id}")
    def get_trip(request: Request, trip_id: str):
        p = principal(request)
        tid = canonical_uuid(trip_id)
        trip = store.get_trip(p.driver_id, tid) if tid else None
        if trip is None:
            raise HTTPException(404, "not found")
        return trip

    @app.delete("/api/v1/trips/{trip_id}", status_code=204)
    def delete_trip(request: Request, trip_id: str):
        p = principal(request)
        tid = canonical_uuid(trip_id)
        if not tid or not store.delete_trip(p.driver_id, tid):
            raise HTTPException(404, "not found")
        return Response(status_code=204)

    # Dashboard --------------------------------------------------------------------------------------------------------
    def _days(days: int) -> int:
        if days not in (30, 90, 365):
            raise HTTPException(422, "days must be 30, 90 or 365")
        return days

    @app.get("/api/v1/dashboard/summary")
    def dashboard_summary(request: Request, days: int = 30):
        p = principal(request)
        days = _days(days)
        out = cabinet.summary(store.all_trip_summaries(p.driver_id), utcnow(), days)
        d = store.get_driver(p.driver_id)
        out["driver"] = {"driverId": d["id"], "driverName": d["name"], "createdAt": d["created_at"],
                         "language": d["language"], "demo": bool(d["is_demo"])}
        return out

    @app.get("/api/v1/dashboard/charts")
    def dashboard_charts(request: Request, days: int = 30):
        p = principal(request)
        return cabinet.charts(store.all_trip_summaries(p.driver_id), utcnow(), _days(days))

    # QR login ---------------------------------------------------------------------------------------------------------
    def public_base(request: Request) -> str:
        return settings.public_url or str(request.base_url).rstrip("/")

    @app.post("/api/v1/auth/qr")
    def qr_create(request: Request):
        rate_limit(request, "qr", settings.qr_create_per_ip_5min, 300)
        if secrets.randbelow(20) == 0:
            store.cleanup_cabinet()
        nonce = secrets.token_urlsafe(24)          # 32 url-safe characters
        poll_secret = secrets.token_urlsafe(32)
        ch = store.create_qr_challenge(nonce, poll_secret, settings.qr_ttl_seconds)
        resp = JSONResponse({"challengeId": ch["id"], "qr": f"{public_base(request)}/qr?c={ch['id']}&n={nonce}",
                             "expiresAt": ch["expires_at"]})
        set_cookie(resp, QR_COOKIE, poll_secret, settings.qr_ttl_seconds + 180)
        return resp

    @app.post("/api/v1/auth/qr/approve")
    async def qr_approve(request: Request):
        if not request.headers.get("authorization"):
            raise unauthorized()
        p = principal(request, allow_session=False)
        body = await parse_json(request, ApproveIn, 16 * 1024, "invalid approval")
        cid = canonical_uuid(body.challengeId)
        if cid is None:
            raise HTTPException(404, "unknown or expired challenge")
        result = store.approve_qr_challenge(cid, body.nonce, p.driver_id)
        if result == "used":
            raise HTTPException(409, "challenge already used")
        if result != "ok":
            raise HTTPException(404, "unknown or expired challenge")
        log.info("QR login approved for driver %s", p.driver_id)
        return {"ok": True}

    @app.get("/api/v1/auth/qr/{challenge_id}")
    def qr_poll(request: Request, challenge_id: str):
        cid = canonical_uuid(challenge_id)
        ch = store.get_qr_challenge(cid) if cid else None
        poll = request.cookies.get(QR_COOKIE) or ""
        if ch is None or not poll or not secrets.compare_digest(ch["poll_hash"], hash_token(poll)):
            raise HTTPException(404, "unknown challenge")
        now = iso()
        status = ch["status"]
        if status == "pending":
            return {"status": "expired" if ch["expires_at"] <= now else "pending"}
        if status == "denied":
            return {"status": "denied"}
        if status == "approved":
            late = iso(utcnow() - timedelta(seconds=settings.qr_ttl_seconds))
            if (ch["approved_at"] or "") < late or not store.consume_qr_challenge(cid):
                return {"status": "expired"}
            token = store.create_session(ch["driver_id"], settings.session_days,
                                         request.headers.get("user-agent"))
            resp = JSONResponse({"status": "approved"})
            set_cookie(resp, SESSION_COOKIE, token, settings.session_days * 86400)
            return resp
        return {"status": "expired"}       # consumed: one-time

    @app.post("/api/v1/auth/logout")
    def logout(request: Request):
        cookie = request.cookies.get(SESSION_COOKIE)
        if cookie:
            check_csrf(request)
            store.delete_session(cookie)
        resp = JSONResponse({"ok": True})
        clear_cookie(resp, SESSION_COOKIE)
        return resp

    @app.post("/api/v1/auth/logout-all")
    def logout_all(request: Request):
        p = principal(request)
        n = store.delete_driver_sessions(p.driver_id)
        resp = JSONResponse({"ok": True, "deletedSessions": n})
        if p.via == "session":
            clear_cookie(resp, SESSION_COOKIE)
        return resp

    # Admin ------------------------------------------------------------------------------------------------------------
    @app.post("/api/v1/admin/login")
    async def admin_login(request: Request):
        check_csrf(request)
        rate_limit(request, "admin-login", settings.admin_login_per_ip_15min, 900)
        body = await parse_json(request, AdminLoginIn, 4 * 1024, "invalid login")
        if not is_admin_token(body.token.strip()):
            raise HTTPException(401, "wrong admin token")
        resp = JSONResponse({"ok": True})
        set_cookie(resp, ADMIN_COOKIE, store.create_admin_session(settings.admin_session_hours),
                   settings.admin_session_hours * 3600)
        return resp

    @app.post("/api/v1/admin/logout")
    def admin_logout(request: Request):
        cookie = request.cookies.get(ADMIN_COOKIE)
        if cookie:
            check_csrf(request)
            store.delete_admin_session(cookie)
        resp = JSONResponse({"ok": True})
        clear_cookie(resp, ADMIN_COOKIE)
        return resp

    @app.get("/api/v1/admin/overview")
    def admin_overview(request: Request):
        require_admin_web(request)
        drivers = []
        for d in store.list_drivers():
            platforms = sorted({p for p in (d["platforms"] or "").split(",") if p})
            drivers.append({
                "driverId": d["id"], "driverName": d["name"], "createdAt": d["created_at"], "demo": bool(d["is_demo"]),
                "language": d["language"], "platforms": platforms, "tripCount": d["trip_count"],
                "distanceKm": round(d["distance_m"] / 1000, 1), "points": d["points"],
                "level": cabinet.level_for(d["points"]),
                "avgScore": round(d["avg_score"], 1) if d["avg_score"] is not None else None,
                "lastTripAt": d["last_trip_at"], "lastSeenAt": d["last_seen_at"]})
        counts = store.status_counts()
        versions = store.published_versions()
        return {
            "drivers": drivers,
            "totals": {"drivers": len(drivers), "trips": sum(d["tripCount"] for d in drivers),
                       "distanceKm": round(sum(d["distanceKm"] for d in drivers), 1),
                       "activeLast30Days": sum(1 for d in drivers if d["lastTripAt"] and
                                               d["lastTripAt"] >= iso(utcnow() - timedelta(days=30)))},
            "training": {"samples": counts["by_status"], "dataset": counts["by_split"],
                         "currentModel": versions[0]["version"] if versions else None,
                         "workerHeartbeat": store.get_state("worker_heartbeat")},
            "serverTime": iso(),
        }

    # Web pages --------------------------------------------------------------------------------------------------------
    def index(request: Request) -> HTMLResponse:
        base = (request.scope.get("root_path") or "").rstrip("/") + "/"
        page = index_template.replace("{{BASE}}", html.escape(base, quote=True)).replace("{{VERSION}}", __version__)
        headers = {"Cache-Control": "no-cache"}
        if request.url.path.rstrip("/").endswith("/qr"):
            headers["Referrer-Policy"] = "no-referrer"   # the QR link carries the one-time nonce
        return HTMLResponse(page, headers=headers)

    for route in SPA_ROUTES:
        app.add_api_route(route, index, methods=["GET"], include_in_schema=False, response_class=HTMLResponse)

    app.mount("/static", CachedStaticFiles(directory=STATIC_DIR), name="static")

    @app.exception_handler(_ValidationFailed)
    async def _validation_failed(request: Request, exc: _ValidationFailed):
        return exc.response

    app.add_middleware(SecurityHeadersMiddleware)
    app.add_middleware(ProxyHeadersMiddleware, trusted=trusted)


class _ValidationFailed(Exception):
    def __init__(self, response: JSONResponse):
        self.response = response
