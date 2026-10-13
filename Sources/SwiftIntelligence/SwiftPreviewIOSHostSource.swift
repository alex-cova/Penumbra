/// The source of the preview host for the iOS Simulator: `UmbraPreviewHost.app`'s executable.
///
/// It speaks the protocol of ``SwiftPreviewHostSource`` (JSON lines on a Unix socket it binds,
/// `--socket <path>` as an argument, `load`, `render`, `quit`, a `ready` event first), so the
/// session's connection and queue are the macOS host's. What differs is the process around it:
///
/// - It is an app, started with `simctl launch` and installed with `simctl install`, so it needs a
///   bundle (``infoPlist(bundleIdentifier:minimumOSVersion:)``) and an ad-hoc signature.
/// - It must adopt the scene lifecycle: an app built with the iOS 27 SDK that does not traps at
///   launch (`___UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption`, measured in
///   `Tools/PreviewSpike/ios-simulator`). `UIApplicationSceneManifest` names `UmbraSceneDelegate`.
/// - The window is a real scene window of the device's size, so `render` ignores the requested
///   `width` and `height` and reports the size it drew (`pointWidth`, `pointHeight`), as the
///   macOS host does for `fit`. Safe areas, the navigation bar's large title and the keyboard
///   guide are the system's, so `safeTop` and `safeBottom` are not used.
/// - A frame is `UIWindow.drawHierarchy` at the screen's scale (or the requested one, if finer):
///   presented sheets are part of the window's hierarchy and are in it. The status bar is not.
/// - `mouse`, `scroll` and `key` are answered with `ack` and do nothing yet (plan §9, S3).
///
/// The simulator process is a Mac process: it binds the socket, loads the thunk by its absolute
/// path and writes the PNG anywhere the Mac user can write.
public enum SwiftPreviewIOSHostSource {
    public static let fileName = "main.swift"

    /// The bundle's `Info.plist`: a scene manifest naming the host's scene delegate and nothing else.
    public static func infoPlist(bundleIdentifier: String, minimumOSVersion: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key><string>\(bundleIdentifier)</string>
            <key>CFBundleExecutable</key><string>UmbraPreviewHost</string>
            <key>CFBundleName</key><string>UmbraPreviewHost</string>
            <key>CFBundleDisplayName</key><string>Umbra Preview</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            <key>CFBundleVersion</key><string>1</string>
            <key>CFBundleShortVersionString</key><string>1</string>
            <key>MinimumOSVersion</key><string>\(minimumOSVersion)</string>
            <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
            <key>UILaunchScreen</key><dict/>
            <key>UIApplicationSceneManifest</key>
            <dict>
                <key>UIApplicationSupportsMultipleScenes</key><false/>
                <key>UISceneConfigurations</key>
                <dict>
                    <key>UIWindowSceneSessionRoleApplication</key>
                    <array>
                        <dict>
                            <key>UISceneConfigurationName</key><string>Default</string>
                            <key>UISceneDelegateClassName</key><string>UmbraSceneDelegate</string>
                        </dict>
                    </array>
                </dict>
            </dict>
        </dict>
        </plist>
        """
    }

    public static let text = #"""
    import Darwin
    import Foundation
    import SwiftUI
    import UIKit
    import UmbraPreviewSupport

    @MainActor
    final class PreviewHost {
        static let shared = PreviewHost()

        var window: UIWindow?
        var client: Int32 = -1
        var hasPreviewView = false
        /// `ready` is sent once the socket has a client and the scene has a window, in either order.
        var announced = false

        /// `DynamicTypeSize`'s case names, as `UIContentSizeCategory`.
        static func category(forDynamicType name: String) -> UIContentSizeCategory {
            switch name {
            case "xSmall": return .extraSmall
            case "small": return .small
            case "medium": return .medium
            case "xLarge": return .extraLarge
            case "xxLarge": return .extraExtraLarge
            case "xxxLarge": return .extraExtraExtraLarge
            case "accessibility1": return .accessibilityMedium
            case "accessibility2": return .accessibilityLarge
            case "accessibility3": return .accessibilityExtraLarge
            case "accessibility4": return .accessibilityExtraExtraLarge
            case "accessibility5": return .accessibilityExtraExtraExtraLarge
            default: return .large
            }
        }

        func windowReady(_ window: UIWindow) {
            self.window = window
            announceIfReady()
        }

        func clientConnected(_ descriptor: Int32) {
            client = descriptor
            announceIfReady()
        }

        func announceIfReady() {
            guard !announced, client >= 0, window != nil else { return }
            announced = true
            send(["event": "ready"])
        }

        func send(_ object: [String: Any]) {
            guard client >= 0, var data = try? JSONSerialization.data(withJSONObject: object) else { return }
            data.append(10)
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(client, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if written <= 0 { return }
                    offset += written
                }
            }
        }

        func handle(_ object: [String: Any]) {
            switch object["cmd"] as? String {
            case "load": load(object)
            case "render": render(object)
            case "mouse", "scroll", "key": send(["event": "ack"])
            case "quit": exit(0)
            default: send(["event": "error", "message": "unknown command"])
            }
        }

        func load(_ object: [String: Any]) {
            let generation = object["generation"] as? Int ?? 0
            func fail(_ message: String) {
                send(["event": "loaded", "generation": generation, "ok": false, "error": message])
            }
            guard let window else { return fail("no window") }
            guard let path = object["dylib"] as? String else { return fail("no dylib") }
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
                return fail(String(cString: dlerror()))
            }
            guard let symbol = dlsym(handle, "umbra_preview_make_view") else {
                return fail("umbra_preview_make_view not found")
            }
            if !hasPreviewView {
                typealias Make = @convention(c) () -> UnsafeMutableRawPointer
                let make = unsafeBitCast(symbol, to: Make.self)
                let controller = Unmanaged<UIViewController>.fromOpaque(make()).takeRetainedValue()
                window.rootViewController = controller
                hasPreviewView = true
            } else {
                // The thunk replaced `UmbraPreview.content()`: the root creates it again.
                UmbraReload.shared.reset()
            }
            send(["event": "loaded", "generation": generation, "ok": true])
        }

