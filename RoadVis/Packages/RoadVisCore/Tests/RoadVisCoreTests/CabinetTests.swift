import XCTest
@testable import RoadVisCore

/// `docs/CABINET_API.md` §2 (trip payload) and §4 (QR login payload).
final class CabinetTripPayloadTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Straight track northwards at a constant speed, one point per second.
    private func straightTrip(seconds: Int, speedKmh: Double, limit: Int? = 60) -> Trip {
        var points: [TripPoint] = []
        var position = GeoPoint(41.3, 69.28)
        for i in 0...seconds {
            points.append(TripPoint(date: t0.addingTimeInterval(Double(i)), coordinate: position,
                                    speedKmh: speedKmh, speedLimitKmh: limit, horizontalAccuracy: 5))
            position = Geo.destination(from: position, bearing: 0, distance: speedKmh / 3.6)
        }
        return Trip(startedAt: t0, endedAt: t0.addingTimeInterval(Double(seconds)),
                    origin: TripEndpoint(name: "Yunusobod", coordinate: points.first?.coordinate),
                    destination: TripEndpoint(name: nil, coordinate: points.last?.coordinate), points: points)
    }

    private func json(_ payload: CabinetTripPayload) throws -> [String: Any] {
        let data = try payload.encoded()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testExactKeyNames() throws {
        var trip = straightTrip(seconds: 120, speedKmh: 36)
        trip.arrived = true
        trip.events = [DrivingEvent(kind: .tailgating, severity: .warning, date: t0.addingTimeInterval(30),
                                    coordinate: GeoPoint(41.301, 69.28), speedKmh: 36, value: 6.5, limit: 25,
                                    duration: 4)]
        let payload = try XCTUnwrap(CabinetTripPayload.make(trip: trip, appVersion: "1.4"))
        let object = try json(payload)
        XCTAssertEqual(Set(object.keys), [
            "id", "platform", "appVersion", "startedAt", "endedAt", "distanceMeters", "durationSeconds",
            "movingSeconds", "avgSpeedKmh", "maxSpeedKmh", "timeOverLimitSeconds", "score", "arrived",
            "startedWithNavigation", "origin", "destination", "eventCounts", "speedBands", "avgLeadDistanceMeters",
            "shareBelowRecommendedGap", "track", "events",
        ])
        XCTAssertEqual(object["id"] as? String, trip.id.uuidString.lowercased())
        XCTAssertEqual(object["platform"] as? String, "ios")
        XCTAssertEqual(object["appVersion"] as? String, "1.4")
        XCTAssertEqual(object["startedAt"] as? String, CabinetTripPayload.timestamp(t0))
        XCTAssertTrue((object["startedAt"] as? String ?? "").hasSuffix("Z"))
        XCTAssertEqual(object["arrived"] as? Bool, true)
        XCTAssertEqual(object["startedWithNavigation"] as? Bool, false)
        XCTAssertEqual((object["distanceMeters"] as? Double) ?? 0, 1200, accuracy: 3)
        XCTAssertEqual((object["durationSeconds"] as? Double) ?? 0, 120, accuracy: 1e-9)
        XCTAssertNotNil(object["score"] as? Int)
        XCTAssertTrue(object["avgLeadDistanceMeters"] is NSNull)
        XCTAssertTrue(object["shareBelowRecommendedGap"] is NSNull)

        let origin = try XCTUnwrap(object["origin"] as? [String: Any])
        XCTAssertEqual(Set(origin.keys), ["lat", "lon", "name"])
        XCTAssertEqual(origin["name"] as? String, "Yunusobod")
        let destination = try XCTUnwrap(object["destination"] as? [String: Any])
        XCTAssertTrue(destination["name"] is NSNull)

        XCTAssertEqual(object["eventCounts"] as? [String: Int], ["tailgating": 1])
        let bands = try XCTUnwrap(object["speedBands"] as? [String: Double])
        XCTAssertEqual(Set(bands.keys), Set(TripSpeedBand.allCases.map(\.rawValue)))
        XCTAssertEqual(bands["urban"] ?? 0, 120, accuracy: 1e-9)

        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(Set(events[0].keys),
                       ["kind", "severity", "at", "lat", "lon", "speedKmh", "value", "limit", "durationSeconds"])
        XCTAssertEqual(events[0]["kind"] as? String, "tailgating")
        XCTAssertEqual(events[0]["severity"] as? String, "warning")
        XCTAssertEqual(events[0]["at"] as? String, CabinetTripPayload.timestamp(t0.addingTimeInterval(30)))
        XCTAssertEqual(events[0]["value"] as? Double, 6.5)
        XCTAssertEqual(events[0]["limit"] as? Double, 25)
        XCTAssertEqual(events[0]["durationSeconds"] as? Double, 4)
    }

    func testTimestampsAreISO8601UTC() {
        XCTAssertEqual(CabinetTripPayload.timestamp(Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00Z")
    }

    func testSeverityNames() {
        XCTAssertEqual(CabinetTripPayload.severityName(.info), "info")
        XCTAssertEqual(CabinetTripPayload.severityName(.warning), "warning")
        XCTAssertEqual(CabinetTripPayload.severityName(.violation), "violation")
    }

    func testTrackRowFormat() throws {
        var trip = straightTrip(seconds: 120, speedKmh: 36, limit: nil)
        trip.points[0].speedKmh = nil
        let payload = try XCTUnwrap(CabinetTripPayload.make(trip: trip, appVersion: "1.4"))
        let object = try json(payload)
        let track = try XCTUnwrap(object["track"] as? [[Any]])
        // A straight line simplifies to its two ends.
        XCTAssertEqual(track.count, 2)
        for row in track { XCTAssertEqual(row.count, 5) }
        let first = track[0]
        XCTAssertEqual(first[0] as? Double ?? 0, 41.3, accuracy: 1e-9)
        XCTAssertEqual(first[1] as? Double ?? 0, 69.28, accuracy: 1e-9)
        XCTAssertEqual(first[2] as? Double, 0)
        XCTAssertTrue(first[3] is NSNull)
        XCTAssertTrue(first[4] is NSNull)
        let last = track[1]
        XCTAssertEqual(last[2] as? Double, 120)
        XCTAssertEqual(last[3] as? Double, 36)

        trip = straightTrip(seconds: 120, speedKmh: 36, limit: 60)
        let row = try XCTUnwrap(CabinetTripPayload.track(for: trip).last)
        let data = try JSONEncoder().encode(row)
        XCTAssertEqual(String(decoding: data, as: UTF8.self).filter { $0 == "," }.count, 4)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Any])
        XCTAssertEqual(decoded[4] as? Int, 60)
    }

    func testTrackKeepsTurnsWithinTolerance() {
        // East 60 s, then north 60 s: the corner survives the 5 m simplification.
        var points: [TripPoint] = []
        var position = GeoPoint(41.3, 69.28)
        for i in 0...120 {
            points.append(TripPoint(date: t0.addingTimeInterval(Double(i)), coordinate: position, speedKmh: 36,
                                    horizontalAccuracy: 5))
            position = Geo.destination(from: position, bearing: i < 60 ? 90 : 0, distance: 10)
        }
        let trip = Trip(startedAt: t0, endedAt: t0.addingTimeInterval(120), points: points)
        let track = CabinetTripPayload.track(for: trip)
        XCTAssertEqual(track.count, 3)
        XCTAssertEqual(track[1].secondsFromStart, 60, accuracy: 1e-9)
    }

    func testSimplificationCapsTheTrack() {
        // 6000 points of a winding road with a ±8 m zigzag on top: at 5 m nearly every point survives, so the
        // tolerance has to grow until the 2000-row cap holds (the winding itself stays).
        var points: [TripPoint] = []
        var axis = GeoPoint(41.3, 69.28)
        for i in 0..<6000 {
            let bearing = 90 + 70 * sin(Double(i) / 150)
            let offset = Geo.destination(from: axis, bearing: bearing + 90, distance: i % 2 == 0 ? 8 : -8)
            points.append(TripPoint(date: t0.addingTimeInterval(Double(i)), coordinate: offset, speedKmh: 40,
                                    horizontalAccuracy: 5))
            axis = Geo.destination(from: axis, bearing: bearing, distance: 11)
        }
        XCTAssertGreaterThan(Geo.simplify(points.map(\.coordinate), tolerance: 5).count,
                             CabinetTripPayload.maxTrackPoints)
        let trip = Trip(startedAt: t0, endedAt: t0.addingTimeInterval(6000), points: points)
        let track = CabinetTripPayload.track(for: trip)
        XCTAssertLessThanOrEqual(track.count, CabinetTripPayload.maxTrackPoints)
        XCTAssertGreaterThan(track.count, 2)
        XCTAssertEqual(track.first?.secondsFromStart, 0)
        XCTAssertEqual(track.last?.secondsFromStart, 5999)
        // Time-ordered.
        XCTAssertEqual(track.map(\.secondsFromStart), track.map(\.secondsFromStart).sorted())
        XCTAssertEqual(CabinetTripPayload.maxTrackPoints, 2000)
        XCTAssertEqual(CabinetTripPayload.simplifyToleranceMeters, 5)
    }

    func testSimplifiedIndicesMatchSimplify() {
        var points: [GeoPoint] = []
        var position = GeoPoint(41.3, 69.28)
        for i in 0..<500 {
            points.append(position)
            position = Geo.destination(from: position, bearing: Double((i * 37) % 360), distance: 8)
        }
        XCTAssertEqual(Geo.simplifiedIndices(points, tolerance: 5).map { points[$0] },
                       Geo.simplify(points, tolerance: 5))
        XCTAssertEqual(Geo.simplifiedIndices(points, maxPoints: 50).map { points[$0] },
                       Geo.simplify(points, maxPoints: 50))
    }

    func testSkipRule() {
        // 120 s at 7.2 km/h = 240 m < 300 m.
        XCTAssertNil(CabinetTripPayload.make(trip: straightTrip(seconds: 120, speedKmh: 7.2), appVersion: "1"))
        // 50 s at 72 km/h = 1000 m but < 60 s.
        XCTAssertNil(CabinetTripPayload.make(trip: straightTrip(seconds: 50, speedKmh: 72), appVersion: "1"))
        // 60 s at 36 km/h = 600 m.
        XCTAssertNotNil(CabinetTripPayload.make(trip: straightTrip(seconds: 60, speedKmh: 36), appVersion: "1"))
        XCTAssertFalse(CabinetTripPayload.isUploadable(distanceMeters: 299.9, durationSeconds: 600))
        XCTAssertFalse(CabinetTripPayload.isUploadable(distanceMeters: 5000, durationSeconds: 59.9))
        XCTAssertTrue(CabinetTripPayload.isUploadable(distanceMeters: 300, durationSeconds: 60))
    }

    func testScoreMatchesTripScoring() throws {
        var trip = straightTrip(seconds: 300, speedKmh: 54)
        trip.events = [
            DrivingEvent(kind: .harshBraking, date: t0.addingTimeInterval(10)),
            DrivingEvent(kind: .redLightRunning, severity: .violation, date: t0.addingTimeInterval(20)),
        ]
        let payload = try XCTUnwrap(CabinetTripPayload.make(trip: trip, appVersion: "1"))
        XCTAssertEqual(payload.score, TripScoring.score(for: trip).score)
        XCTAssertEqual(payload.eventCounts, ["harshBraking": 1, "redLightRunning": 1])
        XCTAssertEqual(payload.events.map(\.kind), ["harshBraking", "redLightRunning"])
        XCTAssertTrue(payload.events[0].lat == nil)
    }

    func testUploadOutcome() {
        XCTAssertEqual(CabinetTripUploadOutcome(statusCode: 201), .uploaded)
        XCTAssertEqual(CabinetTripUploadOutcome(statusCode: 200), .uploaded)
        XCTAssertEqual(CabinetTripUploadOutcome(statusCode: 413), .rejected)
        XCTAssertEqual(CabinetTripUploadOutcome(statusCode: 422), .rejected)
        XCTAssertEqual(CabinetTripUploadOutcome(statusCode: 401), .unauthorized)
        XCTAssertEqual(CabinetTripUploadOutcome(statusCode: 429), .retryLater)
        XCTAssertEqual(CabinetTripUploadOutcome(statusCode: 503), .retryLater)
    }

    func testRegisterAndMeBodies() throws {
        let request = CabinetRegisterRequest(platform: "ios", appVersion: "1.4", deviceName: "iPhone",
                                             driverName: "Dilshod", language: "uz")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["platform", "appVersion", "deviceName", "driverName", "language"])

        let registered = try JSONDecoder().decode(CabinetRegisterResponse.self, from: Data("""
        {"deviceToken": "abcdefghijabcdefghijabcdefghijabcdefghij123", "driverId": "9b2f7c1e-0000-4000-8000-000000000001", "driverName": "Dilshod"}
        """.utf8))
        XCTAssertEqual(registered.driverName, "Dilshod")

        let me = try JSONDecoder().decode(CabinetMe.self, from: Data("""
        {"driverId": "d1", "driverName": "Ali", "createdAt": "2026-11-28T08:00:00Z", "tripCount": 3, "points": 412.0, "level": 3}
        """.utf8))
        XCTAssertEqual(me, CabinetMe(driverId: "d1", driverName: "Ali", createdAt: "2026-11-28T08:00:00Z",
                                     tripCount: 3, points: 412, level: 3))
        let rename = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(CabinetRenameRequest(driverName: "Vali"))) as? [String: Any])
        XCTAssertEqual(rename as? [String: String], ["driverName": "Vali"])
    }
}

