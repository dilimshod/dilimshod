"""Driver cabinet HTTP API (CABINET_API.md sections 1, 2, 4, 5)."""

from __future__ import annotations

import json
import sqlite3
import uuid
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from roadvis_trainer.config import Settings
from roadvis_trainer.storage import Store, utcnow
from roadvis_trainer.cabinet_api import client_ip, parse_networks

from conftest import ADMIN

WEB = {"X-RoadVis": "1"}


@pytest.fixture
def sclient(app):
    """HTTPS client (session cookies are Secure)."""
    with TestClient(app, base_url="https://testserver") as c:
        yield c


def register(client, **over) -> dict:
    body = {"platform": "ios", "appVersion": "1.4", "deviceName": "iPhone 15", "driverName": "Dilshod",
            "language": "uz", **over}
    r = client.post("/api/v1/devices/register", json=body)
    assert r.status_code == 201, r.text
    return r.json()


def auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def make_trip(trip_id: str | None = None, **over) -> dict:
    t = {
        "id": trip_id or str(uuid.uuid4()), "platform": "ios", "appVersion": "1.4",
        "startedAt": "2026-11-20T08:00:00Z", "endedAt": "2026-11-20T08:35:10Z",
        "distanceMeters": 18250.0, "durationSeconds": 2110.0, "movingSeconds": 1730.0,
        "avgSpeedKmh": 31.1, "maxSpeedKmh": 78.0, "timeOverLimitSeconds": 42.0,
        "score": 86, "arrived": True, "startedWithNavigation": True,
        "origin": {"lat": 41.31, "lon": 69.28, "name": "Yunusobod"},
        "destination": {"lat": 41.29, "lon": 69.21, "name": "TDTU"},
        "eventCounts": {"speeding": 2, "tailgating": 5},
        "speedBands": {"0-20": 300.0, "20-40": 900.0, "40-60": 600.0, "60-80": 300.0, "80+": 10.0},
        "avgLeadDistanceMeters": 14.2, "shareBelowRecommendedGap": 0.18,
        "track": [[41.31, 69.28, 0.0, 0.0, 60], [41.3102, 69.2805, 5.0, 23.5, 60], [41.3105, 69.281, 9.0, None, None]],
        "events": [{"kind": "tailgating", "severity": "warning", "at": "2026-11-20T08:05:00Z", "lat": 41.30,
                    "lon": 69.27, "speedKmh": 45.0, "value": 6.5, "limit": 25.0, "durationSeconds": 4.0}],
    }
    t.update(over)
    return t


def login_web(client, device_token: str) -> str:
    """Runs the QR flow in ``client`` (the browser) approved by ``device_token`` (the app); returns the session."""
    r = client.post("/api/v1/auth/qr")
    assert r.status_code == 200
    ch = r.json()
    nonce = ch["qr"].split("n=")[1]
    r = client.post("/api/v1/auth/qr/approve", headers=auth(device_token),
                    json={"challengeId": ch["challengeId"], "nonce": nonce})
    assert r.status_code == 200 and r.json() == {"ok": True}
    r = client.get(f"/api/v1/auth/qr/{ch['challengeId']}")
    assert r.json() == {"status": "approved"}
    return client.cookies.get("rv_session")


# Registration --------------------------------------------------------------------------------------------------------
def test_register_and_me(client):
    reg = register(client)
    assert len(reg["deviceToken"]) >= 43 and reg["driverName"] == "Dilshod"
    uuid.UUID(reg["driverId"])
    r = client.get("/api/v1/me", headers=auth(reg["deviceToken"]))
    assert r.status_code == 200
    me = r.json()
    assert set(me) == {"driverId", "driverName", "createdAt", "tripCount", "points", "level"}
    assert me["driverId"] == reg["driverId"] and me["tripCount"] == 0 and me["points"] == 0 and me["level"] == 1


def test_registered_token_works_for_samples(client):
    from conftest import upload

    reg = register(client)
    assert upload(client, reg["deviceToken"]).status_code == 201


def test_register_validation_and_defaults(client):
    assert client.post("/api/v1/devices/register", json={"platform": "windows"}).status_code == 422
    assert client.post("/api/v1/devices/register", content=b"not json",
                       headers={"Content-Type": "application/json"}).status_code == 422
    reg = register(client, driverName="  ‮ Ali\n  Valiyev ", language="ru-RU")
    assert reg["driverName"] == "Ali Valiyev"
    reg = register(client, driverName=None, deviceName=None)
    assert reg["driverName"] == "RoadVis"


