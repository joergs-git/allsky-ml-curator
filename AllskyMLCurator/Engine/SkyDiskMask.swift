import CoreGraphics
import Foundation
import ImageIO

/// Crops an allsky frame to its circular sky disk and neutralises the
/// area outside the circle.
///
/// Why: the ingest pipeline already stripped overlay folders like
/// `keogram/` and `meta/`, but each individual allsky JPG still carries
/// a rectangular sensor frame with burned-in overlay text around the
/// fisheye circle (exposure, gain, stars, moon phase, timestamp…).
/// Feeding that directly into Apple Vision's feature-print extractor
/// would teach the classifier to read the overlay font instead of the
/// sky. The mask zeroes that risk: before the embedding stage we crop
/// to a square around the fisheye circle and paint every pixel
/// outside the circle with neutral 50 % grey, so the embedding sees a
/// uniform context and can only latch onto true sky content.
///
/// For Phase 1.1+ (FITS support) the mask is still useful because
/// FITS fisheye frames are also typically rectangular — the circle
/// geometry values just come from the FITS header instead of
/// `AppSettings`.
enum SkyDiskMask {

    /// Fisheye circle geometry expressed in source-image pixels.
    struct Geometry: Equatable, Sendable {
        var centerXPx: Int
        var centerYPx: Int
        var radiusPx: Int

        /// The geometry currently configured for a given camera type
        /// (Preferences → Camera). Values are user-editable defaults.
        static func fromSettings(for cameraType: CameraType) -> Geometry {
            switch cameraType {
            case .color:
                return Geometry(
                    centerXPx: AppSettings.shared.colorFisheyeCenterXPx,
                    centerYPx: AppSettings.shared.colorFisheyeCenterYPx,
                    radiusPx: AppSettings.shared.colorFisheyeRadiusPx
                )
            case .monochrome:
                return Geometry(
                    centerXPx: AppSettings.shared.monoFisheyeCenterXPx,
                    centerYPx: AppSettings.shared.monoFisheyeCenterYPx,
                    radiusPx: AppSettings.shared.monoFisheyeRadiusPx
                )
            }
        }
    }

    /// Apply the mask to a `CGImage` and return a square result of
    /// side `2 × radius`. Pixels outside the circle are neutral grey.
    ///
    /// The output is an 8-bit sRGB RGBA bitmap — exactly the format
    /// Vision wants for its feature-print extractor, so the caller
    /// can feed the result directly into a `VNImageRequestHandler`.
    static func apply(
        to image: CGImage, geometry: Geometry
    ) -> CGImage? {
        let side = geometry.radiusPx * 2
        guard side > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
                      | CGBitmapInfo.byteOrder32Big.rawValue

        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        // 1. Paint the backdrop with neutral grey (0.5 on every channel).
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))

        // 2. Clip to the circular sky disk and paint the image inside.
        //    The source-image space origin is top-left; CG origin is
        //    bottom-left — we flip Y when computing the draw offset.
        context.saveGState()
        context.addEllipse(in: CGRect(x: 0, y: 0, width: side, height: side))
        context.clip()

        let imageWidth = image.width
        let imageHeight = image.height
        // CG uses a bottom-left origin. The fisheye geometry is
        // expressed top-down (pixel (0, 0) = top-left), so flip Y.
        let drawOriginX = CGFloat(geometry.radiusPx - geometry.centerXPx)
        let drawOriginY = CGFloat(geometry.radiusPx)
            + CGFloat(geometry.centerYPx)
            - CGFloat(imageHeight)
        context.draw(
            image,
            in: CGRect(
                x: drawOriginX,
                y: drawOriginY,
                width: CGFloat(imageWidth),
                height: CGFloat(imageHeight)
            )
        )
        context.restoreGState()

        return context.makeImage()
    }

    /// Convenience: load the image from disk, apply the mask, return.
    static func apply(
        to url: URL, geometry: Geometry
    ) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return apply(to: image, geometry: geometry)
    }
}
