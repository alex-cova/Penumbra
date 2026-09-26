//  Vendored from SplitView (MIT) — Copyright (c) 2023 Steven G. Harris.
//  See LICENSE in this directory. Ported for Hextech, then Umbra: `@ObservedObject`/`@EnvironmentObject`
//  replaced by `@Observable` holders + `.environment`, two-parameter `onChange`.

import SwiftUI

/// A View with a draggable `splitter` between `primary` and `secondary`.
///
/// Views are layed out either horizontally or vertically as defined by `layout`
/// and separated by `spacing()`,  and the `splitter` is  centered within it.
///
/// The same Split view is used regardless of `layout`, since the math is all the same but applied
/// to width or height depending on whether `layout.isHorizontal` or not.
struct Split<P: View, D: SplitDivider, S: View>: View {

    /// The `primary` View, left when `layout==.horizontal`, top when `layout==.vertical`.
    private let primary: P
    /// The `secondary` View, right when `layout==.horizontal`, bottom when `layout==.vertical`.
    private let secondary: S
    /// The `splitter` View that sits between `primary` and `secondary`.
    private let splitter: D
    /// The constraints within which the splitter can travel and which side if any has priority
    private let constraints: SplitConstraints
    /// Function to execute with `constrainedFraction` as argument during drag
    private let onDrag: ((CGFloat) -> Void)?
    /// The minimum fraction of full width/height that `primary` can occupy
    private let minPFraction: CGFloat?
    /// The minimum fraction of full width/height that `secondary` can occupy
    private let minSFraction: CGFloat?
    /// Whether `primary` can be hidden by dragging beyond half of `minPFraction`
    private let dragToHideP: Bool
    /// Whether `secondary` can be hidden by dragging beyond half of `minSFraction`
    private let dragToHideS: Bool
    /// Used to change the SplitLayout of a Split
    private let layout: LayoutHolder
    /// Only affects the initial layout, but updated to `constrainedFraction` after dragging ends.
    private let fraction: FractionHolder
    /// Use to hide/show `secondary` independent of dragging. When value is `false`, will restore to `constrainedFraction`.
    private let hide: SideHolder
    /// Fraction that tracks the `splitter` position across full width/height, where minPFraction <= constrainedFraction <= (1-minSFraction)
    @State private var constrainedFraction: CGFloat
    /// Fraction that tracks the cursor across full width/height during drag, where 0  <= fullFraction <= 1
    @State private var fullFraction: CGFloat
    /// The previous size, used to determine how to change `constrainedFraction` as size changes
    @State private var oldSize: CGSize?
    /// The previous position as we drag the `splitter`
    @State private var previousPosition: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let horizontal = layout.isHorizontal
            let size = geometry.size
            let width = size.width
            let height = size.height
            let length = horizontal ? width : height
            let breadth = horizontal ? height : width
            let hidePrimary = sideToHide().isPrimary || hide.side.isPrimary
            let hideSecondary = sideToHide().isSecondary || hide.side.isSecondary
            let minPLength = length * ((hidePrimary ? 0 : minPFraction) ?? 0)
            let minSLength = length * ((hideSecondary ? 0 : minSFraction) ?? 0)
            let pLength = max(minPLength, pLength(in: size))
            let sLength = max(minSLength, sLength(in: size))
            let spacing = spacing()
            let pWidth = horizontal ? max(minPLength, min(width - spacing, pLength - spacing / 2)) : breadth
            let pHeight = horizontal ? breadth : max(minPLength, min(height - spacing, pLength - spacing / 2))
            let sWidth = horizontal ? max(minSLength, min(width - pLength, sLength - spacing / 2)) : breadth
            let sHeight = horizontal ? breadth : max(minSLength, min(height - pLength, sLength - spacing / 2))
            let sOffset = horizontal ? CGSize(width: pWidth + spacing, height: 0) : CGSize(width: 0, height: pHeight + spacing)
            let dCenter = horizontal ? CGPoint(x: pWidth + spacing / 2, y: height / 2) : CGPoint(x: width / 2, y: pHeight + spacing / 2)
            ZStack(alignment: .topLeading) {
                if !hidePrimary {
                    primary
                        .frame(width: pWidth, height: pHeight)
                }
                if !hideSecondary {
                    secondary
                        .frame(width: sWidth, height: sHeight)
                        .offset(sOffset)
                }
                // Only show the splitter if it is draggable. See isDraggable comments.
                if isDraggable() {
                    splitter
                        .position(dCenter)
                        .simultaneousGesture(drag(in: size))
                }
            }
            // Our size changes when the window size changes or the containing window's size changes.
            // Note our size doesn't change when dragging the splitter, but when we have nested split
            // views, dragging our splitter can cause the size of another split view to change.
            // Umbra: synchronous `onChange` rather than upstream's `task(id:)`. A task runs after the
            // frame is committed, so during a live window resize the priority side was first laid
            // out at the old fraction and then snapped back — a visible wobble on every tick.
            // `setConstrainedFraction` ignores a zero size, which is what `task` was avoiding.
            .onChange(of: geometry.size, initial: true) { _, size in
                setConstrainedFraction(in: size)
            }
            .clipped()  // Can cause problems in some List styles if not clipped
            .environment(layout)
            .onChange(of: fraction.value) { _, new in constrainedFraction = new }
        }
    }

    /// Public init only allows `primary` and `secondary`, with `splitter` defaulting to Splitter.
    ///
    /// The `layout`, `fraction`,  `hide` ,  `constraints`, and any custom `splitter` must be specified using the modifiers if they are not defaults
    init(@ViewBuilder primary: @escaping () -> P, @ViewBuilder secondary: @escaping () -> S) where D == Splitter {
        let layout = LayoutHolder()
        let fraction = FractionHolder()
        let hide = SideHolder()
        let constraints = SplitConstraints()
        self.init(layout, fraction: fraction, hide: hide, constraints: constraints, onDrag: nil, primary: { primary() }, splitter: { D() }, secondary: { secondary() })
    }

    /// Private init requires all values for Split state to be specified and is used by the modifiers.
    private init(_ layout: LayoutHolder, fraction: FractionHolder, hide: SideHolder, constraints: SplitConstraints, onDrag: ((CGFloat) -> Void)?, @ViewBuilder primary: @escaping () -> P, @ViewBuilder splitter: @escaping () -> D, @ViewBuilder secondary: @escaping () -> S) {
        self.layout = layout
        self.fraction = fraction
        self.hide = hide
        self.constraints = constraints
        self.onDrag = onDrag
        self.primary = primary()
        self.splitter = splitter()
        self.secondary = secondary()
        _constrainedFraction = State(initialValue: fraction.value)  // Local fraction updated during drag
        _fullFraction = State(initialValue: fraction.value)         // Local fraction updated during drag
        // Constants we use a lot and want to simplify access and avoid recomputing
        minPFraction = constraints.minPFraction
        minSFraction = constraints.minSFraction
        dragToHideP = constraints.minPFraction != nil && constraints.dragToHideP
        dragToHideS = constraints.minSFraction != nil && constraints.dragToHideS
    }

    /// Return the spacing between `primary` and `secondary`, which is occupied by the splitter's `visibleThickness`.
    ///
    /// If we are previewing the hide (i.e., drag-to-hide) or we are using the `hideSplitter` styling and a side is hidden,
    /// then return 0, because the splitter is not visible.
    private func spacing() -> CGFloat {
        let styling = splitter.styling
        if styling.previewHide {
            return styling.hideSplitter ? 0 : styling.visibleThickness
        } else if hide.side != nil && styling.hideSplitter {
            return 0
        } else {
            return styling.visibleThickness
        }
    }

    /// Set the constrainedFraction to maintain the size of the priority side when size changes, as called from task(id:) modifier.
    private func setConstrainedFraction(in size: CGSize) {
        guard let side = constraints.priority else { return }
        // A zero-length first measurement would make the next change scale a 0pt pane.
        guard size.width > 0, size.height > 0 else { return }
        guard let oldSize else {
            // We need to know the oldSize to be able to adjust constrainedFraction in a way
            // that maintains a fixed width/height for the priority side.
            oldSize = size
            return
        }
        let horizontal = layout.isHorizontal
        let oldLength = horizontal ? oldSize.width : oldSize.height
        let newLength = horizontal ? size.width : size.height
        let delta = newLength - oldLength
        self.oldSize = size     // Retain even if delta might be zero because layout might change
        if delta == 0 { return }
        let oldPLength = constrainedFraction * oldLength
        // If holding the primary side constant, the pLength doesn't change
        let newPLength = side.isPrimary ? oldPLength : oldPLength + delta
        let newFraction = newPLength / newLength
        // Always keep the constrainedFraction within bounds of minimums if specified
        constrainedFraction = min(1 - (minSFraction ?? 0), max((minPFraction ?? 0), newFraction))
        fraction.value = constrainedFraction
    }

    /// The Gesture recognized by the `splitter`.
    ///
    /// The main function of dragging is to modify the `constrainedFraction` and to track `fullFraction`.
    ///
    /// Whenever we drag, we also set `hide.value` to `nil`. This is because the `pLength` and
    /// `sLength` key off of `hide` to return the full width/height when its value is non-nil.
    ///
    /// When we are done dragging, we set the value of `fraction`, which does nothing unless someone
    /// is holding onto it.
    private func drag(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { gesture in
                unhide(in: size)    // Unhide if the splitter is hidden, but resetting constrainedFraction first
                let fraction = fraction(for: gesture, in: size)
                constrainedFraction = fraction.constrained
                fullFraction = fraction.full
                splitter.styling.previewHide = !isDraggable() || sideToHide() != nil
                onDrag?(constrainedFraction)
                previousPosition = layout.isHorizontal ? constrainedFraction * size.width : constrainedFraction * size.height
            }
            .onEnded { _ in
                previousPosition = nil
                splitter.styling.previewHide = false     // We are never previewing the hidden state when drag ends
                hide.side = sideToHide()
                // The fullFraction is used to determine the sideToHide, so we need to reset when done dragging,
                // but *after* setting the hide.side.
                fullFraction = constrainedFraction
                fraction.value = constrainedFraction
            }
    }

    /// Return the side to hide for previewing in the drag-to-hide operation.
    ///
    /// Note a side is not necessarily hidden when `sideToHide` is called.
    ///
    /// Use a rounded-to-3-decimal-places constrainedFraction because... floating point.
    private func sideToHide() -> SplitSide? {
        guard dragToHideP || dragToHideS else { return nil }
        if dragToHideP && (round(fullFraction * 1000) / 1000.0) <= (minPFraction! / 2) {
            return .primary
        } else if dragToHideS && (round((1 - fullFraction) * 1000) / 1000.0) <= (minSFraction! / 2) {
            return .secondary
        } else {
            return nil
        }
    }

    /// Return a new value for `constrained` and `full` fractions based on the DragGesture.
    ///
    /// The `constrained` value is always between `minSFraction` and `minPFraction` (if specified).
    /// The `full` value is always between 0 and 1.
    ///
    /// We use a delta based on `previousPosition` so the `splitter` follows the location where drag begins, not
    /// the center of the splitter.
    func fraction(for gesture: DragGesture.Value, in size: CGSize) -> (constrained: CGFloat, full: CGFloat) {
        let horizontal = layout.isHorizontal
        let length = horizontal ? size.width : size.height                                              // Size in direction of dragging
        let splitterLocation = length * constrainedFraction                                             // Splitter position prior to drag
        let gestureLocation = horizontal ? gesture.location.x : gesture.location.y                      // Gesture location in direction of dragging
        let gestureTranslation = horizontal ? gesture.translation.width : gesture.translation.height    // Gesture movement since beginning of drag
        let delta = previousPosition == nil ? gestureTranslation : gestureLocation - previousPosition!  // Amount moved since last change
        let constrainedLocation = max(0, min(length, splitterLocation + delta))                         // New location kept in proper bounds
        let fullFraction = constrainedLocation / length                                                 // Fraction of full size without regard to constraints
        let constrainedFraction = min(1 - (minSFraction ?? 0), max((minPFraction ?? 0), fullFraction))  // Fraction of full size kept within constraints
        return (constrained: constrainedFraction, full: fullFraction)
    }

    /// Return whether the splitter is draggable.
    ///
    /// The splitter becomes non-draggable if `splitter.styling.hideSplitter` is `true`
    /// and either side is hidden. When the splitter is non-draggable, it is not part of
    /// the `body` of Split. It is not just hidden -- it doesn't even exist to respond to drag events.
    ///
    /// **Important**: You must provide a means to unhide the side (e.g., a hide/show
    /// button) if your splitter can become non-draggable.
    private func isDraggable() -> Bool {
        if hide.side == nil {
            return true
        } else {
            return !splitter.styling.hideSplitter
        }
    }

    /// Unhide before dragging if a side is hidden.
    ///
    /// When we set `hide.size` to nil, the `body` is recomputed based on `constrainedFraction`.
    /// However, `constrainedFraction` is set to what it was before hiding (so it can be restored properly).
    /// Here we reset `constrainedFraction` to the "hidden" position so that drag behaves smoothly from
    /// that position.
    private func unhide(in size: CGSize) {
        if hide.side != nil {
            let length = layout.isHorizontal ? size.width : size.height
            let pLength = pLength(in: size)
            constrainedFraction = pLength / length
            hide.side = nil
        }
    }

    /// The length of `primary` in the `layout` direction, without regard to any inset for the Splitter
    private func pLength(in size: CGSize) -> CGFloat {
        let length = layout.isHorizontal ? size.width : size.height
        if let side = hide.side {
            return side.isSecondary ? length : 0
        } else {
            if let sideToHide = sideToHide() {
                return sideToHide.isSecondary ? length : 0
            } else {
                return length * constrainedFraction
            }
        }
    }

    /// The length of `secondary` in the `layout` direction, without regard to any inset for the Splitter
    private func sLength(in size: CGSize) -> CGFloat {
        let length = layout.isHorizontal ? size.width : size.height
        if let side = hide.side {
            return side.isPrimary ? length : 0
        } else {
            if let sideToHide = sideToHide() {
                return sideToHide.isPrimary ? length : 0
            } else {
                return length - pLength(in: size)
            }
        }
    }

    //MARK: Modifiers

    /// Return a new Split with the `splitter` set to the `splitter` passed-in.
    func splitter<T>(@ViewBuilder _ splitter: @escaping () -> T) -> Split<P, T, S> where T: View {
        Split<P, T, S>(layout, fraction: fraction, hide: hide, constraints: constraints, onDrag: onDrag, primary: { primary }, splitter: splitter, secondary: { secondary })
    }

    /// Return a new instance of Split with `constraints` set to a SplitConstraints holding these values.
    func constraints(minPFraction: CGFloat? = nil, minSFraction: CGFloat? = nil, priority: SplitSide? = nil, dragToHideP: Bool = false, dragToHideS: Bool = false) -> Split {
        let constraints = SplitConstraints(minPFraction: minPFraction, minSFraction: minSFraction, priority: priority, dragToHideP: dragToHideP, dragToHideS: dragToHideS)
        return Split(layout, fraction: fraction, hide: hide, constraints: constraints, onDrag: onDrag, primary: { primary }, splitter: { splitter }, secondary: { secondary })
    }

    /// Return a new instance of Split with `constraints` set to this SplitConstraints.
    func constraints(_ constraints: SplitConstraints) -> Split {
        self.constraints(minPFraction: constraints.minPFraction, minSFraction: constraints.minSFraction, priority: constraints.priority, dragToHideP: constraints.dragToHideP, dragToHideS: constraints.dragToHideS)
    }

    /// Return a new instance of Split with `onDrag` set to `callback`.
    func onDrag(_ callback: ((CGFloat) -> Void)?) -> Split {
        Split(layout, fraction: fraction, hide: hide, constraints: constraints, onDrag: callback, primary: { primary }, splitter: { splitter }, secondary: { secondary })
    }

    /// Return a new instance of Split with its `splitter.styling` set to these values.
    func styling(color: Color? = nil, inset: CGFloat? = nil, visibleThickness: CGFloat? = nil, invisibleThickness: CGFloat? = nil, hideSplitter: Bool = false) -> Split {
        let styling = SplitStyling(color: color, inset: inset, visibleThickness: visibleThickness, invisibleThickness: invisibleThickness, hideSplitter: hideSplitter)
        splitter.styling.reset(from: styling)
        return Split(layout, fraction: fraction, hide: hide, constraints: constraints, onDrag: onDrag, primary: { primary }, splitter: { splitter }, secondary: { secondary })
    }

    /// Return a new instance of Split with its `splitter.styling` set to the values of this `styling`.
    func styling(_ styling: SplitStyling) -> Split {
        self.styling(color: styling.color, inset: styling.inset, visibleThickness: styling.visibleThickness, invisibleThickness: styling.invisibleThickness, hideSplitter: styling.hideSplitter)
    }

    /// Return a new instance of Split with `layout` set to this LayoutHolder.
    func layout(_ layout: LayoutHolder) -> Split {
        Split(layout, fraction: fraction, hide: hide, constraints: constraints, onDrag: onDrag, primary: { primary }, splitter: { splitter }, secondary: { secondary })
    }

    /// Return a new instance of Split with `fraction` set to this FractionHolder.
    func fraction(_ fraction: FractionHolder) -> Split {
        Split(layout, fraction: fraction, hide: hide, constraints: constraints, onDrag: onDrag, primary: { primary }, splitter: { splitter }, secondary: { secondary })
    }

    /// Return a new instance of Split with `fraction` set to a FractionHolder holding onto this CGFloat.
    func fraction(_ fraction: CGFloat) -> Split {
        self.fraction(FractionHolder(fraction))
    }

    /// Return a new instance of Split with `hide` set to this SideHolder.
    func hide(_ side: SideHolder) -> Split {
        Split(layout, fraction: fraction, hide: side, constraints: constraints, onDrag: onDrag, primary: { primary }, splitter: { splitter }, secondary: { secondary })
    }

    /// Return a new instance of Split with `hide` set to a SideHolder holding onto this SplitSide.
    func hide(_ side: SplitSide) -> Split {
        self.hide(SideHolder(side))
    }
}
