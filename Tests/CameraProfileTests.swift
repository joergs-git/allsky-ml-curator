import XCTest
@testable import AllskyMLCurator

/// Coverage for `CameraProfile` JSON decoding. Regression-guards the
/// subtle interaction between `keyDecodingStrategy = .convertFromSnakeCase`
/// and explicit CodingKeys (mixing the two silently breaks decoding —
/// the strategy rewrites incoming keys before the CodingKeys lookup
/// runs, so snake_case raw values no longer match).
final class CameraProfileTests: XCTestCase {

    func testDecodesColorProfileFromSnakeCaseJSON() throws {
        let json = """
        {
          "id": "rheine_color_allsky_2024",
          "display_name": "Rheine color allsky 2024",
          "site": {
            "name": "Rheine",
            "latitude_deg": 52.17,
            "longitude_deg": 7.25,
            "timezone": "Europe/Berlin"
          },
          "sensor": {
            "type": "color",
            "day_capable": true,
            "pixel_width": 1920,
            "pixel_height": 1080,
            "bit_depth": 8,
            "file_format": "jpg"
          },
          "fisheye": {
            "center_x_px": 960,
            "center_y_px": 540,
            "radius_px": 500,
            "ellipse_ratio": 1.0
          },
          "overlay_mask_rects_px": [],
          "orientation": {
            "north_azimuth_deg_at_pixel_up": 0.0,
            "rotation_clockwise": true
          },
          "file_path_patterns": {
            "nas_base": "/volume1/AllSky-Rheine",
            "supabase_column": "allsky_url"
          },
          "calibration": {
            "notes": "placeholder"
          },
          "schema_version": 1
        }
        """
        let profile = try decode(json)

        XCTAssertEqual(profile.id, "rheine_color_allsky_2024")
        XCTAssertEqual(profile.displayName, "Rheine color allsky 2024")
        XCTAssertEqual(profile.site.latitudeDeg, 52.17, accuracy: 0.0001)
        XCTAssertEqual(profile.sensor.type, .color)
        XCTAssertTrue(profile.sensor.dayCapable)
        XCTAssertEqual(profile.sensor.pixelWidth, 1920)
        XCTAssertEqual(profile.fisheye.centerXPx, 960, accuracy: 0.0001)
        XCTAssertEqual(profile.fisheye.radiusPx, 500, accuracy: 0.0001)
        XCTAssertEqual(profile.orientation.northAzimuthDegAtPixelUp, 0.0)
        XCTAssertTrue(profile.orientation.rotationClockwise)
        XCTAssertEqual(profile.filePathPatterns.nasBase, "/volume1/AllSky-Rheine")
        XCTAssertEqual(profile.filePathPatterns.supabaseColumn, "allsky_url")
    }

    func testDecodesMonoProfileExclusionFlag() throws {
        let json = """
        {
          "id": "rheine_mono_zwo_asi290_2024",
          "display_name": "Mono ZWO",
          "site": { "name": "Rheine", "latitude_deg": 52.17,
                    "longitude_deg": 7.25, "timezone": "Europe/Berlin" },
          "sensor": {
            "type": "monochrome",
            "day_capable": false,
            "day_exclusion_sun_alt_deg": -6.0,
            "pixel_width": 1936,
            "pixel_height": 1096,
            "bit_depth": 16,
            "file_format": "fits"
          },
          "fisheye": {
            "center_x_px": 968, "center_y_px": 548,
            "radius_px": 520, "ellipse_ratio": 1.0
          },
          "overlay_mask_rects_px": [],
          "orientation": {
            "north_azimuth_deg_at_pixel_up": 0.0,
            "rotation_clockwise": true
          },
          "file_path_patterns": {
            "nas_base": "/volume1/AllSky-Rheine/zwo",
            "supabase_columns": ["zwo_url", "zwo_fits_url"]
          },
          "calibration": {},
          "schema_version": 1
        }
        """
        let profile = try decode(json)

        XCTAssertEqual(profile.sensor.type, .monochrome)
        XCTAssertFalse(profile.sensor.dayCapable)
        XCTAssertEqual(profile.sensor.dayExclusionSunAltDeg, -6.0)

        // Exclusion rule: mono camera with the sun above the cutoff is
        // never a usable frame; below the cutoff it is.
        XCTAssertTrue(profile.sensor.isExcludedAtSunAlt(+10))
        XCTAssertFalse(profile.sensor.isExcludedAtSunAlt(-10))
        XCTAssertEqual(profile.filePathPatterns.supabaseColumns, ["zwo_url", "zwo_fits_url"])
    }

    func testIgnoresExtraKeysLikeDollarSchemaAndComment() throws {
        // The shipped JSONs carry "$schema" and per-section "comment"
        // fields for developer convenience. Neither exists in the Swift
        // struct; JSONDecoder must silently ignore them.
        let json = """
        {
          "$schema": "../camera_profile.schema.json",
          "id": "test_color_x", "display_name": "Test",
          "site": { "name": "X", "latitude_deg": 0, "longitude_deg": 0,
                    "timezone": "UTC" },
          "sensor": { "type": "color", "day_capable": true,
                      "pixel_width": 1, "pixel_height": 1,
                      "bit_depth": 8, "file_format": "jpg" },
          "fisheye": { "comment": "placeholder",
                       "center_x_px": 0, "center_y_px": 0,
                       "radius_px": 0, "ellipse_ratio": 1.0 },
          "overlay_mask_rects_px": [
            { "comment": "placeholder", "x": 0, "y": 0,
              "width": 0, "height": 0 }
          ],
          "orientation": {
            "comment": "placeholder",
            "north_azimuth_deg_at_pixel_up": 0.0,
            "rotation_clockwise": true
          },
          "file_path_patterns": { "nas_base": "/x" },
          "calibration": { "notes": "placeholder" },
          "schema_version": 1
        }
        """
        XCTAssertNoThrow(try decode(json))
    }

    // MARK: - Helpers

    private func decode(_ json: String) throws -> CameraProfile {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cameraProfileTest-\(UUID()).json")
        try json.data(using: .utf8)!.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try CameraProfile.load(from: tmp)
    }
}
