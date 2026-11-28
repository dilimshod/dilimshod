"""Demo driver with realistic Tashkent trips (``roadvis-trainer demo-driver --trips 25``), so the dashboard can be shown
before real trips arrive. Routes follow a small hand-made graph of main Tashkent avenues (approximate coordinates);
speed, stops, speeding, events and scores are simulated per trip with a seeded RNG (reproducible).
"""

from __future__ import annotations

import heapq
import math
import random
import uuid
from datetime import datetime, timedelta, timezone

from .cabinet import TASHKENT, iso_z
from .storage import Store

# Junctions / places (lat, lon) — approximate positions along the main avenues.
NODES: dict[str, tuple[float, float, str]] = {
    "amirTemur": (41.3111, 69.2797, "Amir Temur xiyoboni"),
    "minor": (41.3262, 69.2836, "Minor"),
    "bodomzor": (41.3383, 69.2855, "Bodomzor"),
    "yunusobod": (41.3640, 69.2890, "Yunusobod"),
    "mustaqillik": (41.3157, 69.2706, "Mustaqillik maydoni"),
    "furqat": (41.3133, 69.2510, "Tashkent City"),
    "chorsu": (41.3262, 69.2353, "Chorsu"),
    "samarqandDarvoza": (41.3168, 69.2238, "Samarqand Darvoza"),
    "novza": (41.2930, 69.2255, "Novza"),
    "chilonzor": (41.2756, 69.2034, "Chilonzor"),
    "oybek": (41.2995, 69.2752, "Oybek"),
    "shotaRustaveli": (41.2870, 69.2690, "Shota Rustaveli"),
    "aeroport": (41.2625, 69.2785, "Toshkent aeroporti"),
    "hamidOlimjon": (41.3183, 69.2985, "Hamid Olimjon"),
    "buyukIpakYoli": (41.3265, 69.3345, "Mirzo Ulug‘bek"),
    "olmazor": (41.3478, 69.2245, "Olmazor"),
    "beruniy": (41.3445, 69.2060, "Beruniy"),
    "sergeli": (41.2290, 69.2210, "Sergeli"),
    "kuyluk": (41.2540, 69.3320, "Qo‘yliq"),
}

# Edges: (a, b, speed limit km/h, lateral bend factor for a gentle curve).
EDGES = [
    ("amirTemur", "minor", 60, 0.04), ("minor", "bodomzor", 70, -0.02), ("bodomzor", "yunusobod", 70, 0.03),
    ("amirTemur", "mustaqillik", 60, 0.08), ("mustaqillik", "furqat", 60, -0.05), ("furqat", "chorsu", 60, 0.06),
    ("chorsu", "samarqandDarvoza", 60, -0.04), ("furqat", "novza", 70, 0.05), ("samarqandDarvoza", "novza", 60, 0.03),
    ("novza", "chilonzor", 70, -0.03), ("amirTemur", "oybek", 60, 0.05), ("oybek", "shotaRustaveli", 60, -0.04),
    ("shotaRustaveli", "aeroport", 60, 0.03), ("amirTemur", "hamidOlimjon", 60, -0.06),
    ("hamidOlimjon", "buyukIpakYoli", 70, 0.04), ("chorsu", "olmazor", 60, 0.05), ("olmazor", "beruniy", 70, -0.03),
    ("bodomzor", "olmazor", 70, 0.08), ("chilonzor", "sergeli", 80, 0.06), ("shotaRustaveli", "novza", 60, -0.08),
    ("aeroport", "sergeli", 80, -0.05), ("aeroport", "kuyluk", 70, 0.04), ("buyukIpakYoli", "kuyluk", 80, -0.06),
    ("mustaqillik", "oybek", 40, 0.02), ("beruniy", "chilonzor", 80, 0.1),
]

PLACES = ["yunusobod", "chilonzor", "chorsu", "furqat", "buyukIpakYoli", "sergeli", "aeroport", "amirTemur", "olmazor",
          "beruniy", "kuyluk", "novza"]

BANDS = [("0-20", 0, 20), ("20-40", 20, 40), ("40-60", 40, 60), ("60-80", 60, 80), ("80+", 80, 10_000)]


def _haversine(a: tuple[float, float], b: tuple[float, float]) -> float:
    r = 6371000.0
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


