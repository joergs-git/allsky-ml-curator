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
        GeometryReader { proxy in
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

                if isSelected {
                    Rectangle()
                        .strokeBorder(
                            AppColors.selection(nightMode),
                            lineWidth: 4
                        )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.width)
        }
        .aspectRatio(1, contentMode: .fit)
        .task {
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
