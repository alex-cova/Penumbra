import AppKit
import SwiftUI

/// SwiftUI `@main` + `swift run` (no app bundle) leaves the process at the default
/// `.prohibited` activation policy, so windows can appear but never become key.
/// Restore `.regular` before activation, then key the windows after SwiftUI creates them.
@MainActor
public final class IDEAppDelegate: NSObject, NSApplicationDelegate {
    /// SwiftUI's `NSApplicationDelegateAdaptor` installs an internal `NSApp.delegate` wrapper,
    /// so `NSApp.delegate as? IDEAppDelegate` always fails. The adaptor-owned instance is kept here.
    static weak var shared: IDEAppDelegate?

    /// Called when the dock icon is clicked and every window has been closed. Wired from
    /// `IDEWindowReopenBridge` so SwiftUI can open a fresh `WindowGroup` window.
    var onReopenWithoutVisibleWindows: (() -> Void)?

    public override init() {
        super.init()
        Self.shared = self
    }

    public func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        Self.installApplicationIconIfNeeded()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        IDESecondaryShortcutMonitor.install()
        Task { @MainActor in
            Self.activateAndKeyWindows()
        }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            let hidden = Self.restorableWindows().filter { !$0.isVisible }
            if hidden.isEmpty {
                onReopenWithoutVisibleWindows?()
            } else {
                for window in hidden {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
        Self.activateAndKeyWindows()
        return true
    }

    /// Files or folders dropped on the Dock icon, opened with Open With, or `open -a Umbra <path>`.
    /// A folder becomes the project; files open as tabs (`IDEWorkspace.openDroppedURLs`). They go
    /// to the active window through `IDEWindowRegistry`, which holds them until a window exists.
    public func application(_ application: NSApplication, open urls: [URL]) {
        IDEWindowRegistry.shared.open(urls: urls)
        if IDEWindowRegistry.shared.activeWorkspace != nil {
            Self.activateAndKeyWindows()
        }
    }

    /// The tab bar's + button and File > New Window Tab reach here through the responder chain.
    @objc func newWindowForTab(_ sender: Any?) {
        IDEWindowRegistry.shared.openNewTab()
    }

    /// One prompt for unsaved editors in every window.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        IDEWindowRegistry.shared.confirmQuit() ? .terminateNow : .terminateCancel
    }

    public func applicationWillTerminate(_ notification: Notification) {
        IDEWindowRegistry.shared.saveSessionsForTermination()
        IDEWindowRegistry.shared.tearDownAll()
    }

    private static func restorableWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.canBecomeKey && $0.level == .normal }
    }

    private static func activateAndKeyWindows() {
        NSApp.activate(ignoringOtherApps: true)
        for window in restorableWindows() {
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
        guard let delegate = IDEAppDelegate.shared else { return }
        delegate.onReopenWithoutVisibleWindows = {
            openWindow(id: "main")
        }
        IDEWindowRegistry.shared.setOpenWindowAction {
            openWindow(id: "main")
        }
    }
}