def test_register_rate_limit(client):
    for _ in range(10):
        register(client)
    r = client.post("/api/v1/devices/register", json={"platform": "android"})
    assert r.status_code == 429 and int(r.headers["Retry-After"]) > 0


def test_register_rate_limit_is_per_client_ip_behind_proxy(app):
    # Requests from the local proxy (127.0.0.1) are told apart by CF-Connecting-IP.
    with TestClient(app, client=("127.0.0.1", 40000)) as proxy:
        for _ in range(10):
            assert proxy.post("/api/v1/devices/register", json={"platform": "ios"},
                              headers={"CF-Connecting-IP": "203.0.113.7"}).status_code == 201
        assert proxy.post("/api/v1/devices/register", json={"platform": "ios"},
                          headers={"CF-Connecting-IP": "203.0.113.7"}).status_code == 429
        assert proxy.post("/api/v1/devices/register", json={"platform": "ios"},
                          headers={"CF-Connecting-IP": "203.0.113.8"}).status_code == 201
    # A direct (untrusted) client cannot pick its address with the header.
    with TestClient(app, client=("198.51.100.1", 40000)) as direct:
        for i in range(10):
            assert direct.post("/api/v1/devices/register", json={"platform": "ios"},
                               headers={"CF-Connecting-IP": f"203.0.114.{i}"}).status_code == 201
        assert direct.post("/api/v1/devices/register", json={"platform": "ios"},
                           headers={"CF-Connecting-IP": "203.0.114.99"}).status_code == 429


def test_client_ip_rules():
    nets = parse_networks("127.0.0.0/8,::1/128,172.16.0.0/12")
    assert client_ip("127.0.0.1", {"cf-connecting-ip": "1.2.3.4", "x-forwarded-for": "5.6.7.8"}, nets) == "1.2.3.4"
    assert client_ip("172.18.0.1", {"x-forwarded-for": "9.9.9.9, 1.2.3.4, 172.18.0.5"}, nets) == "1.2.3.4"
    assert client_ip("127.0.0.1", {"cf-connecting-ip": "garbage", "x-forwarded-for": "8.8.8.8"}, nets) == "8.8.8.8"
    assert client_ip("127.0.0.1", {}, nets) == "127.0.0.1"
    assert client_ip("8.8.4.4", {"cf-connecting-ip": "1.2.3.4"}, nets) == "8.8.4.4"
    assert client_ip("testclient", {"cf-connecting-ip": "1.2.3.4"}, nets) == "testclient"


# Me ------------------------------------------------------------------------------------------------------------------
def test_me_requires_auth(client):
    assert client.get("/api/v1/me").status_code == 401
    assert client.get("/api/v1/me", headers=auth("rvt_nope")).status_code == 401
    assert client.get("/api/v1/me", headers=auth(ADMIN)).status_code == 401   # the admin is not a driver


def test_patch_me(client):
    reg = register(client)
    r = client.patch("/api/v1/me", headers=auth(reg["deviceToken"]), json={"driverName": "Aziz"})
    assert r.status_code == 200 and r.json()["driverName"] == "Aziz"
    assert client.patch("/api/v1/me", headers=auth(reg["deviceToken"]), json={"driverName": "   "}).status_code == 422
    assert client.patch("/api/v1/me", headers=auth(reg["deviceToken"]), json={}).status_code == 422


def test_cli_token_gets_profile_lazily(client, token, store):
    assert store.list_drivers() == []
    r = client.get("/api/v1/me", headers=auth(token))
    assert r.status_code == 200 and r.json()["driverName"] == "test-phone"
    again = client.get("/api/v1/me", headers=auth(token)).json()
    assert again["driverId"] == r.json()["driverId"] and len(store.list_drivers()) == 1


def test_delete_me_deletes_everything(sclient, store, settings):
    reg = register(sclient)
    tok = reg["deviceToken"]
    assert sclient.post("/api/v1/trips", headers=auth(tok), json=make_trip()).status_code == 201
    login_web(sclient, tok)
    r = sclient.delete("/api/v1/me", headers=auth(tok))
    assert r.status_code == 204
    assert sclient.get("/api/v1/me", headers=auth(tok)).status_code == 401
    assert sclient.get("/api/v1/trips").status_code == 401          # the web session is gone too
    with sqlite3.connect(settings.db_path) as db:
        for table in ("drivers", "trips", "web_sessions"):
            assert db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0] == 0
        assert db.execute("SELECT COUNT(*) FROM tokens WHERE driver_id=?", (reg["driverId"],)).fetchone()[0] == 0


