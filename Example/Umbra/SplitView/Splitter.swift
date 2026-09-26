//  Vendored from SplitView (MIT) — Copyright (c) 2023 Steven G. Harris.
//  See LICENSE in this directory. Ported for Hextech, then Umbra: `@EnvironmentObject` -> `@Environment`,
//  two-parameter `onChange`, macOS-only cursor handling.

import AppKit
import SwiftUI

/// Custom splitters must conform to SplitDivider, just like the default `Splitter`.
protocol SplitDivider: View {
    var styling: SplitStyling { get }
}

/// The Splitter that separates the `primary` from `secondary` views in a `Split` view.
///
/// The Splitter holds onto `styling`, which is accessed by Split to determine the `visibleThickness` by which
/// the `primary` and `secondary` views are separated. The `styling` also publishes `previewHide`, which
/// specifies whether we are previewing what Split will look like when we hide a side.
struct Splitter: SplitDivider {

    @Environment(LayoutHolder.self) private var layout
    let styling: SplitStyling
    @State private var dividerColor: Color  // Changes based on styling.previewHide
    private var color: Color { privateColor ?? styling.color }
    private var inset: CGFloat { privateInset ?? styling.inset }
    private var visibleThickness: CGFloat { privateVisibleThickness ?? styling.visibleThickness }
    private var invisibleThickness: CGFloat { privateInvisibleThickness ?? styling.invisibleThickness }
    private let privateColor: Color?
    private let privateInset: CGFloat?
    private let privateVisibleThickness: CGFloat?
    private let privateInvisibleThickness: CGFloat?

    // Defaults
    static let defaultColor: Color = IDEAppearance.ColorToken.border
    static let defaultInset: CGFloat = 0
    static let defaultVisibleThickness: CGFloat = 1
    static let defaultInvisibleThickness: CGFloat = 10

    var body: some View {
        ZStack {
            switch layout.value {
            case .horizontal:
                Color.clear
                    .frame(width: invisibleThickness)
                    .padding(0)
                RoundedRectangle(cornerRadius: visibleThickness / 2)
                    .fill(dividerColor)
                    .frame(width: visibleThickness)
                    .padding(EdgeInsets(top: inset, leading: 0, bottom: inset, trailing: 0))
            case .vertical:
                Color.clear
                    .frame(height: invisibleThickness)
                    .padding(0)
                RoundedRectangle(cornerRadius: visibleThickness / 2)
                    .fill(dividerColor)
                    .frame(height: visibleThickness)
                    .padding(EdgeInsets(top: 0, leading: inset, bottom: 0, trailing: inset))
            }
        }
        .contentShape(Rectangle())
        .task { dividerColor = color } // Otherwise, styling.color does not appear at open
        // If we are previewing hiding a side using drag-to-hide, and the splitter will be
        // hidden when the side is hidden (styling.hideSplitter is true), then set the
        // splitter color to clear. When the splitter is actually hidden, it doesn't even
        // exist, but when previewing it does, so we have to make it invisible this way.
        .onChange(of: styling.previewHide) { _, hide in
            if hide {
                dividerColor = styling.hideSplitter ? .clear : privateColor ?? color
            } else {
                dividerColor = privateColor ?? color
            }
        }
        .onHover { inside in
            // With nested split views, it's possible to transition from one Splitter to another,
            // so we always need to pop the current cursor (a no-op when it's the only one). We
            // may or may not push the hover cursor depending on whether it's inside or not.
            NSCursor.pop()
            if inside {
                layout.isHorizontal ? NSCursor.resizeLeftRight.push() : NSCursor.resizeUpDown.push()
            }
        }
    }

    init(color: Color? = nil, inset: CGFloat? = nil, visibleThickness: CGFloat? = nil, invisibleThickness: CGFloat? = nil) {
        privateColor = color
        privateInset = inset
        privateVisibleThickness = visibleThickness
        privateInvisibleThickness = invisibleThickness
        styling = SplitStyling(color: color, inset: inset, visibleThickness: visibleThickness, invisibleThickness: invisibleThickness)
        _dividerColor = State(initialValue: color ?? Self.defaultColor)
    }

    init(styling: SplitStyling) {
        privateColor = styling.color
        privateInset = styling.inset
        privateVisibleThickness = styling.visibleThickness
        privateInvisibleThickness = styling.invisibleThickness
        self.styling = styling
        _dividerColor = State(initialValue: styling.color)
    }
}

extension Splitter {

    /// A Splitter (that responds to changes in layout) that is a line across the full breadth of the view.
    static func line(color: Color? = nil, visibleThickness: CGFloat? = nil) -> Splitter {
        Splitter(color: color, inset: 0, visibleThickness: visibleThickness ?? 1)
    }

    /// An invisible Splitter (that responds to changes in layout) that is a line across the full breadth of the view
    static func invisible() -> Splitter {
        Splitter.line(visibleThickness: 0)
    }

    /// Umbra: the 1pt border rule between two panes *inside* one island (a list beside its
    /// detail), where there is no frame-coloured gap to act as the seam. The drag target is kept
    /// to the island gap's width so it doesn't swallow clicks at either pane's edge.
    static func rule() -> Splitter {
        Splitter(
            color: IDEAppearance.ColorToken.border,
            inset: 0,
            visibleThickness: 1,
            invisibleThickness: IDEAppearance.Spacing.islandGap
        )
    }
}
