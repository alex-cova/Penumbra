import Foundation

/// Which files the Swift index reads. Build output, package checkouts and generated project
/// folders stay out; a file over a megabyte is almost always generated.
public enum SwiftPaths {
    public static let extensions: Set<String> = ["swift"]
    public static let skipDirectories: Set<String> = [
        ".build", ".swiftpm", "DerivedData", "Pods", "Carthage", "checkouts", "node_modules", ".git", "xcuserdata"
    ]
    public static let maxBytes = 1_048_576

    public static func isSourceFile(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    public static func isSkipped(_ url: URL) -> Bool {
        if isManifest(url) { return true }
        return url.pathComponents.contains { skipDirectories.contains($0) }
    }

    /// `Package.swift` and `Package@swift-5.9.swift`: a script whose `let package` would otherwise be
    /// a global every file could name. It is still parsed when it is the open document.
    public static func isManifest(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name == "Package.swift" || (name.hasPrefix("Package@swift-") && name.hasSuffix(".swift"))
    }
}