def _edge_points(a: str, b: str, bend: float) -> list[tuple[float, float]]:
    """A gently curved polyline between two junctions (quadratic Bézier, ~40 m spacing)."""
    (la, lo, _), (lb, lob, _) = NODES[a], NODES[b]
    mid = ((la + lb) / 2 + (lob - lo) * bend, (lo + lob) / 2 - (lb - la) * bend)
    n = max(4, int(_haversine((la, lo), (lb, lob)) / 40))
    pts = []
    for i in range(n + 1):
        t = i / n
        pts.append(((1 - t) ** 2 * la + 2 * (1 - t) * t * mid[0] + t ** 2 * lb,
                    (1 - t) ** 2 * lo + 2 * (1 - t) * t * mid[1] + t ** 2 * lob))
    return pts


def _graph() -> dict[str, list[tuple[str, float, int, float]]]:
    g: dict[str, list] = {k: [] for k in NODES}
    for a, b, limit, bend in EDGES:
        d = _haversine(NODES[a][:2], NODES[b][:2])
        g[a].append((b, d, limit, bend))
        g[b].append((a, d, limit, -bend))
    return g


def route(src: str, dst: str) -> list[tuple[float, float, int]]:
    """Shortest path along the avenue graph as ``(lat, lon, limit)`` points."""
    g = _graph()
    dist = {src: 0.0}
    prev: dict[str, tuple[str, int, float]] = {}
    heap = [(0.0, src)]
    while heap:
        d, u = heapq.heappop(heap)
        if u == dst:
            break
        if d > dist.get(u, math.inf):
            continue
        for v, w, limit, bend in g[u]:
            if d + w < dist.get(v, math.inf):
                dist[v] = d + w
                prev[v] = (u, limit, bend)
                heapq.heappush(heap, (d + w, v))
    path, node = [], dst
    while node != src:
        u, limit, bend = prev[node]
        path.append((u, node, limit, bend))
        node = u
    pts: list[tuple[float, float, int]] = []
    for u, v, limit, bend in reversed(path):
        seg = _edge_points(u, v, bend)
        pts.extend((la, lo, limit) for la, lo in (seg if not pts else seg[1:]))
    return pts


