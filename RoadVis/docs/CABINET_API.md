# RoadVis driver cabinet — contract (apps ⇄ RoadVis server ⇄ web dashboard)

The RoadVis server (`RoadVisTrainer/`, already running at `https://trafficcounter.uz/roadvis`, see
`TRAINING_API.md`) gets a **driver cabinet**: every phone is a driver profile; finished trips are uploaded
automatically; a modern web dashboard at `https://trafficcounter.uz/roadvis/` shows driving style charts,
violations, recommendations and points. Login on the website is **only by QR code scanned with the RoadVis app**
(no passwords). Everything is free; the existing trafficcounter.uz site is not touched.

Privacy: trips contain GPS tracks. Sync is off until the driver enables «Кабинет водителя» in the app (one switch;
enabling it registers the phone). A driver sees only their own data. "Delete my data" in the app and on the
website deletes the profile, trips and tokens on the server.

## 1. Device registration (driver profile bound to the phone)

`POST /api/v1/devices/register` (no auth; rate limit 10 per IP per hour) — JSON
`{"platform": "ios|android", "appVersion": "1.4", "deviceName": "iPhone 15", "driverName": "Dilshod", "language": "uz|ru|en"}`
→ `201 {"deviceToken": "<opaque, 43+ chars>", "driverId": "<uuid>", "driverName": "Dilshod"}`.
- One driver profile per registration; the token is shown once and stored by the app (iOS Keychain, Android private
  prefs). It is the same kind of bearer token as the training tokens: the app also uses it for
  `/api/v1/samples` (so continuous learning no longer needs a manually created token; a manually entered token
  still works).
- `GET /api/v1/me` (bearer) → `{"driverId", "driverName", "createdAt", "tripCount", "points", "level"}`.
- `PATCH /api/v1/me` (bearer) `{"driverName": "..."}` → updated `me`.
- `DELETE /api/v1/me` (bearer) → `204`; deletes profile, trips, web sessions and the token.
- Existing CLI-created tokens get a driver profile lazily on first use of a cabinet endpoint.

## 2. Trip upload (automatic after every finished trip)

`POST /api/v1/trips` (bearer) — JSON, idempotent by `id` (`201` created, `200` replaced, `401`, `413` > 5 MB,
`422`, `429` > 200 trips/day):
```json
{
  "id": "uuid", "platform": "ios|android", "appVersion": "1.4",
  "startedAt": "2026-11-28T08:00:00Z", "endedAt": "2026-11-28T08:35:10Z",
  "distanceMeters": 18250.0, "durationSeconds": 2110.0, "movingSeconds": 1730.0,
  "avgSpeedKmh": 31.1, "maxSpeedKmh": 78.0, "timeOverLimitSeconds": 42.0,
  "score": 86, "arrived": true, "startedWithNavigation": true,
  "origin": {"lat": 41.31, "lon": 69.28, "name": "Yunusobod"},
  "destination": {"lat": 41.29, "lon": 69.21, "name": "TDTU"},
  "eventCounts": {"speeding": 2, "tailgating": 5},
  "speedBands": {"0-20": 300.0, "20-40": 900.0, "40-60": 600.0, "60-80": 300.0, "80+": 10.0},
  "avgLeadDistanceMeters": 14.2, "shareBelowRecommendedGap": 0.18,
  "track": [[41.31, 69.28, 0.0, 0.0, 60], [41.3102, 69.2805, 5.0, 23.5, 60]],
  "events": [{"kind": "tailgating", "severity": "warning", "at": "2026-11-28T08:05:00Z",
              "lat": 41.30, "lon": 69.27, "speedKmh": 45.0, "value": 6.5, "limit": 25.0, "durationSeconds": 4.0}]
}
```
- `track` rows: `[lat, lon, secondsFromStart, speedKmh|null, speedLimitKmh|null]`, simplified on the phone to
  ≤ 2000 points (Douglas–Peucker 5 m, `Geo.simplify`).
- `kind` = `DrivingEventKind` raw values (`speeding, tailgating, collisionRisk, laneDeparture, redLightRunning,
  stopSignIgnored, pedestrianNotYielded, harshBraking, harshAcceleration, trafficOfficerSeen, roadWorkersSeen`);
  `severity` = `info|warning|violation`. `score` = `TripScoring.score` of the app (0–100). Speed-band keys are the
  `TripSpeedBand` raw values of the core (use them as they are; the server just displays them).