def test_delete_me_from_website(sclient):
    reg = register(sclient)
    login_web(sclient, reg["deviceToken"])
    assert sclient.delete("/api/v1/me").status_code == 403           # CSRF header missing
    r = sclient.delete("/api/v1/me", headers=WEB)
    assert r.status_code == 204 and "rv_session" in r.headers.get("set-cookie", "")
    assert sclient.get("/api/v1/me", headers=auth(reg["deviceToken"])).status_code == 401


# Trips ---------------------------------------------------------------------------------------------------------------
def test_trip_upsert_list_get_delete(client):
    tok = register(client)["deviceToken"]
    t = make_trip()
    r = client.post("/api/v1/trips", headers=auth(tok), json=t)
    assert r.status_code == 201 and r.json()["points"] == 177
    r = client.post("/api/v1/trips", headers=auth(tok), json={**t, "score": 50})
    assert r.status_code == 200 and r.json()["status"] == "replaced"
    lst = client.get("/api/v1/trips", headers=auth(tok)).json()
    assert isinstance(lst, list) and len(lst) == 1
    assert "track" not in lst[0] and "events" not in lst[0] and lst[0]["score"] == 50
    full = client.get(f"/api/v1/trips/{t['id']}", headers=auth(tok)).json()
    assert full["track"][2] == [41.3105, 69.281, 9.0, None, None] and full["events"][0]["kind"] == "tailgating"
    assert full["origin"]["name"] == "Yunusobod" and full["startedAt"] == "2026-11-20T08:00:00Z"
    me = client.get("/api/v1/me", headers=auth(tok)).json()
    assert me["tripCount"] == 1 and me["points"] == full["points"] == 91 + 20
    assert client.delete(f"/api/v1/trips/{t['id']}", headers=auth(tok)).status_code == 204
    assert client.get(f"/api/v1/trips/{t['id']}", headers=auth(tok)).status_code == 404
    assert client.delete(f"/api/v1/trips/{t['id']}", headers=auth(tok)).status_code == 404


def test_trip_violation_removes_bonus_and_counts_from_events(client):
    tok = register(client)["deviceToken"]
    t = make_trip(eventCounts={}, events=[
        {"kind": "redLightRunning", "severity": "violation", "at": "2026-11-20T08:06:00Z"},
        {"kind": "tailgating", "severity": "warning", "at": "2026-11-20T08:07:00Z"}])
    assert client.post("/api/v1/trips", headers=auth(tok), json=t).json()["points"] == 157
    full = client.get(f"/api/v1/trips/{t['id']}", headers=auth(tok)).json()
    assert full["eventCounts"] == {"redLightRunning": 1, "tailgating": 1} and full["hasViolation"] is True


def test_trips_are_private(client):
    a, b = register(client)["deviceToken"], register(client)["deviceToken"]
    t = make_trip()
    client.post("/api/v1/trips", headers=auth(a), json=t)
    assert client.get(f"/api/v1/trips/{t['id']}", headers=auth(b)).status_code == 404
    assert client.get("/api/v1/trips", headers=auth(b)).json() == []
    assert client.delete(f"/api/v1/trips/{t['id']}", headers=auth(b)).status_code == 404
    # the same id from another driver is a separate trip
    assert client.post("/api/v1/trips", headers=auth(b), json=t).status_code == 201


@pytest.mark.parametrize("over", [
    {"id": "not-a-uuid"},
    {"score": 101},
    {"platform": "windows"},
    {"endedAt": "2026-11-20T07:00:00Z"},
    {"startedAt": "2030-01-01T00:00:00Z", "endedAt": "2030-01-01T01:00:00Z"},
    {"distanceMeters": -1},
    {"track": [[91, 69.2, 0, 10, 60]]},
    {"track": [[41.3, 69.2]]},
    {"track": [[41.3, 69.2, 0, 900, 60]]},
    {"events": [{"kind": "tailgating", "severity": "bad", "at": "2026-11-20T08:05:00Z"}]},
    {"events": [{"kind": "x y", "severity": "info", "at": "2026-11-20T08:05:00Z"}]},
    {"shareBelowRecommendedGap": 1.5},
    {"startedAt": None},
])
def test_trip_validation(client, over):
    tok = register(client)["deviceToken"]
    r = client.post("/api/v1/trips", headers=auth(tok), json=make_trip(**over))
    assert r.status_code == 422, r.text


