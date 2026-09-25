import AppKit
import SwiftUI

/// SwiftUI `@main` + `swift run` (no app bundle) leaves the process at the default
/// `.prohibited` activation policy, so windows can appear but never become key.
/// Restore `.regular` before activation, then key the windows after SwiftUI creates them.
@MainActor
public final class IDEAppDelegate: NSObject, NSApplicationDelegate {
    weak var workspace: IDEWorkspace?
    /// Called when the dock icon is clicked and every window has been closed. Wired from
    /// `IDEWindowReopenBridge` so SwiftUI can open a fresh `WindowGroup` window.
    var onReopenWithoutVisibleWindows: (() -> Void)?

    public override init() {
        super.init()
    }

    public func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        Self.installApplicationIconIfNeeded()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        Task { @MainActor in
            Self.activateAndKeyWindows()
        }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            onReopenWithoutVisibleWindows?()
        }
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

    /// `swift run` and the Xcode dev target ship no `umbra.icns` in the bundle, so the dock falls
    /// back to the generic executable icon even though release `build-app.sh` bundles one.
    private static func installApplicationIconIfNeeded() {
        guard NSApp.applicationIconImage == nil else { return }
        for bundle in resourceBundles {
            if let image = loadApplicationIcon(from: bundle) {
                NSApp.applicationIconImage = image
                return
            }
        }
    }

    private static var resourceBundles: [Bundle] {
        var bundles = [Bundle.main]
        #if SWIFT_PACKAGE
        bundles.append(Bundle.module)
        #endif
        return bundles
    }

    private static func loadApplicationIcon(from bundle: Bundle) -> NSImage? {
        if let url = bundle.url(forResource: "umbra", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        if let url = bundle.url(forResource: "Umbra", withExtension: "jpeg"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 512, height: 512)
            return image
        }
        return nil
    }
}

/// Keeps `IDEAppDelegate.onReopenWithoutVisibleWindows` wired to SwiftUI's `openWindow` action.
struct IDEWindowReopenBridge: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear(perform: register)
    }

    private func register() {
        guard let delegate = NSApp.delegate as? IDEAppDelegate else { return }
        delegate.onReopenWithoutVisibleWindows = {
            openWindow(id: "main")
        }
    }
}