- Trips shorter than 300 m or 60 s are not uploaded. Upload happens right after the trip is saved, retried later
  (on app start / when the network returns) until 2xx; the app keeps a small "pending upload" list of trip ids.
- `GET /api/v1/trips?limit=&before=` (bearer or web session) → list (summary fields, no track);
  `GET /api/v1/trips/{id}` → full trip; `DELETE /api/v1/trips/{id}` → `204`.

## 3. Points, levels, badges, recommendations (computed on the server, deterministic)

- Trip points = `round(score * min(distanceKm, 100) / 10)` + 20 bonus if the trip has no event of severity
  `violation` and distance ≥ 2 km. Total points = sum. Level = `floor(sqrt(points / 50)) + 1`; next-level threshold
  shown as progress.
- Badges (each once): `firstTrip`, `km100` / `km500` / `km1000` (total distance), `clean10` (10 trips in a row
  without violations), `calmDriver` (30 days average score ≥ 90 over ≥ 10 trips), `safeGap` (5 trips in a row with
  `shareBelowRecommendedGap` < 0.1), `nightOwl` (trip started 22:00–05:00 local Asia/Tashkent with score ≥ 90).
- Recommendations: rule-based, per the last 30 days, each with a priority, uz/ru/en text, and the metric it is
  based on (e.g. tailgating per 100 km > 3 → keep-distance advice citing the 2-second rule; speeding share of time
  > 2 % → speed advice; harshBraking per 100 km > 2 → anticipation advice; laneDeparture → lane advice;
  pedestrianNotYielded / redLightRunning / stopSignIgnored any → strong safety advice). At most 5, sorted by
  priority. Texts are advice for a beginner driver; camera-based events are estimates and are labelled so.

## 4. QR login for the website

1. Browser opens `https://trafficcounter.uz/roadvis/` (or `/roadvis/login`) → page calls
   `POST /api/v1/auth/qr` → `{"challengeId": "<uuid>", "qr": "<payload>", "expiresAt": "..."}` (TTL 120 s; the page
   renews automatically). QR payload (also a valid https link):
   `https://trafficcounter.uz/roadvis/qr?c=<challengeId>&n=<nonce>` — `nonce` = 32 random url-safe chars,
   stored hashed.
2. The page polls `GET /api/v1/auth/qr/{challengeId}` every 2 s → `{"status": "pending|approved|expired|denied"}`.
3. The driver taps «Войти на сайт» in the app, scans the QR, sees "Log in on the website as <driverName>?" and
   confirms → app sends `POST /api/v1/auth/qr/approve` (bearer device token) `{"challengeId": "...", "nonce": "..."}`
   → `200 {"ok": true}` (`404` unknown/expired, `409` already used, `401`). The app only accepts payloads whose
   host+path prefix equals its configured server URL (no logging in to foreign sites).
4. On `approved` the polling response sets an httpOnly, Secure, SameSite=Lax session cookie (`rv_session`, 30 days,
   path `/roadvis/`, stored hashed server-side) and returns `{"status": "approved"}`; the page loads the dashboard.
   One-time: the challenge cannot be approved twice. "Log out" deletes the session; "Log out everywhere" (from app
   settings or website) deletes all sessions of the driver.
- If someone opens the QR link in a normal phone browser (no app), the page says to scan it from the RoadVis app.

## 5. Web dashboard (served by the same FastAPI app, static files + JSON API, no build step)

Pages (single-page app under `/roadvis/`, uz/ru/en switcher, default uz, dark+light themes, responsive, logo from
the app): login (big QR, app instructions), overview (points/level progress ring, total km, trips, average score,
score trend line, events per 100 km by kind, speed-band donut, weekly activity heatmap, badges, recommendations),
trips list (date, A→B, km, duration, score chip, events), trip detail (MapLibre GL JS + OpenFreeMap dark map with
the track coloured by speed vs limit, event markers, speed/limit chart over time, events list), profile (driver
name, devices, log out everywhere, delete data). Libraries vendored into the static folder (MapLibre GL JS,
a chart library such as Apache ECharts or Chart.js), so the page works without third-party CDNs.
JSON endpoints for the web (session cookie): `GET /api/v1/dashboard/summary?days=30|90|365`,
`GET /api/v1/dashboard/charts?days=`, plus the trip endpoints above. Admin overview (admin token login form):
list of drivers with totals.
