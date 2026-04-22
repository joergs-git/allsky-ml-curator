// Shared color palette for standard and night mode.
// Night mode: black background + red UI for dark-adapted vision at the
// telescope. Ported from the sibling AstroTriage-blinkV2 project and
// extended with tier colors for the 0-5 rating classes plus the R / T
// flag overlays.

import SwiftUI

enum AppColors {

    // MARK: - Text

    static func fg(_ night: Bool) -> Color {
        night ? .red : Color(NSColor.labelColor)
    }

    static func fgDim(_ night: Bool) -> Color {
        night ? .red.opacity(0.7) : Color(NSColor.secondaryLabelColor)
    }

    static func fgVeryDim(_ night: Bool) -> Color {
        night ? .red.opacity(0.4) : Color(NSColor.tertiaryLabelColor)
    }

    // MARK: - Backgrounds

    static func bg(_ night: Bool) -> Color {
        night ? .black : Color(NSColor.windowBackgroundColor)
    }

    static func bgToolbar(_ night: Bool) -> Color {
        night ? Color(red: 0.06, green: 0, blue: 0)
              : Color(NSColor.underPageBackgroundColor)
    }

    static func bgControl(_ night: Bool) -> Color {
        night ? Color(red: 0.08, green: 0, blue: 0)
              : Color(NSColor.controlBackgroundColor)
    }

    static func bgInput(_ night: Bool) -> Color {
        night ? Color(red: 0.12, green: 0, blue: 0)
              : Color(NSColor.textBackgroundColor)
    }

    // MARK: - Dividers / accents

    static func divider(_ night: Bool) -> Color {
        night ? Color(red: 0.3, green: 0, blue: 0) : Color(NSColor.separatorColor)
    }

    static func accent(_ night: Bool) -> Color {
        night ? Color(red: 0.7, green: 0, blue: 0) : .accentColor
    }

    // MARK: - Rating tier colors
    //
    // Applied as the entire tile padding/border in the matrix view —
    // adjacent tiles of the same rating class visibly merge into a
    // continuous color bar. Colors are deliberately saturated so a
    // rated tile can't be missed at a glance. Night mode collapses
    // them to red-spectrum brightness variants for dark-adapted vision.

    static func tier(_ ratingClass: RatingClass, night: Bool) -> Color {
        switch ratingClass {
        case .unrated:
            // No hue — unrated tiles show transparent/neutral backing so
            // rated ones pop against them.
            return night ? Color(red: 0.05, green: 0, blue: 0)
                         : Color(white: 0.18)
        case .unsuitable:  // 1 — saturated red (don't image)
            return night ? Color(red: 0.50, green: 0, blue: 0)
                         : Color(red: 0.92, green: 0.20, blue: 0.18)
        case .partial:     // 2 — amber (borderline)
            return night ? Color(red: 0.75, green: 0, blue: 0)
                         : Color(red: 0.98, green: 0.70, blue: 0.10)
        case .suitable:    // 3 — bright green (imaging-ready)
            return night ? Color(red: 1.00, green: 0, blue: 0)
                         : Color(red: 0.10, green: 0.78, blue: 0.30)
        }
    }

    /// Selection highlight — a color that always contrasts with the
    /// tier colors (iOS-style bright blue in standard mode, warm red-
    /// orange at night). Used as the thick outline around a selected
    /// tile in the matrix view.
    static func selection(_ night: Bool) -> Color {
        night ? Color(red: 1.0, green: 0.45, blue: 0.15)
              : Color(red: 0.00, green: 0.48, blue: 1.00)
    }

    // MARK: - Orthogonal flag badges

    /// Reflection (`R`) halo / badge color.
    static func reflectionFlag(_ night: Bool) -> Color {
        night ? Color(red: 0.85, green: 0.15, blue: 0)
              : Color(red: 1.00, green: 0.55, blue: 0.00)  // amber
    }

    /// Transitional (`T`) badge color — gain-settling / twilight garbage.
    static func transitionalFlag(_ night: Bool) -> Color {
        night ? Color(red: 0.65, green: 0.15, blue: 0.40)
              : Color(red: 0.70, green: 0.35, blue: 0.95)  // bold violet
    }

    // MARK: - Predictions

    /// Highlight used on the prediction badge overlay while the model's
    /// top-class confidence is below the autonomous threshold.
    static func predictionLowConfidence(_ night: Bool) -> Color {
        night ? Color(red: 0.4, green: 0, blue: 0) : .yellow.opacity(0.8)
    }

    /// Highlight used when prediction confidence crosses the autonomous
    /// threshold and the app is willing to auto-label.
    static func predictionHighConfidence(_ night: Bool) -> Color {
        night ? Color(red: 0.7, green: 0, blue: 0) : .green.opacity(0.9)
    }
}
