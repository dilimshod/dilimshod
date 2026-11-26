"""SQLite storage: devices/tokens, samples, candidates, published versions, key/value state.

The API process and the worker process share one database file (WAL mode). Every call opens its own short-lived
connection, so there is no cross-thread sharing.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import secrets
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
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


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def iso(dt: datetime | None = None) -> str:
    """ISO 8601 UTC timestamp with a ``Z`` suffix and second precision."""
    return (dt or utcnow()).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Store:
    """Thin wrapper around the SQLite file."""

    def __init__(self, db_path: Path):
        self.db_path = Path(db_path)
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as db:
            db.executescript(SCHEMA)

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
