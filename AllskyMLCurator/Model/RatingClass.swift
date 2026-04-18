import Foundation

/// Cloudiness rating applied by the curator. Orthogonal flags
/// (reflection, transitional) live on `LabelRecord` separately.
enum RatingClass: Int, Codable, CaseIterable, Sendable {
    case unrated   = 0
    case fullCloud = 1
    case mostly    = 2
    case some      = 3
    case thin      = 4  // thin cloud or dust layer
    case clear     = 5

    /// Short human-readable name used in tooltips and preferences.
    var shortName: String {
        switch self {
        case .unrated:   return "unrated"
        case .fullCloud: return "full clouds"
        case .mostly:    return "mostly clouds"
        case .some:      return "some clouds"
        case .thin:      return "thin / dust"
        case .clear:     return "clear"
        }
    }

    /// Whether this class should receive the extra clear-sky training
    /// weight boost. Rheine nights are dominantly cloudy, so rare clear
    /// samples (4 and 5) carry more training signal per instance.
    var isClearSkyBoostEligible: Bool {
        switch self {
        case .thin, .clear: return true
        default:            return false
        }
    }
}

/// Label provenance. Distinguishes pure human labels from provisional
/// or confirmed autonomous ones; drives sample-weight in retrain.
enum LabelSource: String, Codable, Sendable {
    case human          = "human"
    case auto           = "auto"           // provisional, excluded from retrain
    case autoConfirmed  = "auto_confirmed" // human-confirmed, weighted 0.3×
}

/// Time-of-day category derived from sun altitude. Thresholds follow the
/// standard twilight definitions.
enum TimeOfDay: String, Codable, Sendable {
    case day                  = "day"                  // sun_alt > 0°
    case civilTwilight        = "civil_twilight"       // -6°  ≤ sun_alt ≤ 0°
    case nauticalTwilight     = "nautical_twilight"    // -12° ≤ sun_alt < -6°
    case astronomicalTwilight = "astronomical_twilight"// -18° ≤ sun_alt < -12°
    case night                = "night"                // sun_alt < -18°
}