final class QRLoginPayloadTests: XCTestCase {
    private let base = "https://trafficcounter.uz/roadvis"
    private let challenge = "3f1c2b9a-7d4e-4c1a-9b8e-2a6f0d5c4e3b"
    private let nonce = "Ab3_kLm9-QwErTyUiOp1234567890zXc"   // 32 url-safe chars

    private func link(_ prefix: String = "https://trafficcounter.uz/roadvis") -> String {
        "\(prefix)/qr?c=\(challenge)&n=\(nonce)"
    }

    func testValid() throws {
        let payload = try QRLoginPayload.parse(link(), configuredBase: base).get()
        XCTAssertEqual(payload, QRLoginPayload(challengeId: challenge, nonce: nonce, host: "trafficcounter.uz"))
        // Trailing slash in the configured URL, upper-case host, parameters in another order.
        let swapped = "https://TrafficCounter.uz/roadvis/qr?n=\(nonce)&c=\(challenge)"
        XCTAssertNoThrow(try QRLoginPayload.parse(swapped, configuredBase: base + "/").get())
    }

    func testForeignHost() {
        XCTAssertEqual(QRLoginPayload.parse(link("https://evil.example/roadvis"), configuredBase: base),
                       .failure(.foreignSite))
        XCTAssertEqual(QRLoginPayload.parse(link("https://trafficcounter.uz.evil.example/roadvis"),
                                            configuredBase: base), .failure(.foreignSite))
        XCTAssertEqual(QRLoginPayload.parse(link("https://trafficcounter.uz@evil.example/roadvis"),
                                            configuredBase: base), .failure(.foreignSite))
        XCTAssertEqual(QRLoginPayload.parse(link("https://trafficcounter.uz:8443/roadvis"), configuredBase: base),
                       .failure(.foreignSite))
    }

