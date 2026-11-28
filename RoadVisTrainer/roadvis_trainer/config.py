"""Settings, read from environment variables (see ``.env.example``)."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path


def _int(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    return int(raw) if raw else default


def _float(name: str, default: float) -> float:
    raw = os.environ.get(name, "").strip()
    return float(raw) if raw else default


def _str(name: str, default: str) -> str:
    raw = os.environ.get(name, "").strip()
    return raw or default


def _bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name, "").strip().lower()
    if not raw:
        return default
    return raw in ("1", "true", "yes", "on")


def load_env_file(path: str | os.PathLike | None = None) -> None:
    """Loads ``KEY=VALUE`` lines from ``.env`` (or ``ROADVIS_ENV_FILE``) without overriding the real environment."""
    p = Path(path or os.environ.get("ROADVIS_ENV_FILE", ".env"))
    if not p.is_file():
        return
    for line in p.read_text("utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key, value = key.strip(), value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


# Loopback plus private networks: nginx on the host reaches the Docker container from the bridge gateway.
DEFAULT_TRUSTED_PROXIES = "127.0.0.0/8,::1/128,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,fc00::/7"


@dataclass
class Settings:
    """All tunables of the service. Defaults follow ``RoadVis/docs/TRAINING_API.md``."""

    data_dir: Path = Path("data")
    # Public URL prefix behind the reverse proxy, e.g. "/roadvis" (nginx strips it, see README).
    root_path: str = ""
    admin_token: str = field(default="", repr=False)
    enable_docs: bool = False

    # Ingest (contract section 3).
    max_image_bytes: int = 2 * 1024 * 1024
    max_meta_bytes: int = 256 * 1024
    daily_limit: int = 600
    max_candidate_bytes: int = 600 * 1024 * 1024

    # Worker / auto-label (contract section 4.2).
    teacher_model: str = "yolo11x.pt"
    teacher_imgsz: int = 1280
    worker_threads: int = 2
    worker_batch: int = 4
    worker_poll_seconds: float = 15.0
    worker_max_attempts: int = 3
    label_conf: float = 0.50
    ambiguous_conf: float = 0.25
    consistency_min_hits: int = 5
    consistency_iou: float = 0.30

    # Dataset (contract section 4.2 and 4.6).
    test_freeze_at: int = 300
    dataset_cap: int = 50_000

    # Gate and publishing (contract sections 4.4 and 4.5).
    eval_imgsz: int = 960
    baseline_model: str = "yolo11s.pt"
    gate_min_test_images: int = 100
    keep_versions: int = 3

    # Driver cabinet (RoadVis/docs/CABINET_API.md).
    # Public base URL used in QR payloads, e.g. "https://trafficcounter.uz/roadvis" (derived from the request if empty).
    public_url: str = ""
    # Peers whose CF-Connecting-IP / X-Forwarded-For / X-Forwarded-Proto headers are trusted (the local reverse proxy).
    trusted_proxies: str = DEFAULT_TRUSTED_PROXIES
    cookie_secure: bool = True
    register_per_ip_hour: int = 10
    qr_create_per_ip_5min: int = 30
    admin_login_per_ip_15min: int = 10
    qr_ttl_seconds: int = 120
    session_days: int = 30
    admin_session_hours: int = 12
    max_trip_bytes: int = 5 * 1024 * 1024
    trips_per_day: int = 200
    max_track_points: int = 5000
    max_trip_events: int = 2000

    @property
    def cookie_path(self) -> str:
        """Cookie path derived from the public prefix: "/roadvis/" in production, "/" locally."""
        return (self.root_path.rstrip("/") + "/") if self.root_path else "/"

    @classmethod
    def from_env(cls) -> "Settings":
        root = _str("ROADVIS_ROOT_PATH", os.environ.get("ROOT_PATH", "")).rstrip("/")
        if root and not root.startswith("/"):
            root = "/" + root
        return cls(
            data_dir=Path(_str("ROADVIS_DATA_DIR", "data")).expanduser().resolve(),
            root_path=root,
            admin_token=os.environ.get("ROADVIS_ADMIN_TOKEN", "").strip(),
            enable_docs=_bool("ROADVIS_ENABLE_DOCS", False),
            max_image_bytes=_int("ROADVIS_MAX_IMAGE_BYTES", 2 * 1024 * 1024),
            daily_limit=_int("ROADVIS_DAILY_LIMIT", 600),
            max_candidate_bytes=_int("ROADVIS_MAX_CANDIDATE_BYTES", 600 * 1024 * 1024),
            teacher_model=_str("ROADVIS_TEACHER_MODEL", "yolo11x.pt"),
            teacher_imgsz=_int("ROADVIS_TEACHER_IMGSZ", 1280),
            worker_threads=max(1, _int("ROADVIS_WORKER_THREADS", 2)),
            worker_batch=max(1, _int("ROADVIS_WORKER_BATCH", 4)),
            worker_poll_seconds=_float("ROADVIS_WORKER_POLL_SECONDS", 15.0),
            test_freeze_at=_int("ROADVIS_TEST_FREEZE_AT", 300),
            dataset_cap=_int("ROADVIS_DATASET_CAP", 50_000),
            eval_imgsz=_int("ROADVIS_EVAL_IMGSZ", 960),
            baseline_model=_str("ROADVIS_BASELINE_MODEL", "yolo11s.pt"),
            gate_min_test_images=_int("ROADVIS_GATE_MIN_TEST_IMAGES", 100),
            keep_versions=max(1, _int("ROADVIS_KEEP_VERSIONS", 3)),
            public_url=_str("ROADVIS_PUBLIC_URL", "").rstrip("/"),
            trusted_proxies=_str("ROADVIS_TRUSTED_PROXIES", DEFAULT_TRUSTED_PROXIES),
            cookie_secure=_bool("ROADVIS_COOKIE_SECURE", True),
            register_per_ip_hour=_int("ROADVIS_REGISTER_PER_IP_HOUR", 10),
            qr_ttl_seconds=_int("ROADVIS_QR_TTL_SECONDS", 120),
            session_days=_int("ROADVIS_SESSION_DAYS", 30),
            admin_session_hours=_int("ROADVIS_ADMIN_SESSION_HOURS", 12),
            max_trip_bytes=_int("ROADVIS_MAX_TRIP_BYTES", 5 * 1024 * 1024),
            trips_per_day=_int("ROADVIS_TRIPS_PER_DAY", 200),
        )

    # Paths ---------------------------------------------------------------------------------------------------------
    @property
    def db_path(self) -> Path:
        return self.data_dir / "roadvis.sqlite3"

    @property
    def incoming_dir(self) -> Path:
        return self.data_dir / "incoming"

    @property
    def dataset_dir(self) -> Path:
        return self.data_dir / "dataset"

    @property
    def candidates_dir(self) -> Path:
        return self.data_dir / "candidates"

    @property
    def reports_dir(self) -> Path:
        return self.data_dir / "reports"

    @property
    def models_dir(self) -> Path:
        return self.data_dir / "models"

    @property
    def tmp_dir(self) -> Path:
        return self.data_dir / "tmp"

    def ensure_dirs(self) -> None:
        for d in (self.data_dir, self.incoming_dir, self.dataset_dir, self.candidates_dir, self.reports_dir,
                  self.models_dir, self.tmp_dir):
            d.mkdir(parents=True, exist_ok=True)
        for kind in ("images", "labels"):
            for split in ("train", "val", "test"):
                (self.dataset_dir / kind / split).mkdir(parents=True, exist_ok=True)
