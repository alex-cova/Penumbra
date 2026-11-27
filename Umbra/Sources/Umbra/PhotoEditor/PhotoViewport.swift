import CoreGraphics
import Foundation

/// Where the photo sits on the canvas, as an on-screen scale plus a pan offset. Pure and
/// `Sendable` so the geometry is unit-tested without a view.
///
/// `zoom` is **screen points per image pixel**: `1` is actual size (100%), `0.5` is half size,
/// `4` magnifies each source pixel to a 4×4 block. `imageRect(imagePixelSize:in:)` is the single
/// source of truth for the photo's on-screen frame — the crop overlay, grid, loupe, redaction and
/// split-compare all derive from it rather than repeating scale/offset arithmetic.
///
/// Modelled on `ViewportState` (DiagramKit) but not reused: its zoom is world units and its
/// `0.25...4` range is wrong for pixel-level photo inspection.
nonisolated struct PhotoViewport: Equatable, Sendable {
    /// Screen points per image pixel. `1` == actual size == 100%.
    var zoom: CGFloat
    /// Pan in points, measured from the image centred in the canvas.
    var offset: CGSize

    static let minZoom: CGFloat = 0.05
    static let maxZoom: CGFloat = 16

    static let zoomStep: CGFloat = 1.25

    static let identity = PhotoViewport(zoom: 1, offset: .zero)

    init(zoom: CGFloat = 1, offset: CGSize = .zero) {
        self.zoom = Self.clampZoom(zoom)
        self.offset = offset
    }

    static func clampZoom(_ value: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return 1 }
        return min(maxZoom, max(minZoom, value))
    }

    /// Displayed as a whole-number percentage in the canvas badge and header.
    var percent: Int { Int((zoom * 100).rounded()) }

    // MARK: - Framing

    /// Largest zoom that fits the whole image inside `canvasSize`.
    static func fitZoom(imagePixelSize: CGSize, in canvasSize: CGSize) -> CGFloat {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0,
              canvasSize.width > 0, canvasSize.height > 0 else { return 1 }
        return clampZoom(min(
            canvasSize.width / imagePixelSize.width,
            canvasSize.height / imagePixelSize.height
        ))
    }

    /// Smallest zoom that covers `canvasSize` on both axes (the shorter edge touches).
    static func fillZoom(imagePixelSize: CGSize, in canvasSize: CGSize) -> CGFloat {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0,
              canvasSize.width > 0, canvasSize.height > 0 else { return 1 }
        return clampZoom(max(
            canvasSize.width / imagePixelSize.width,
            canvasSize.height / imagePixelSize.height
        ))
    }

    /// Fit-to-window, centred.
    static func fitting(imagePixelSize: CGSize, in canvasSize: CGSize) -> PhotoViewport {
        PhotoViewport(zoom: fitZoom(imagePixelSize: imagePixelSize, in: canvasSize), offset: .zero)
    }

    /// Actual pixels (100%), centred.
    func actualSize() -> PhotoViewport {
        PhotoViewport(zoom: 1, offset: .zero)
    }

    /// Fill the canvas, centred.
    static func filling(imagePixelSize: CGSize, in canvasSize: CGSize) -> PhotoViewport {
        PhotoViewport(zoom: fillZoom(imagePixelSize: imagePixelSize, in: canvasSize), offset: .zero)
    }

    // MARK: - Geometry

    /// The photo's frame on the canvas, in view points.
    func imageRect(imagePixelSize: CGSize, in canvasSize: CGSize) -> CGRect {
        let size = CGSize(width: imagePixelSize.width * zoom, height: imagePixelSize.height * zoom)
        let center = CGPoint(
            x: canvasSize.width / 2 + offset.width,
            y: canvasSize.height / 2 + offset.height
        )
        return CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// View point → image-pixel coordinate (top-left origin, `0...imagePixelSize`). Not clamped.
    func imagePoint(forView viewPoint: CGPoint, imagePixelSize: CGSize, in canvasSize: CGSize) -> CGPoint {
        let rect = imageRect(imagePixelSize: imagePixelSize, in: canvasSize)
        guard zoom > 0 else { return .zero }
        return CGPoint(x: (viewPoint.x - rect.minX) / zoom, y: (viewPoint.y - rect.minY) / zoom)
    }

    // MARK: - Transforms

    func panned(by delta: CGSize) -> PhotoViewport {
        PhotoViewport(
            zoom: zoom,
            offset: CGSize(width: offset.width + delta.width, height: offset.height + delta.height)
        )
    }

    /// Set zoom while keeping the image pixel currently under `viewPoint` pinned to `viewPoint`.
    func zoomed(
        to newZoom: CGFloat,
        toward viewPoint: CGPoint,
        imagePixelSize: CGSize,
        in canvasSize: CGSize
    ) -> PhotoViewport {
        let clamped = Self.clampZoom(newZoom)
        guard zoom > 0, imagePixelSize.width > 0, imagePixelSize.height > 0,
              canvasSize.width > 0, canvasSize.height > 0 else {
            return PhotoViewport(zoom: clamped, offset: offset)
        }
        let rect = imageRect(imagePixelSize: imagePixelSize, in: canvasSize)
        let imageX = (viewPoint.x - rect.minX) / zoom
        let imageY = (viewPoint.y - rect.minY) / zoom
        let newOriginX = viewPoint.x - imageX * clamped
        let newOriginY = viewPoint.y - imageY * clamped
        let newSize = CGSize(width: imagePixelSize.width * clamped, height: imagePixelSize.height * clamped)
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        return PhotoViewport(
            zoom: clamped,
            offset: CGSize(
                width: newOriginX + newSize.width / 2 - center.x,
                height: newOriginY + newSize.height / 2 - center.y
            )
        )
    }

    func zoomedIn(
        toward viewPoint: CGPoint,
        imagePixelSize: CGSize,
        in canvasSize: CGSize,
        step: CGFloat = zoomStep
    ) -> PhotoViewport {
        zoomed(to: zoom * step, toward: viewPoint, imagePixelSize: imagePixelSize, in: canvasSize)
    }

    func zoomedOut(
        toward viewPoint: CGPoint,
        imagePixelSize: CGSize,
        in canvasSize: CGSize,
        step: CGFloat = zoomStep
    ) -> PhotoViewport {
        zoomed(to: zoom / step, toward: viewPoint, imagePixelSize: imagePixelSize, in: canvasSize)
    }

    /// Fit the viewport to a normalized (`0...1`) sub-rect of the image — used by "Zoom to crop".
    func zoomedToRegion(
        _ normalized: CGRect,
        imagePixelSize: CGSize,
        in canvasSize: CGSize,
        margin: CGFloat = 0.94
    ) -> PhotoViewport {
        guard normalized.width > 0, normalized.height > 0,
              imagePixelSize.width > 0, imagePixelSize.height > 0,
              canvasSize.width > 0, canvasSize.height > 0 else { return self }
        let regionPixels = CGSize(
            width: imagePixelSize.width * normalized.width,
            height: imagePixelSize.height * normalized.height
        )
        let fit = Self.clampZoom(min(
            canvasSize.width / regionPixels.width,
            canvasSize.height / regionPixels.height
        ) * margin)
        // Region centre in image pixels, relative to the image centre.
        let regionCenter = CGPoint(
            x: (normalized.midX - 0.5) * imagePixelSize.width,
            y: (normalized.midY - 0.5) * imagePixelSize.height
        )
        return PhotoViewport(
            zoom: fit,
            offset: CGSize(width: -regionCenter.x * fit, height: -regionCenter.y * fit)
        )
    }

    /// Clamp the pan so the image never leaves a dead gap: axes smaller than the canvas centre,
    /// larger axes stop at the edge.
    func clamped(imagePixelSize: CGSize, in canvasSize: CGSize) -> PhotoViewport {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0,
              canvasSize.width > 0, canvasSize.height > 0 else { return self }
        let size = CGSize(width: imagePixelSize.width * zoom, height: imagePixelSize.height * zoom)
        var next = offset
        if size.width <= canvasSize.width {
            next.width = 0
        } else {
            let limit = (size.width - canvasSize.width) / 2
            next.width = min(limit, max(-limit, next.width))
        }
        if size.height <= canvasSize.height {
            next.height = 0
        } else {
            let limit = (size.height - canvasSize.height) / 2
            next.height = min(limit, max(-limit, next.height))
        }
        return PhotoViewport(zoom: zoom, offset: next)
    }
}
