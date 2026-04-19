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
    /// Classifier output for this tile, if the model has been trained
    /// and an embedding exists. Rendered as a ghost badge in the
    /// top-right corner.
    let prediction: ClassifierEngine.Prediction?
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

    /// True when this tile is rated AND the classifier disagrees with
    /// the human label. Used by the label-audit workflow to visually
    /// pick out frames where either the model is wrong or the label
    /// might be. Surfaced as a dashed red border + a class-number
    /// badge so the curator can spot the mismatch without opening
    /// Inspection on every single tile.
    private var isMismatch: Bool {
        guard isRated, let prediction else { return false }
        return prediction.topClass != ratingClass
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
                    if let prediction, !isRated {
                        predictionBadge(prediction)
                            .padding(.trailing, bandWidth + 4)
                            .padding(.top, bandWidth + 4)
                    } else if let prediction, isMismatch {
                        mismatchBadge(prediction)
                            .padding(.trailing, bandWidth + 4)
                            .padding(.top, bandWidth + 4)
                    } else if hasTransitional {
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

            if isMismatch {
                // Dashed warning outline painted *inside* any
                // selection / cursor ring so a selected mismatch
                // still reads as selected first. Colour is a deep
                // warning orange that stays legible on both the
                // light and dark band colours of tier 1 (red) and
                // tier 5 (green) — a pure red border would disappear
                // on class-1 tiles, a pure yellow one on class-4.
                Rectangle()
                    .strokeBorder(
                        Color.orange.opacity(0.95),
                        style: StrokeStyle(
                            lineWidth: 2.5,
                            dash: [5, 3]
                        )
                    )
                    .padding(bandWidth / 2)
            }

            if isCursor {
                // 1 s full-cycle pulse using TimelineView — opacity
                // swings between 0.4 and 1.0 so the keyboard cursor is
                // unmistakable even when the whole page is selected
                // (Cmd+A) and every tile already wears a static
                // selection outline.
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let phase = 0.5 + 0.5 * sin(t * 2 * .pi)   // 1 Hz → 1 s cycle
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
            // Tile-level work is now thumbnail-only. The previous
            // design also kicked off `EmbeddingPipeline.generate`
            // concurrently so unrated tiles would accumulate
            // predictions the moment the classifier was trained —
            // but on libraries with thousands of unrated frames the
            // 3-slot embedding semaphore filled up faster than the
            // cooperative thread pool could drain it, and scroll
            // would stall at a few hundred tiles while the queue
            // grew without bound.
            //
            // Rated images still get their embeddings via the
            // `ContentView.warmRatedEmbeddings` launch-time walker.
            // Unrated frames stay embedding-less until the user
            // explicitly asks the classifier to predict them (via
            // training + `recomputeAllPredictions` or the autonomous
            // rater) — both of which iterate deliberately rather
            // than racing with scroll.
            let filePath = item.image.filePath
            let cameraType = item.image.cameraSource.cameraType
            image = await ThumbnailCache.shared.generate(
                for: filePath, cameraType: cameraType
            )
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

    /// Warning badge shown on rated tiles when the classifier's
    /// top pick disagrees with the human rating. Format: `⚠ {N}`
    /// where N is the class the model would have picked. Tier-
    /// coloured so the curator sees *what* the model predicted, not
    /// just that there's a disagreement — two glances turn into one.
    private func mismatchBadge(
        _ prediction: ClassifierEngine.Prediction
    ) -> some View {
        let color = AppColors.tier(prediction.topClass, night: nightMode)
        return HStack(spacing: 2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8, weight: .black))
            Text("\(prediction.topClass.rawValue)")
                .font(.system(size: 12, weight: .black, design: .monospaced))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(color)
        .clipShape(Capsule())
        .overlay(
            Capsule().stroke(Color.orange, lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 1, y: 1)
    }

    /// Ghost badge showing the classifier's top pick for an unrated
    /// frame. Only rendered when the tile has no human rating yet, so
    /// the prediction never fights with a real rating's stars.
    /// Appearance: "? N" with the tier color of class N and alpha
    /// scaled by the classifier's confidence.
    private func predictionBadge(
        _ prediction: ClassifierEngine.Prediction
    ) -> some View {
        let alpha = max(0.35, min(1.0, Double(prediction.topProbability)))
        let color = AppColors.tier(prediction.topClass, night: nightMode)
        return HStack(spacing: 2) {
            Image(systemName: "brain")
                .font(.system(size: 8, weight: .black))
            Text("\(prediction.topClass.rawValue)")
                .font(.system(size: 12, weight: .black, design: .monospaced))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(color.opacity(alpha))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.5), radius: 1, y: 1)
    }
}
