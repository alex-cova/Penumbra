import CoreGraphics

/// Frame math for the Metal text canvas, factored out of ``LayoutManager`` so it can be
/// unit-tested without a live Metal device.
///
/// The canvas paints an opaque solid background (see `MetalRenderer.setCanvasPaintSpec`), so it
/// must never claim the gutter column (line numbers, fold ribbon) — otherwise it paints straight
/// over them. That is avoided here by insetting the canvas's leading edge by `gutterWidth`, which
/// the caller must also use for the paint spec's `frame` so the background solid matches what is
/// actually shown on screen.
enum MetalCanvasGeometry {
    /// - Parameters:
    ///   - viewport: The layout manager's current viewport, in content space
    ///     (`origin = contentOffset`, `size = visible frame size`).
    ///   - gutterWidth: Total width of the gutter column to exclude from the canvas's leading edge.
    ///   - isScrollViewOverlay: `true` when the canvas is a fixed overlay directly on the scroll
    ///     view (the production Metal path); its on-screen `viewFrame` is then relative to the
    ///     scroll view's own bounds (origin near zero) rather than to content space.
    /// - Returns: `viewFrame` — the canvas view's own frame, in whichever coordinate space
    ///   `isScrollViewOverlay` implies — and `canvasFrame`, the content-space rect to hand to
    ///   `LinePaintBackend.setViewport`/`setCanvasPaintSpec` for shader projection and the
    ///   background solid.
    static func frames(
        viewport: CGRect,
        gutterWidth: CGFloat,
        isScrollViewOverlay: Bool
    ) -> (viewFrame: CGRect, canvasFrame: CGRect) {
        let insetWidth = max(viewport.width - gutterWidth, 0)
        let canvasFrame = CGRect(x: viewport.minX + gutterWidth, y: viewport.minY, width: insetWidth, height: viewport.height)
        if isScrollViewOverlay {
            let viewFrame = CGRect(x: gutterWidth, y: 0, width: insetWidth, height: viewport.height)
            return (viewFrame, canvasFrame)
        } else {
            return (canvasFrame, canvasFrame)
        }
    }
}
