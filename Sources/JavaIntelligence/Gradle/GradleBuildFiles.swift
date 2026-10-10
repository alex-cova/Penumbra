import Foundation

/// Which paths under a project root are Gradle build inputs: the ones whose content decides whether
/// the synced model is still right. Generated output (`build/`), the daemon cache (`.gradle/`),
/// dependency folders and hidden folders are skipped, so a sync doesn't immediately ask to sync
/// again and `npm install` doesn't raise a reload banner.
///
/// Paths are judged **relative to the project root**: a project that lives under a folder named
/// `build` (or a hidden one) is still a project.
public enum GradleBuildFiles {
    /// Folders that never hold build inputs. Hidden folders (`.git`, `.gradle`, `.idea`…) are skipped
    /// on top of these.
    static let ignoredDirectoryNames: Set<String> = [
        ".git", ".gradle", "build", "out", "node_modules", ".idea", ".vscode"
    ]

    /// `relativePath` is slash-separated and relative to the project root.
    public static func isBuildInput(relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard let name = components.last else { return false }
        let directories = components.dropLast()
        for directory in directories where directory.hasPrefix(".") || ignoredDirectoryNames.contains(String(directory)) {
            return false
        }
        switch name {
        case "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "gradle.properties":
            return true
        case "libs.versions.toml":
            return directories.last == "gradle"
        case "gradle-wrapper.properties":
            return directories.suffix(2).elementsEqual(["gradle", "wrapper"])
        default:
            return false
        }
    }

    /// The path FSEvents would report for `url`: every symlink resolved with `realpath`, so
    /// `/var/folders/…` becomes `/private/var/folders/…`. `URL.resolvingSymlinksInPath()` is not
    /// enough, it deliberately turns `/private/var` back into `/var`, and a prefix test against an
    /// event path would then fail for every file in a temporary or `/tmp` project.
    public static func canonicalRootPath(for url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else {
            return url.standardizedFileURL.resolvingSymlinksInPath().path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// For an absolute path that FSEvents reported under `root`; take `root` from
    /// ``canonicalRootPath(for:)``. A path outside `root` is not a build input.
    public static func matches(path: String, root: String) -> Bool {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return false }
        return isBuildInput(relativePath: String(path.dropFirst(prefix.count)))
    }

    /// For an absolute path when no root is known: every component counts, so a project under a
    /// hidden or `build` folder is rejected. Prefer ``matches(path:root:)``.
    public static func matches(path: String) -> Bool {
        isBuildInput(relativePath: path)
    }

    /// The relative paths of every build input under `root`, sorted. This is the one walk behind both
    /// ``GradleBuildFingerprintCollector`` and ``GradleBuildFileSnapshot``, so they agree on what a
    /// build input is.
    public static func inputPaths(under root: URL) -> [String] {
        var paths: [String] = []
        collect(from: root, relativePrefix: "", into: &paths)
        return paths.sorted()
    }

    private static func collect(from directory: URL, relativePrefix: String, into paths: inout [String]) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for entry in entries {
            let name = entry.lastPathComponent
            let relative = relativePrefix + name
            if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                guard !ignoredDirectoryNames.contains(name) else { continue }
                collect(from: entry, relativePrefix: relative + "/", into: &paths)
            } else if isBuildInput(relativePath: relative) {
                paths.append(relative)
            }
        }
    }
}
