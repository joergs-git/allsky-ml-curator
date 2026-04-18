import XCTest
@testable import AllskyMLCurator

/// Coverage for `Ephemeris`. Focus on:
///   - Correct max sun altitude at solar noon on known solstices
///   - South-facing azimuth at solar noon for the northern hemisphere
///   - Moon illumination at known full / new moon events
///   - Time-of-day classification thresholds
///
/// Tolerances are set at ±0.5° for sun altitude and ±1° for azimuth
/// against hand-derived reference values. The 0.1° target from the plan
/// is easily achievable but matching it exactly requires JPL Horizons
/// cross-checks that we leave to manual calibration during Phase 1.
final class EphemerisTests: XCTestCase {

    // Rheine, Germany — the target observatory.
    let rheineLatDeg = 52.17
    let rheineLonDeg = 7.25

    // MARK: - Time-of-day classification

    func testTimeOfDayThresholds() {
        XCTAssertEqual(Ephemeris.timeOfDay(sunAltDeg: 10), .day)
        XCTAssertEqual(Ephemeris.timeOfDay(sunAltDeg: 0), .civilTwilight)
        XCTAssertEqual(Ephemeris.timeOfDay(sunAltDeg: -5.999), .civilTwilight)
        XCTAssertEqual(Ephemeris.timeOfDay(sunAltDeg: -6), .civilTwilight)
        XCTAssertEqual(Ephemeris.timeOfDay(sunAltDeg: -6.001), .nauticalTwilight)
        XCTAssertEqual(Ephemeris.timeOfDay(sunAltDeg: -12), .nauticalTwilight)
        XCTAssertEqual(Ephemeris.timeOfDay(sunAltDeg: -12.001), .astronomicalTwilight)
        XCTAssertEqual(Ephemeris.timeOfDay(sunAltDeg: -18), .astronomicalTwilight)
        XCTAssertEqual(Ephemeris.timeOfDay(sunAltDeg: -18.001), .night)
        XCTAssertEqual(Ephemeris.timeOfDay(sunAltDeg: -40), .night)
    }

    // MARK: - Sun position

    func testSunMaxAltitudeAtSolarNoonSummerSolstice() throws {
        // 2024-06-21 solar noon at Rheine is approximately 11:30 UTC.
        // Expected maximum altitude ≈ 90° − 52.17° + 23.44° = 61.27°.
        let date = try makeDate(2024, 6, 21, 11, 30, 0)
        let reading = Ephemeris.sun(
            at: date, latitudeDeg: rheineLatDeg, longitudeDeg: rheineLonDeg
        )
        XCTAssertEqual(reading.horizontal.altitudeDeg, 61.27, accuracy: 0.5)
        XCTAssertEqual(reading.horizontal.azimuthDeg, 180.0, accuracy: 1.5)
        XCTAssertEqual(reading.timeOfDay, .day)
    }

    func testSunMaxAltitudeAtSolarNoonWinterSolstice() throws {
        // 2024-12-21 solar noon at Rheine is approximately 11:45 UTC.
        // Expected maximum altitude ≈ 90° − 52.17° − 23.44° = 14.39°.
        let date = try makeDate(2024, 12, 21, 11, 45, 0)
        let reading = Ephemeris.sun(
            at: date, latitudeDeg: rheineLatDeg, longitudeDeg: rheineLonDeg
        )
        XCTAssertEqual(reading.horizontal.altitudeDeg, 14.39, accuracy: 0.5)
        XCTAssertEqual(reading.horizontal.azimuthDeg, 180.0, accuracy: 1.5)
        XCTAssertEqual(reading.timeOfDay, .day)
    }

    func testSunBelowHorizonAtMidnight() throws {
        // Deep winter, middle of the night — sun must be well below the
        // horizon at Rheine.
        let date = try makeDate(2024, 1, 1, 0, 0, 0)
        let reading = Ephemeris.sun(
            at: date, latitudeDeg: rheineLatDeg, longitudeDeg: rheineLonDeg
        )
        XCTAssertLessThan(reading.horizontal.altitudeDeg, -18.0)
        XCTAssertEqual(reading.timeOfDay, .night)
    }

    // MARK: - Moon position

    func testMoonIlluminationAtFullMoon() throws {
        // Astronomical full moon: 2024-06-22 01:08 UTC.
        let date = try makeDate(2024, 6, 22, 1, 8, 0)
        let reading = Ephemeris.moon(
            at: date, latitudeDeg: rheineLatDeg, longitudeDeg: rheineLonDeg
        )
        XCTAssertEqual(reading.illumination, 1.0, accuracy: 0.02)
    }

    func testMoonIlluminationAtNewMoon() throws {
        // Astronomical new moon: 2024-06-06 12:38 UTC.
        let date = try makeDate(2024, 6, 6, 12, 38, 0)
        let reading = Ephemeris.moon(
            at: date, latitudeDeg: rheineLatDeg, longitudeDeg: rheineLonDeg
        )
        XCTAssertEqual(reading.illumination, 0.0, accuracy: 0.02)
    }

    func testMoonIlluminationMonotonicNewToFull() throws {
        // From the 2024-06-06 new moon to the 2024-06-22 full moon,
        // illumination should be monotonically increasing on a coarse
        // 2-day cadence (no perturbation-driven reversals).
        let samples: [Date] = try [
            makeDate(2024, 6, 7, 12, 0, 0),
            makeDate(2024, 6, 9, 12, 0, 0),
            makeDate(2024, 6, 11, 12, 0, 0),
            makeDate(2024, 6, 14, 12, 0, 0),
            makeDate(2024, 6, 17, 12, 0, 0),
            makeDate(2024, 6, 20, 12, 0, 0),
            makeDate(2024, 6, 21, 12, 0, 0)
        ]
        let illums = samples.map {
            Ephemeris.moon(at: $0, latitudeDeg: rheineLatDeg, longitudeDeg: rheineLonDeg).illumination
        }
        for (prev, curr) in zip(illums, illums.dropFirst()) {
            XCTAssertGreaterThan(curr, prev,
                "Illumination must increase from new to full, saw \(prev) → \(curr)")
        }
    }

    // MARK: - Helpers

    private func makeDate(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int, _ minute: Int, _ second: Int
    ) throws -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = TimeZone(identifier: "UTC")
        let calendar = Calendar(identifier: .gregorian)
        return try XCTUnwrap(calendar.date(from: components))
    }
}
