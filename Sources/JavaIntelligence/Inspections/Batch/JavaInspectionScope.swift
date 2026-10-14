import Foundation

/// The files an "Inspect Code" run covers.
public struct JavaInspectionScope: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Every `.java` file under the project's source roots.
        case project
        /// Files under one module's directory.
        case module(directory: URL)
        case directory(URL)
        /// Explicit files (the Explorer's selection, the active file).
        case files([URL])
        /// Files with uncommitted changes.
        case uncommitted([URL])
        case openFiles([URL])
    }

    public var kind: Kind
    public var includeTests: Bool
    /// Comma-separated globs on the project-relative path; `!` excludes (`*Dto.java, !**/generated/**`).
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
        case .module(let directory): "Module \(directory.lastPathComponent)"
        case .directory(let url): "Directory \(url.lastPathComponent)"
        case .files(let urls): urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        case .uncommitted: "Uncommitted files"
        case .openFiles: "Open files"
        }
    }

    /// The Java files in scope, sorted by path. Only directory listing touches the disk.
    public func resolve(projectRoots: [URL], classifier: JavaInspectionFileClassifier) -> [URL] {
        var candidates: [URL]
        switch kind {
        case .project:
            candidates = projectRoots.flatMap { SourceRoot(directory: $0).javaFileURLs() }
        case .module(let directory):
            let prefix = directory.standardizedFileURL.path + "/"
            let inRoots = projectRoots.flatMap { SourceRoot(directory: $0).javaFileURLs() }
            candidates = inRoots.filter { $0.standardizedFileURL.path.hasPrefix(prefix) }
        case .directory(let url):
            candidates = SourceRoot(directory: url).javaFileURLs()
        case .files(let urls), .uncommitted(let urls), .openFiles(let urls):
            candidates = urls.filter { $0.pathExtension == "java" }
        }
        var seen = Set<String>()
        var result: [URL] = []
        for url in candidates {
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { continue }
            let file = classifier.context(for: standardized)
            if !includeTests, file.isTest { continue }
            if !JavaPathGlob.passes(masks: fileMasks, path: file.relativePath) { continue }
            result.append(standardized)
        }
        return result.sorted { $0.path < $1.path }
    }
}