    func testForeignPath() {
        XCTAssertEqual(QRLoginPayload.parse(link("https://trafficcounter.uz/other"), configuredBase: base),
                       .failure(.foreignSite))
        XCTAssertEqual(QRLoginPayload.parse(link("https://trafficcounter.uz"), configuredBase: base),
                       .failure(.foreignSite))
        XCTAssertEqual(QRLoginPayload.parse(link("https://trafficcounter.uz/roadvis/x"), configuredBase: base),
                       .failure(.foreignSite))
        XCTAssertEqual(QRLoginPayload.parse("https://trafficcounter.uz/roadvis/login?c=\(challenge)&n=\(nonce)",
                                            configuredBase: base), .failure(.foreignSite))
    }

    func testMissingParameters() {
        XCTAssertEqual(QRLoginPayload.parse("https://trafficcounter.uz/roadvis/qr?c=\(challenge)", configuredBase: base),
                       .failure(.missingParameters))
        XCTAssertEqual(QRLoginPayload.parse("https://trafficcounter.uz/roadvis/qr?n=\(nonce)", configuredBase: base),
                       .failure(.missingParameters))
        XCTAssertEqual(QRLoginPayload.parse("https://trafficcounter.uz/roadvis/qr?c=not-a-uuid&n=\(nonce)",
                                            configuredBase: base), .failure(.missingParameters))
        XCTAssertEqual(QRLoginPayload.parse("https://trafficcounter.uz/roadvis/qr?c=\(challenge)&n=short",
                                            configuredBase: base), .failure(.missingParameters))
        XCTAssertEqual(QRLoginPayload.parse("https://trafficcounter.uz/roadvis/qr?c=\(challenge)&n=%3Cscript%3E1234567890123456",
                                            configuredBase: base), .failure(.missingParameters))
        XCTAssertEqual(QRLoginPayload.parse("hello world", configuredBase: base), .failure(.notALink))
        XCTAssertEqual(QRLoginPayload.parse("roadvis://qr?c=\(challenge)&n=\(nonce)", configuredBase: base),
                       .failure(.notALink))
    }

