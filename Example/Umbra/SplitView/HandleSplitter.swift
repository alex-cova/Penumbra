import AppKit
import SwiftUI

/// Umbra's divider: the frame-coloured gap between two islands, with a short capsule at the
/// centre of the seam that only appears under the cursor. The islands already read as separate
/// surfaces, so a resting rule would be the hairline the Islands look removed.
///
/// Conforming to `SplitDivider` is the whole contract for a custom divider: expose a
/// `SplitStyling`, and `Split` will read `visibleThickness` from it to decide how much space to
/// reserve between the panes. Everything else about the view is yours.
struct HandleSplitter: SplitDivider {
    @Environment(LayoutHolder.self) private var layout
    let styling: SplitStyling

    @State private var hovering = false

    /// - Parameters:
    ///   - color: Capsule colour at rest. Clear by default: the gap alone marks the seam.
    ///   - activeColor: Capsule colour while hovered, so the affordance shows under the cursor.
    ///   - thickness: The gap reserved between the two panes.
    ///   - hitThickness: Width of the invisible drag target. Anything wider than `thickness`
    ///     overlays the panes on both sides, and clicks landing there never reach their content
    ///     (the editor's gutter and overlay scroller sit right at a pane edge).
    ///   - handleLength: How far the capsule runs along the seam.
    ///   - handleThickness: How fat the capsule is across the seam.
    ///   - hidesWithPane: Drop the gap and the drag target while a side is hidden, so a hidden
    ///     sidebar leaves no empty seam behind. `SplitPanes.hiddenSide` relies on this.
    init(
        color: Color = .clear,
        activeColor: Color = IDEAppearance.ColorToken.muted.opacity(0.45),
        thickness: CGFloat = IDEAppearance.Spacing.islandGap,
        hitThickness: CGFloat = IDEAppearance.Spacing.islandGap,
        handleLength: CGFloat = 32,
        handleThickness: CGFloat = 3,
        hidesWithPane: Bool = true
    ) {
        self.activeColor = activeColor
        self.handleLength = handleLength
        self.handleThickness = handleThickness
        styling = SplitStyling(
            color: color,
            inset: 0,
            visibleThickness: thickness,
            invisibleThickness: hitThickness,
            hideSplitter: hidesWithPane
        )
    }

    private let activeColor: Color
    private let handleLength: CGFloat
    private let handleThickness: CGFloat

    var body: some View {
        let horizontal = layout.isHorizontal
        // While drag-to-hide is previewing, Split expects the divider to disappear.
        let previewing = styling.previewHide && styling.hideSplitter

        ZStack {
            // The drag target.
            Color.clear
                .frame(
                    width: horizontal ? styling.invisibleThickness : nil,
                    height: horizontal ? nil : styling.invisibleThickness
                )

            Capsule()
                .fill(previewing ? .clear : (hovering ? activeColor : styling.color))
                .frame(
                    width: horizontal ? handleThickness : handleLength,
                    height: horizontal ? handleLength : handleThickness
                )
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            // Nested splits can hand the cursor straight from one divider to another, so always
            // pop before deciding whether to push — popping an empty stack is a no-op.
            NSCursor.pop()
            if inside {
                layout.isHorizontal ? NSCursor.resizeLeftRight.push() : NSCursor.resizeUpDown.push()
            }
        }
    }
}