def simulate_trip(rng: random.Random, start: datetime, src: str, dst: str, style: float) -> dict:
    """One trip as an upload payload. ``style`` 0 (calm) … 1 (aggressive) drives speeding and events."""
    pts = route(src, dst)
    cum = [0.0]
    for p, q in zip(pts, pts[1:]):
        cum.append(cum[-1] + _haversine(p[:2], q[:2]))
    total = cum[-1]
    dt = 2.0
    pos = t = speed = 0.0
    idx = 0
    next_stop = rng.uniform(600, 1800)
    stop_wait = 0.0
    rows: list[list] = []
    events: list[dict] = []
    over = moving = 0.0
    bands = {b[0]: 0.0 for b in BANDS}
    max_speed = 0.0
    burst_until = -1.0
    burst_over = 0.0
    braking_hard = False
    last_tail = -999.0
    gap_low = gap_total = 0.0
    lead_sum = lead_n = 0.0
    while pos < total and t < 4 * 3600:
        while idx < len(cum) - 2 and cum[idx + 1] < pos:
            idx += 1
        limit = pts[idx][2]
        if stop_wait > 0:
            target = 0.0
            stop_wait -= dt
        else:
            congestion = 0.65 + 0.35 * math.sin(t / 97.0 + idx * 0.01) ** 2
            target = limit * congestion * rng.uniform(0.85, 1.0)
            if t < burst_until:
                target = limit + burst_over
            elif rng.random() < 0.0015 + 0.012 * style:
                burst_until = t + rng.uniform(8, 20 + 30 * style)
                burst_over = rng.uniform(3, 6 + 18 * style)
            if pos > next_stop and pos < total - 150:
                if speed < 6:
                    stop_wait = rng.uniform(15, 55)
                    next_stop = pos + rng.uniform(600, 1900)
                    if style > 0.7 and rng.random() < 0.06:
                        lat, lon, _ = pts[idx]
                        events.append(_event("redLightRunning", "violation", start, t, lat, lon, speed, None, None))
                elif not braking_hard and speed > 35 and rng.random() < 0.02 + 0.25 * style * style:
                    braking_hard = True
                    lat, lon, _ = pts[idx]
                    events.append(_event("harshBraking", "warning", start, t, lat, lon, speed,
                                         round(rng.uniform(3.6, 6.0), 1), None, 1.5))
                target = 0.0
            else:
                braking_hard = False
        if total - pos < 120:
            target = min(target, 12.0)
        accel = 2.0 if target > speed else (-4.5 if braking_hard else -1.8)
        new_speed = speed + accel * dt * 3.6
        new_speed = min(new_speed, target) if accel > 0 else max(new_speed, target)
        speed = max(0.0, new_speed)
        if speed > 3:
            moving += dt
            # Lead vehicle: time gap in seconds; the recommended gap is the 2-second rule.
            gap_s = max(0.4, rng.gauss(3.2 - 1.8 * style, 0.6))
            lead_sum += gap_s * speed / 3.6
            lead_n += 1
            gap_total += dt
            if gap_s < 2.0:
                gap_low += dt
                if gap_s < 1.0 and t - last_tail > 120 and rng.random() < 0.5:
                    lat, lon, _ = pts[idx]
                    events.append(_event("tailgating", "warning", start, t, lat, lon, speed,
                                         round(gap_s * speed / 3.6, 1), round(2 * speed / 3.6, 1), 4.0))
                    last_tail = t
        if speed > limit:
            over += dt
            if speed > limit + 10 and (not events or events[-1]["kind"] != "speeding" or
                                       t - _secs(events[-1], start) > 60):
                lat, lon, _ = pts[idx]
                events.append(_event("speeding", "violation" if speed > limit + 20 else "warning", start, t, lat, lon,
                                     speed, round(speed, 1), float(limit), 6.0))
        for name, lo_, hi in BANDS:
            if lo_ <= speed < hi:
                bands[name] += dt
        max_speed = max(max_speed, speed)
        lat, lon = _interp(pts, cum, idx, pos)
        rows.append([round(lat, 6), round(lon, 6), round(t, 1), round(speed, 1), limit])
        pos += speed / 3.6 * dt
        t += dt
    lat, lon, limit = pts[-1]
    rows.append([round(lat, 6), round(lon, 6), round(t, 1), 0.0, limit])

    # Rare camera events, mostly on "aggressive" trips.
    for kind, sev, p in (("laneDeparture", "warning", 0.25 + 0.6 * style), ("collisionRisk", "warning", 0.1 + 0.4 * style),
                         ("pedestrianNotYielded", "violation", 0.02 + 0.2 * style * style),
                         ("harshAcceleration", "warning", 0.2 + 0.5 * style),
                         ("trafficOfficerSeen", "info", 0.25), ("roadWorkersSeen", "info", 0.12)):
        while rng.random() < p:
            r = rows[rng.randrange(len(rows))]
            events.append(_event(kind, sev, start, r[2], r[0], r[1], r[3], None, None, 2.0))
            p *= 0.4
    events.sort(key=lambda e: e["at"])
    counts: dict[str, int] = {}
    for e in events:
        counts[e["kind"]] = counts.get(e["kind"], 0) + 1
    share_over = over / moving if moving else 0.0
    gap_share = gap_low / gap_total if gap_total else 0.0
    faults = sum(v for k, v in counts.items() if k not in ("trafficOfficerSeen", "roadWorkersSeen"))
    per10 = faults / max(1.0, total / 10000)
    violations = sum(1 for e in events if e["severity"] == "violation")
    score = 100 - share_over * 150 - per10 * 3 - violations * 8 - gap_share * 20
    score = int(max(35, min(99, round(score + rng.uniform(-1.5, 2.5)))))
    o, d = NODES[src], NODES[dst]
    return {
        "id": str(uuid.UUID(int=rng.getrandbits(128), version=4)),
        "platform": "ios", "appVersion": "1.4",
        "startedAt": iso_z(start), "endedAt": iso_z(start + timedelta(seconds=t)),
        "distanceMeters": round(total, 1), "durationSeconds": round(t, 1), "movingSeconds": round(moving, 1),
        "avgSpeedKmh": round(total / 1000 / (moving / 3600), 1) if moving else 0.0,
        "maxSpeedKmh": round(max_speed, 1), "timeOverLimitSeconds": round(over, 1),
        "score": score, "arrived": True, "startedWithNavigation": rng.random() < 0.6,
        "origin": {"lat": o[0], "lon": o[1], "name": o[2]},
        "destination": {"lat": d[0], "lon": d[1], "name": d[2]},
        "eventCounts": counts,
        "speedBands": {k: round(v, 1) for k, v in bands.items()},
        "avgLeadDistanceMeters": round(lead_sum / lead_n, 1) if lead_n else None,
        "shareBelowRecommendedGap": round(gap_share, 3),
        "track": _thin(rows, 1500),
        "events": events,
    }


