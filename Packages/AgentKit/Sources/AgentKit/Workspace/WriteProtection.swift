import Foundation

/// Where the agent never writes: version-control data and build output. Mirrors Umbra's Explorer,
/// which treats `build`, `out` and `target` as output only directly under a project that has a
/// build file, so a Java package called `build` stays editable.
public struct WriteProtection: Sendable {
    public var alwaysProtected: Set<String>
    public var outputDirectoryNames: Set<String>
    public var projectMarkers: Set<String>

    public static let `default` = WriteProtection(
        alwaysProtected: [".git", ".gradle"],
        outputDirectoryNames: ["build", "out", "target", "node_modules", ".build"],
        projectMarkers: [
            "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "pom.xml", "package.json", "Package.swift",
        ])

    public init(alwaysProtected: Set<String>, outputDirectoryNames: Set<String>, projectMarkers: Set<String>) {
        self.alwaysProtected = alwaysProtected
        self.outputDirectoryNames = outputDirectoryNames
        self.projectMarkers = projectMarkers
    }

    /// Whether a resolved absolute path under `root` is protected. A path may not exist yet.
    public func isProtected(_ url: URL, root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return false }
        var parent = rootPath
        for component in path.dropFirst(rootPath.count + 1).split(separator: "/") {
            let name = String(component)
            if alwaysProtected.contains(name) { return true }
            if outputDirectoryNames.contains(name),
               projectMarkers.contains(where: { FileManager.default.fileExists(atPath: parent + "/" + $0) }) {
                return true
            }
            parent += "/" + name
        }
        return false
    }
}

/// Files that likely hold credentials. What the agent reads goes to the model's provider, so these
/// are not read.
public enum SecretFilePolicy {
    /// Globs the user added to the built-in list. A pattern that doesn't parse is skipped: failing
    /// closed on a typo would hide nothing, and refusing to start would lose the setting entirely.
    public static func patterns(from lines: [String]) -> [GlobPattern] {
        lines.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .compactMap { try? GlobPattern($0) }
    }

    public static func isLikelySecret(_ path: String, extra: [GlobPattern]) -> Bool {
        isLikelySecret(path) || extra.contains { $0.matches(path) }
    }

    public static func isLikelySecret(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name == ".env" || name.hasPrefix(".env.") || name.hasSuffix(".env") { return true }
        if name == ".netrc" || name == ".npmrc" || name == ".pgpass" { return true }
        if name.hasPrefix("id_rsa") || name.hasPrefix("id_ed25519") || name.hasPrefix("id_ecdsa") || name.hasPrefix("id_dsa") {
            return true
        }
        let ext = (name as NSString).pathExtension
        return ["pem", "key", "p12", "pfx", "keystore", "jks"].contains(ext)
    }
}
