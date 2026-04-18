import Foundation

/// Computes a deterministic reflection-risk score for an allsky frame
/// based on sun and moon geometry. The score feeds two UI cues:
///   - amber halo around matrix tiles that likely carry a reflection
///   - a pre-populated `reflection_flag = 1` suggestion the curator can
///     confirm or dismiss with the `R` key
///
/// The score is rule-based, not learned. After ~300 human labels the
/// app logs correlation between `reflection_flag=1` and this score; if
/// the rules diverge from reality, the thresholds are retuned.
enum ReflectionPrefilter {

    /// Input parameters for scoring a single frame.
    struct Input: Equatable {
        var sunAltDeg: Double
        var moonAltDeg: Double
        var moonIlluminationFraction: Double   // 0.0 new … 1.0 full
        var cameraIsDayCapable: Bool           // mono camera → false
    }

    /// Compute the reflection-risk score ∈ [0, 1]. Higher = more likely
    /// that the frame shows dome / bright-body reflections despite
    /// possibly clear sky.
    static func score(_ input: Input) -> Double {
        var risk = 0.0
        risk = max(risk, sunRisk(sunAltDeg: input.sunAltDeg,
                                 cameraIsDayCapable: input.cameraIsDayCapable))
        risk = max(risk, moonRisk(moonAltDeg: input.moonAltDeg,
                                  illumination: input.moonIlluminationFraction))
        return min(1.0, risk)
    }

    // MARK: - Individual risk contributions

    /// Sun-driven reflection risk.
    ///
    /// - For a mono (non-day-capable) camera, any sun above −6° is an
    ///   exclusion event, not just a reflection risk — but this scorer
    ///   still emits a high value so the UI can show the halo during
    ///   the narrow sliver when the frame exists but is flagged.
    /// - For a color (day-capable) camera, daylight frames need no
    ///   reflection treatment; dawn/dusk twilight is where reflections
    ///   actually appear on the dome.
    private static func sunRisk(
        sunAltDeg: Double,
        cameraIsDayCapable: Bool
    ) -> Double {
        if cameraIsDayCapable {
            // Daylight: no reflection concern — glare model handled elsewhere.
            if sunAltDeg > 0 { return 0.0 }
            // Civil / nautical twilight: reflections appear on the dome
            // and can masquerade as clouds.
            if sunAltDeg > -12 {
                // Linear ramp: 0 at sun_alt = -12°, 1 at sun_alt = +6°.
                return clamp((sunAltDeg + 12) / 18, min: 0, max: 1)
            }
            return 0.0
        } else {
            // Mono camera — there are no useful frames above −6° anyway.
            if sunAltDeg > -6 { return 1.0 }
            if sunAltDeg > -12 { return 0.5 * (sunAltDeg + 12) / 6 }
            return 0.0
        }
    }

    /// Moon-driven reflection risk.
    ///
    /// A half-or-brighter moon above the horizon produces a visible
    /// reflection on the plexiglass dome that easily reads as a cloud
    /// patch in the allsky frame.
    private static func moonRisk(
        moonAltDeg: Double,
        illumination: Double
    ) -> Double {
        if moonAltDeg <= 0 { return 0.0 }
        if illumination < 0.3 { return 0.0 }

        // Two contributing factors:
        //   - how high above the horizon the moon sits (max out at 30°)
        //   - how bright it is (linear in illumination above the 30 %
        //     threshold, saturating at full moon)
        let altitudeFactor = clamp(moonAltDeg / 30.0, min: 0, max: 1)
        let brightnessFactor = clamp(
            (illumination - 0.3) / 0.7, min: 0, max: 1
        )
        return altitudeFactor * brightnessFactor
    }

    // MARK: - Helpers

    private static func clamp(
        _ value: Double, min lower: Double, max upper: Double
    ) -> Double {
        Swift.max(lower, Swift.min(upper, value))
    }
}
