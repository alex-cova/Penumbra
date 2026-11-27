import AppKit
import SwiftUI

/// Lets a mouse wheel scroll a sideways tab row. Ported from Silica's
/// `WheelScrollsSideways`: vertical wheel travel is rewritten as horizontal
/// while the pointer is on the bar; trackpads are left alone.
struct IDEWheelScrollsSideways: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ nsView: AnchorView, context: Context) {}

    static func dismantleNSView(_ nsView: AnchorView, coordinator: ()) {
        nsView.stopWatching()
    }

    final class AnchorView: NSView {
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopWatching()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === window, event.phase.isEmpty, event.momentumPhase.isEmpty,
                      event.scrollingDeltaX == 0, event.scrollingDeltaY != 0,
                      bounds.contains(convert(event.locationInWindow, from: nil)) else { return event }
                return event.turnedSideways() ?? event
            }
        }

        func stopWatching() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

/// Closes the tab under a middle click, as browsers and other editors do.
/// Ported from Silica's `MiddleClickClosesTab`, keyed by document ID.
struct IDEMiddleClickClosesTab: NSViewRepresentable {
    /// The tab at a horizontal position in the bar, if there's one.
    let tab: (CGFloat) -> UUID?
    let close: (UUID) -> Void

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.tab = tab
        nsView.close = close
    }

    static func dismantleNSView(_ nsView: AnchorView, coordinator: ()) {
        nsView.stopWatching()
    }

    final class AnchorView: NSView {
        var tab: (CGFloat) -> UUID? = { _ in nil }
        var close: (UUID) -> Void = { _ in }

        private var monitor: Any?
        private var pressed: UUID?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopWatching()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        func stopWatching() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            pressed = nil
        }

        private func handle(_ event: NSEvent) {
            guard event.buttonNumber == 2 else { return }
            let point = convert(event.locationInWindow, from: nil)
            let isBlocked = window?.attachedSheet != nil || NSApp.modalWindow != nil
            let hit = event.window === window && !isBlocked && bounds.contains(point) ? tab(point.x) : nil
            if event.type == .otherMouseDown {
                pressed = hit
                return
            }
            defer { pressed = nil }
            guard let hit, hit == pressed else { return }
            DispatchQueue.main.async { [weak self] in self?.close(hit) }
        }
    }
}

/// Follows the pointer through a tab drag. SwiftUI's `DragGesture` on a tab inside a scroll view
/// stopped reporting moves once the drag began, so the tabs never made room; the events are read
/// here instead, as a local monitor, and handed on unchanged (a plain click still reaches the tab).
///
/// A press on a tab that moves 4 pt starts the drag, mouse-up drops it, Esc cancels it. Points
/// given to the closures are in the editor panes' space (`barOrigin` is where this view starts in it).
struct IDETabDragTracker: NSViewRepresentable {
    /// What a press at a horizontal position in the bar can pick up: the tab and where it starts.
    let tab: (CGFloat) -> (id: UUID, minX: CGFloat)?
    /// The bar's tabs and where it starts. Handed to `publish` whenever it changes, from here and
    /// not from an `onChange` in the bar: that one dropped the update that followed a tab being
    /// added to a new pane, leaving the bar published without its widths.
    let geometry: IDETabBarGeometry
    let publish: (IDETabBarGeometry) -> Void
    /// The tab, where the pointer took hold of it (from its top-left), and the pointer.
    let begin: (UUID, CGPoint, CGPoint) -> Void
    let move: (CGPoint) -> Void
    let drop: () -> Void
    let cancel: () -> Void

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.tab = tab
        nsView.barOrigin = geometry.origin
        if nsView.published != geometry {
            nsView.published = geometry
            publish(geometry)
        }
        nsView.begin = begin
        nsView.move = move
        nsView.drop = drop
        nsView.cancel = cancel
    }

    static func dismantleNSView(_ nsView: AnchorView, coordinator: ()) {
        nsView.stopWatching(cancelling: true)
    }

    final class AnchorView: NSView {
        var tab: (CGFloat) -> (id: UUID, minX: CGFloat)? = { _ in nil }
        var barOrigin: CGPoint = .zero
        fileprivate var published: IDETabBarGeometry?
        var begin: (UUID, CGPoint, CGPoint) -> Void = { _, _, _ in }
        var move: (CGPoint) -> Void = { _ in }
        var drop: () -> Void = {}
        var cancel: () -> Void = {}

        private struct Press {
            var tab: UUID
            var start: CGPoint
            var grab: CGPoint
        }

        private static let threshold: CGFloat = 4
        private static let escape: UInt16 = 53

        private var monitor: Any?
        private var press: Press?
        private var isDragging = false

        /// Points in the bar grow downwards, like the panes' space they are added to.
        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopWatching(cancelling: true)
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
                // nil swallows the event (Esc during a drag), so it must not fall back to `event`.
                guard let self else { return event }
                return handle(event)
            }
        }

        func stopWatching(cancelling: Bool = false) {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            press = nil
            if isDragging {
                isDragging = false
                if cancelling { cancel() }
            }
        }

        private func panesPoint(_ local: CGPoint) -> CGPoint {
            CGPoint(x: local.x + barOrigin.x, y: local.y + barOrigin.y)
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            switch event.type {
            case .leftMouseDown:
                press = nil
                isDragging = false
                let isBlocked = window?.attachedSheet != nil || NSApp.modalWindow != nil
                guard event.window === window, !isBlocked else { return event }
                let point = convert(event.locationInWindow, from: nil)
                guard bounds.contains(point), let hit = tab(point.x) else { return event }
                press = Press(tab: hit.id, start: point, grab: CGPoint(x: point.x - hit.minX, y: point.y))
            case .leftMouseDragged:
                guard let press, event.window === window else { return event }
                let point = convert(event.locationInWindow, from: nil)
                if isDragging {
                    move(panesPoint(point))
                } else if hypot(point.x - press.start.x, point.y - press.start.y) >= Self.threshold {
                    isDragging = true
                    begin(press.tab, press.grab, panesPoint(point))
                }
            case .leftMouseUp:
                let wasDragging = isDragging
                press = nil
                isDragging = false
                if wasDragging { drop() }
            case .keyDown:
                guard isDragging, event.keyCode == Self.escape else { return event }
                press = nil
                isDragging = false
                cancel()
                return nil
            default:
                break
            }
            return event
        }
    }
}

private extension NSEvent {
    /// A copy with vertical wheel travel made horizontal, as holding Shift does.
    func turnedSideways() -> NSEvent? {
        guard let copy = cgEvent?.copy() else { return nil }
        let lines = copy.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let fraction = copy.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let points = copy.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        copy.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        copy.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: lines)
        copy.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        copy.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fraction)
        copy.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        copy.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: points)
        return NSEvent(cgEvent: copy)
    }
}
