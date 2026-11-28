"""SQLite storage: devices/tokens, samples, candidates, published versions, key/value state, and the driver cabinet
(drivers, trips, web sessions, QR login challenges, rate-limit events).

The API process and the worker process share one database file (WAL mode). Every call opens its own short-lived
connection, so there is no cross-thread sharing.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import secrets
import sqlite3
import uuid
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Iterator

SCHEMA = """
CREATE TABLE IF NOT EXISTS tokens (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    token_hash TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL,
    revoked_at TEXT,
    last_used_at TEXT
);
CREATE TABLE IF NOT EXISTS samples (
    id TEXT PRIMARY KEY,
    device_id INTEGER NOT NULL,
    received_at TEXT NOT NULL,
    received_day TEXT NOT NULL,
    platform TEXT,
    app_version TEXT,
    captured_at TEXT,
    reasons TEXT,
    width INTEGER,
    height INTEGER,
    status TEXT NOT NULL,           -- queued | kept | rejected | evicted
    reason TEXT,                    -- rejection reason (small record only, files are deleted)
    split TEXT,                     -- train | val | test (kept frames)
    dhash TEXT,
    sharpness REAL,
    brightness REAL,
    n_labels INTEGER,
    attempts INTEGER NOT NULL DEFAULT 0,
    processed_at TEXT
);
CREATE INDEX IF NOT EXISTS samples_status ON samples(status);
CREATE INDEX IF NOT EXISTS samples_device_day ON samples(device_id, received_day);
CREATE TABLE IF NOT EXISTS candidates (
    id TEXT PRIMARY KEY,
    created_at TEXT NOT NULL,
    status TEXT NOT NULL,           -- pending | evaluating | accepted | rejected | error
    weights_path TEXT,
    training_metrics TEXT,
    report_path TEXT,
    version TEXT,
    message TEXT,
    finished_at TEXT
);
CREATE TABLE IF NOT EXISTS versions (
    version TEXT PRIMARY KEY,
    created_at TEXT NOT NULL,
    status TEXT NOT NULL,           -- published | deleted
    manifest TEXT NOT NULL,
    candidate_id TEXT
);
CREATE TABLE IF NOT EXISTS state (
    key TEXT PRIMARY KEY,
    value TEXT
);
"""

# Driver cabinet (RoadVis/docs/CABINET_API.md). Idempotent: applied on every start by both processes.
CABINET_SCHEMA = """
CREATE TABLE IF NOT EXISTS drivers (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    language TEXT NOT NULL DEFAULT 'uz',
    created_at TEXT NOT NULL,
    is_demo INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS trips (
    driver_id TEXT NOT NULL REFERENCES drivers(id) ON DELETE CASCADE,
    id TEXT NOT NULL,
    started_at TEXT NOT NULL,
    ended_at TEXT NOT NULL,
    created_at TEXT NOT NULL,
    created_day TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    distance_m REAL NOT NULL,
    score INTEGER NOT NULL,
    has_violation INTEGER NOT NULL,
    points INTEGER NOT NULL,
    summary TEXT NOT NULL,          -- JSON: every trip field except track and events
    detail TEXT NOT NULL,           -- JSON: {"track": [...], "events": [...]}
    PRIMARY KEY (driver_id, id)
);
CREATE INDEX IF NOT EXISTS trips_driver_started ON trips(driver_id, started_at);
CREATE INDEX IF NOT EXISTS trips_driver_day ON trips(driver_id, created_day);
CREATE TABLE IF NOT EXISTS web_sessions (
    token_hash TEXT PRIMARY KEY,
    driver_id TEXT NOT NULL REFERENCES drivers(id) ON DELETE CASCADE,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    last_seen_at TEXT,
    user_agent TEXT
);
CREATE INDEX IF NOT EXISTS web_sessions_driver ON web_sessions(driver_id);
CREATE TABLE IF NOT EXISTS admin_sessions (
    token_hash TEXT PRIMARY KEY,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS qr_challenges (
    id TEXT PRIMARY KEY,
    nonce_hash TEXT NOT NULL,
    poll_hash TEXT NOT NULL,        -- binds polling to the browser that created the challenge (httpOnly cookie)
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    status TEXT NOT NULL,           -- pending | approved | consumed | denied
    driver_id TEXT,
    approved_at TEXT
);
CREATE TABLE IF NOT EXISTS rate_events (
    bucket TEXT NOT NULL,
    at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS rate_events_bucket ON rate_events(bucket, at);
"""

# Columns added to existing tables (guarded ALTER TABLE: SQLite has no ADD COLUMN IF NOT EXISTS).
TOKEN_COLUMNS = {"driver_id": "TEXT", "platform": "TEXT", "app_version": "TEXT", "device_name": "TEXT"}


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def iso(dt: datetime | None = None) -> str:
    """ISO 8601 UTC timestamp with a ``Z`` suffix and second precision."""
    return (dt or utcnow()).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class CabinetMixin:
    """Driver cabinet queries (mixed into :class:`Store`)."""

    # Drivers ---------------------------------------------------------------------------------------------------------
    def create_driver(self, name: str, *, language: str = "uz", platform: str | None = None,
                      app_version: str | None = None, device_name: str | None = None, is_demo: bool = False,
                      created_at: str | None = None) -> tuple[dict, str]:
        """Creates a driver profile with one device token; returns ``(driver, plain token)``."""
        driver_id = str(uuid.uuid4())
        token = "rvt_" + secrets.token_urlsafe(32)
        now = created_at or iso()
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            db.execute("INSERT INTO drivers(id, name, language, created_at, is_demo) VALUES(?,?,?,?,?)",
                       (driver_id, name, language, now, int(is_demo)))
            db.execute("INSERT INTO tokens(name, token_hash, created_at, driver_id, platform, app_version, device_name)"
                       " VALUES(?,?,?,?,?,?,?)", (device_name or f"{platform or 'device'}-{driver_id[:8]}",
                                                  hash_token(token), now, driver_id, platform, app_version,
                                                  device_name))
            db.execute("COMMIT")
        return self.get_driver(driver_id), token

    def get_driver(self, driver_id: str) -> dict | None:
        with self.connect() as db:
            row = db.execute("SELECT id, name, language, created_at, is_demo FROM drivers WHERE id=?",
                             (driver_id,)).fetchone()
        return dict(row) if row else None

    def rename_driver(self, driver_id: str, name: str) -> None:
        with self.connect() as db:
            db.execute("UPDATE drivers SET name=? WHERE id=?", (name, driver_id))

    def token_principal(self, token: str) -> dict | None:
        """``{token_id, name, driver_id}`` of an active token; creates the driver profile lazily for tokens that were
        made with ``roadvis-trainer token create`` (contract section 1)."""
        if not token:
            return None
        digest = hash_token(token)
        with self.connect() as db:
            row = db.execute("SELECT id, name, driver_id FROM tokens WHERE token_hash=? AND revoked_at IS NULL",
                             (digest,)).fetchone()
            if row is None:
                return None
            now = iso()
            driver_id = row["driver_id"]
            if driver_id is None or db.execute("SELECT 1 FROM drivers WHERE id=?", (driver_id,)).fetchone() is None:
                db.execute("BEGIN IMMEDIATE")
                current = db.execute("SELECT driver_id FROM tokens WHERE id=?", (row["id"],)).fetchone()["driver_id"]
                if current is not None and db.execute("SELECT 1 FROM drivers WHERE id=?", (current,)).fetchone():
                    driver_id = current
                else:
                    driver_id = str(uuid.uuid4())
                    db.execute("INSERT INTO drivers(id, name, language, created_at) VALUES(?,?,?,?)",
                               (driver_id, row["name"][:60] or "RoadVis", "uz", now))
                    db.execute("UPDATE tokens SET driver_id=? WHERE id=?", (driver_id, row["id"]))
                db.execute("COMMIT")
            db.execute("UPDATE tokens SET last_used_at=? WHERE id=?", (now, row["id"]))
        return {"token_id": row["id"], "name": row["name"], "driver_id": driver_id}

    def driver_devices(self, driver_id: str) -> list[dict]:
        with self.connect() as db:
            rows = db.execute("SELECT id, name, platform, app_version, device_name, created_at, last_used_at "
                              "FROM tokens WHERE driver_id=? AND revoked_at IS NULL ORDER BY id", (driver_id,))
            return [dict(r) for r in rows]

    def driver_sessions(self, driver_id: str) -> list[dict]:
        with self.connect() as db:
            rows = db.execute("SELECT token_hash, created_at, last_seen_at, user_agent FROM web_sessions "
                              "WHERE driver_id=? AND expires_at > ? ORDER BY created_at DESC", (driver_id, iso()))
            return [dict(r) for r in rows]

    def delete_driver(self, driver_id: str) -> bool:
        """Deletes the profile, its trips, web sessions, pending QR approvals and device tokens."""
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            db.execute("DELETE FROM trips WHERE driver_id=?", (driver_id,))
            db.execute("DELETE FROM web_sessions WHERE driver_id=?", (driver_id,))
            db.execute("DELETE FROM qr_challenges WHERE driver_id=?", (driver_id,))
            db.execute("DELETE FROM tokens WHERE driver_id=?", (driver_id,))
            n = db.execute("DELETE FROM drivers WHERE id=?", (driver_id,)).rowcount
            db.execute("COMMIT")
        return n > 0

    def list_drivers(self) -> list[dict]:
        """Every driver with totals (admin overview, CLI)."""
        with self.connect() as db:
            rows = db.execute(
                "SELECT d.id, d.name, d.language, d.created_at, d.is_demo,"
                " (SELECT COUNT(*) FROM trips t WHERE t.driver_id=d.id) AS trip_count,"
                " (SELECT COALESCE(SUM(distance_m), 0) FROM trips t WHERE t.driver_id=d.id) AS distance_m,"
                " (SELECT COALESCE(SUM(points), 0) FROM trips t WHERE t.driver_id=d.id) AS points,"
                " (SELECT AVG(score) FROM trips t WHERE t.driver_id=d.id) AS avg_score,"
                " (SELECT MAX(started_at) FROM trips t WHERE t.driver_id=d.id) AS last_trip_at,"
                " (SELECT GROUP_CONCAT(COALESCE(platform, ''), ',') FROM tokens k"
                "   WHERE k.driver_id=d.id AND k.revoked_at IS NULL) AS platforms,"
                " (SELECT MAX(last_used_at) FROM tokens k WHERE k.driver_id=d.id) AS last_seen_at"
                " FROM drivers d ORDER BY d.created_at DESC").fetchall()
        return [dict(r) for r in rows]

    # Trips -----------------------------------------------------------------------------------------------------------
    def trip_exists(self, driver_id: str, trip_id: str) -> bool:
        with self.connect() as db:
            return db.execute("SELECT 1 FROM trips WHERE driver_id=? AND id=?", (driver_id, trip_id)).fetchone() \
                is not None

    def trips_created_on(self, driver_id: str, day: str) -> int:
        with self.connect() as db:
            return int(db.execute("SELECT COUNT(*) AS n FROM trips WHERE driver_id=? AND created_day=?",
                                  (driver_id, day)).fetchone()["n"])

    def upsert_trip(self, driver_id: str, trip_id: str, *, started_at: str, ended_at: str, distance_m: float,
                    score: int, has_violation: bool, points: int, summary: dict, detail: dict,
                    now: datetime | None = None) -> bool:
        """Inserts or replaces a trip; returns True if it was created."""
        now = now or utcnow()
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            existed = db.execute("SELECT 1 FROM trips WHERE driver_id=? AND id=?", (driver_id, trip_id)).fetchone()
            args = (started_at, ended_at, iso(now), distance_m, score, int(has_violation), points,
                    json.dumps(summary, separators=(",", ":")), json.dumps(detail, separators=(",", ":")))
            if existed:
                db.execute("UPDATE trips SET started_at=?, ended_at=?, updated_at=?, distance_m=?, score=?,"
                           " has_violation=?, points=?, summary=?, detail=? WHERE driver_id=? AND id=?",
                           (*args, driver_id, trip_id))
            else:
                db.execute("INSERT INTO trips(started_at, ended_at, updated_at, distance_m, score, has_violation,"
                           " points, summary, detail, driver_id, id, created_at, created_day)"
                           " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                           (*args, driver_id, trip_id, iso(now), now.strftime("%Y-%m-%d")))
            db.execute("COMMIT")
        return not existed

    @staticmethod
    def _trip_summary(row) -> dict:
        d = json.loads(row["summary"])
        d["points"] = row["points"]
        d["hasViolation"] = bool(row["has_violation"])
        d["uploadedAt"] = row["created_at"]
        return d

    def list_trips(self, driver_id: str, *, limit: int = 50, before: str | None = None) -> list[dict]:
        sql = "SELECT summary, points, has_violation, created_at FROM trips WHERE driver_id=?"
        args: list = [driver_id]
        if before:
            sql += " AND started_at < ?"
            args.append(before)
        sql += " ORDER BY started_at DESC, id DESC LIMIT ?"
        args.append(limit)
        with self.connect() as db:
            return [self._trip_summary(r) for r in db.execute(sql, args)]

    def all_trip_summaries(self, driver_id: str) -> list[dict]:
        """All trips of a driver, oldest first (input of the points/badges/charts computations)."""
        with self.connect() as db:
            rows = db.execute("SELECT summary, points, has_violation, created_at FROM trips WHERE driver_id=?"
                              " ORDER BY started_at, id", (driver_id,))
            return [self._trip_summary(r) for r in rows]

    def get_trip(self, driver_id: str, trip_id: str) -> dict | None:
        with self.connect() as db:
            row = db.execute("SELECT summary, detail, points, has_violation, created_at FROM trips"
                             " WHERE driver_id=? AND id=?", (driver_id, trip_id)).fetchone()
        if row is None:
            return None
        d = self._trip_summary(row)
        d.update(json.loads(row["detail"]))
        return d

    def delete_trip(self, driver_id: str, trip_id: str) -> bool:
        with self.connect() as db:
            return db.execute("DELETE FROM trips WHERE driver_id=? AND id=?", (driver_id, trip_id)).rowcount > 0

    def driver_totals(self, driver_id: str) -> dict:
        with self.connect() as db:
            row = db.execute("SELECT COUNT(*) AS n, COALESCE(SUM(points), 0) AS points FROM trips WHERE driver_id=?",
                             (driver_id,)).fetchone()
        return {"trip_count": int(row["n"]), "points": int(row["points"])}

    # Web sessions ----------------------------------------------------------------------------------------------------
    def create_session(self, driver_id: str, days: int, user_agent: str | None = None) -> str:
        token = "rvs_" + secrets.token_urlsafe(32)
        now = utcnow()
        with self.connect() as db:
            db.execute("INSERT INTO web_sessions(token_hash, driver_id, created_at, expires_at, last_seen_at,"
                       " user_agent) VALUES(?,?,?,?,?,?)",
                       (hash_token(token), driver_id, iso(now), iso(now + timedelta(days=days)), iso(now),
                        (user_agent or "")[:300]))
        return token

    def session_driver(self, token: str) -> dict | None:
        """``{driver_id, token_hash}`` of a live web session (and refreshes ``last_seen_at`` at most once a minute)."""
        if not token or len(token) > 200:
            return None
        digest = hash_token(token)
        now = utcnow()
        with self.connect() as db:
            row = db.execute("SELECT driver_id, last_seen_at FROM web_sessions WHERE token_hash=? AND expires_at > ?",
                             (digest, iso(now))).fetchone()
            if row is None:
                return None
            if not row["last_seen_at"] or row["last_seen_at"] < iso(now - timedelta(minutes=1)):
                db.execute("UPDATE web_sessions SET last_seen_at=? WHERE token_hash=?", (iso(now), digest))
        return {"driver_id": row["driver_id"], "token_hash": digest}

    def delete_session(self, token: str) -> None:
        with self.connect() as db:
            db.execute("DELETE FROM web_sessions WHERE token_hash=?", (hash_token(token),))

    def delete_driver_sessions(self, driver_id: str) -> int:
        with self.connect() as db:
            return db.execute("DELETE FROM web_sessions WHERE driver_id=?", (driver_id,)).rowcount

    def create_admin_session(self, hours: int) -> str:
        token = "rva_" + secrets.token_urlsafe(32)
        now = utcnow()
        with self.connect() as db:
            db.execute("INSERT INTO admin_sessions(token_hash, created_at, expires_at) VALUES(?,?,?)",
                       (hash_token(token), iso(now), iso(now + timedelta(hours=hours))))
        return token

    def admin_session_valid(self, token: str) -> bool:
        if not token or len(token) > 200:
            return False
        with self.connect() as db:
            return db.execute("SELECT 1 FROM admin_sessions WHERE token_hash=? AND expires_at > ?",
                              (hash_token(token), iso())).fetchone() is not None

    def delete_admin_session(self, token: str) -> None:
        with self.connect() as db:
            db.execute("DELETE FROM admin_sessions WHERE token_hash=?", (hash_token(token),))

    # QR challenges ---------------------------------------------------------------------------------------------------
    def create_qr_challenge(self, nonce: str, poll_secret: str, ttl_seconds: int,
                            now: datetime | None = None) -> dict:
        now = now or utcnow()
        cid = str(uuid.uuid4())
        expires = now + timedelta(seconds=ttl_seconds)
        with self.connect() as db:
            db.execute("INSERT INTO qr_challenges(id, nonce_hash, poll_hash, created_at, expires_at, status)"
                       " VALUES(?,?,?,?,?, 'pending')", (cid, hash_token(nonce), hash_token(poll_secret), iso(now),
                                                         iso(expires)))
        return {"id": cid, "expires_at": iso(expires)}

    def get_qr_challenge(self, cid: str) -> dict | None:
        with self.connect() as db:
            row = db.execute("SELECT * FROM qr_challenges WHERE id=?", (cid,)).fetchone()
        return dict(row) if row else None

    def approve_qr_challenge(self, cid: str, nonce: str, driver_id: str, now: datetime | None = None) -> str:
        """Returns ``ok``, ``unknown`` (404: no such challenge, expired, wrong nonce, denied) or ``used`` (409)."""
        now = now or utcnow()
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            try:
                row = db.execute("SELECT * FROM qr_challenges WHERE id=?", (cid,)).fetchone()
                if row is None or row["status"] == "denied":
                    return "unknown"
                nonce_ok = hmac.compare_digest(row["nonce_hash"], hash_token(nonce))
                if not nonce_ok:
                    if row["status"] == "pending" and row["expires_at"] > iso(now):
                        # A wrong nonce burns the challenge: the page shows "denied" and renews its QR.
                        db.execute("UPDATE qr_challenges SET status='denied' WHERE id=?", (cid,))
                    return "unknown"
                if row["status"] in ("approved", "consumed"):
                    return "used"
                if row["expires_at"] <= iso(now):
                    return "unknown"
                db.execute("UPDATE qr_challenges SET status='approved', driver_id=?, approved_at=? WHERE id=?",
                           (driver_id, iso(now), cid))
                return "ok"
            finally:
                db.execute("COMMIT")

    def consume_qr_challenge(self, cid: str) -> bool:
        """Marks an approved challenge consumed (exactly one poll wins)."""
        with self.connect() as db:
            return db.execute("UPDATE qr_challenges SET status='consumed' WHERE id=? AND status='approved'",
                              (cid,)).rowcount == 1

    def cleanup_cabinet(self, now: datetime | None = None) -> None:
        """Deletes expired sessions, old QR challenges and rate-limit events."""
        now = now or utcnow()
        with self.connect() as db:
            db.execute("DELETE FROM web_sessions WHERE expires_at <= ?", (iso(now),))
            db.execute("DELETE FROM admin_sessions WHERE expires_at <= ?", (iso(now),))
            db.execute("DELETE FROM qr_challenges WHERE expires_at <= ?", (iso(now - timedelta(hours=1)),))
            db.execute("DELETE FROM rate_events WHERE at < ?", (now.timestamp() - 86400,))

    # Rate limits -----------------------------------------------------------------------------------------------------
    def rate_hit(self, bucket: str, limit: int, window_seconds: float, now: float | None = None) -> float | None:
        """Records one event in ``bucket``; returns None if allowed, else the seconds until the next slot frees up."""
        now = now if now is not None else utcnow().timestamp()
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            try:
                db.execute("DELETE FROM rate_events WHERE bucket=? AND at <= ?", (bucket, now - window_seconds))
                rows = db.execute("SELECT at FROM rate_events WHERE bucket=? ORDER BY at", (bucket,)).fetchall()
                if len(rows) >= limit:
                    return max(1.0, rows[0]["at"] + window_seconds - now)
                db.execute("INSERT INTO rate_events(bucket, at) VALUES(?, ?)", (bucket, now))
                return None
            finally:
                db.execute("COMMIT")


class Store(CabinetMixin):
    """Thin wrapper around the SQLite file."""

    def __init__(self, db_path: Path):
        self.db_path = Path(db_path)
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as db:
            db.executescript(SCHEMA)
            db.executescript(CABINET_SCHEMA)
            have = {r["name"] for r in db.execute("PRAGMA table_info(tokens)")}
            for col, decl in TOKEN_COLUMNS.items():
                if col not in have:
                    try:
                        db.execute(f"ALTER TABLE tokens ADD COLUMN {col} {decl}")
                    except sqlite3.OperationalError as exc:  # the other process migrated at the same moment
                        if "duplicate column" not in str(exc).lower():
                            raise
            db.execute("CREATE INDEX IF NOT EXISTS tokens_driver ON tokens(driver_id)")

    @contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]:
        db = sqlite3.connect(self.db_path, timeout=30, isolation_level=None)
        db.row_factory = sqlite3.Row
        try:
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("PRAGMA busy_timeout=30000")
            db.execute("PRAGMA foreign_keys=ON")
            yield db
        finally:
            db.close()

    # State -----------------------------------------------------------------------------------------------------------
    def get_state(self, key: str, default: str | None = None) -> str | None:
        with self.connect() as db:
            row = db.execute("SELECT value FROM state WHERE key=?", (key,)).fetchone()
        return row["value"] if row else default

    def set_state(self, key: str, value: str) -> None:
        with self.connect() as db:
            db.execute("INSERT INTO state(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                       (key, value))

    # Tokens ----------------------------------------------------------------------------------------------------------
    def create_token(self, name: str) -> str:
        """Creates a device token and returns the plain value (shown once, only the sha256 is stored)."""
        name = name.strip()
        if not name:
            raise ValueError("token name must not be empty")
        token = "rvt_" + secrets.token_urlsafe(32)
        with self.connect() as db:
            db.execute("INSERT INTO tokens(name, token_hash, created_at) VALUES(?, ?, ?)",
                       (name, hash_token(token), iso()))
        return token

    def list_tokens(self) -> list[dict]:
        with self.connect() as db:
            rows = db.execute("SELECT id, name, created_at, revoked_at, last_used_at FROM tokens ORDER BY id").fetchall()
        return [dict(r) for r in rows]

    def revoke_token(self, ident: str) -> int:
        """Revokes tokens by numeric id or by name; returns the number of tokens revoked."""
        with self.connect() as db:
            if ident.isdigit():
                cur = db.execute("UPDATE tokens SET revoked_at=? WHERE id=? AND revoked_at IS NULL", (iso(), int(ident)))
            else:
                cur = db.execute("UPDATE tokens SET revoked_at=? WHERE name=? AND revoked_at IS NULL", (iso(), ident))
            return cur.rowcount

    def device_for_token(self, token: str) -> dict | None:
        """Returns ``{id, name}`` of the active device that owns ``token`` (constant-time hash lookup)."""
        if not token:
            return None
        digest = hash_token(token)
        with self.connect() as db:
            row = db.execute("SELECT id, name FROM tokens WHERE token_hash=? AND revoked_at IS NULL",
                             (digest,)).fetchone()
            if row is None:
                return None
            db.execute("UPDATE tokens SET last_used_at=? WHERE id=?", (iso(), row["id"]))
        return dict(row)

    # Samples ---------------------------------------------------------------------------------------------------------
    def sample_exists(self, sample_id: str) -> bool:
        with self.connect() as db:
            return db.execute("SELECT 1 FROM samples WHERE id=?", (sample_id,)).fetchone() is not None

    def uploads_today(self, device_id: int, day: str) -> int:
        with self.connect() as db:
            row = db.execute("SELECT COUNT(*) AS n FROM samples WHERE device_id=? AND received_day=?",
                             (device_id, day)).fetchone()
        return int(row["n"])

    def insert_sample(self, *, sample_id: str, device_id: int, meta: dict, width: int, height: int,
                      now: datetime | None = None, status: str = "queued") -> None:
        now = now or utcnow()
        with self.connect() as db:
            db.execute(
                "INSERT INTO samples(id, device_id, received_at, received_day, platform, app_version, captured_at,"
                " reasons, width, height, status) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                (sample_id, device_id, iso(now), now.strftime("%Y-%m-%d"), meta.get("platform"),
                 meta.get("appVersion"), meta.get("capturedAt"), json.dumps(meta.get("reasons", [])), width, height,
                 status),
            )

    def set_sample_status(self, sample_id: str, status: str) -> None:
        self._update_sample(sample_id, status=status)

    def delete_sample_row(self, sample_id: str) -> None:
        with self.connect() as db:
            db.execute("DELETE FROM samples WHERE id=?", (sample_id,))

    def stale_receiving(self, before_iso: str) -> list[str]:
        with self.connect() as db:
            rows = db.execute("SELECT id FROM samples WHERE status='receiving' AND received_at < ?",
                              (before_iso,)).fetchall()
        return [r["id"] for r in rows]

    def queued_samples(self, limit: int) -> list[dict]:
        with self.connect() as db:
            rows = db.execute("SELECT * FROM samples WHERE status='queued' ORDER BY received_at, id LIMIT ?",
                              (limit,)).fetchall()
        return [dict(r) for r in rows]

    def mark_rejected(self, sample_id: str, reason: str, **extra) -> None:
        self._update_sample(sample_id, status="rejected", reason=reason, processed_at=iso(), **extra)

    def mark_kept(self, sample_id: str, split: str, dhash: str, sharpness: float, brightness: float,
                  n_labels: int) -> None:
        self._update_sample(sample_id, status="kept", split=split, dhash=dhash, sharpness=sharpness,
                            brightness=brightness, n_labels=n_labels, processed_at=iso(), reason=None)

    def bump_attempts(self, sample_id: str) -> int:
        with self.connect() as db:
            db.execute("UPDATE samples SET attempts=attempts+1 WHERE id=?", (sample_id,))
            row = db.execute("SELECT attempts FROM samples WHERE id=?", (sample_id,)).fetchone()
        return int(row["attempts"]) if row else 0

    def _update_sample(self, sample_id: str, **fields) -> None:
        cols = ", ".join(f"{k}=?" for k in fields)
        with self.connect() as db:
            db.execute(f"UPDATE samples SET {cols} WHERE id=?", (*fields.values(), sample_id))

    def kept_hashes(self) -> list[str]:
        with self.connect() as db:
            rows = db.execute("SELECT dhash FROM samples WHERE status='kept' AND dhash IS NOT NULL").fetchall()
        return [r["dhash"] for r in rows]

    def split_count(self, split: str) -> int:
        with self.connect() as db:
            row = db.execute("SELECT COUNT(*) AS n FROM samples WHERE status='kept' AND split=?", (split,)).fetchone()
        return int(row["n"])

    def kept_count(self) -> int:
        with self.connect() as db:
            return int(db.execute("SELECT COUNT(*) AS n FROM samples WHERE status='kept'").fetchone()["n"])

    def oldest_kept(self, split: str, limit: int) -> list[dict]:
        with self.connect() as db:
            rows = db.execute("SELECT id, split FROM samples WHERE status='kept' AND split=? "
                              "ORDER BY processed_at, received_at, id LIMIT ?", (split, limit)).fetchall()
        return [dict(r) for r in rows]

    def mark_evicted(self, sample_id: str) -> None:
        self._update_sample(sample_id, status="evicted", reason="retention")

    def status_counts(self) -> dict:
        with self.connect() as db:
            by_status = {r["status"]: r["n"] for r in
                         db.execute("SELECT status, COUNT(*) AS n FROM samples GROUP BY status")}
            by_split = {r["split"]: r["n"] for r in
                        db.execute("SELECT split, COUNT(*) AS n FROM samples WHERE status='kept' GROUP BY split")}
            reasons = {r["reason"]: r["n"] for r in
                       db.execute("SELECT reason, COUNT(*) AS n FROM samples WHERE status='rejected' GROUP BY reason")}
        return {"by_status": by_status, "by_split": by_split, "rejected_by_reason": reasons}

    # Candidates ------------------------------------------------------------------------------------------------------
    def insert_candidate(self, cand_id: str, weights_path: str, training_metrics: dict | None) -> None:
        with self.connect() as db:
            db.execute("INSERT INTO candidates(id, created_at, status, weights_path, training_metrics) "
                       "VALUES(?, ?, 'pending', ?, ?)",
                       (cand_id, iso(), weights_path, json.dumps(training_metrics) if training_metrics else None))

    def pending_candidates(self) -> list[dict]:
        with self.connect() as db:
            rows = db.execute("SELECT * FROM candidates WHERE status='pending' ORDER BY created_at, id").fetchall()
        return [dict(r) for r in rows]

    def get_candidate(self, cand_id: str) -> dict | None:
        with self.connect() as db:
            row = db.execute("SELECT * FROM candidates WHERE id=?", (cand_id,)).fetchone()
        return dict(row) if row else None

    def update_candidate(self, cand_id: str, **fields) -> None:
        cols = ", ".join(f"{k}=?" for k in fields)
        with self.connect() as db:
            db.execute(f"UPDATE candidates SET {cols} WHERE id=?", (*fields.values(), cand_id))

    def recent_candidates(self, limit: int = 5) -> list[dict]:
        with self.connect() as db:
            rows = db.execute("SELECT id, created_at, status, version, message, finished_at FROM candidates "
                              "ORDER BY created_at DESC, id DESC LIMIT ?", (limit,)).fetchall()
        return [dict(r) for r in rows]

    # Versions --------------------------------------------------------------------------------------------------------
    def insert_version(self, version: str, manifest: dict, candidate_id: str | None) -> None:
        with self.connect() as db:
            db.execute("INSERT INTO versions(version, created_at, status, manifest, candidate_id) "
                       "VALUES(?, ?, 'published', ?, ?)", (version, manifest["createdAt"], json.dumps(manifest),
                                                         candidate_id))

    def published_versions(self) -> list[dict]:
        """Published versions, newest first."""
        with self.connect() as db:
            rows = db.execute("SELECT version, created_at, manifest, candidate_id FROM versions "
                              "WHERE status='published' ORDER BY created_at DESC, rowid DESC").fetchall()
        out = []
        for r in rows:
            d = dict(r)
            d["manifest"] = json.loads(d["manifest"])
            out.append(d)
        return out

    def get_version(self, version: str) -> dict | None:
        with self.connect() as db:
            row = db.execute("SELECT version, created_at, status, manifest FROM versions WHERE version=?",
                             (version,)).fetchone()
        if not row:
            return None
        d = dict(row)
        d["manifest"] = json.loads(d["manifest"])
        return d

    def version_names_for_day(self, day: str) -> list[str]:
        with self.connect() as db:
            rows = db.execute("SELECT version FROM versions WHERE version LIKE ?", (day + "-%",)).fetchall()
        return [r["version"] for r in rows]

    def mark_version_deleted(self, version: str) -> None:
        with self.connect() as db:
            db.execute("UPDATE versions SET status='deleted' WHERE version=?", (version,))


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def tokens_equal(a: str, b: str) -> bool:
    """Constant-time comparison of two secrets (via their digests, so lengths do not leak)."""
    return hmac.compare_digest(hash_token(a), hash_token(b))
