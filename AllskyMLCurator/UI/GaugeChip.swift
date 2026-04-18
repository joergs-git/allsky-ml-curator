import SwiftUI

/// A compact dashboard chip used across the main toolbar. Layout:
///
/// ```
/// ┌─────────────────────────┐
/// │ Title           [ icon ]│
/// │                  ring   │
/// │  BIG number             │
/// │  subtitle               │
/// └─────────────────────────┘
/// ```
///
/// The icon lives inside a circular ring filled with the current
/// `value / range`. Pulsing is driven by the SF Symbol's
/// `.symbolEffect(.pulse)` when `iconAnimates == true` so the chip
/// visibly "thinks" during training / pushing / warming without the
/// caller having to drive any extra animation state.
struct GaugeChip: View {

    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let primaryText: String
    let secondaryText: String
    let iconName: String
    let iconAnimates: Bool
    let tint: Color
    let nightMode: Bool

    private var progress: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(1, max(0, (value - range.lowerBound) / span))
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(AppColors.divider(nightMode), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        tint,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: progress)

                iconView
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 1) {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(AppColors.fgVeryDim(nightMode))
                Text(primaryText)
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(tint)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: true, vertical: false)
                Text(secondaryText)
                    .font(.caption2)
                    .foregroundStyle(AppColors.fgDim(nightMode))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(minWidth: 120, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(AppColors.bgControl(nightMode).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(AppColors.divider(nightMode), lineWidth: 0.5)
        )
    }

    @ViewBuilder private var iconView: some View {
        let base = Image(systemName: iconName)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(tint)
        if iconAnimates {
            base.symbolEffect(.pulse, options: .repeating)
        } else {
            base
        }
    }
}
