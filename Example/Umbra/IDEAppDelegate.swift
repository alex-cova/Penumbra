import AppKit

/// SwiftUI `@main` + `swift run` (no app bundle) leaves the process at the default
/// `.prohibited` activation policy, so windows can appear but never become key.
/// Restore `.regular` before activation, then key the windows after SwiftUI creates them.
@MainActor
final class IDEAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        Task { @MainActor in
            Self.activateAndKeyWindows()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.activateAndKeyWindows()
        return true
    }

    private static func activateAndKeyWindows() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeKey && window.isVisible {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
