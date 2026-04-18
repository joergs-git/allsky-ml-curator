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
    // Applied as the tile border in the matrix view and as label badges.
    // Night-mode variants reduce all hues to red so dark-adapted vision
    // is preserved while still distinguishing classes by brightness.

    static func tier(_ ratingClass: RatingClass, night: Bool) -> Color {
        switch ratingClass {
        case .unrated:
            return night ? Color(red: 0.2, green: 0, blue: 0)
                         : Color(white: 0.5)
        case .fullCloud:
            return night ? Color(red: 0.3, green: 0, blue: 0)
                         : Color(red: 0.8, green: 0.27, blue: 0.27)  // #CC4444
        case .mostly:
            return night ? Color(red: 0.45, green: 0, blue: 0)
                         : Color(red: 0.87, green: 0.53, blue: 0.0)  // orange
        case .some:
            return night ? Color(red: 0.6, green: 0, blue: 0)
                         : Color(red: 0.8, green: 0.8, blue: 0.0)    // yellow
        case .thin:
            return night ? Color(red: 0.75, green: 0, blue: 0)
                         : Color(red: 0.27, green: 0.67, blue: 0.27) // green
        case .clear:
            return night ? Color(red: 0.9, green: 0, blue: 0)
                         : Color(red: 0.13, green: 0.8, blue: 0.13)  // bright green
        }
    }

    // MARK: - Orthogonal flag badges

    /// Reflection (`R`) halo / badge color.
    static func reflectionFlag(_ night: Bool) -> Color {
        night ? Color(red: 0.7, green: 0.1, blue: 0)
              : Color(red: 1.0, green: 0.6, blue: 0.0)  // amber
    }

    /// Transitional (`T`) badge color — gain-settling / twilight garbage.
    static func transitionalFlag(_ night: Bool) -> Color {
        night ? Color(red: 0.5, green: 0.1, blue: 0.3)
              : Color(red: 0.6, green: 0.4, blue: 0.8)  // dim violet
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
