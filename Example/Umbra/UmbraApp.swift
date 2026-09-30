import AppKit
import SwiftUI

@main
struct UmbraApp: App {
    @NSApplicationDelegateAdaptor(IDEAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            IDEWindowScene()
        }
        // Every external open (Dock drop, Open With) goes to `IDEAppDelegate.application(_:open:)`
        // and `IDEWindowRegistry`; without this SwiftUI opens a new window per URL.
        .handlesExternalEvents(matching: ["*"])
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
