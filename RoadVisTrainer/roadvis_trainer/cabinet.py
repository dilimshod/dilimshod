"""Driver cabinet logic (RoadVis/docs/CABINET_API.md section 3): points, levels, badges, recommendations and the
dashboard aggregates. Pure functions over trip summaries — no I/O, deterministic for a given input and ``now``.

A *trip summary* is the dict stored for every uploaded trip (camelCase contract fields without ``track``/``events``)
plus ``hasViolation`` (any event of severity ``violation``) and ``points``.
"""

from __future__ import annotations

import math
import re
from datetime import datetime, timedelta, timezone
from decimal import ROUND_HALF_UP, Decimal
from typing import Iterable

# Asia/Tashkent is UTC+5 all year (no DST since 1992); a fixed offset avoids depending on tzdata in the container.
TASHKENT = timezone(timedelta(hours=5), "Asia/Tashkent")

EVENT_KINDS = ("speeding", "tailgating", "collisionRisk", "laneDeparture", "redLightRunning", "stopSignIgnored",
               "pedestrianNotYielded", "harshBraking", "harshAcceleration", "trafficOfficerSeen", "roadWorkersSeen")
# Events estimated from the camera (labelled as estimates in the UI and in recommendations).
CAMERA_KINDS = frozenset({"tailgating", "collisionRisk", "laneDeparture", "redLightRunning", "stopSignIgnored",
                          "pedestrianNotYielded", "trafficOfficerSeen", "roadWorkersSeen"})
# Informational sightings: not driving faults, excluded from "events per 100 km" totals.
INFO_KINDS = frozenset({"trafficOfficerSeen", "roadWorkersSeen"})

BADGES = ("firstTrip", "km100", "km500", "km1000", "clean10", "calmDriver", "safeGap", "nightOwl")
LEVEL_STEP = 50  # Level = floor(sqrt(points / 50)) + 1


