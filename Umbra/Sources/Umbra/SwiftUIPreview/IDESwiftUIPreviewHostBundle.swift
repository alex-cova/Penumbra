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

    /// Keys of the app's own `Info.plist` that its code can depend on and the host does not set:
    /// custom fonts (registered at launch), localizations, a forced appearance, usage descriptions
    /// (so an access request in a preview asks instead of trapping), App Transport Security and the
    /// orientations. The identity, the scene manifest and the device family stay the host's.
    static func carriedInfoKeys(_ key: String) -> Bool {
        if key.hasPrefix("NS") && key.hasSuffix("UsageDescription") { return true }
        return [
            "UIAppFonts", "CFBundleLocalizations", "CFBundleDevelopmentRegion", "UIUserInterfaceStyle",
            "UIRequiresFullScreen", "NSAppTransportSecurity", "UISupportedInterfaceOrientations",
            "UISupportedInterfaceOrientations~ipad", "UIStatusBarStyle", "UIViewControllerBasedStatusBarAppearance"
        ].contains(key)
    }

    /// The host's keys with the donor's carried ones added (the host's own win).
    static func mergedInfo(host: [String: Any], donor: [String: Any]) -> [String: Any] {
        var merged = host
        for (key, value) in donor where carriedInfoKeys(key) && merged[key] == nil { merged[key] = value }
        return merged
    }

    /// Adds the donor app's carried `Info.plist` keys to the bundle's. Returns the keys it added.
    @discardableResult
    static func mergeInfoPlist(from donor: String, into bundlePath: String) -> [String] {
        guard let donorInfo = NSDictionary(contentsOfFile: donor + "/Info.plist") as? [String: Any],
              let hostInfo = NSDictionary(contentsOfFile: bundlePath + "/Info.plist") as? [String: Any] else { return [] }
        let merged = mergedInfo(host: hostInfo, donor: donorInfo)
        let added = merged.keys.filter { hostInfo[$0] == nil }.sorted()
        guard !added.isEmpty,
              let data = try? PropertyListSerialization.data(fromPropertyList: merged, format: .xml, options: 0) else { return [] }
        return (try? data.write(to: URL(fileURLWithPath: bundlePath + "/Info.plist"), options: .atomic)) != nil ? added : []
    }

    /// Copies the `*.bundle` directories of a SwiftPM build's products folder (`<Package>_<Target>.bundle`,
    /// holding a package's resources) into the app. SwiftPM's `Bundle.module` looks beside the
    /// executable of an app, and traps when it is not there (measured in the S4 spike: the build
    /// folder's path is not a fallback on the simulator).
    @discardableResult
    static func copyPackageBundles(fromBin binPath: String, to bundlePath: String, fileManager: FileManager = .default) -> [String] {
        var copied: [String] = []
        for name in ((try? fileManager.contentsOfDirectory(atPath: binPath)) ?? []).sorted() where name.hasSuffix(".bundle") {
            let destination = bundlePath + "/" + name
            try? fileManager.removeItem(atPath: destination)
            if (try? fileManager.copyItem(atPath: binPath + "/" + name, toPath: destination)) != nil { copied.append(name) }
        }
        return copied
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
