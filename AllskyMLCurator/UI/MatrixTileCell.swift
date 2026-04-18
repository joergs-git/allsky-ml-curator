import AppKit
import SwiftUI

/// Single tile in the matrix view. Shows the thumbnail with a border
/// in the current rating's tier color; an amber halo when the
/// reflection flag is set; a violet corner badge when the
/// transitional flag is set.
///
/// Selected tiles carry an accent outline so keyboard navigation is
/// obvious even without a cursor.
struct MatrixTileCell: View {

    let item: ImageLibrary.ImageListItem
    let isSelected: Bool
    let nightMode: Bool

    @State private var image: NSImage?

    private var ratingClass: RatingClass {
        item.label?.ratingClass ?? .unrated
    }

    private var hasReflection: Bool {
        item.label?.reflectionFlag ?? false
    }

    private var hasTransitional: Bool {
        item.label?.transitionalFlag ?? false
    }

    var body: some View {
        ZStack {
            thumbnailLayer
                .overlay(alignment: .topTrailing) {
                    if hasTransitional {
                        flagBadge("T", color: AppColors.transitionalFlag(nightMode))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if hasReflection {
                        flagBadge("R", color: AppColors.reflectionFlag(nightMode))
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(
                            AppColors.tier(ratingClass, night: nightMode),
                            lineWidth: 3
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            isSelected ? AppColors.accent(nightMode) : .clear,
                            lineWidth: isSelected ? 3 : 0
                        )
                        .padding(-3)
                )
        }
        .aspectRatio(1, contentMode: .fit)
        .task {
            image = await ThumbnailCache.shared.generate(for: item.image.filePath)
        }
    }

    // MARK: - Layers

    @ViewBuilder private var thumbnailLayer: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(AppColors.bgControl(nightMode))
                .overlay {
                    ProgressView().controlSize(.small)
                }
        }
    }

    private func flagBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.9))
            .clipShape(Capsule())
            .padding(4)
    }
}