def test_trip_limits(client, settings):
    tok = register(client)["deviceToken"]
    assert client.post("/api/v1/trips", json=make_trip()).status_code == 401
    big = make_trip(track=[[41.3, 69.2, float(i), 30.0, 60.0] for i in range(settings.max_track_points + 1)])
    assert client.post("/api/v1/trips", headers=auth(tok), json=big).status_code == 422
    huge = b'{"id": "' + b"x" * (settings.max_trip_bytes + 10) + b'"}'
    r = client.post("/api/v1/trips", headers={**auth(tok), "Content-Type": "application/json"}, content=huge)
    assert r.status_code == 413


def test_trip_daily_limit(client, settings):
    settings.trips_per_day = 3
    tok = register(client)["deviceToken"]
    ids = [str(uuid.uuid4()) for _ in range(3)]
    for i in ids:
        assert client.post("/api/v1/trips", headers=auth(tok), json=make_trip(i)).status_code == 201
    r = client.post("/api/v1/trips", headers=auth(tok), json=make_trip())
    assert r.status_code == 429 and "Retry-After" in r.headers
    # replacing an existing trip is still allowed
    assert client.post("/api/v1/trips", headers=auth(tok), json=make_trip(ids[0])).status_code == 200


def test_trip_list_paging(client):
    tok = register(client)["deviceToken"]
    base = datetime(2026, 11, 1, 8, tzinfo=timezone.utc)
    for i in range(5):
        s = base + timedelta(days=i)
        client.post("/api/v1/trips", headers=auth(tok), json=make_trip(
            startedAt=s.strftime("%Y-%m-%dT%H:%M:%SZ"), endedAt=(s + timedelta(minutes=30)).strftime(
                "%Y-%m-%dT%H:%M:%SZ")))
    page1 = client.get("/api/v1/trips?limit=2", headers=auth(tok)).json()
    assert [t["startedAt"][:10] for t in page1] == ["2026-11-05", "2026-11-04"]
    page2 = client.get(f"/api/v1/trips?limit=2&before={page1[-1]['startedAt']}", headers=auth(tok)).json()
    assert [t["startedAt"][:10] for t in page2] == ["2026-11-03", "2026-11-02"]
    assert client.get("/api/v1/trips?limit=0", headers=auth(tok)).status_code == 422
    assert client.get("/api/v1/trips?before=yesterday", headers=auth(tok)).status_code == 422


# QR login ------------------------------------------------------------------------------------------------------------
def test_qr_flow_sets_session_cookie(sclient, settings):
    reg = register(sclient)
    r = sclient.post("/api/v1/auth/qr")
    ch = r.json()
    assert set(ch) == {"challengeId", "qr", "expiresAt"}
    assert ch["qr"].startswith(f"https://testserver/qr?c={ch['challengeId']}&n=")
    nonce = ch["qr"].split("&n=")[1]
    assert len(nonce) == 32
    assert sclient.get(f"/api/v1/auth/qr/{ch['challengeId']}").json() == {"status": "pending"}
    r = sclient.post("/api/v1/auth/qr/approve", headers=auth(reg["deviceToken"]),
                     json={"challengeId": ch["challengeId"], "nonce": nonce})
    assert r.status_code == 200 and r.json() == {"ok": True}
    r = sclient.get(f"/api/v1/auth/qr/{ch['challengeId']}")
    assert r.json() == {"status": "approved"}
    cookie = [h for h in r.headers.get_list("set-cookie") if h.startswith("rv_session=")][0]
    low = cookie.lower()
    assert "httponly" in low and "secure" in low and "samesite=lax" in low and "path=/" in low
    assert f"max-age={30 * 86400}" in low
    me = sclient.get("/api/v1/me").json()
    assert me["driverId"] == reg["driverId"]
    # one-time: the session is issued once
    assert sclient.get(f"/api/v1/auth/qr/{ch['challengeId']}").json() == {"status": "expired"}
    # stored hashed
    with sqlite3.connect(settings.db_path) as db:
        hashes = [r[0] for r in db.execute("SELECT token_hash FROM web_sessions")]
        nonces = [r[0] for r in db.execute("SELECT nonce_hash FROM qr_challenges")]
    assert sclient.cookies.get("rv_session") not in hashes and nonce not in nonces