# Time helpers ----------------------------------------------------------------------------------------------------------
def parse_time(value: str | datetime) -> datetime:
    if isinstance(value, datetime):
        dt = value
    else:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def iso_z(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def local_time(value: str | datetime) -> datetime:
    return parse_time(value).astimezone(TASHKENT)


# Points and levels ---------------------------------------------------------------------------------------------------
def round_half_up(value: float) -> int:
    """Rounds .5 away from zero (Python's ``round`` rounds half to even), on the decimal representation."""
    return int(Decimal(repr(float(value))).quantize(Decimal(1), rounding=ROUND_HALF_UP))


def trip_points(score: float, distance_meters: float, has_violation: bool) -> int:
    """``round(score * min(distanceKm, 100) / 10)`` (half up) + 20 if the trip has no violation and is >= 2 km."""
    km = Decimal(repr(max(0.0, float(distance_meters)))) / 1000
    raw = Decimal(repr(float(score))) * min(km, Decimal(100)) / 10
    points = int(raw.quantize(Decimal(1), rounding=ROUND_HALF_UP))
    if not has_violation and km >= 2:
        points += 20
    return points


def level_for(points: int) -> int:
    """``floor(sqrt(points / 50)) + 1``, computed exactly with integers."""
    return math.isqrt(max(0, int(points)) // LEVEL_STEP) + 1


def level_info(points: int) -> dict:
    level = level_for(points)
    start = LEVEL_STEP * (level - 1) ** 2
    nxt = LEVEL_STEP * level ** 2
    return {"level": level, "points": int(points), "levelStartPoints": start, "nextLevelPoints": nxt,
            "progress": round((points - start) / (nxt - start), 4)}


def trip_has_violation(events: Iterable[dict]) -> bool:
    return any((e.get("severity") == "violation") for e in events)


# Badges --------------------------------------------------------------------------------------------------------------
def _sorted(trips: Iterable[dict]) -> list[dict]:
    return sorted(trips, key=lambda t: (parse_time(t["startedAt"]), t.get("id", "")))


def compute_badges(trips: Iterable[dict]) -> list[dict]:
    """Every badge with ``earned``, ``earnedAt`` (start of the trip that earned it), ``progress`` 0–1, ``current`` and
    ``target``. Once earned a badge stays earned (it is a property of the trip history, not of "now")."""
    ts = _sorted(trips)
    out: dict[str, dict] = {b: {"id": b, "earned": False, "earnedAt": None, "progress": 0.0, "current": 0,
                                "target": 1} for b in BADGES}

    def earn(badge: str, trip: dict) -> None:
        if not out[badge]["earned"]:
            out[badge].update(earned=True, earnedAt=iso_z(parse_time(trip["startedAt"])), progress=1.0)

    km_total = 0.0
    clean = clean_best = 0
    gap = gap_best = 0
    window: list[tuple[datetime, float]] = []
    for t in ts:
        started = parse_time(t["startedAt"])
        earn("firstTrip", t)
        km_total += max(0.0, float(t.get("distanceMeters") or 0)) / 1000
        for badge, target in (("km100", 100), ("km500", 500), ("km1000", 1000)):
            if km_total >= target:
                earn(badge, t)
        clean = 0 if t.get("hasViolation") else clean + 1
        clean_best = max(clean_best, clean)
        if clean >= 10:
            earn("clean10", t)
        share = t.get("shareBelowRecommendedGap")
        if share is not None:  # trips without lead-vehicle data neither count nor break the streak
            gap = gap + 1 if float(share) < 0.1 else 0
            gap_best = max(gap_best, gap)
            if gap >= 5:
                earn("safeGap", t)
        window.append((started, float(t.get("score") or 0)))
        window = [w for w in window if w[0] > started - timedelta(days=30)]
        if len(window) >= 10 and sum(s for _, s in window) / len(window) >= 90:
            earn("calmDriver", t)
        hour = started.astimezone(TASHKENT).hour
        if (hour >= 22 or hour < 5) and float(t.get("score") or 0) >= 90:
            earn("nightOwl", t)

    def progress(badge: str, current: float, target: float) -> None:
        b = out[badge]
        b["current"], b["target"] = round(current, 1), target
        if not b["earned"]:
            b["progress"] = round(min(1.0, current / target), 4) if target else 0.0

    progress("firstTrip", min(len(ts), 1), 1)
    for badge, target in (("km100", 100), ("km500", 500), ("km1000", 1000)):
        progress(badge, km_total, target)
    progress("clean10", clean, 10)
    progress("safeGap", gap, 5)
    n = len(window)
    avg = sum(s for _, s in window) / n if n else 0.0
    progress("calmDriver", min(n, 10), 10)
    if not out["calmDriver"]["earned"] and n:
        out["calmDriver"]["progress"] = round(min(1.0, n / 10) * min(1.0, avg / 90), 4)
    out["calmDriver"]["average"] = round(avg, 1)
    progress("nightOwl", 1 if out["nightOwl"]["earned"] else 0, 1)
    return [out[b] for b in BADGES]


# Period statistics ---------------------------------------------------------------------------------------------------
def in_period(trips: Iterable[dict], start: datetime | None, end: datetime | None = None) -> list[dict]:
    res = []
    for t in trips:
        s = parse_time(t["startedAt"])
        if (start is None or s >= start) and (end is None or s < end):
            res.append(t)
    return res


def event_totals(trips: Iterable[dict]) -> dict[str, int]:
    totals: dict[str, int] = {}
    for t in trips:
        for kind, n in (t.get("eventCounts") or {}).items():
            totals[kind] = totals.get(kind, 0) + int(n or 0)
    return totals


def period_stats(trips: list[dict]) -> dict:
    n = len(trips)
    km = sum(max(0.0, float(t.get("distanceMeters") or 0)) for t in trips) / 1000
    duration = sum(float(t.get("durationSeconds") or 0) for t in trips)
    moving = sum(float(t.get("movingSeconds") or t.get("durationSeconds") or 0) for t in trips)
    over = sum(float(t.get("timeOverLimitSeconds") or 0) for t in trips)
    events = event_totals(trips)
    faults = sum(v for k, v in events.items() if k not in INFO_KINDS)
    violations = sum(1 for t in trips if t.get("hasViolation"))
    return {
        "trips": n,
        "distanceKm": round(km, 1),
        "durationSeconds": round(duration),
        "movingSeconds": round(moving),
        "avgScore": round(sum(float(t.get("score") or 0) for t in trips) / n, 1) if n else None,
        "maxSpeedKmh": round(max((float(t.get("maxSpeedKmh") or 0) for t in trips), default=0.0), 1),
        "avgSpeedKmh": round(km / (moving / 3600), 1) if moving > 0 else None,
        "overLimitShare": round(over / moving, 4) if moving > 0 else None,
        "events": faults,
        "eventsPer100Km": round(faults / km * 100, 2) if km > 0 else None,
        "tripsWithViolation": violations,
        "cleanTripShare": round((n - violations) / n, 4) if n else None,
        "points": sum(int(t.get("points") or 0) for t in trips),
    }


# Recommendations -----------------------------------------------------------------------------------------------------
MIN_KM_FOR_RATES = 10.0       # rate-based rules need some distance, or one event on a short trip dominates
MIN_MOVING_FOR_SPEED = 600.0  # seconds

_STRONG = {
    "pedestrianNotYielded": {
        "title": {"uz": "Piyodalarga doim yo‘l bering", "ru": "Всегда пропускайте пешеходов",
                  "en": "Always give way to pedestrians"},
        "text": {
            "uz": "Piyodaga yo‘l berilmagan bo‘lishi mumkin bo‘lgan holatlar: {n}. Har bir piyodalar o‘tish joyi "
                  "oldidan tezlikni pasaytiring va kimdir kutayotgan yoki o‘tayotgan bo‘lsa, to‘liq to‘xtang — "
                  "piyoda ustuvor. Bu kamera asosidagi taxmin.",
            "ru": "Ситуаций, когда пешеход мог быть не пропущен: {n}. Сбрасывайте скорость перед каждым "
                  "пешеходным переходом и полностью останавливайтесь, если человек ждёт или уже переходит — "
                  "у пешехода приоритет. Это оценка по камере.",
            "en": "Situations where a pedestrian may not have been given way: {n}. Slow down before every "
                  "crossing and stop completely if someone is waiting or already crossing — pedestrians have "
                  "priority. This is a camera-based estimate."}},
    "redLightRunning": {
        "title": {"uz": "Qizil chiroqda to‘xtang", "ru": "Останавливайтесь на красный",
                  "en": "Stop on red"},
        "text": {
            "uz": "Qizil chiroqqa o‘tish ehtimoli bo‘lgan holatlar: {n}. Chorrahaga yaqinlashganda tezlikni "
                  "oldindan kamaytiring: sariq chiroq yonsa, xavfsiz to‘xtash mumkin bo‘lsa — to‘xtang. Bu kamera "
                  "asosidagi taxmin.",
            "ru": "Возможных проездов на красный: {n}. Подъезжая к перекрёстку, заранее снижайте скорость: если "
                  "загорелся жёлтый и вы можете безопасно остановиться — остановитесь. Это оценка по камере.",
            "en": "Possible red-light crossings: {n}. Ease off early when approaching a junction: if the light "
                  "turns yellow and you can stop safely, stop. This is a camera-based estimate."}},
    "stopSignIgnored": {
        "title": {"uz": "«STOP» belgisida to‘liq to‘xtang", "ru": "Полная остановка у знака «Стоп»",
                  "en": "Make a full stop at STOP signs"},
        "text": {
            "uz": "«STOP» belgisiga amal qilinmagan bo‘lishi mumkin bo‘lgan holatlar: {n}. Belgi oldida "
                  "g‘ildiraklar to‘liq to‘xtashi kerak, so‘ng ikki tomonga qarab, yo‘l bo‘sh bo‘lsa harakatlaning. "
                  "Bu kamera asosidagi taxmin.",
            "ru": "Возможных проездов знака «Стоп» без остановки: {n}. У знака колёса должны полностью "
                  "остановиться; посмотрите в обе стороны и двигайтесь, только когда дорога свободна. Это оценка "
                  "по камере.",
            "en": "Possible STOP-sign roll-throughs: {n}. The wheels must stop completely at the sign; look both "
                  "ways and move off only when the road is clear. This is a camera-based estimate."}},
}

_RATE_RULES = [
    # id, kind, threshold per 100 km, priority, level
    ("collisionRisk", "collisionRisk", 0.5, 2, "high"),
    ("keepDistance", "tailgating", 3.0, 3, "high"),
    ("anticipation", "harshBraking", 2.0, 4, "medium"),
    ("laneDiscipline", "laneDeparture", 1.0, 4, "medium"),
    ("smoothAcceleration", "harshAcceleration", 3.0, 5, "low"),
]

_TEXTS = {
    "collisionRisk": {
        "title": {"uz": "Oldingi mashinaga e’tibor bering", "ru": "Следите за машиной впереди",
                  "en": "Watch the car ahead"},
        "text": {
            "uz": "100 km ga {v} ta to‘qnashuv xavfi ogohlantirishi (me’yor: {t} dan kam). Telefonni chetga "
                  "qo‘ying, ko‘zingizni yo‘ldan uzmang va oldingi mashina tormozlasa, darhol sekinlashishga tayyor "
                  "turing. Bu kamera asosidagi taxmin.",
            "ru": "{v} предупреждений о риске столкновения на 100 км (норма: меньше {t}). Отложите телефон, не "
                  "отводите взгляд от дороги и будьте готовы сразу притормозить вслед за машиной впереди. Это "
                  "оценка по камере.",
            "en": "{v} collision-risk warnings per 100 km (aim for fewer than {t}). Put the phone away, keep your "
                  "eyes on the road and be ready to brake as soon as the car ahead does. This is a camera-based "
                  "estimate."}},
    "keepDistance": {
        "title": {"uz": "Masofani saqlang: 2 soniya qoidasi", "ru": "Держите дистанцию: правило 2 секунд",
                  "en": "Keep your distance: the 2-second rule"},
        "text": {
            "uz": "100 km ga {v} marta juda yaqin masofa (me’yor: {t} dan kam). Oldingi mashina biror belgidan "
                  "o‘tganda «bir ming bir, bir ming ikki» deb sanang — siz bu belgiga 2 soniyadan oldin yetib "
                  "kelmasligingiz kerak. Yomg‘irda va tunda masofani ikki baravar oshiring. Bu kamera asosidagi "
                  "taxmin.",
            "ru": "{v} случаев слишком малой дистанции на 100 км (норма: меньше {t}). Когда машина впереди "
                  "проезжает ориентир, считайте «раз-и-два» — вы должны доехать до него не раньше чем через 2 "
                  "секунды. В дождь и ночью увеличьте дистанцию вдвое. Это оценка по камере.",
            "en": "{v} tailgating events per 100 km (aim for fewer than {t}). When the car ahead passes a marker, "
                  "count “one thousand one, one thousand two” — you should not reach it in under 2 "
                  "seconds. Double the gap in rain and at night. This is a camera-based estimate."}},
    "keepDistanceGap": {
        "title": {"uz": "Masofani saqlang: 2 soniya qoidasi", "ru": "Держите дистанцию: правило 2 секунд",
                  "en": "Keep your distance: the 2-second rule"},
        "text": {
            "uz": "Harakat vaqtining {v}% ida masofa tavsiya etilganidan kam bo‘lgan (me’yor: {t}% dan kam). "
                  "Oldingi mashina bilan kamida 2 soniyalik oraliq qoldiring, yomg‘irda va tunda — 4 soniya. Bu "
                  "kamera asosidagi taxmin.",
            "ru": "{v}% времени дистанция была меньше рекомендуемой (норма: меньше {t}%). Оставляйте до машины "
                  "впереди не меньше 2 секунд, в дождь и ночью — 4 секунды. Это оценка по камере.",
            "en": "For {v}% of the time the gap was shorter than recommended (aim for under {t}%). Leave at least "
                  "2 seconds to the car ahead, 4 seconds in rain and at night. This is a camera-based estimate."}},
    "speed": {
        "title": {"uz": "Tezlik chegarasiga rioya qiling", "ru": "Соблюдайте ограничение скорости",
                  "en": "Stay within the speed limit"},
        "text": {
            "uz": "Harakat vaqtining {v}% ida tezlik chegaradan oshgan (me’yor: {t}% dan kam). Belgilarni "
                  "kuzating, tezlikni oldindan pasaytiring va tirband bo‘lmagan yo‘lda ham chegaradan oshmang: "
                  "10 km/soat farq to‘xtash yo‘lini sezilarli uzaytiradi.",
            "ru": "{v}% времени в движении скорость превышала ограничение (норма: меньше {t}%). Следите за "
                  "знаками, сбрасывайте скорость заранее и не превышайте даже на свободной дороге: лишние 10 км/ч "
                  "заметно удлиняют тормозной путь.",
            "en": "You were over the limit for {v}% of your moving time (aim for under {t}%). Watch the signs, "
                  "slow down early and stay under the limit even on an empty road: an extra 10 km/h noticeably "
                  "lengthens your stopping distance."}},
    "anticipation": {
        "title": {"uz": "Vaziyatni oldindan ko‘ring", "ru": "Предвидьте ситуацию",
                  "en": "Look further ahead"},
        "text": {
            "uz": "100 km ga {v} marta keskin tormozlash (me’yor: {t} dan kam). Faqat oldingi mashinaga emas, "
                  "uzoqroqqa — svetofor, piyodalar, tirbandlikka qarang va gazni oldindan qo‘yib yuboring. Silliq "
                  "tormozlash yoqilg‘i va tormoz kolodkalarini tejaydi.",
            "ru": "{v} резких торможений на 100 км (норма: меньше {t}). Смотрите дальше машины впереди — на "
                  "светофоры, пешеходов, пробку — и заранее отпускайте газ. Плавное торможение экономит топливо и "
                  "колодки.",
            "en": "{v} harsh-braking events per 100 km (aim for fewer than {t}). Look beyond the car in front — "
                  "lights, pedestrians, queues — and lift off the accelerator early. Smooth braking saves fuel and "
                  "brake pads."}},
    "laneDiscipline": {
        "title": {"uz": "O‘z bo‘lagingizda harakatlaning", "ru": "Держитесь своей полосы",
                  "en": "Stay in your lane"},
        "text": {
            "uz": "100 km ga {v} marta bo‘lakdan chiqish (me’yor: {t} dan kam). Bo‘lakni almashtirishdan oldin "
                  "ko‘zguga qarang va burilish chirog‘ini yoqing; charchaganingizda dam oling. Bu kamera asosidagi "
                  "taxmin.",
            "ru": "{v} выездов из полосы на 100 км (норма: меньше {t}). Перед перестроением смотрите в зеркала и "
                  "включайте поворотник; при усталости делайте перерыв. Это оценка по камере.",
            "en": "{v} lane departures per 100 km (aim for fewer than {t}). Check your mirrors and signal before "
                  "changing lanes, and take a break when you feel tired. This is a camera-based estimate."}},
    "smoothAcceleration": {
        "title": {"uz": "Silliq tezlaning", "ru": "Разгоняйтесь плавно", "en": "Accelerate smoothly"},
        "text": {
            "uz": "100 km ga {v} marta keskin tezlanish (me’yor: {t} dan kam). Gaz pedalini asta bosing — bu "
                  "xavfsizroq, yo‘lovchilar uchun qulayroq va yoqilg‘ini tejaydi.",
            "ru": "{v} резких ускорений на 100 км (норма: меньше {t}). Нажимайте на газ плавно — это безопаснее, "
                  "комфортнее для пассажиров и экономит топливо.",
            "en": "{v} harsh-acceleration events per 100 km (aim for fewer than {t}). Press the accelerator "
                  "gently — it is safer, more comfortable for passengers and saves fuel."}},
    "keepItUp": {
        "title": {"uz": "Ajoyib, shunday davom eting!", "ru": "Отлично, так держать!", "en": "Great, keep it up!"},
        "text": {
            "uz": "So‘nggi 30 kunda jiddiy kamchiliklar topilmadi (o‘rtacha ball: {v}). Masofani saqlashda, "
                  "tezlik chegarasida va piyodalarga yo‘l berishda shu odatni davom ettiring.",
            "ru": "За последние 30 дней серьёзных замечаний нет (средний балл: {v}). Продолжайте держать "
                  "дистанцию, соблюдать скорость и пропускать пешеходов.",
            "en": "No significant issues in the last 30 days (average score: {v}). Keep holding your distance, "
                  "respecting the limit and giving way to pedestrians."}},
}


def _fmt(value: float) -> str:
    return f"{value:.1f}".rstrip("0").rstrip(".") if value != int(value) else str(int(value))


def _texts(key: str, **kw) -> tuple[dict, dict]:
    src = _STRONG.get(key) or _TEXTS[key]
    return dict(src["title"]), {lang: s.format(**kw) for lang, s in src["text"].items()}


def recommendations(trips: Iterable[dict], now: datetime, days: int = 30, limit: int = 5) -> list[dict]:
    """Rule-based advice for the last ``days`` days, at most ``limit``, most important first (``priority`` 1 is the
    highest). Each has ``id``, ``priority``, ``level`` (high|medium|low|info), ``estimate`` (camera-based), the
    ``metric`` it is based on, and ``title``/``text`` in uz/ru/en."""
    recent = in_period(trips, now - timedelta(days=days), None)
    if not recent:
        return []
    events = event_totals(recent)
    km = sum(max(0.0, float(t.get("distanceMeters") or 0)) for t in recent) / 1000
    moving = sum(float(t.get("movingSeconds") or t.get("durationSeconds") or 0) for t in recent)
    over = sum(float(t.get("timeOverLimitSeconds") or 0) for t in recent)
    recs: list[tuple[int, float, dict]] = []

    def add(rid: str, text_key: str, priority: int, level: str, metric: str, value: float, threshold: float,
            unit: str, estimate: bool, **fmt) -> None:
        title, text = _texts(text_key, **fmt)
        ratio = value / threshold if threshold else value
        recs.append((priority, -ratio, {
            "id": rid, "priority": priority, "level": level, "estimate": estimate,
            "metric": {"name": metric, "value": round(value, 2), "threshold": threshold, "unit": unit},
            "title": title, "text": text}))

    for kind in ("pedestrianNotYielded", "redLightRunning", "stopSignIgnored"):
        n = events.get(kind, 0)
        if n > 0:
            add(kind, kind, 1, "high", kind, n, 0, "count", True, n=n)

    if km >= MIN_KM_FOR_RATES:
        tail_done = False
        for rid, kind, threshold, priority, level in _RATE_RULES:
            per100 = events.get(kind, 0) / km * 100
            if per100 > threshold:
                add(rid, rid, priority, level, f"{kind}Per100Km", per100, threshold, "per100km",
                    kind in CAMERA_KINDS, v=_fmt(round(per100, 1)), t=_fmt(threshold))
                tail_done = tail_done or rid == "keepDistance"
        shares = [float(t["shareBelowRecommendedGap"]) for t in recent if t.get("shareBelowRecommendedGap") is not None]
        if not tail_done and shares:
            avg_share = sum(shares) / len(shares)
            if avg_share > 0.25:
                add("keepDistance", "keepDistanceGap", 3, "high", "shareBelowRecommendedGap", avg_share, 0.25,
                    "share", True, v=_fmt(round(avg_share * 100)), t="25")

    if moving >= MIN_MOVING_FOR_SPEED:
        share = over / moving
        if share > 0.02:
            add("speed", "speed", 3, "high" if share > 0.08 else "medium", "speedingShareOfTime", share, 0.02,
                "share", False, v=_fmt(round(share * 100, 1)), t="2")

    if not recs and len(recent) >= 3:
        avg = sum(float(t.get("score") or 0) for t in recent) / len(recent)
        if avg >= 80:
            add("keepItUp", "keepItUp", 9, "info", "averageScore", avg, 80, "score", False, v=_fmt(round(avg)))

    recs.sort(key=lambda r: (r[0], r[1], r[2]["id"]))
    return [r[2] for r in recs[:limit]]


# Charts --------------------------------------------------------------------------------------------------------------
_BAND_NUM = re.compile(r"\d+(?:\.\d+)?")


def band_sort_key(band: str) -> tuple[float, str]:
    m = _BAND_NUM.search(band)
    return (float(m.group()) if m else math.inf, band)


def charts(trips: list[dict], now: datetime, days: int) -> dict:
    """Series for the overview charts over the last ``days`` days (dates/hours in Asia/Tashkent)."""
    start = now - timedelta(days=days)
    recent = in_period(trips, start, None)
    per_day: dict[str, dict] = {}
    heat: dict[tuple[int, int], dict] = {}
    bands: dict[str, float] = {}
    for t in _sorted(recent):
        lt = local_time(t["startedAt"])
        day = lt.strftime("%Y-%m-%d")
        km = max(0.0, float(t.get("distanceMeters") or 0)) / 1000
        d = per_day.setdefault(day, {"date": day, "trips": 0, "km": 0.0, "scoreSum": 0.0})
        d["trips"] += 1
        d["km"] += km
        d["scoreSum"] += float(t.get("score") or 0)
        cell = heat.setdefault((lt.weekday(), lt.hour), {"trips": 0, "km": 0.0})
        cell["trips"] += 1
        cell["km"] += km
        for band, secs in (t.get("speedBands") or {}).items():
            bands[band] = bands.get(band, 0.0) + float(secs or 0)
    km_total = sum(max(0.0, float(t.get("distanceMeters") or 0)) for t in recent) / 1000
    events = event_totals(recent)
    band_total = sum(bands.values())
    return {
        "days": days,
        "from": iso_z(start),
        "to": iso_z(now),
        "daily": [{"date": d["date"], "trips": d["trips"], "km": round(d["km"], 1),
                   "avgScore": round(d["scoreSum"] / d["trips"], 1)} for d in per_day.values()],
        "tripScores": [{"id": t.get("id"), "startedAt": t["startedAt"], "score": t.get("score"),
                        "distanceKm": round(max(0.0, float(t.get("distanceMeters") or 0)) / 1000, 1)}
                       for t in _sorted(recent)],
        "events": sorted(({"kind": k, "count": n, "per100Km": round(n / km_total * 100, 2) if km_total > 0 else None,
                           "estimate": k in CAMERA_KINDS, "info": k in INFO_KINDS}
                          for k, n in events.items() if n > 0),
                         key=lambda e: (-e["count"], e["kind"])),
        "speedBands": [{"band": b, "seconds": round(s), "share": round(s / band_total, 4) if band_total else 0}
                       for b, s in sorted(bands.items(), key=lambda kv: band_sort_key(kv[0]))],
        "heatmap": [{"weekday": wd, "hour": h, "trips": c["trips"], "km": round(c["km"], 1)}
                    for (wd, h), c in sorted(heat.items())],
        "distanceKm": round(km_total, 1),
    }


def summary(trips: list[dict], now: datetime, days: int) -> dict:
    """Overview numbers: level, totals, this period vs the previous one, badges, recommendations, last trip."""
    points = sum(int(t.get("points") or 0) for t in trips)
    start = now - timedelta(days=days)
    ordered = _sorted(trips)
    return {
        "days": days,
        "level": level_info(points),
        "totals": period_stats(trips),
        "period": period_stats(in_period(trips, start, None)),
        "previous": period_stats(in_period(trips, start - timedelta(days=days), start)),
        "badges": compute_badges(trips),
        "recommendations": recommendations(trips, now),
        "lastTrip": ordered[-1] if ordered else None,
        "generatedAt": iso_z(now),
    }
