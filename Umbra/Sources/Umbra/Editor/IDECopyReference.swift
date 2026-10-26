import Foundation

/// The folders a path can be written relative to in the Copy popup. All paths are standardized.
struct IDECopyReferenceRoots: Equatable {
    var projectRoot: String?
    /// The git toplevel, when the open folder is inside a repository.
    var repositoryRoot: String?
    /// Gradle subproject / Maven module directories.
    var contentRoots: [String] = []
    /// Source directories the build model reports.
    var sourceRoots: Set<String> = []
}

/// What the Copy popup (Explorer and editor) offers for a file: the same path written relative to
/// each root, a Java class name, and `path:line` references. Pure, so it is testable.
enum IDECopyReference {
    struct Row: Equatable {
        let label: String
        let value: String
    }

    /// Rows grouped as the popup shows them, a separator between groups. A row that does not apply
    /// (no repository, a file outside every source root) is left out.
    static func sections(for url: URL, roots: IDECopyReferenceRoots) -> [[Row]] {
        let path = url.standardizedFileURL.path
        var sections: [[Row]] = [[
            Row(label: "Absolute Path", value: path),
            Row(label: "File Name", value: url.lastPathComponent)
        ]]
        var relative: [Row] = []
        if let projectRoot = roots.projectRoot, let value = relativePath(path, to: projectRoot) {
            relative.append(Row(label: "Path from Project Root", value: value))
        }
        if let root = contentRoot(for: path, in: roots), let value = relativePath(path, to: root) {
            relative.append(Row(label: "Path from Content Root", value: value))
        }
        if let root = sourceRoot(for: path, in: roots), let value = relativePath(path, to: root) {
            relative.append(Row(label: "Path from Source Root", value: value))
        }
        if let root = roots.repositoryRoot, let value = relativePath(path, to: root) {
            relative.append(Row(label: "Path from Repository Root", value: value))
        }
        if !relative.isEmpty { sections.append(relative) }
        return sections
    }

    /// The deepest module directory holding `path`, or the project root when no module does.
    static func contentRoot(for path: String, in roots: IDECopyReferenceRoots) -> String? {
        let candidates = roots.contentRoots + (roots.projectRoot.map { [$0] } ?? [])
        return deepestRoot(containing: path, in: candidates)
    }

    /// The deepest build-model source directory holding `path`; failing that, the
    /// `…/src/<set>/{java,kotlin,resources}` convention, which also covers resource folders the
    /// model does not list and projects that have not synced yet.
    static func sourceRoot(for path: String, in roots: IDECopyReferenceRoots) -> String? {
        if let root = deepestRoot(containing: path, in: Array(roots.sourceRoots)) { return root }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        // The last component is the item itself, so a root is at most its parent.
        guard components.count >= 4 else { return nil }
        for index in stride(from: components.count - 2, through: 2, by: -1) {
            guard ["java", "kotlin", "resources"].contains(components[index]),
                  components[index - 2] == "src" else { continue }
            return "/" + components[0...index].joined(separator: "/")
        }
        return nil
    }

    /// `com.foo.Bar` for `<source root>/com/foo/Bar.java`; `nil` outside a source root or for a
    /// file that declares no class by its name.
    static func javaQualifiedName(for url: URL, roots: IDECopyReferenceRoots) -> String? {
        let path = url.standardizedFileURL.path
        guard url.pathExtension == "java",
              !["package-info", "module-info"].contains(url.deletingPathExtension().lastPathComponent),
              let root = sourceRoot(for: path, in: roots),
              let relative = relativePath(path, to: root) else { return nil }
        let name = relative.dropLast(".java".count)
        guard !name.isEmpty else { return nil }
        return name.split(separator: "/").joined(separator: ".")
    }

    /// The path a line reference starts from: relative to the repository root, else the open
    /// folder, else absolute.
    static func referencePath(for url: URL, roots: IDECopyReferenceRoots) -> String {
        let path = url.standardizedFileURL.path
        for root in [roots.repositoryRoot, roots.projectRoot] {
            if let root, let value = relativePath(path, to: root) { return value }
        }
        return path
    }

    /// 1-based lines a selection covers. A selection that ends at the start of a line does not
    /// include that line; an empty selection is the caret's line. Inputs are 0-based.
    static func lineRange(startLine: Int, endLine: Int, endColumn: Int, isEmpty: Bool) -> ClosedRange<Int> {
        let first = max(0, startLine) + 1
        guard !isEmpty, endLine > startLine else { return first...first }
        let last = (endColumn == 0 ? endLine - 1 : endLine) + 1
        return first...max(first, last)
    }

    /// `path:42` for one line, `path:18-57` for several.
    static func lineReference(path: String, lines: ClosedRange<Int>) -> String {
        lines.lowerBound == lines.upperBound
            ? "\(path):\(lines.lowerBound)"
            : "\(path):\(lines.lowerBound)-\(lines.upperBound)"
    }

    // MARK: - Paths

    static func relativePath(_ path: String, to root: String) -> String? {
        if path == root { return "." }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    static func deepestRoot(containing path: String, in candidates: [String]) -> String? {
        candidates
            .filter { relativePath(path, to: $0) != nil }
            .max { $0.count < $1.count }
    }
}