        func render(_ object: [String: Any]) {
            let generation = object["generation"] as? Int ?? 0
            func fail(_ message: String) {
                send(["event": "frame", "generation": generation, "ok": false, "error": message])
            }
            guard let window, hasPreviewView, let output = object["output"] as? String else { return fail("nothing loaded") }
            window.overrideUserInterfaceStyle = (object["scheme"] as? String) == "dark" ? .dark : .light
            let environment = UmbraEnvironment.shared
            let dynamicType = object["dynamicType"] as? String ?? "large"
            let locale = object["locale"] as? String ?? ""
            let rightToLeft = object["rightToLeft"] as? Bool ?? false
            // UIKit's own parts (the navigation bar, the keyboard) follow traits, not SwiftUI's
            // environment, so the text size and the layout direction go in as trait overrides.
            window.traitOverrides.preferredContentSizeCategory = PreviewHost.category(forDynamicType: dynamicType)
            window.traitOverrides.layoutDirection = rightToLeft ? .rightToLeft : .leftToRight
            if environment.dynamicTypeSize != dynamicType { environment.dynamicTypeSize = dynamicType }
            if environment.localeIdentifier != locale { environment.localeIdentifier = locale }
            if environment.rightToLeft != rightToLeft { environment.rightToLeft = rightToLeft }
            // SwiftUI commits asynchronously: give it a few run-loop turns before drawing.
            for _ in 0..<3 {
                window.layoutIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
            }
            let bounds = window.bounds
            let screenScale = window.traitCollection.displayScale
            var scale = max(CGFloat((object["scale"] as? Double) ?? 0), screenScale > 0 ? screenScale : 2)
            // Stay under about 36 megapixels, as the macOS host does.
            let area = bounds.width * bounds.height
            if area * scale * scale > 36_000_000 { scale = (36_000_000 / area).squareRoot() }
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = true
            let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
                window.drawHierarchy(in: bounds, afterScreenUpdates: true)
            }
            guard let png = image.pngData() else { return fail("no image") }
            let temporary = output + ".tmp"
            do {
                try png.write(to: URL(fileURLWithPath: temporary))
                _ = rename(temporary, output)
            } catch {
                return fail("\(error)")
            }
            send(["event": "frame", "generation": generation, "ok": true, "path": output,
                  "width": Int(bounds.width * scale), "height": Int(bounds.height * scale),
                  "pointWidth": Double(bounds.width), "pointHeight": Double(bounds.height)])
        }
    }

    @objc(UmbraAppDelegate)
    final class AppDelegate: UIResponder, UIApplicationDelegate {}

    @objc(UmbraSceneDelegate)
    final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
        var window: UIWindow?

        func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
            guard let windowScene = scene as? UIWindowScene else { return }
            let window = UIWindow(windowScene: windowScene)
            window.rootViewController = UIViewController()
            window.makeKeyAndVisible()
            self.window = window
            MainActor.assumeIsolated { PreviewHost.shared.windowReady(window) }
        }
    }

    // MARK: - Socket

    func serve(path: String) {
        unlink(path)
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(path.utf8.prefix(raw.count - 1))
            raw.copyBytes(from: bytes)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(server, 1) == 0 else {
            FileHandle.standardError.write(Data("bind failed: \(String(cString: strerror(errno)))\n".utf8))
            exit(2)
        }
        Thread.detachNewThread {
            let connection = accept(server, nil, nil)
            if connection < 0 { exit(3) }
            DispatchQueue.main.async { MainActor.assumeIsolated { PreviewHost.shared.clientConnected(connection) } }
            var pending = Data()
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = read(connection, &chunk, chunk.count)
                if count <= 0 { exit(0) } // Umbra went away.
                pending.append(contentsOf: chunk[0..<count])
                while let newline = pending.firstIndex(of: 10) {
                    let line = pending[..<newline]
                    pending.removeSubrange(...newline)
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    DispatchQueue.main.async { MainActor.assumeIsolated { PreviewHost.shared.handle(object) } }
                }
            }
        }
    }

    let arguments = CommandLine.arguments
    guard let flag = arguments.firstIndex(of: "--socket"), flag + 1 < arguments.count else {
        FileHandle.standardError.write(Data("usage: host --socket <path>\n".utf8))
        exit(64)
    }
    serve(path: arguments[flag + 1])
    UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, "UmbraAppDelegate")
    """#
}
