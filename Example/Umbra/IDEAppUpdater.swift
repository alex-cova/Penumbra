import AppKit
import Sparkle

/// Sparkle-based automatic updates for release `.app` bundles. Disabled during `swift run` and
/// other non-bundle dev builds that lack `SUFeedURL` in their Info.plist.
@MainActor
enum IDEAppUpdater {
    private static var controller: SPUStandardUpdaterController?

    /// Whether Sparkle is active in this process (release app bundle with a feed URL).
    static var isEnabled: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
            && (Bundle.main.infoDictionary?["SUFeedURL"] as? String)?.isEmpty == false
    }

    /// Whether the user can manually check for updates right now.
    static var canCheckForUpdates: Bool {
        isEnabled && controller?.updater.canCheckForUpdates == true
    }

    static var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    static var automaticallyDownloadsUpdates: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    static func startIfNeeded() {
        guard isEnabled, controller == nil else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    static func checkForUpdates(_ sender: Any?) {
        controller?.checkForUpdates(sender)
    }
}
