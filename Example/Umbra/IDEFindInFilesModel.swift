import EditorIntelligence
import Foundation
import Observation

/// What the Find and Replace in Files drawer shows and asks: the query and its toggles, the file mask
/// and scope, the hits and the status line. Session-only, one per window. Running a search or a
/// replacement needs the window's editors and project, so those are in `IDEWorkspace+FindInFiles.swift`.
@MainActor
@Observable
final class IDEFindInFilesModel {
    var isVisible = false
    var query = ""
    var replacement = ""
    var isCaseSensitive = false
    var matchesWholeWord = false
    var usesRegex = false
    /// File mask (`*.java, !*Test.java`) and scope; session-only, like the toggles.
    var mask = ""
    var scope = IDEFindInFilesScope.project
    /// Whether the drawer shows its replacement row (⇧⌘R opens it that way).
    var isReplaceVisible = false
    var hits: [ProjectSearchResult] = []
    var status = ""

    /// The query the drawer's field and option toggles describe.
    var searchQuery: WorkspaceSearchQuery {
        WorkspaceSearchQuery(
            text: query,
            isCaseSensitive: isCaseSensitive,
            matchWholeWord: matchesWholeWord,
            useRegularExpression: usesRegex
        )
    }

    /// Why the mask cannot be used, or nil when it is fine.
    var maskProblem: String? {
        let invalid = FileMask(mask).invalidPatterns
        return invalid.isEmpty ? nil : "Invalid file mask: \(invalid.joined(separator: ", "))"
    }

    /// What the mask and scope describe, for both Find and Replace so they see the same files.
    /// `openFilePaths` and `changedFilePaths` are the window's open editors and git changes, which the
    /// two file-list scopes narrow to.
    func filter(openFilePaths: Set<String>, changedFilePaths: [String]) -> ProjectSearchFilter {
        let mask = FileMask(mask)
        switch scope {
        case .project:
            return ProjectSearchFilter(mask: mask)
        case .directory(let url):
            return ProjectSearchFilter(mask: mask, directory: url)
        case .openFiles:
            return ProjectSearchFilter(mask: mask, onlyFiles: Set(openFilePaths.map { URL(fileURLWithPath: $0) }))
        case .changedFiles:
            return ProjectSearchFilter(mask: mask, onlyFiles: Set(changedFilePaths.map { URL(fileURLWithPath: $0) }))
        }
    }

    func scopeDescription(for filter: ProjectSearchFilter) -> String {
        var parts: [String] = []
        if !filter.mask.isEmpty { parts.append("files matching \(filter.mask.text.trimmingCharacters(in: .whitespaces))") }
        switch scope {
        case .project: break
        case .directory(let url): parts.append("the folder \(url.lastPathComponent)")
        case .openFiles: parts.append("open files")
        case .changedFiles: parts.append("files changed in git")
        }
        return parts.joined(separator: " in ")
    }

    /// A scope folder that is no longer inside the project (another folder was opened) falls back to the project.
    func resetStaleScope(root: URL) {
        guard case .directory(let url) = scope else { return }
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        if path != rootPath, !path.hasPrefix(rootPath + "/") { scope = .project }
    }

    /// Shows the drawer, with a hint in the status line the first time.
    func show(hasProject: Bool) {
        isVisible = true
        if status.isEmpty {
            status = hasProject ? "Enter a query and press Return" : "Open a folder to search the project"
        }
    }

    func setResults(_ results: [ProjectSearchResult]) {
        hits = results
        switch results.count {
        case 0: status = "No results"
        case 1: status = "1 result"
        default: status = "\(results.count) results"
        }
    }

    /// Clears the hits and says why there is nothing to show.
    func fail(_ message: String) {
        hits = []
        status = message
    }
}
