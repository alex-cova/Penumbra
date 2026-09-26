import SwiftUI

/// Two-pane split that accepts **point-based** sizes the way `HSplitView` children do
/// (`.frame(minWidth: 220, idealWidth: 260, maxWidth: 320)`), and translates them into the
/// fraction constraints `HSplit`/`VSplit` actually take. Without this bridge every migrated call
/// site would have to hand-guess a fraction, which changes meaning the moment the window resizes.
///
/// Beyond parity with `HSplitView` it adds what `HSplitView` never had: a divider position that
/// survives navigating away and app relaunch (`storageKey`), and a side that keeps its width when
/// the window resizes (`priority`).
///
///     SplitPanes(minPrimary: 220, maxPrimary: 320, idealPrimary: 260,
///                minSecondary: 400, storageKey: "http.sidebar") {
///         sidebar
///     } secondary: {
///         detail
///     }
struct SplitPanes<Primary: View, Secondary: View, Divider: SplitDivider>: View {
    var axis: SplitLayout = .horizontal
    /// Smallest width (or height, when vertical) the leading/top pane may shrink to, in points.
    var minPrimary: CGFloat = 0
    /// Largest the leading/top pane may grow to, in points. Zero means unbounded.
    var maxPrimary: CGFloat = 0
    /// Width the leading/top pane opens at, in points. Zero falls back to `defaultFraction`.
    var idealPrimary: CGFloat = 0
    /// Smallest width (or height, when vertical) the trailing/bottom pane may shrink to, in points.
    var minSecondary: CGFloat = 0
    /// Largest the trailing/bottom pane may grow to, in points. Zero means unbounded.
    var maxSecondary: CGFloat = 0
    /// Width the trailing/bottom pane opens at, in points. For layouts where the sidebar is the
    /// *second* pane. Zero falls back to `defaultFraction`.
    var idealSecondary: CGFloat = 0
    /// Divider position at first open, as a fraction of the full length. Ignored when
    /// `idealPrimary` or `idealSecondary` is set.
    var defaultFraction: CGFloat = 0.5
    /// When set, the divider position is persisted in `UserDefaults` under this key.
    var storageKey: String?
    /// Side that keeps a fixed size as the container resizes. `nil` keeps the fraction instead.
    var priority: SplitSide? = .primary
    /// Called with the divider's position as both panes' lengths in points whenever it settles:
    /// at the end of a drag, and when the container resizes. The values are in the units
    /// `idealPrimary`/`idealSecondary` take, so feeding one back on the next launch reopens the
    /// divider in the same place. Hosts that persist sizes in points (Umbra's `IDESessionStore`)
    /// save from here instead of using `storageKey`. Mid-drag positions are not reported.
    var onResize: ((_ primary: CGFloat, _ secondary: CGFloat) -> Void)?
    /// Collapses `.primary` or `.secondary` to zero width/height without unmounting either pane
    /// — unlike conditionally omitting `SplitPanes` itself at the call site (or swapping one
    /// pane's content for `EmptyView()`), which changes the generic view-tree shape and tears
    /// down *both* panes, including anything stateful like a hosted `NSViewRepresentable`. `nil`
    /// shows both.
    var hiddenSide: SplitSide?
    @ViewBuilder var primary: () -> Primary
    @ViewBuilder var secondary: () -> Secondary
    /// The view drawn between the panes. Defaults to `HandleSplitter`.
    @ViewBuilder var divider: () -> Divider

    /// Held in `@State` so the divider position survives re-renders of the parent view.
    @State private var fraction: FractionHolder
    /// Backs `hiddenSide` — `Split` reads this live to lay out a hidden side at zero width while
    /// keeping it mounted; seeded from `hiddenSide` at init and kept in sync by `onChange` below,
    /// since `SplitPanes` itself is a value type re-created on every parent render.
    @State private var hideHolder: SideHolder
    /// `idealPrimary` is in points but the divider is positioned by fraction, so it can only be
    /// resolved once the container has been measured — and only once, or it would fight the user.
    @State private var resolvedIdeal = false

    init(
        axis: SplitLayout = .horizontal,
        minPrimary: CGFloat = 0,
        maxPrimary: CGFloat = 0,
        idealPrimary: CGFloat = 0,
        minSecondary: CGFloat = 0,
        maxSecondary: CGFloat = 0,
        idealSecondary: CGFloat = 0,
        defaultFraction: CGFloat = 0.5,
        storageKey: String? = nil,
        priority: SplitSide? = .primary,
        hiddenSide: SplitSide? = nil,
        onResize: ((_ primary: CGFloat, _ secondary: CGFloat) -> Void)? = nil,
        @ViewBuilder primary: @escaping () -> Primary,
        @ViewBuilder secondary: @escaping () -> Secondary,
        @ViewBuilder divider: @escaping () -> Divider
    ) {
        self.axis = axis
        self.minPrimary = minPrimary
        self.maxPrimary = maxPrimary
        self.idealPrimary = idealPrimary
        self.minSecondary = minSecondary
        self.maxSecondary = maxSecondary
        self.idealSecondary = idealSecondary
        self.defaultFraction = defaultFraction
        self.storageKey = storageKey
        self.priority = priority
        self.hiddenSide = hiddenSide
        self.onResize = onResize
        self.primary = primary
        self.secondary = secondary
        self.divider = divider
        if let storageKey {
            _fraction = State(initialValue: .usingUserDefaults(defaultFraction, key: storageKey))
        } else {
            _fraction = State(initialValue: FractionHolder(defaultFraction))
        }
        _hideHolder = State(initialValue: SideHolder(hiddenSide))
    }

