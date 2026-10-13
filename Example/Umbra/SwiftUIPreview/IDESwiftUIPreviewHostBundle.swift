import Foundation

/// The simulator host's app bundle: an `Info.plist` and the executable `swiftc` links into it, plus
/// the resources of the app the project builds (asset catalogs, storyboards, strings, resource
/// bundles), so `Image("logo")` and `Color("brand")` find what they do in the real app.
enum IDESwiftUIPreviewHostBundle {
    /// What of the app is not copied: its executable and everything that identifies or signs it.
    private static let skipped: Set<String> = [
        "Info.plist", "PkgInfo", "_CodeSignature", "embedded.mobileprovision", "Frameworks", "PlugIns", "Watch", "SC_Info"
    ]

    /// A new, empty bundle directory with `infoPlist` in it; whatever was there is removed first
    /// (an old executable and its signature).
    static func create(at bundlePath: String, infoPlist: String, fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: bundlePath) { try fileManager.removeItem(atPath: bundlePath) }
        try fileManager.createDirectory(atPath: bundlePath, withIntermediateDirectories: true)
        try infoPlist.write(toFile: bundlePath + "/Info.plist", atomically: true, encoding: .utf8)
    }

    /// The `.app` the build left in `binPath` for `target`: the one named like it, else the only one.
    static func donor(in binPath: String, target: String, fileManager: FileManager = .default) -> String? {
        let apps = ((try? fileManager.contentsOfDirectory(atPath: binPath)) ?? []).filter { $0.hasSuffix(".app") }.sorted()
        let name = apps.first { $0 == target + ".app" } ?? (apps.count == 1 ? apps[0] : nil)
        return name.map { binPath + "/" + $0 }
    }

    /// Copies the donor's resources into the bundle. Returns what it copied; a failure to copy one
    /// item leaves it out (the preview is still useful) and is not an error.
    @discardableResult
    static func copyResources(from donor: String, to bundlePath: String, fileManager: FileManager = .default) -> [String] {
        var executable: String?
        if let info = NSDictionary(contentsOfFile: donor + "/Info.plist") { executable = info["CFBundleExecutable"] as? String }
        var copied: [String] = []
        for name in (try? fileManager.contentsOfDirectory(atPath: donor)) ?? [] {
            guard !skipped.contains(name), name != executable, name != "UmbraPreviewHost" else { continue }
            let destination = bundlePath + "/" + name
            guard !fileManager.fileExists(atPath: destination) else { continue }
            if (try? fileManager.copyItem(atPath: donor + "/" + name, toPath: destination)) != nil { copied.append(name) }
        }
        return copied
    }
}
