import Foundation

/// Astrophoto-usability rating applied by the curator. 0.8.0 collapsed
/// the previous 5-class meteorological-okta scheme (full clouds →
/// clear) into a 3-class decision-theoretic scheme because the okta
/// granularity produced unresolvable label ambiguity — a frame with
/// 50 % horizon cloud but a clear zenith, or a flat thin overcast
/// with stars showing through, had no unambiguous mapping to an okta
/// class. The 3-class scheme asks the only question the downstream
/// consumers (AstroTriage frame-quality, CloudWatcher threshold
/// tuning) actually care about: **can I image through this?**
///
/// Symmetric mapping from the old 5-class labels:
///   1 (full clouds) + 2 (mostly) → 1 (unsuitable)
///   3 (some clouds)              → 2 (partial)
///   4 (thin)       + 5 (clear)   → 3 (suitable)
///
/// Applied by migration `v8_remap_rating_classes_to_three_class` at
/// launch. Lossless given the fixed mapping; any label lifted into a
/// category it doesn't actually belong in (e.g. an old "3 — some
/// clouds" that was really a full-clouds night with a tiny gap) can
/// be re-classified post-migration via the mismatch-audit workflow.
///
/// Orthogonal flags (reflection, transitional) still live on
/// `LabelRecord` separately.
enum RatingClass: Int, Codable, CaseIterable, Sendable {
    case unrated    = 0
    case unsuitable = 1   // don't bother — cloud / fog too heavy
    case partial    = 2   // borderline — maybe wide-field / lucky patches
    case suitable   = 3   // imaging-ready clear sky

    /// Short human-readable name used in tooltips and preferences.
    var shortName: String {
        switch self {
        case .unrated:    return "unrated"
        case .unsuitable: return "unsuitable"
        case .partial:    return "partial"
        case .suitable:   return "suitable"
        }
    }

    /// Decision-theoretic hint alongside the pill in the side panel
    /// so the curator can calibrate on the actual usage question
    /// rather than the prior meteorological-okta estimate.
    var coverageHint: String {
        switch self {
        case .unrated:    return ""
        case .unsuitable: return "don't image"
        case .partial:    return "mosaic / wide-field only"
        case .suitable:   return "full-quality imaging"
        }
    }

    /// Ordinal distance from another class — 0 when identical, 2 at
    /// the extremes (suitable ↔ unsuitable). `.unrated` (0) falls
    /// outside the ordinal axis and returns 0; callers should gate
    /// on `isRated` before invoking `distance`.
    func distance(to other: RatingClass) -> Int {
        guard rawValue > 0, other.rawValue > 0 else { return 0 }
        return abs(rawValue - other.rawValue)
    }
}

/// Label provenance. Distinguishes pure human labels from provisional
/// or confirmed autonomous ones; drives sample-weight in retrain.
enum LabelSource: String, Codable, Sendable {
    case human          = "human"
    case auto           = "auto"           // provisional, excluded from retrain
    case autoConfirmed  = "auto_confirmed" // human-confirmed, weighted 0.3×
}

/// Rating filter applied to the matrix view. Pure rating-class
/// filter — the "only mismatches" dimension is orthogonal and
/// applied as a separate post-fetch predicate in `ContentView` so
/// the two filters compose (e.g. "only class-5 mismatches" = pick
/// clear in the pulldown AND flip the mismatches toggle on).
///
/// Lives here rather than in the UI layer because the database query
/// path uses it too. `displayName` doubles as the picker label.
enum RatingFilter: Hashable, Identifiable, Sendable {
    case any
    case unrated
    case exactly(RatingClass)
    /// 0.8.6: show soft-excluded frames (Backspace no longer
    /// hard-deletes; it flips `images.is_excluded = 1`). This filter
    /// is how the curator resurfaces them to audit or restore.
    case excluded

    var id: String {
        switch self {
        case .any:                   return "any"
        case .unrated:               return "unrated"
        case .exactly(let c):        return "cls\(c.rawValue)"
        case .excluded:              return "excluded"
        }
    }

    var displayName: String {
        switch self {
        case .any:              return "Any rating"
        case .unrated:          return "Only unrated"
        case .exactly(let c):
            return "Only \(c.rawValue) — \(c.shortName)"
        case .excluded:         return "Only excluded (trash)"
        }
    }

    /// All cases in a stable order for the menu.
    static var allCases: [RatingFilter] {
        [
            .any,
            .unrated,
            .exactly(.unsuitable),
            .exactly(.partial),
            .exactly(.suitable),
            .excluded
        ]
    }

    /// Does this filter include the given class?
    func includes(_ cls: RatingClass) -> Bool {
        switch self {
        case .any:              return true
        case .unrated:          return cls == .unrated
        case .exactly(let c):   return cls == c
        case .excluded:         return true
        }
    }

    /// True when this filter is showing the soft-excluded pile —
    /// the matrix needs to flip `includeExcluded` on the DB read AND
    /// restrict to `is_excluded == true`.
    var isExcludedView: Bool {
        if case .excluded = self { return true }
        return false
    }
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