    func testHTTPOnlyForHTTPServer() throws {
        XCTAssertEqual(QRLoginPayload.parse(link("http://trafficcounter.uz/roadvis"), configuredBase: base),
                       .failure(.insecure))
        let local = "http://192.168.1.20:8000/roadvis"
        let payload = try QRLoginPayload.parse(link(local), configuredBase: local).get()
        XCTAssertEqual(payload.host, "192.168.1.20")
        XCTAssertEqual(QRLoginPayload.parse(link("http://192.168.1.20:9000/roadvis"), configuredBase: local),
                       .failure(.foreignSite))
        XCTAssertEqual(QRLoginPayload.parse(link(), configuredBase: "not a url"), .failure(.badConfiguredBase))
    }

    func testApproveOutcome() {
        XCTAssertEqual(QRApproveOutcome(statusCode: 200), .approved)
        XCTAssertEqual(QRApproveOutcome(statusCode: 404), .expired)
        XCTAssertEqual(QRApproveOutcome(statusCode: 409), .alreadyUsed)
        XCTAssertEqual(QRApproveOutcome(statusCode: 401), .unauthorized)
        XCTAssertEqual(QRApproveOutcome(statusCode: 500), .serverError(500))
        let body = try? JSONSerialization.jsonObject(
            with: JSONEncoder().encode(QRApproveRequest(challengeId: challenge, nonce: nonce))) as? [String: String]
        XCTAssertEqual(body, ["challengeId": challenge, "nonce": nonce])
    }
}