def _secs(event: dict, start: datetime) -> float:
    return (datetime.fromisoformat(event["at"].replace("Z", "+00:00")) - start).total_seconds()


def _event(kind, severity, start, t, lat, lon, speed, value, limit, duration=None) -> dict:
    e = {"kind": kind, "severity": severity, "at": iso_z(start + timedelta(seconds=t)), "lat": round(lat, 6),
         "lon": round(lon, 6), "speedKmh": round(speed, 1)}
    if value is not None:
        e["value"] = value
    if limit is not None:
        e["limit"] = limit
    if duration is not None:
        e["durationSeconds"] = duration
    return e


def _interp(pts, cum, idx, pos) -> tuple[float, float]:
    a, b = pts[idx], pts[min(idx + 1, len(pts) - 1)]
    seg = cum[min(idx + 1, len(cum) - 1)] - cum[idx]
    f = 0.0 if seg <= 0 else max(0.0, min(1.0, (pos - cum[idx]) / seg))
    return a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f


def _thin(rows: list[list], max_points: int) -> list[list]:
    if len(rows) <= max_points:
        return rows
    step = math.ceil(len(rows) / max_points)
    out = rows[::step]
    if out[-1] is not rows[-1]:
        out.append(rows[-1])
    return out


def demo_trips(n: int, seed: int = 7, now: datetime | None = None) -> list[dict]:
    """``n`` trips over roughly the last ``2.4 * n`` days: commutes, errands and a few late-night drives; the driving
    style improves over time (so the score trend has a story)."""
    rng = random.Random(seed)
    now = (now or datetime.now(timezone.utc)).astimezone(TASHKENT)
    span = max(7, int(n * 2.4))
    trips = []
    home, work = "yunusobod", "chilonzor"
    for i in range(n):
        day = now - timedelta(days=span * (n - i) / n + rng.uniform(0, 0.6))
        kind = rng.random()
        if kind < 0.55:
            hour, minute = (rng.choice([7, 8, 8, 9]), rng.randrange(60)) if i % 2 == 0 else (rng.choice([17, 18, 19]),
                                                                                          rng.randrange(60))
            src, dst = (home, work) if i % 2 == 0 else (work, home)
        elif kind < 0.85:
            hour, minute = rng.choice([10, 12, 13, 15, 20]), rng.randrange(60)
            src, dst = rng.sample(PLACES, 2)
        else:
            hour, minute = rng.choice([22, 23, 0, 1]), rng.randrange(60)
            src, dst = rng.sample(PLACES, 2)
        start = day.replace(hour=hour, minute=minute, second=rng.randrange(60), microsecond=0)
        if start > now - timedelta(hours=1):
            start = now - timedelta(hours=rng.uniform(2, 8))
        progress = i / max(1, n - 1)
        style = max(0.0, min(1.0, 0.7 - 0.65 * progress + rng.uniform(-0.15, 0.15)))
        trips.append(simulate_trip(rng, start.astimezone(timezone.utc), src, dst, style))
    return trips


def create_demo_driver(store: Store, trips: int = 25, name: str = "Demo haydovchi", seed: int = 7) -> tuple[dict, str]:
    """Creates a demo driver profile with ``trips`` simulated trips; returns ``(driver, device token)``."""
    from .cabinet_api import TripIn, save_trip

    first = demo_trips(trips, seed=seed)
    created_at = min((t["startedAt"] for t in first), default=None)
    driver, token = store.create_driver(name, language="uz", platform="ios", app_version="1.4",
                                        device_name="Demo iPhone", is_demo=True,
                                        created_at=created_at and iso_z(datetime.fromisoformat(
                                            created_at.replace("Z", "+00:00")) - timedelta(hours=1)))
    for payload in first:
        save_trip(store, driver["id"], payload["id"], TripIn.model_validate(payload))
    return driver, token
