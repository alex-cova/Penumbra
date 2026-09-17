@preconcurrency import AppKit

/// Layout container that mounts a view without destroying it when re-mounted — pairs with
/// ``EditorHostCache`` so a cached hosted view (e.g. a `TextView`) survives SwiftUI
/// `NSViewRepresentable` identity churn.
///
/// A `NSViewRepresentable`'s `makeNSView` runs again whenever SwiftUI decides the view lost its
/// identity — e.g. a sidebar toggling on/off moving a pane to a different position in the view
/// tree. Returning a fresh `EditorHostContainer` each time is cheap and expected; what must *not*
/// happen is the cached view inside it being torn down too. `mount(_:)` is idempotent for that
/// reason: mounting the same, already-mounted view is a no-op rather than a remove-and-re-add.
public final class EditorHostContainer: NSView {
    private weak var mountedHost: NSView?

    /// No-ops if `host` is already the mounted view. Otherwise removes any existing subview and
    /// adds `host`, sized to fill the container.
    public func mount(_ host: NSView) {
        if mountedHost === host, host.superview === self {
            return
        }
        subviews.forEach { $0.removeFromSuperview() }
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        mountedHost = host
    }

    override public func layout() {
        super.layout()
        if let mountedHost, mountedHost.superview === self {
            mountedHost.frame = bounds
        }
    }

    override public var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    /// SwiftUI chrome around a representable must not become first responder or a
    /// `@Published` caret update will steal typing focus from the mounted `TextView`.
    override public var acceptsFirstResponder: Bool { false }

    override public func becomeFirstResponder() -> Bool { false }

    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
