//  Vendored from SplitView (MIT) — Copyright (c) 2023 Steven G. Harris.
//  See LICENSE in this directory. Ported for Hextech, then Umbra: Combine-era observation -> `@Observable`.

import Observation
import SwiftUI

@MainActor
@Observable
final class SplitStyling {
    /// Color of the visible part of the default Splitter.
    var color: Color
    /// The inset for the visible part of the default Splitter from the ends it reaches to.
    var inset: CGFloat
    /// The visible thickness of the default Splitter and the `spacing` between the `primary` and `secondary` views.
    var visibleThickness: CGFloat
    /// The thickness across which the dragging will be detected.
    var invisibleThickness: CGFloat
    /// Whether to hide the splitter along with the side when SplitSide is set.
    var hideSplitter: Bool
    /// Whether we are previewing what hiding will look like.
    var previewHide: Bool

    init(color: Color? = nil, inset: CGFloat? = nil, visibleThickness: CGFloat? = nil, invisibleThickness: CGFloat? = nil, hideSplitter: Bool = false) {
        self.color = color ?? Splitter.defaultColor
        self.inset = inset ?? Splitter.defaultInset
        self.visibleThickness = visibleThickness ?? Splitter.defaultVisibleThickness
        self.invisibleThickness = invisibleThickness ?? Splitter.defaultInvisibleThickness
        self.hideSplitter = hideSplitter
        self.previewHide = false        // We never start out previewing
    }

    /// Splitter holds onto a single SplitStyling instance, so switching styling means mutating it in place.
    func reset(from styling: SplitStyling) {
        color = styling.color
        inset = styling.inset
        visibleThickness = styling.visibleThickness
        invisibleThickness = styling.invisibleThickness
        hideSplitter = styling.hideSplitter
        previewHide = styling.previewHide
    }
}
