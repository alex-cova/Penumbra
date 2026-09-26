//  Vendored from SplitView (MIT) — Copyright (c) 2023 Steven G. Harris.
//  See LICENSE in this directory. Ported for Hextech, then Umbra: Combine-era observation -> `@Observable`.

import Foundation
import Observation

/// Holds the `layout` that a `Split` view observes to decide whether it lays out horizontally or vertically.
///
/// Use the static `usingUserDefaults` method to save state automatically in `UserDefaults.standard`.
@MainActor
@Observable
final class LayoutHolder {
    var value: SplitLayout {
        didSet {
            setter?(value)
        }
    }
    @ObservationIgnored var getter: (() -> SplitLayout)?
    @ObservationIgnored var setter: ((SplitLayout) -> Void)?

    var isHorizontal: Bool { value == .horizontal }

    init(_ layout: SplitLayout? = nil, getter: (() -> SplitLayout)? = nil, setter: ((SplitLayout) -> Void)? = nil) {
        value = getter?() ?? layout ?? .horizontal
        self.getter = getter
        self.setter = setter
    }

    static func usingUserDefaults(_ layout: SplitLayout? = nil, key: String) -> LayoutHolder {
        LayoutHolder(
            layout,
            getter: {
                guard
                    let value = UserDefaults.standard.value(forKey: key) as? String,
                    let layout = SplitLayout(rawValue: value)
                else {
                    return .horizontal
                }
                return layout
            },
            setter: { layout in
                UserDefaults.standard.set(layout.rawValue, forKey: key)
            }
        )
    }

    func toggle() {
        value = value == .horizontal ? .vertical : .horizontal
    }
}

/// Holds the fraction of the width/height at which the `splitter` is positioned upon open.
///
/// Use the static `usingUserDefaults` method to save state automatically in `UserDefaults.standard`.
@MainActor
@Observable
final class FractionHolder {
    var value: CGFloat {
        didSet {
            setter?(value)
        }
    }
    @ObservationIgnored var getter: (() -> CGFloat)?
    @ObservationIgnored var setter: ((CGFloat) -> Void)?

    init(_ fraction: CGFloat? = nil, getter: (() -> CGFloat)? = nil, setter: ((CGFloat) -> Void)? = nil) {
        value = getter?() ?? fraction ?? 0.5
        self.getter = getter
        self.setter = setter
    }

    static func usingUserDefaults(_ fraction: CGFloat? = nil, key: String) -> FractionHolder {
        FractionHolder(
            fraction,
            getter: { UserDefaults.standard.value(forKey: key) as? CGFloat ?? fraction ?? 0.5 },
            setter: { fraction in UserDefaults.standard.set(fraction, forKey: key) }
        )
    }
}

/// Holds which `SplitSide` (if any) is hidden.
///
/// Use the static `usingUserDefaults` method to save state automatically in `UserDefaults.standard`.
@MainActor
@Observable
final class SideHolder {
    private var value: SplitSide? {
        didSet {
            setter?(value)
        }
    }
    @ObservationIgnored var getter: (() -> SplitSide?)?
    @ObservationIgnored var setter: ((SplitSide?) -> Void)?
    var side: SplitSide? {
        get { value }
        set { setValue(newValue) }
    }
    var oldSide: SplitSide? { oldValue }
    @ObservationIgnored private var oldValue: SplitSide?

    init(_ hide: SplitSide? = nil, getter: (() -> SplitSide?)? = nil, setter: ((SplitSide?) -> Void)? = nil) {
        let value = getter?() ?? hide
        self.value = value
        self.getter = getter
        self.setter = setter
        // Note .secondary will always toggle() by default if hide is initially nil.
        // If you want to toggle .primary when hide is initially nil, then use toggle(.primary)
        // or toggle(.left) or toggle(.top). See discussion below in the toggle method.
        oldValue = value == nil ? .secondary : nil
    }

    /// Hide the `side`.
    func hide(_ side: SplitSide) {
        setValue(side)
    }

    /// Toggle whether `side` is hidden or not.
    ///
    /// For example, multiple invocations of `toggle(.primary)` will alternate between the
    /// `.primary`  (or `.left` or `.top`) side being hidden or visible.
    ///
    /// If `side` is not specified, then `toggle` does hide/show of the` .secondary` side or of the
    /// initially hidden `side` that was identified when the SideHolder was instantiated.
    func toggle(_ side: SplitSide? = nil) {
        guard let side else {
            setValue(oldValue)
            return
        }
        if (side.isPrimary && value.isPrimary) || (side.isSecondary && value.isSecondary) {
            setValue(oldValue)
        } else {
            setValue(side)
        }
    }

    private func setValue(_ side: SplitSide?) {
        guard value != side else { return }
        let oldSide = value
        value = side
        oldValue = oldSide
    }

    static func usingUserDefaults(_ hide: SplitSide? = nil, key: String) -> SideHolder {
        SideHolder(
            hide,
            getter: {
                guard
                    let value = UserDefaults.standard.value(forKey: key) as? String,
                    let side = SplitSide(rawValue: value)
                else {
                    return nil
                }
                return side
            },
            setter: { side in
                UserDefaults.standard.set(side?.rawValue, forKey: key)
            }
        )
    }
}
