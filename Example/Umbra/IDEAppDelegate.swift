import AppKit

/// SwiftUI `@main` + `swift run` (no app bundle) leaves the process at the default
/// `.prohibited` activation policy, so windows can appear but never become key.
/// Restore `.regular` before activation, then key the windows after SwiftUI creates them.
@MainActor
public final class IDEAppDelegate: NSObject, NSApplicationDelegate {
    weak var workspace: IDEWorkspace?

    public override init() {
        super.init()
    }

    public func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        Task { @MainActor in
            Self.activateAndKeyWindows()
        }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.activateAndKeyWindows()
        return true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        workspace?.saveSession()
    }

    private static func activateAndKeyWindows() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeKey && window.isVisible {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
