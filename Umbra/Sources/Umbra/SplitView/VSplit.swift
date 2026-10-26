//  Vendored from SplitView (MIT) — Copyright (c) 2023 Steven G. Harris.
//  See LICENSE in this directory. Ported for Hextech, then Umbra: see README.md.

import SwiftUI

struct VSplit<P: View, D: SplitDivider, S: View>: View {
    private let fraction: FractionHolder
    private let hide: SideHolder
    private let constraints: SplitConstraints
    private let onDrag: ((CGFloat) -> Void)?
    private let primary: P
    private let splitter: D
    private let secondary: S

    var body: some View {
        Split(primary: { primary }, secondary: { secondary })
            .layout(LayoutHolder(.vertical))
            .constraints(constraints)
            .onDrag(onDrag)
            .splitter { splitter }
            .fraction(fraction)
            .hide(hide)
    }

    init(@ViewBuilder top: @escaping () -> P, @ViewBuilder bottom: @escaping () -> S) where D == Splitter {
        let fraction = FractionHolder()
        let hide = SideHolder()
        let constraints = SplitConstraints()
        self.init(fraction: fraction, hide: hide, constraints: constraints, onDrag: nil, primary: { top() }, splitter: { D() }, secondary: { bottom() })
    }

    private init(fraction: FractionHolder, hide: SideHolder, constraints: SplitConstraints, onDrag: ((CGFloat) -> Void)?, @ViewBuilder primary: @escaping () -> P, @ViewBuilder splitter: @escaping () -> D, @ViewBuilder secondary: @escaping () -> S) {
        self.fraction = fraction
        self.hide = hide
        self.constraints = constraints
        self.onDrag = onDrag
        self.primary = primary()
        self.splitter = splitter()
        self.secondary = secondary()
    }

    //MARK: Modifiers

    // Note: Modifiers return a new VSplit instance with the same state except for what is
    // being modified.

    /// Return a new VSplit with the `splitter` set to the `splitter` passed-in.
    func splitter<T>(@ViewBuilder _ splitter: @escaping () -> T) -> VSplit<P, T, S> where T: View {
        VSplit<P, T, S>(fraction: fraction, hide: hide, constraints: constraints, onDrag: onDrag, primary: { primary }, splitter: splitter, secondary: { secondary })
    }

    /// Return a new instance of VSplit with `constraints` set to these values.
    func constraints(minPFraction: CGFloat? = nil, minSFraction: CGFloat? = nil, priority: SplitSide? = nil, dragToHideP: Bool = false, dragToHideS: Bool = false) -> VSplit {
        let constraints = SplitConstraints(minPFraction: minPFraction, minSFraction: minSFraction, priority: priority, dragToHideP: dragToHideP, dragToHideS: dragToHideS)
        return VSplit(fraction: fraction, hide: hide, constraints: constraints, onDrag: onDrag, primary: { primary }, splitter: { splitter }, secondary: { secondary })
    }

    /// Return a new instance of VSplit with `onDrag` set to `callback`.
    func onDrag(_ callback: ((CGFloat) -> Void)?) -> VSplit {
        VSplit(fraction: fraction, hide: hide, constraints: constraints, onDrag: callback, primary: { primary }, splitter: { splitter }, secondary: { secondary })
    }

    /// Return a new instance of VSplit with its `splitter.styling` set to these values.
    func styling(color: Color? = nil, inset: CGFloat? = nil, visibleThickness: CGFloat? = nil, invisibleThickness: CGFloat? = nil, hideSplitter: Bool = false) -> VSplit {
        let styling = SplitStyling(color: color, inset: inset, visibleThickness: visibleThickness, invisibleThickness: invisibleThickness, hideSplitter: hideSplitter)
        splitter.styling.reset(from: styling)
        return VSplit(fraction: fraction, hide: hide, constraints: constraints, onDrag: onDrag, primary: { primary }, splitter: { splitter }, secondary: { secondary })
    }

    /// Return a new instance of VSplit with `fraction` set to this FractionHolder
    func fraction(_ fraction: FractionHolder) -> VSplit<P, D, S> {
        VSplit(fraction: fraction, hide: hide, constraints: constraints, onDrag: onDrag, primary: { primary }, splitter: { splitter }, secondary: { secondary })
    }

    /// Return a new instance of VSplit with `fraction` set to a FractionHolder holding onto this CGFloat
    func fraction(_ fraction: CGFloat) -> VSplit<P, D, S> {
        self.fraction(FractionHolder(fraction))
    }

    /// Return a new instance of VSplit with `hide` set to this SideHolder
    func hide(_ side: SideHolder) -> VSplit<P, D, S> {
        VSplit(fraction: fraction, hide: side, constraints: constraints, onDrag: onDrag, primary: { primary }, splitter: { splitter }, secondary: { secondary })
    }

    /// Return a new instance of VSplit with `hide` set to a SideHolder holding onto this SplitSide
    func hide(_ side: SplitSide) -> VSplit<P, D, S> {
        self.hide(SideHolder(side))
    }
}