def test_qr_cookie_path_follows_root_path(tmp_path):
    from roadvis_trainer.api import create_app

    s = Settings(data_dir=tmp_path / "d", admin_token=ADMIN, root_path="/roadvis")
    s.ensure_dirs()
    with TestClient(create_app(s), base_url="https://testserver") as c:
        tok = register(c)["deviceToken"]
        r = c.post("/roadvis/api/v1/auth/qr")
        ch = r.json()
        assert ch["qr"].startswith("https://testserver/roadvis/qr?c=")
        c.post("/roadvis/api/v1/auth/qr/approve", headers=auth(tok),
               json={"challengeId": ch["challengeId"], "nonce": ch["qr"].split("&n=")[1]})
        r = c.get(f"/roadvis/api/v1/auth/qr/{ch['challengeId']}")
        cookie = [h for h in r.headers.get_list("set-cookie") if h.startswith("rv_session=")][0]
        assert "Path=/roadvis/" in cookie
        assert c.get("/roadvis/api/v1/me").status_code == 200


def test_qr_public_url_setting(settings, app):
    settings.public_url = "https://trafficcounter.uz/roadvis"
    with TestClient(app, base_url="https://testserver") as c:
        assert c.post("/api/v1/auth/qr").json()["qr"].startswith("https://trafficcounter.uz/roadvis/qr?c=")


def test_qr_scheme_from_trusted_proxy(app):
    with TestClient(app, base_url="http://trafficcounter.uz", client=("127.0.0.1", 1)) as c:
        r = c.post("/api/v1/auth/qr", headers={"X-Forwarded-Proto": "https"})
        assert r.json()["qr"].startswith("https://trafficcounter.uz/qr?")
    with TestClient(app, base_url="http://trafficcounter.uz", client=("8.8.8.8", 1)) as c:
        r = c.post("/api/v1/auth/qr", headers={"X-Forwarded-Proto": "https"})
        assert r.json()["qr"].startswith("http://trafficcounter.uz/qr?")


def test_qr_expired(sclient, store):
    tok = register(sclient)["deviceToken"]
    ch = sclient.post("/api/v1/auth/qr").json()
    nonce = ch["qr"].split("&n=")[1]
    with store.connect() as db:
        db.execute("UPDATE qr_challenges SET expires_at=?", ((utcnow() - timedelta(seconds=1))
                                                              .strftime("%Y-%m-%dT%H:%M:%SZ"),))
    assert sclient.get(f"/api/v1/auth/qr/{ch['challengeId']}").json() == {"status": "expired"}
    r = sclient.post("/api/v1/auth/qr/approve", headers=auth(tok), json={"challengeId": ch["challengeId"],
                                                                         "nonce": nonce})
    assert r.status_code == 404


def test_qr_reused(sclient):
    a, b = register(sclient)["deviceToken"], register(sclient)["deviceToken"]
    ch = sclient.post("/api/v1/auth/qr").json()
    body = {"challengeId": ch["challengeId"], "nonce": ch["qr"].split("&n=")[1]}
    assert sclient.post("/api/v1/auth/qr/approve", headers=auth(a), json=body).status_code == 200
    assert sclient.post("/api/v1/auth/qr/approve", headers=auth(b), json=body).status_code == 409
    assert sclient.post("/api/v1/auth/qr/approve", headers=auth(a), json=body).status_code == 409
    assert sclient.get(f"/api/v1/auth/qr/{ch['challengeId']}").json() == {"status": "approved"}
    assert sclient.post("/api/v1/auth/qr/approve", headers=auth(a), json=body).status_code == 409


def test_qr_wrong_nonce_denies(sclient):
    tok = register(sclient)["deviceToken"]
    ch = sclient.post("/api/v1/auth/qr").json()
    nonce = ch["qr"].split("&n=")[1]
    bad = {"challengeId": ch["challengeId"], "nonce": "A" * 32}
    assert sclient.post("/api/v1/auth/qr/approve", headers=auth(tok), json=bad).status_code == 404
    assert sclient.get(f"/api/v1/auth/qr/{ch['challengeId']}").json() == {"status": "denied"}
    good = {"challengeId": ch["challengeId"], "nonce": nonce}
    assert sclient.post("/api/v1/auth/qr/approve", headers=auth(tok), json=good).status_code == 404
    unknown = {"challengeId": str(uuid.uuid4()), "nonce": nonce}
    assert sclient.post("/api/v1/auth/qr/approve", headers=auth(tok), json=unknown).status_code == 404
    assert sclient.post("/api/v1/auth/qr/approve", headers=auth(tok),
                        json={"challengeId": "x", "nonce": nonce}).status_code == 404


