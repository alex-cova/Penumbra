import AppKit
import SwiftUI

@main
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
                    .focusedSceneValue(\.ideWorkspace, workspace)
                    .background(IDEWindowReopenBridge())
            }
        }
        .frame(minWidth: 960, minHeight: 640)
        .onAppear {
            if workspace == nil {
                workspace = IDEWorkspace()
            }
        }
    }
}
