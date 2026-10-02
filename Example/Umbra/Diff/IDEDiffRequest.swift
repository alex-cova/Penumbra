import Foundation
import GitIntelligence

/// Where one side of a diff comes from.
enum IDEDiffSource: Hashable, Sendable {
    /// A version git stores, by path relative to the repository root.
    case revision(GitRevision, relativePath: String)
    /// The file on disk (or its open editor's live text), by absolute path.
    case workingTree(path: String)
    /// Fixed text: the clipboard, or nothing for a file that is added or deleted.
    case text(String)
}

struct IDEDiffSide: Hashable, Sendable {
    var source: IDEDiffSource
    var title: String
}

/// What the diff viewer compares, and what its hunk buttons may do with it.
struct IDEDiffRequest: Hashable, Sendable, Identifiable {
    var left: IDEDiffSide
    var right: IDEDiffSide
    /// The file this is about (absolute), for its language, Jump to Source and the tab title.
    var filePath: String?
    /// Tab title.
    var title: String

    /// Opening the same comparison again selects its tab.
    var id: String { "\(left.source)|\(right.source)" }

    /// Hunk buttons that write to git's index rather than to the text.
    enum IndexAction: Sendable {
        /// Index ↔ working tree: a hunk can be staged.
        case stage
        /// HEAD ↔ index: a hunk can be unstaged.
        case unstage
    }

    var indexAction: IndexAction? {
        switch (left.source, right.source) {
        case (.revision(.index, _), .workingTree): .stage
        case (.revision(.head, _), .revision(.index, _)): .unstage
        default: nil
        }
    }

    /// The path git knows the file by, for a hunk patch.
    var repositoryRelativePath: String? {
        for source in [left.source, right.source] {
            if case .revision(_, let path) = source { return path }
        }
        return nil
    }

    /// Only the working tree can be edited (and reverted hunk by hunk).
    var isRightEditable: Bool {
        if case .workingTree = right.source { return true }
        return false
    }

    var workingTreePath: String? {
        if case .workingTree(let path) = right.source { return path }
        if case .workingTree(let path) = left.source { return path }
        return nil
    }

    private static func fileName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    // MARK: - Factories

    /// A changed file from the Changes list: unstaged changes compare the index with the working
    /// tree, staged ones HEAD with the index (as `git diff` and `git diff --cached` do).
    static func change(path: String, relativePath: String, staged: Bool, isNew: Bool) -> IDEDiffRequest {
        let name = fileName(path)
        if staged {
            let left = isNew
                ? IDEDiffSide(source: .text(""), title: "Not in HEAD")
                : IDEDiffSide(source: .revision(.head, relativePath: relativePath), title: "HEAD")
            return IDEDiffRequest(
                left: left,
                right: IDEDiffSide(source: .revision(.index, relativePath: relativePath), title: "Staged"),
                filePath: path,
                title: "\(name) (Staged)"
            )
        }
        let left = isNew
            ? IDEDiffSide(source: .text(""), title: "Untracked")
            : IDEDiffSide(source: .revision(.index, relativePath: relativePath), title: "Staged")
        return IDEDiffRequest(
            left: left,
            right: IDEDiffSide(source: .workingTree(path: path), title: "Your Version"),
            filePath: path,
            title: "\(name) (Changes)"
        )
    }

    /// One file of a commit against the commit's first parent.
    static func commitFile(hash: String, shortHash: String, path: String, oldPath: String?, repositoryRoot: String) -> IDEDiffRequest {
        let absolute = (repositoryRoot as NSString).appendingPathComponent(path)
        return IDEDiffRequest(
            left: IDEDiffSide(source: .revision(.parent(of: hash), relativePath: oldPath ?? path), title: "\(shortHash)^"),
            right: IDEDiffSide(source: .revision(.commit(hash), relativePath: path), title: shortHash),
            filePath: absolute,
            title: "\(fileName(path)) (\(shortHash))"
        )
    }

    /// The file on disk against a branch, a tag or HEAD.
    static func workingTree(path: String, relativePath: String, against revision: GitRevision, revisionTitle: String) -> IDEDiffRequest {
        IDEDiffRequest(
            left: IDEDiffSide(source: .revision(revision, relativePath: relativePath), title: revisionTitle),
            right: IDEDiffSide(source: .workingTree(path: path), title: "Your Version"),
            filePath: path,
            title: "\(fileName(path)) (\(revisionTitle))"
        )
    }

    /// The clipboard against the file (or an unsaved buffer's text, with no path).
    static func clipboard(_ clipboard: String, path: String?, text: String?, name: String) -> IDEDiffRequest {
        let right = path.map { IDEDiffSide(source: .workingTree(path: $0), title: "Your Version") }
            ?? IDEDiffSide(source: .text(text ?? ""), title: name)
        return IDEDiffRequest(
            left: IDEDiffSide(source: .text(clipboard), title: "Clipboard"),
            right: right,
            filePath: path,
            title: "\(name) (Clipboard)"
        )
    }
}