def test_qr_foreign_or_missing_token(sclient):
    ch = sclient.post("/api/v1/auth/qr").json()
    body = {"challengeId": ch["challengeId"], "nonce": ch["qr"].split("&n=")[1]}
    assert sclient.post("/api/v1/auth/qr/approve", json=body).status_code == 401
    assert sclient.post("/api/v1/auth/qr/approve", headers=auth("rvt_foreign"), json=body).status_code == 401
    assert sclient.post("/api/v1/auth/qr/approve", headers=auth(ADMIN), json=body).status_code == 401
    # a web session cannot approve (only the app's device token can)
    reg = register(sclient)
    login_web(sclient, reg["deviceToken"])
    ch2 = sclient.post("/api/v1/auth/qr").json()
    body2 = {"challengeId": ch2["challengeId"], "nonce": ch2["qr"].split("&n=")[1]}
    assert sclient.post("/api/v1/auth/qr/approve", headers=WEB, json=body2).status_code == 401
    assert sclient.get(f"/api/v1/auth/qr/{ch2['challengeId']}").json() == {"status": "pending"}


def test_qr_poll_bound_to_browser(app):
    with TestClient(app, base_url="https://testserver") as browser, \
            TestClient(app, base_url="https://testserver") as attacker:
        tok = register(browser)["deviceToken"]
        ch = browser.post("/api/v1/auth/qr").json()
        browser.post("/api/v1/auth/qr/approve", headers=auth(tok),
                     json={"challengeId": ch["challengeId"], "nonce": ch["qr"].split("&n=")[1]})
        assert attacker.get(f"/api/v1/auth/qr/{ch['challengeId']}").status_code == 404
        assert "rv_session" not in attacker.cookies
        assert browser.get(f"/api/v1/auth/qr/{ch['challengeId']}").json() == {"status": "approved"}


def test_qr_unknown_challenge(sclient):
    assert sclient.get(f"/api/v1/auth/qr/{uuid.uuid4()}").status_code == 404
    assert sclient.get("/api/v1/auth/qr/nope").status_code == 404


# Sessions ------------------------------------------------------------------------------------------------------------
def test_session_auth_on_dashboard_endpoints(sclient):
    reg = register(sclient)
    sclient.post("/api/v1/trips", headers=auth(reg["deviceToken"]), json=make_trip())
    for path in ("/api/v1/dashboard/summary", "/api/v1/dashboard/charts", "/api/v1/trips", "/api/v1/me",
                 "/api/v1/me/devices"):
        assert sclient.get(path).status_code == 401, path
    login_web(sclient, reg["deviceToken"])
    s = sclient.get("/api/v1/dashboard/summary?days=90")
    assert s.status_code == 200
    body = s.json()
    assert body["days"] == 90 and body["driver"]["driverId"] == reg["driverId"]
    assert {"level", "totals", "period", "previous", "badges", "recommendations", "lastTrip"} <= set(body)
    assert s.headers["cache-control"] == "no-store"
    c = sclient.get("/api/v1/dashboard/charts?days=365").json()
    assert {"daily", "tripScores", "events", "speedBands", "heatmap"} <= set(c)
    assert sclient.get("/api/v1/dashboard/charts?days=7").status_code == 422
    assert len(sclient.get("/api/v1/trips").json()) == 1
    dev = sclient.get("/api/v1/me/devices").json()
    assert dev["devices"][0]["platform"] == "ios" and dev["sessions"][0]["current"] is True
    # trips cannot be uploaded with a web session
    assert sclient.post("/api/v1/trips", headers=WEB, json=make_trip()).status_code == 401


def test_dashboard_with_bearer(client):
    tok = register(client)["deviceToken"]
    assert client.get("/api/v1/dashboard/summary", headers=auth(tok)).status_code == 200


def test_expired_session(sclient, store):
    reg = register(sclient)
    login_web(sclient, reg["deviceToken"])
    with store.connect() as db:
        db.execute("UPDATE web_sessions SET expires_at='2000-01-01T00:00:00Z'")
    assert sclient.get("/api/v1/me").status_code == 401


