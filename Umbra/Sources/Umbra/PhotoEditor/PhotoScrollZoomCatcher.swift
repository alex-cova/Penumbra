import AppKit
import SwiftUI

/// Turns ⌘+scroll over the canvas into zoom. The reference Hextech canvas used a
/// `ScrollWheelZoomCatcher` that no longer exists upstream, so this is Umbra's own: a local event
/// monitor filtered to the catcher's frame (a background view never reliably receives
/// scroll-wheel events through SwiftUI hit testing). Pinch zoom stays a `MagnifyGesture` on the
/// canvas itself.
struct PhotoScrollZoomCatcher: View {
    var onZoom: (_ factor: CGFloat, _ point: CGPoint) -> Void

    var body: some View {
        CatcherRepresentable(onZoom: onZoom)
    }
}

private struct CatcherRepresentable: NSViewRepresentable {
    var onZoom: (_ factor: CGFloat, _ point: CGPoint) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(view: view, onZoom: onZoom)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onZoom = onZoom
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var onZoom: ((_ factor: CGFloat, _ point: CGPoint) -> Void)?
        private weak var view: NSView?
        private var monitor: Any?

        func install(view: NSView, onZoom: @escaping (_ factor: CGFloat, _ point: CGPoint) -> Void) {
            self.view = view
            self.onZoom = onZoom
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let view = self.view else { return event }
                // Local monitors fire on the main thread, so touching the view under an
                // assumed MainActor is sound. The box is unchecked Sendable for exactly
                // that reason: everything in it stays on the main thread here.
                struct Unchecked: @unchecked Sendable { var view: NSView; var event: NSEvent }
                let box = Unchecked(view: view, event: event)
                // The outcome crosses back as a Sendable value because the monitor
                // closure itself is nonisolated.
                enum Outcome: Sendable {
                    case pass
                    case zoom(factor: CGFloat, point: CGPoint)
                }
                let outcome: Outcome = MainActor.assumeIsolated {
                    let view = box.view
                    let event = box.event
                    guard let window = view.window else { return .pass }
                    guard event.window == window, event.modifierFlags.contains(.command) else {
                        return .pass
                    }
                    let local = view.convert(event.locationInWindow, from: nil)
                    guard local.x >= 0, local.y >= 0,
                          local.x <= view.bounds.width, local.y <= view.bounds.height else {
                        return .pass
                    }
                    // `scrollingDeltaY` already accounts for the natural-scroll preference.
                    let delta = event.scrollingDeltaY
                    let factor: CGFloat = delta > 0 ? 1.12 : (delta < 0 ? 1 / 1.12 : 1)
                    guard factor != 1 else { return .pass }
                    // NSView is bottom-left origin; the SwiftUI canvas is top-left.
                    return .zoom(factor: factor, point: CGPoint(x: local.x, y: view.bounds.height - local.y))
                }
                switch outcome {
                case .pass:
                    return event
                case let .zoom(factor, point):
                    self.onZoom?(factor, point)
                    return nil
                }
            }
        }

        func tearDown() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
