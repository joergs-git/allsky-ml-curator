import AppKit
import SwiftUI

/// A single tile in the matrix view.
///
/// Layout: the entire tile frame is filled with a tier-colored rectangle
/// whenever the frame has been rated. The thumbnail sits inside a small
/// inset, so adjacent tiles of the same class form a visibly continuous
/// color band — the curator can spot groups at a glance. A selection
/// outline (bright accent colour) wraps the whole tile when it is part
/// of the active selection. Stars in the top-left encode the rating
/// class redundantly so the rating reads even at small grid sizes.
struct MatrixTileCell: View {

    let item: ImageLibrary.ImageListItem
    let isSelected: Bool
    /// True when this tile is where the arrow keys will move from next.
    /// Distinguishes the single "active" tile inside a multi-selection.
    let isCursor: Bool
    let nightMode: Bool

    @State private var image: NSImage?

    private var ratingClass: RatingClass {
        item.label?.ratingClass ?? .unrated
    }

    private var isRated: Bool {
        ratingClass != .unrated
    }

    private var hasReflection: Bool {
        item.label?.reflectionFlag ?? false
    }

    private var hasTransitional: Bool {
        item.label?.transitionalFlag ?? false
    }

    private var tierColor: Color {
        AppColors.tier(ratingClass, night: nightMode)
    }

    /// How thick the colored band around the thumbnail should be. The
    /// band is visible only when the tile is rated — unrated tiles get
    /// a 1 px breathing space so the grid is still readable.
    private var bandWidth: CGFloat { isRated ? 6 : 1 }

    var body: some View {
        // `GeometryReader` inside each cell used to drive LazyVGrid into
        // very slow layout convergence at a few thousand items (the
        // visible scroll would stall at ~1000 frames while SwiftUI kept
        // re-measuring). Plain ZStack + aspectRatio is measured once
        // per column-width and scales to thousands of tiles cleanly.
        ZStack {
            backgroundFill

            thumbnailLayer
                .padding(bandWidth)

            VStack {
                HStack(alignment: .top) {
                    if isRated {
                        starsBadge
                            .padding(.leading, bandWidth + 4)
                            .padding(.top, bandWidth + 4)
                    }
                    Spacer()
                    if hasTransitional {
                        flagBadge("T", color: AppColors.transitionalFlag(nightMode))
                            .padding(.trailing, bandWidth + 4)
                            .padding(.top, bandWidth + 4)
                    }
                }
                Spacer()
                if hasReflection {
                    HStack {
                        Spacer()
                        flagBadge("R", color: AppColors.reflectionFlag(nightMode))
                            .padding(.trailing, bandWidth + 4)
                            .padding(.bottom, bandWidth + 4)
                    }
                }
            }

            if isCursor {
                // 0.5 s full-cycle pulse using TimelineView — opacity
                // swings between 0.4 and 1.0 so the keyboard cursor is
                // unmistakable even when the whole page is selected
                // (Cmd+A) and every tile already wears a static
                // selection outline.
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let phase = 0.5 + 0.5 * sin(t * 4 * .pi)   // 2 Hz → 0.5 s cycle
                    Rectangle()
                        .strokeBorder(
                            AppColors.selection(nightMode)
                                .opacity(0.4 + 0.6 * phase),
                            lineWidth: 6
                        )
                }
            } else if isSelected {
                Rectangle()
                    .strokeBorder(
                        AppColors.selection(nightMode),
                        lineWidth: 4
                    )
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: item.image.filePath) {
            image = await ThumbnailCache.shared.generate(for: item.image.filePath)
        }
    }

    // MARK: - Layers

    @ViewBuilder private var backgroundFill: some View {
        if isRated {
            Rectangle().fill(tierColor)
        } else {
            Rectangle().fill(AppColors.bgControl(nightMode))
        }
    }

    @ViewBuilder private var thumbnailLayer: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fill)
                .clipped()
        } else {
            Rectangle()
                .fill(AppColors.bgControl(nightMode))
                .overlay { ProgressView().controlSize(.small) }
        }
    }

    /// 1..5 stars in the tier color, with a dark background plate so
    /// they read over bright sky content too.
    private var starsBadge: some View {
        HStack(spacing: 1) {
            ForEach(0..<ratingClass.rawValue, id: \.self) { _ in
                Image(systemName: "star.fill")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(tierColor)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.black.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func flagBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .black, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.5), radius: 1, y: 1)
    }
}