def test_csrf_header_required_for_cookie_requests(sclient):
    reg = register(sclient)
    tok = reg["deviceToken"]
    t = make_trip()
    sclient.post("/api/v1/trips", headers=auth(tok), json=t)
    login_web(sclient, tok)
    assert sclient.patch("/api/v1/me", json={"driverName": "X"}).status_code == 403
    assert sclient.delete(f"/api/v1/trips/{t['id']}").status_code == 403
    assert sclient.post("/api/v1/auth/logout-all").status_code == 403
    assert sclient.post("/api/v1/auth/logout").status_code == 403
    assert sclient.patch("/api/v1/me", json={"driverName": "X"}, headers={"X-RoadVis": "0"}).status_code == 403
    assert sclient.patch("/api/v1/me", json={"driverName": "X"}, headers=WEB).status_code == 200
    assert sclient.delete(f"/api/v1/trips/{t['id']}", headers=WEB).status_code == 204
    # bearer requests (the app) do not need the header
    assert sclient.patch("/api/v1/me", json={"driverName": "Y"}, headers=auth(tok)).status_code == 200


def test_logout_and_logout_everywhere(app):
    with TestClient(app, base_url="https://testserver") as b1, TestClient(app, base_url="https://testserver") as b2:
        reg = register(b1)
        tok = reg["deviceToken"]
        login_web(b1, tok)
        login_web(b2, tok)
        r = b1.post("/api/v1/auth/logout", headers=WEB)
        assert r.status_code == 200
        assert b1.get("/api/v1/me").status_code == 401
        assert b2.get("/api/v1/me").status_code == 200
        login_web(b1, tok)
        r = b2.post("/api/v1/auth/logout-all", headers=WEB)
        assert r.status_code == 200 and r.json()["deletedSessions"] == 2
        assert b1.get("/api/v1/me").status_code == 401 and b2.get("/api/v1/me").status_code == 401
        # from the app
        login_web(b1, tok)
        r = b1.post("/api/v1/auth/logout-all", headers=auth(tok))
        assert r.json() == {"ok": True, "deletedSessions": 1}
        assert b1.get("/api/v1/me").status_code == 401


# Admin ---------------------------------------------------------------------------------------------------------------
def test_admin_login_and_overview(sclient):
    tok = register(sclient, driverName="Nodira")["deviceToken"]
    sclient.post("/api/v1/trips", headers=auth(tok), json=make_trip())
    assert sclient.get("/api/v1/admin/overview").status_code == 401
    assert sclient.post("/api/v1/admin/login", json={"token": ADMIN}).status_code == 403     # CSRF header
    assert sclient.post("/api/v1/admin/login", json={"token": "wrong"}, headers=WEB).status_code == 401
    r = sclient.post("/api/v1/admin/login", json={"token": ADMIN}, headers=WEB)
    assert r.status_code == 200
    cookie = [h for h in r.headers.get_list("set-cookie") if h.startswith("rv_admin=")][0].lower()
    assert "httponly" in cookie and "secure" in cookie
    ov = sclient.get("/api/v1/admin/overview").json()
    assert ov["totals"]["drivers"] == 1 and ov["drivers"][0]["driverName"] == "Nodira"
    assert ov["drivers"][0]["tripCount"] == 1 and ov["drivers"][0]["distanceKm"] == 18.2
    # the admin session is not a driver session
    assert sclient.get("/api/v1/me").status_code == 401
    assert sclient.post("/api/v1/admin/logout", headers=WEB).status_code == 200
    assert sclient.get("/api/v1/admin/overview").status_code == 401


def test_admin_overview_with_bearer_and_driver_token_rejected(client):
    tok = register(client)["deviceToken"]
    assert client.get("/api/v1/admin/overview", headers=auth(ADMIN)).status_code == 200
    assert client.get("/api/v1/admin/overview", headers=auth(tok)).status_code == 401


def test_admin_login_rate_limit(sclient):
    for _ in range(10):
        sclient.post("/api/v1/admin/login", json={"token": "wrong"}, headers=WEB)
    assert sclient.post("/api/v1/admin/login", json={"token": ADMIN}, headers=WEB).status_code == 429


# Migration -----------------------------------------------------------------------------------------------------------
def test_migration_from_pre_cabinet_database(tmp_path):
    db_path = tmp_path / "old.sqlite3"
    with sqlite3.connect(db_path) as db:
        db.executescript("""
            CREATE TABLE tokens (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
                token_hash TEXT NOT NULL UNIQUE, created_at TEXT NOT NULL, revoked_at TEXT, last_used_at TEXT);
        """)
        from roadvis_trainer.storage import hash_token

        db.execute("INSERT INTO tokens(name, token_hash, created_at) VALUES('old-phone', ?, '2026-01-01T00:00:00Z')",
                   (hash_token("rvt_old"),))
    store = Store(db_path)
    Store(db_path)  # idempotent
    with store.connect() as db:
        cols = {r["name"] for r in db.execute("PRAGMA table_info(tokens)")}
    assert {"driver_id", "platform", "app_version", "device_name"} <= cols
    assert store.device_for_token("rvt_old")["name"] == "old-phone"
    p = store.token_principal("rvt_old")
    assert p["driver_id"] and store.get_driver(p["driver_id"])["name"] == "old-phone"


