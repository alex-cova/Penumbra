@preconcurrency import AppKit
import ObjectiveC

/// Layout container that mounts a view without destroying it when re-mounted — pairs with
/// ``EditorHostCache`` so a cached hosted view (e.g. a `TextView`) survives SwiftUI
/// `NSViewRepresentable` identity churn.
///
/// A `NSViewRepresentable`'s `makeNSView` runs again whenever SwiftUI decides the view lost its
/// identity — e.g. a sidebar toggling on/off moving a pane to a different position in the view
/// tree. Returning a fresh `EditorHostContainer` each time is cheap and expected; what must *not*
/// happen is the cached view inside it being torn down too. `mount(_:)` is idempotent for that
/// reason: mounting the same, already-mounted view is a no-op rather than a remove-and-re-add.
///
/// The newest container wins. When SwiftUI replaces a container (closing a split rebuilds the
/// layout), `makeNSView` on the new one can run before `updateNSView` on the old one, which is
/// still in the tree until the transaction ends. The old container must not take the host back
/// then, or the host ends up in a container that is about to be discarded and the editor is blank.
public final class EditorHostContainer: NSView {
    private final class Claim {
        weak var container: EditorHostContainer?
        init(_ container: EditorHostContainer) { self.container = container }
    }

    private nonisolated(unsafe) static var claimKey = 0
    private nonisolated(unsafe) static var nextSerial = 0

    private let serial: Int
    private weak var mountedHost: NSView?

    override public init(frame frameRect: NSRect) {
        Self.nextSerial += 1
        serial = Self.nextSerial
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// No-ops if `host` is already the mounted view, or if a newer container has claimed it.
    /// Otherwise removes any existing subview and adds `host`, sized to fill the container.
    public func mount(_ host: NSView) {
        if mountedHost === host, host.superview === self {
            return
        }
        if let owner = (objc_getAssociatedObject(host, &Self.claimKey) as? Claim)?.container,
           owner !== self, owner.serial > serial {
            return
        }
        objc_setAssociatedObject(host, &Self.claimKey, Claim(self), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
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
