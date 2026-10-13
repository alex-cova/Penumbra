import AppKit
import SwiftUI

/// The app scene. The process entry point is `UmbraMain`, which runs the git askpass helper mode
/// before starting this.
struct UmbraApp: App {
    @NSApplicationDelegateAdaptor(IDEAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            IDEWindowScene()
        }
        // Every external open (Dock drop, Open With, `open -a`) goes to
        // `IDEAppDelegate.application(_:open:)` and `IDEWindowRegistry`, which picks the window. So
        // SwiftUI must not open one itself: matching "*" opens a blank window per event, and an
        // empty set also suppresses the launch window. A name no event has matches nothing and
        // leaves the launch window alone.
        .handlesExternalEvents(matching: ["umbra-never-matches-an-event"])
        .windowStyle(.hiddenTitleBar)
        .commands {
            IDEAppCommands()
        }
    }
}

/// One window's content. Each window creates and owns its own `IDEWorkspace`, so windows are
/// independent editors; the menu bar reaches the focused one through `focusedSceneValue`.
struct IDEWindowScene: View {
    /// Created on first appearance rather than as a property default: SwiftUI can re-initialize this
    /// struct and would build (and throw away) a whole workspace each time.
    @State private var workspace: IDEWorkspace?

    var body: some View {
        ZStack {
            if let workspace {
                IDERootView()
                    .environment(workspace)
                    .focusedSceneValue(\.ideWorkspace, workspace.reference)
                    .background(IDEWindowReopenBridge())
            }
        }
        .frame(minWidth: 960, minHeight: 640)
        .background(IDEReopenCenteringView().frame(width: 0, height: 0))
        .onAppear {
            if workspace == nil {
                workspace = IDEWorkspace()
            }
        }
    }
}

/// Centers the window a Dock reopen opens (`IDEWindowRegistry.openWindowForReopen`). It sits outside
/// the `if let workspace` above so it joins the window with its first layout; the workspace's own
/// configurator attaches after `onAppear`, by which time the window is already on screen at SwiftUI's
/// initial position. The window stays transparent until it has been centered, so it never shows
/// anywhere else.
private struct IDEReopenCenteringView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        CenteringView()
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class CenteringView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window,
                  MainActor.assumeIsolated({ IDEWindowRegistry.shared.takeCentersNextWindow() }) else { return }
            window.alphaValue = 0
            window.center()
            // SwiftUI sizes the window to its content after this, which moves the center; place it
            // again once that layout has run, then show it.
            DispatchQueue.main.async { [weak window] in
                DispatchQueue.main.async {
                    guard let window else { return }
                    if !window.styleMask.contains(.fullScreen) {
                        window.center()
                    }
                    window.alphaValue = 1
                }
            }
        }
    }
}