# Demo data -----------------------------------------------------------------------------------------------------------
def test_demo_driver(store):
    from roadvis_trainer.demo import create_demo_driver

    driver, token = create_demo_driver(store, trips=6, seed=3)
    trips = store.all_trip_summaries(driver["id"])
    assert len(trips) == 6 and driver["is_demo"] == 1
    for t in trips:
        assert 41.1 < t["origin"]["lat"] < 41.5 and 69.1 < t["origin"]["lon"] < 69.4
        assert t["distanceMeters"] > 1000 and 0 <= t["score"] <= 100
    full = store.get_trip(driver["id"], trips[0]["id"])
    assert 10 < len(full["track"]) <= 2000
    assert store.token_principal(token)["driver_id"] == driver["id"]


def test_cli_driver_commands(settings, monkeypatch, capsys):
    from roadvis_trainer import cli

    monkeypatch.setenv("ROADVIS_DATA_DIR", str(settings.data_dir))
    assert cli.main(["demo-driver", "--trips", "3"]) == 0
    out = capsys.readouterr().out
    assert "rvt_" in out
    assert cli.main(["driver", "list"]) == 0
    listing = capsys.readouterr().out
    driver_id = listing.split()[0]
    assert "trips    3" in listing
    assert cli.main(["driver", "delete", driver_id]) == 0
    assert cli.main(["driver", "delete", driver_id]) == 1
    capsys.readouterr()
    cli.main(["driver", "list"])
    assert "no drivers" in capsys.readouterr().out


# Static pages ---------------------------------------------------------------------------------------------------------
@pytest.mark.parametrize("path", ["/", "/login", "/trips", f"/trips/{uuid.uuid4()}", "/profile", "/admin", "/qr"])
def test_spa_pages_without_prefix(client, path):
    r = client.get(path)
    assert r.status_code == 200 and r.headers["content-type"].startswith("text/html")
    assert '<base href="/">' in r.text
    csp = r.headers["content-security-policy"]
    assert "default-src 'self'" in csp and "https://tiles.openfreemap.org" in csp
    assert r.headers["x-content-type-options"] == "nosniff" and r.headers["referrer-policy"]


@pytest.mark.parametrize("path", ["/roadvis/", "/roadvis/login", "/", "/login"])
def test_spa_pages_with_prefix(tmp_path, path):
    """Behind nginx the prefix is stripped ("/"), when forwarded unchanged it is "/roadvis/"; both work."""
    from roadvis_trainer.api import create_app

    s = Settings(data_dir=tmp_path / "d", admin_token=ADMIN, root_path="/roadvis")
    s.ensure_dirs()
    with TestClient(create_app(s)) as c:
        r = c.get(path)
        assert r.status_code == 200 and '<base href="/roadvis/">' in r.text
        assert c.get(path.rstrip("/").replace("/login", "") + "/static/js/app.js").status_code == 200


def test_static_assets(client):
    for path in ("/static/js/app.js", "/static/js/i18n.js", "/static/css/app.css", "/static/img/logo.png",
                 "/static/vendor/maplibre/maplibre-gl.js", "/static/vendor/echarts/echarts.min.js",
                 "/static/vendor/qrcode/qrcode.js"):
        r = client.get(path)
        assert r.status_code == 200, path
        assert r.headers["x-content-type-options"] == "nosniff"
    assert "max-age" in client.get("/static/vendor/echarts/echarts.min.js").headers["cache-control"]
    assert client.get("/static/../api.py").status_code == 404
    assert client.get("/qr?c=1&n=2").headers["referrer-policy"] == "no-referrer"


def test_existing_endpoints_unchanged(client, token):
    assert client.get("/healthz").json()["status"] == "ok"
    assert client.get("/api/v1/model/latest", headers=auth(token)).status_code == 204
    assert client.get("/api/v1/admin/status", headers=auth(ADMIN)).status_code == 200
    assert json.loads(client.get("/api/v1/admin/status", headers=auth(ADMIN)).text)["samples"] == {}
