import CoreGraphics
import Foundation

nonisolated enum TransformEngine {
    nonisolated enum AspectPreset: String, CaseIterable, Identifiable, Sendable {
        case original
        case freeform
        case square
        case fourFive
        case sixteenNine
        case threeTwo

        var id: String { rawValue }

        var displayName: LocalizedStringResource {
            switch self {
            case .original: "Original"
            case .freeform: "Freeform"
            case .square: "Square"
            case .fourFive: "4:5"
            case .sixteenNine: "16:9"
            case .threeTwo: "3:2"
            }
        }

        /// Width / height. `nil` for original and freeform (no lock).
        var ratio: CGFloat? {
            switch self {
            case .original, .freeform: nil
            case .square: 1
            case .fourFive: 4 / 5
            case .sixteenNine: 16 / 9
            case .threeTwo: 3 / 2
            }
        }
    }

    /// Normalized (`0...1`) crop rect → integer pixel rect within `pixelSize`.
    static func pixelRect(for normalized: CGRect, in pixelSize: CGSize) -> CGRect {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return .zero }
        let x = (normalized.minX * pixelSize.width).rounded()
        let y = (normalized.minY * pixelSize.height).rounded()
        let width = (normalized.width * pixelSize.width).rounded()
        let height = (normalized.height * pixelSize.height).rounded()
        let integral = CGRect(x: x, y: y, width: max(1, width), height: max(1, height))
        let bounds = CGRect(origin: .zero, size: pixelSize)
        return integral.intersection(bounds)
    }

    /// Inverse of `pixelRect`.
    static func normalizedRect(for pixelRect: CGRect, in pixelSize: CGSize) -> CGRect {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return .zero }
        return CGRect(
            x: pixelRect.minX / pixelSize.width,
            y: pixelRect.minY / pixelSize.height,
            width: pixelRect.width / pixelSize.width,
            height: pixelRect.height / pixelSize.height
        )
    }

    /// UI crop is top-left origin; Core Image extents are bottom-left. Convert a normalized
    /// SwiftUI crop into a pixel rect inside `extent`.
    static func coreImageRect(forNormalizedUI normalized: CGRect, in extent: CGRect) -> CGRect {
        let pixel = pixelRect(for: normalized, in: extent.size)
        return CGRect(
            x: extent.minX + pixel.minX,
            y: extent.minY + (extent.height - pixel.maxY),
            width: pixel.width,
            height: pixel.height
        )
    }

    /// Closest aspect preset for a normalized crop, used when restoring a session.
    static func matchingAspect(for crop: CGRect?) -> AspectPreset {
        guard let crop, crop.height > 0 else { return .original }
        let ratio = crop.width / crop.height
        let locked = AspectPreset.allCases.compactMap { preset -> (AspectPreset, CGFloat)? in
            guard let presetRatio = preset.ratio else { return nil }
            return (preset, abs(presetRatio - ratio))
        }
        if let best = locked.min(by: { $0.1 < $1.1 }), best.1 < 0.02 {
            return best.0
        }
        return .freeform
    }

    /// Affine transform for flip + N quarter-turns + straighten, about the image center,
    /// for an image of `size`. Returns the transform and the resulting bounding size.
    static func orientationTransform(
        flipH: Bool,
        flipV: Bool,
        quarterTurns: Int,
        straightenDegrees: Double,
        size: CGSize
    ) -> (transform: CGAffineTransform, outputSize: CGSize) {
        let turns = ((quarterTurns % 4) + 4) % 4
        let radians = Double(turns) * (.pi / 2) + straightenDegrees * (.pi / 180)

        let toCenter = CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2)
        var centered = CGAffineTransform.identity
        if flipH { centered = centered.scaledBy(x: -1, y: 1) }
        if flipV { centered = centered.scaledBy(x: 1, y: -1) }
        if radians != 0 {
            centered = centered.rotated(by: CGFloat(radians))
        }

        let combined = toCenter.concatenating(centered)
        let corners = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: size.width, y: 0),
            CGPoint(x: size.width, y: size.height),
            CGPoint(x: 0, y: size.height),
        ].map { $0.applying(combined) }

        let minX = corners.map(\.x).min() ?? 0
        let minY = corners.map(\.y).min() ?? 0
        let maxX = corners.map(\.x).max() ?? 0
        let maxY = corners.map(\.y).max() ?? 0
        let outputSize = CGSize(width: maxX - minX, height: maxY - minY)
        let toPositive = CGAffineTransform(translationX: -minX, y: -minY)
        return (combined.concatenating(toPositive), outputSize)
    }

    /// Conform a normalized (`0...1`) crop to a pixel-space aspect `ratio` (width / height) while
    /// keeping `anchor` pinned. Working in real pixels — not a fake square space — is what makes a
    /// "16:9" lock actually 16:9 on a 3:2 source. A `nil` ratio returns `rect` unchanged.
    static func constrainedCrop(
        _ rect: CGRect,
        ratio: CGFloat?,
        anchor: CropAnchor,
        imagePixelSize: CGSize
    ) -> CGRect {
        guard let ratio, ratio > 0,
              imagePixelSize.width > 0, imagePixelSize.height > 0 else { return rect }
        let std = rect.standardized
        let originalPixels = CGRect(
            x: std.minX * imagePixelSize.width,
            y: std.minY * imagePixelSize.height,
            width: std.width * imagePixelSize.width,
            height: std.height * imagePixelSize.height
        )
        var pixels = originalPixels
        switch anchor {
        case .left, .right:
            // A vertical edge was dragged: width is user-driven, derive height.
            pixels.size.height = pixels.width / ratio
        case .top, .bottom:
            pixels.size.width = pixels.height * ratio
        default:
            if pixels.width / max(pixels.height, 0.0001) > ratio {
                pixels.size.width = pixels.height * ratio
            } else {
                pixels.size.height = pixels.width / ratio
            }
        }
        let pinned = anchor.point(in: originalPixels)
        let moved = anchor.point(in: pixels)
        pixels.origin.x += pinned.x - moved.x
        pixels.origin.y += pinned.y - moved.y
        return CGRect(
            x: pixels.minX / imagePixelSize.width,
            y: pixels.minY / imagePixelSize.height,
            width: pixels.width / imagePixelSize.width,
            height: pixels.height / imagePixelSize.height
        )
    }

    /// Largest rect of `ratio` centered in `bounds` (for aspect-locked crop).
    /// A `nil` ratio returns `bounds` unchanged.
    static func fittedRect(ratio: CGFloat?, in bounds: CGRect) -> CGRect {
        guard let ratio, ratio > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let boundsRatio = bounds.width / bounds.height
        let size: CGSize
        if boundsRatio > ratio {
            let height = bounds.height
            size = CGSize(width: height * ratio, height: height)
        } else {
            let width = bounds.width
            size = CGSize(width: width, height: width / ratio)
        }
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}
