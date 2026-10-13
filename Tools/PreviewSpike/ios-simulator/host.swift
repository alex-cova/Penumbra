import UIKit
import SwiftUI
import Darwin

@main
@objc(AppDelegate)
final class AppDelegate: UIResponder, UIApplicationDelegate {}

@objc(SceneDelegate)
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: windowScene)
        w.rootViewController = UIHostingController(rootView:
            NavigationStack { List { Text("Hello from the simulator"); Color(.systemGroupedBackground).frame(height: 40) }.navigationTitle("Spike").navigationBarTitleDisplayMode(.large) })
        w.makeKeyAndVisible()
        window = w
        let out = ProcessInfo.processInfo.environment["UMBRA_OUT"] ?? "/tmp/simspike.png"
        let started = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let r = UIGraphicsImageRenderer(bounds: w.bounds)
            let img = r.image { _ in w.drawHierarchy(in: w.bounds, afterScreenUpdates: true) }
            do {
                try img.pngData()!.write(to: URL(fileURLWithPath: out))
                print("wrote", out)
            } catch {
                print("write failed", error)
            }
            // dlopen a host-built sim dylib
            if let p = ProcessInfo.processInfo.environment["UMBRA_DYLIB"] {
                let h = dlopen(p, RTLD_NOW); let r = h != nil ? "dlopen ok" : "dlopen failed " + String(cString: dlerror()); try? r.write(toFile: out + ".dlopen.txt", atomically: true, encoding: .utf8)
            }
            // unix socket back to the Mac
            if let s = ProcessInfo.processInfo.environment["UMBRA_SOCK"] {
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
                withUnsafeMutableBytes(of: &addr.sun_path) { b in s.withCString { _ = strncpy(b.baseAddress!.assumingMemoryBound(to: CChar.self), $0, b.count - 1) } }
                let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
                print("connect", rc, errno)
                let msg = "{\"event\":\"ready\"}\n"; _ = write(fd, msg, msg.utf8.count)
            }
            print("elapsed", Date().timeIntervalSince(started))
        }
    }
}
