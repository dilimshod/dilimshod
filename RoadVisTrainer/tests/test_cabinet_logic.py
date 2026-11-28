"""Pure cabinet logic: points, levels, badges, recommendations, aggregates (CABINET_API.md section 3)."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from roadvis_trainer import cabinet
from roadvis_trainer.cabinet import compute_badges, level_for, level_info, recommendations, trip_points

NOW = datetime(2026, 11, 28, 12, 0, tzinfo=timezone.utc)


def trip(i: int = 0, *, days_ago: float = 1.0, km: float = 10.0, score: float = 92, violation: bool = False,
         share: float | None = 0.05, counts: dict | None = None, hour_utc: int | None = None, moving: float = 1200,
         over: float = 0.0, bands: dict | None = None) -> dict:
    start = NOW - timedelta(days=days_ago)
    if hour_utc is not None:
        start = start.replace(hour=hour_utc, minute=0, second=0)
    return {"id": f"00000000-0000-4000-8000-{i:012d}", "startedAt": start.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "distanceMeters": km * 1000, "durationSeconds": moving + 60, "movingSeconds": moving,
            "timeOverLimitSeconds": over, "score": score, "hasViolation": violation,
            "shareBelowRecommendedGap": share, "eventCounts": counts or {}, "speedBands": bands or {},
            "maxSpeedKmh": 70.0, "points": trip_points(score, km * 1000, violation)}


def badges_by_id(trips) -> dict:
    return {b["id"]: b for b in compute_badges(trips)}


# Points and levels ---------------------------------------------------------------------------------------------------
@pytest.mark.parametrize("score,meters,violation,expected", [
    (86, 18250, False, 157 + 20),     # 86 * 18.25 / 10 = 156.95 → 157, + 20 bonus
    (86, 18250, True, 157),           # a violation removes the bonus
    (100, 1999, False, 20),           # 19.99 → 20, below 2 km: no bonus
    (100, 2000, False, 20 + 20),      # exactly 2 km earns the bonus
    (90, 250_000, False, 900 + 20),   # distance capped at 100 km
    (50, 1000, False, 5),             # 5.0
    (25, 1000, False, 3),             # 2.5 rounds half up (Python round() would give 2)
    (0, 50_000, False, 20),
])
def test_trip_points(score, meters, violation, expected):
    assert trip_points(score, meters, violation) == expected


@pytest.mark.parametrize("points,level", [(0, 1), (49, 1), (50, 2), (199, 2), (200, 3), (449, 3), (450, 4),
                                          (5000, 11), (4999, 10)])
def test_level(points, level):
    assert level_for(points) == level


def test_level_info_progress():
    info = level_info(300)
    assert info == {"level": 3, "points": 300, "levelStartPoints": 200, "nextLevelPoints": 450,
                    "progress": round(100 / 250, 4)}


def test_has_violation():
    assert cabinet.trip_has_violation([{"severity": "warning"}, {"severity": "violation"}])
    assert not cabinet.trip_has_violation([{"severity": "info"}, {"severity": "warning"}])


# Badges --------------------------------------------------------------------------------------------------------------
def test_no_trips_no_badges():
    b = badges_by_id([])
    assert set(b) == set(cabinet.BADGES)
    assert not any(x["earned"] for x in b.values())


def test_first_trip_and_distance_badges():
    trips = [trip(i, days_ago=40 - i, km=60) for i in range(10)]   # 600 km
    b = badges_by_id(trips)
    assert b["firstTrip"]["earned"] and b["firstTrip"]["earnedAt"] == trips[0]["startedAt"]
    assert b["km100"]["earned"] and b["km100"]["earnedAt"] == trips[1]["startedAt"]   # 120 km after the 2nd
    assert b["km500"]["earned"] and b["km500"]["earnedAt"] == trips[8]["startedAt"]   # 540 km after the 9th
    assert not b["km1000"]["earned"] and b["km1000"]["progress"] == pytest.approx(0.6)


def test_clean10_needs_ten_in_a_row():
    trips = [trip(i, days_ago=60 - i, violation=(i == 5)) for i in range(14)]
    b = badges_by_id(trips)
    assert not b["clean10"]["earned"]
    assert b["clean10"]["current"] == 8
    trips.append(trip(99, days_ago=0.5))
    trips.append(trip(98, days_ago=0.4))
    b = badges_by_id(trips)
    assert b["clean10"]["earned"] and b["clean10"]["earnedAt"] == trips[-1]["startedAt"]


def test_clean10_is_kept_after_a_later_violation():
    trips = [trip(i, days_ago=60 - i) for i in range(10)] + [trip(50, days_ago=1, violation=True)]
    assert badges_by_id(trips)["clean10"]["earned"]


def test_safe_gap_streak_skips_missing_data():
    shares = [0.05, 0.02, None, 0.09, 0.3, 0.01, 0.0, None, 0.05, 0.08]
    trips = [trip(i, days_ago=30 - i, share=s) for i, s in enumerate(shares)]
    assert not badges_by_id(trips)["safeGap"]["earned"]           # streak broken by 0.3, then 4
    trips.append(trip(20, days_ago=1, share=0.099))
    b = badges_by_id(trips)
    assert b["safeGap"]["earned"] and b["safeGap"]["earnedAt"] == trips[-1]["startedAt"]


def test_calm_driver_window():
    nine = [trip(i, days_ago=20 - i, score=95) for i in range(9)]
    assert not badges_by_id(nine)["calmDriver"]["earned"]
    ten = nine + [trip(9, days_ago=5, score=85)]                    # average (9*95 + 85) / 10 = 94
    assert badges_by_id(ten)["calmDriver"]["earned"]
    low = nine + [trip(9, days_ago=5, score=40)]                    # average 89.5
    assert not badges_by_id(low)["calmDriver"]["earned"]
    spread = [trip(i, days_ago=100 - i * 8, score=99) for i in range(10)]   # never 10 within 30 days
    assert not badges_by_id(spread)["calmDriver"]["earned"]


def test_night_owl_uses_tashkent_time():
    # 17:00 UTC = 22:00 in Tashkent → night; 16:59 UTC → 21:59 → not night; 23:59 UTC = 04:59 → night.
    assert badges_by_id([trip(1, hour_utc=17, score=90)])["nightOwl"]["earned"]
    assert not badges_by_id([trip(1, hour_utc=16, score=99)])["nightOwl"]["earned"]
    assert badges_by_id([trip(1, hour_utc=23, score=95)])["nightOwl"]["earned"]
    assert not badges_by_id([trip(1, hour_utc=0, score=99)])["nightOwl"]["earned"]  # 05:00 local
    assert not badges_by_id([trip(1, hour_utc=18, score=89)])["nightOwl"]["earned"]


def test_badges_are_deterministic_and_order_independent():
    trips = [trip(i, days_ago=50 - i, km=30, score=80 + i % 15, violation=i % 7 == 0) for i in range(30)]
    assert compute_badges(trips) == compute_badges(list(reversed(trips)))


# Recommendations -----------------------------------------------------------------------------------------------------
def rec_ids(trips) -> list[str]:
    return [r["id"] for r in recommendations(trips, NOW)]


def test_no_trips_no_recommendations():
    assert recommendations([], NOW) == []


def test_tailgating_advice_cites_two_second_rule():
    recs = recommendations([trip(1, km=100, counts={"tailgating": 4})], NOW)
    assert [r["id"] for r in recs] == ["keepDistance"]
    r = recs[0]
    assert r["metric"] == {"name": "tailgatingPer100Km", "value": 4.0, "threshold": 3.0, "unit": "per100km"}
    assert r["estimate"] is True
    assert "2" in r["title"]["en"] and "2 seconds" in r["text"]["en"]
    assert set(r["title"]) == set(r["text"]) == {"uz", "ru", "en"}
    assert "‘" in r["title"]["uz"] or "‘" in r["text"]["uz"]       # Uzbek Latin uses U+2018
    assert rec_ids([trip(1, km=100, counts={"tailgating": 3})]) == []   # threshold is "> 3"


def test_speed_share_rule():
    assert rec_ids([trip(1, moving=1000, over=21)]) == ["speed"]
    assert rec_ids([trip(1, moving=1000, over=20)]) == []
    assert rec_ids([trip(1, moving=300, over=100)]) == []          # too little driving to judge


def test_strong_safety_advice_comes_first():
    t = trip(1, km=100, counts={"tailgating": 10, "harshBraking": 5, "laneDeparture": 3, "redLightRunning": 1,
                                "pedestrianNotYielded": 2, "stopSignIgnored": 1, "harshAcceleration": 9,
                                "collisionRisk": 4}, moving=3600, over=500)
    recs = recommendations([t], NOW)
    assert len(recs) == 5
    assert [r["priority"] for r in recs] == sorted(r["priority"] for r in recs)
    assert {r["id"] for r in recs[:3]} == {"pedestrianNotYielded", "redLightRunning", "stopSignIgnored"}
    assert recs[0]["level"] == "high"
    assert "2" in recs[[r["id"] for r in recs].index("pedestrianNotYielded")]["text"]["ru"]


def test_rate_rules_need_distance_and_only_last_30_days():
    assert rec_ids([trip(1, km=5, counts={"harshBraking": 3})]) == []
    assert rec_ids([trip(1, km=50, counts={"harshBraking": 3})]) == ["anticipation"]
    assert rec_ids([trip(1, km=50, days_ago=31, counts={"harshBraking": 3})]) == []
    assert rec_ids([trip(1, km=100, counts={"laneDeparture": 2})]) == ["laneDiscipline"]


def test_gap_share_fallback_and_keep_it_up():
    poor_gap = [trip(i, km=20, share=0.4) for i in range(3)]
    assert rec_ids(poor_gap) == ["keepDistance"]
    good = [trip(i, km=20, score=93) for i in range(3)]
    recs = recommendations(good, NOW)
    assert [r["id"] for r in recs] == ["keepItUp"] and recs[0]["level"] == "info"


def test_recommendations_deterministic():
    trips = [trip(i, km=15, counts={"tailgating": i % 3, "harshBraking": 1}, over=i * 5) for i in range(12)]
    assert recommendations(trips, NOW) == recommendations(list(reversed(trips)), NOW)


# Aggregates ----------------------------------------------------------------------------------------------------------
def test_charts_and_summary_shapes():
    trips = [trip(i, days_ago=i * 2 + 0.2, km=10 + i, counts={"speeding": 1, "trafficOfficerSeen": 1},
                  bands={"80+": 10, "0-20": 100, "20-40": 200, "40-60": 50}) for i in range(10)]
    ch = cabinet.charts(trips, NOW, 30)
    assert [b["band"] for b in ch["speedBands"]] == ["0-20", "20-40", "40-60", "80+"]
    assert sum(c["trips"] for c in ch["heatmap"]) == 10
    assert {e["kind"] for e in ch["events"]} == {"speeding", "trafficOfficerSeen"}
    assert len(ch["tripScores"]) == 10
    s = cabinet.summary(trips, NOW, 30)
    assert s["period"]["trips"] == 10 and s["previous"]["trips"] == 0
    assert s["period"]["events"] == 10                    # informational sightings are not counted as faults
    assert s["level"]["points"] == sum(t["points"] for t in trips)
    assert s["lastTrip"]["id"] == trips[0]["id"]
