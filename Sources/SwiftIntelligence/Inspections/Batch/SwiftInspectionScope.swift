import Foundation


/// The files an Inspect Code run over Swift covers. Mirrors ``JavaInspectionScope``: the same kinds, test
/// and file-mask filters, and a short title for a results tab. There is no module kind: a SwiftPM target or
/// an Xcode target is a folder, and "Directory" reaches it.
public struct SwiftInspectionScope: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Every `.swift` file under the project folder.
        case project
        case directory(URL)
        /// Explicit files (the Explorer's selection, the active file).
        case files([URL])
        /// Files with uncommitted changes.
        case uncommitted([URL])
        case openFiles([URL])
    }

    public var kind: Kind
    public var includeTests: Bool
    /// Comma-separated globs on the project-relative path; `!` excludes (`*Generated.swift, !**/Fixtures/**`).
    public var fileMasks: String

    public init(kind: Kind, includeTests: Bool = true, fileMasks: String = "") {
        self.kind = kind
        self.includeTests = includeTests
        self.fileMasks = fileMasks
    }

    /// A short name for a results tab.
    public var title: String {
        switch kind {
        case .project: "Whole project"
        case .directory(let url): "Directory \(url.lastPathComponent)"
        case .files(let urls): urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        case .uncommitted: "Uncommitted files"
        case .openFiles: "Open files"
        }
    }

    /// Folders that hold build products or fetched code, never the user's own sources.
    static let skippedDirectories: Set<String> = [
        ".build", "DerivedData", "Pods", "Carthage", "node_modules", "SourcePackages", "xcuserdata",
    ]

    /// The Swift files in scope, sorted by path. Only directory listing touches the disk.
    public func resolve(projectRoots: [URL]) -> [URL] {
        var candidates: [URL]
        switch kind {
        case .project:
            candidates = projectRoots.flatMap { Self.swiftFiles(under: $0) }
        case .directory(let url):
            candidates = Self.swiftFiles(under: url)
        case .files(let urls), .uncommitted(let urls), .openFiles(let urls):
            candidates = urls.filter { $0.pathExtension == "swift" }
        }
        let roots = projectRoots.map { $0.standardizedFileURL.path }
        var seen = Set<String>()
        var result: [URL] = []
        for url in candidates {
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { continue }
            if !includeTests, Self.isTest(standardized) { continue }
            if !SwiftPathGlob.passes(masks: fileMasks, path: Self.relativePath(of: standardized, roots: roots)) { continue }
            result.append(standardized)
        }
        return result.sorted { $0.path < $1.path }
    }

    /// A test source: under a folder called `Tests` or `*Tests`, or named `*Tests.swift` / `*Test.swift`.
    public static func isTest(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent
        if name.hasSuffix("Tests") || name.hasSuffix("Test") { return true }
        return url.deletingLastPathComponent().pathComponents.contains { $0 == "Tests" || $0.hasSuffix("Tests") }
    }

    static func relativePath(of url: URL, roots: [String]) -> String {
        let path = url.path
        for root in roots where path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        return path
    }

    private static func swiftFiles(under directory: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in walker {
            if skippedDirectories.contains(url.lastPathComponent) {
                walker.skipDescendants()
            } else if url.pathExtension == "swift" {
                files.append(url)
            }
        }
        return files
    }
}
