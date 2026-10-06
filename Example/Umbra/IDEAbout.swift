import AppKit

/// The standard About Umbra panel (Application menu). Works with or without a focused window.
@MainActor
enum IDEAbout {
    static let repositoryURL = URL(string: "https://github.com/alex-cova/Penumbra")!

    static func show() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "Umbra",
            .credits: credits,
        ]
        let version = appVersion
        if !version.isEmpty {
            options[.applicationVersion] = version
        }
        if let icon = applicationIcon {
            options[.applicationIcon] = icon
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static var credits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 8

        let body = NSMutableAttributedString(
            string: "Inspired by the best text editor of all time.\n\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
        )
        body.append(NSAttributedString(
            string: "github.com/alex-cova/Penumbra",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .link: repositoryURL,
                .paragraphStyle: paragraph,
            ]
        ))
        return body
    }

    private static var appVersion: String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !version.isEmpty {
            return version
        }
        if let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
           !version.isEmpty {
            return version
        }
        return ""
    }

    private static var applicationIcon: NSImage? {
        if let image = NSApp.applicationIconImage {
            return image
        }
        for bundle in resourceBundles {
            if let url = bundle.url(forResource: "umbra", withExtension: "icns"),
               let image = NSImage(contentsOf: url) {
                return image
            }
            if let url = bundle.url(forResource: "Umbra", withExtension: "jpeg"),
               let image = NSImage(contentsOf: url) {
                image.size = NSSize(width: 512, height: 512)
                return image
            }
        }
        return nil
    }

    private static var resourceBundles: [Bundle] {
        var bundles = [Bundle.main]
        #if SWIFT_PACKAGE
        bundles.append(Bundle.module)
        #endif
        return bundles
    }
}