    var body: some View {
        GeometryReader { geo in
            let length = axis == .horizontal ? geo.size.width : geo.size.height
            let bounds = fractions(in: length)
            Group {
                switch axis {
                case .horizontal:
                    HSplit(left: primary, right: secondary)
                        .splitter(divider)
                        .fraction(fraction)
                        .constraints(minPFraction: bounds.primary, minSFraction: bounds.secondary, priority: priority)
                        .hide(hideHolder)
                case .vertical:
                    VSplit(top: primary, bottom: secondary)
                        .splitter(divider)
                        .fraction(fraction)
                        .constraints(minPFraction: bounds.primary, minSFraction: bounds.secondary, priority: priority)
                        .hide(hideHolder)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // Umbra: synchronous, so the opening width is resolved before the first frame is
            // drawn instead of flashing the panes at `defaultFraction` (upstream used `task`).
            .onChange(of: length, initial: true) { _, length in applyBounds(in: length) }
            .onChange(of: fraction.value) { _, value in reportResize(fraction: value, length: length) }
        }
        .onChange(of: hiddenSide) { _, newValue in
            hideHolder.side = newValue
        }
        .onChange(of: defaultFraction) { _, newValue in
            // A split positioned only by `defaultFraction` follows it, so a caller can
            // re-balance — the editor's pane chain passes `1 / remaining` and re-spreads its
            // panes evenly when one is added or closed. Points-based and stored positions are
            // the user's and stay put.
            guard idealPrimary == 0, idealSecondary == 0, storageKey == nil else { return }
            fraction.value = newValue
        }
    }

    private func reportResize(fraction: CGFloat, length: CGFloat) {
        guard let onResize, length > 0 else { return }
        onResize((fraction * length).rounded(), ((1 - fraction) * length).rounded())
    }

    /// Resolve the opening width, and hold the divider inside its bounds.
    ///
    /// `Split` enforces its constraints while dragging and while the container resizes, but never
    /// against the fraction it *starts* with — so a stored position from a wider window, or one
    /// that predates a change to these limits, would otherwise lay out past the maximum and
    /// overflow the container. Clamping on every length change covers both.
    private func applyBounds(in length: CGFloat) {
        guard length > 0 else { return }
        let bounds = fractions(in: length)
        let lower = bounds.primary ?? 0
        let upper = 1 - (bounds.secondary ?? 0)
        guard lower <= upper else { return }

        var target = fraction.value
        if !resolvedIdeal {
            resolvedIdeal = true
            let hasStored = storageKey.map { UserDefaults.standard.object(forKey: $0) != nil } ?? false
            if !hasStored {
                if idealPrimary > 0 {
                    target = idealPrimary / length
                } else if idealSecondary > 0 {
                    target = (length - idealSecondary) / length
                }
            }
        }

        let clamped = min(max(target, lower), upper)
        if abs(clamped - fraction.value) > 0.0001 {
            fraction.value = clamped
        }
    }

    /// Convert the point-based sizes to the fraction bounds `Split` constrains against.
    ///
    /// A maximum on one pane is just a minimum on the other — capping the primary at 320pt is the
    /// same as saying the secondary may never be smaller than `length - 320`. That identity is
    /// what lets a fraction-based splitter honour `maxWidth`.
    ///
    /// When the container is too narrow to honour everything, the bounds are scaled down
    /// proportionally rather than fighting each other — the same graceful degradation
    /// `HSplitView` gives when its children can't all meet their `minWidth`.
    private func fractions(in length: CGFloat) -> (primary: CGFloat?, secondary: CGFloat?) {
        guard length > 0 else { return (nil, nil) }
        let pFloor = max(max(0, minPrimary), maxSecondary > 0 ? length - maxSecondary : 0)
        let sFloor = max(max(0, minSecondary), maxPrimary > 0 ? length - maxPrimary : 0)
        var p = pFloor / length
        var s = sFloor / length
        let total = p + s
        let ceiling: CGFloat = 0.95
        if total > ceiling, total > 0 {
            let scale = ceiling / total
            p *= scale
            s *= scale
        }
        return (p > 0 ? p : nil, s > 0 ? s : nil)
    }
}

extension SplitPanes where Divider == HandleSplitter {
    /// The common case: the standard Umbra divider, no `divider:` closure needed.
    init(
        axis: SplitLayout = .horizontal,
        minPrimary: CGFloat = 0,
        maxPrimary: CGFloat = 0,
        idealPrimary: CGFloat = 0,
        minSecondary: CGFloat = 0,
        maxSecondary: CGFloat = 0,
        idealSecondary: CGFloat = 0,
        defaultFraction: CGFloat = 0.5,
        storageKey: String? = nil,
        priority: SplitSide? = .primary,
        hiddenSide: SplitSide? = nil,
        onResize: ((_ primary: CGFloat, _ secondary: CGFloat) -> Void)? = nil,
        @ViewBuilder primary: @escaping () -> Primary,
        @ViewBuilder secondary: @escaping () -> Secondary
    ) {
        self.init(
            axis: axis,
            minPrimary: minPrimary,
            maxPrimary: maxPrimary,
            idealPrimary: idealPrimary,
            minSecondary: minSecondary,
            maxSecondary: maxSecondary,
            idealSecondary: idealSecondary,
            defaultFraction: defaultFraction,
            storageKey: storageKey,
            priority: priority,
            hiddenSide: hiddenSide,
            onResize: onResize,
            primary: primary,
            secondary: secondary,
            divider: { HandleSplitter() }
        )
    }
}
