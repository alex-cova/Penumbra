import AppKit
import EditorIntelligence
import Penumbra

/// Where a file's edits go.
enum IDEWorkspaceEditTarget {
    /// The file is open in an editor: edit its buffer (one undo group, left dirty).
    case live(TextView)
    /// The file isn't open: write it on disk.
    case closed
    /// The file is open but its buffer can't be reached; editing the disk copy would desync it.
    case unavailable(String)
}

/// What the applier needs from the workspace.
@MainActor
protocol IDEWorkspaceEditHost: AnyObject {
    var editProjectRoot: URL? { get }
    func editTarget(for url: URL) async -> IDEWorkspaceEditTarget
    /// Renames a file within its folder and retargets open tabs, like the Explorer's rename.
    func renameFile(from: URL, to: URL) throws
    /// Moves a file to another folder (and retargets open tabs).
    func moveFile(from: URL, to: URL) throws
    /// Moves a file to the Trash and closes any open editors on it.
    func deleteFile(at: URL) throws
}

/// Applies a ``WorkspaceEdit``: files with a live editor go through `TextEditApplicator`, the
/// rest are rewritten on disk (atomically, only inside the project folder), then file renames run.
/// Validation happens first, so a malformed edit changes nothing.
@MainActor
struct IDEWorkspaceEditApplier {
    enum Failure: LocalizedError {
        case outsideProject
        case notUTF8
        case noProject
        case invalidEdit(String)
        case moveNotSupported
        case deleteFailed(String)

        var errorDescription: String? {
            switch self {
            case .outsideProject: return "The file is outside the project folder."
            case .notUTF8: return "The file isn't UTF-8 text."
            case .noProject: return "Open a project folder to edit files that aren't open."
            case .invalidEdit(let detail): return "The rename is inconsistent: \(detail)"
            case .moveNotSupported: return "Moving a file to another folder isn't supported."
            case .deleteFailed(let detail): return detail
            }
        }
    }

    unowned let host: IDEWorkspaceEditHost

    func apply(_ edit: WorkspaceEdit) async -> WorkspaceEditApplyResult {
        var result = WorkspaceEditApplyResult()
        let issues = edit.validate()
        if !issues.isEmpty {
            for issue in issues {
                switch issue {
                case .overlappingEdits(let url, _, _), .invalidRange(let url, _):
                    result.failures[url] = Failure.invalidEdit("overlapping or inverted edits").localizedDescription
                case .duplicateFileRenameSource(let url), .duplicateFileRenameTarget(let url):
                    result.failures[url] = Failure.invalidEdit("conflicting file renames").localizedDescription
                case .duplicateFileDeletion(let url):
                    result.failures[url] = Failure.invalidEdit("conflicting file deletions").localizedDescription
                }
            }
            return result
        }

        for url in edit.affectedURLs {
            let edits = edit.orderedEdits(for: url)
            do {
                switch await host.editTarget(for: url) {
                case .live(let textView):
                    TextEditApplicator.apply(edits, in: textView)
                case .closed:
                    try applyOnDisk(edits, to: url)
                case .unavailable(let reason):
                    result.failures[url] = reason
                    continue
                }
                result.appliedFiles.append(url)
            } catch {
                result.failures[url] = error.localizedDescription
            }
        }

        for rename in edit.fileRenames {
            // A file whose edits failed is left where it is.
            guard result.failures[rename.from] == nil else { continue }
            do {
                let sameFolder = rename.from.deletingLastPathComponent().standardizedFileURL
                    == rename.to.deletingLastPathComponent().standardizedFileURL
                if sameFolder {
                    try host.renameFile(from: rename.from, to: rename.to)
                } else {
                    try host.moveFile(from: rename.from, to: rename.to)
                }
                result.renamedFiles.append(rename)
            } catch {
                result.failures[rename.from] = error.localizedDescription
            }
        }

        for url in edit.fileDeletions {
            guard result.failures[url] == nil else { continue }
            do {
                try host.deleteFile(at: url)
                result.deletedFiles.append(url)
            } catch {
                result.failures[url] = error.localizedDescription
            }
        }
        return result
    }

    /// Rewrites `url` with `edits` (already ordered end-to-start; positions address the file's
    /// current text). The write is atomic and only allowed inside the project folder, the
    /// location the user granted access to.
    private func applyOnDisk(_ edits: [TextEdit], to url: URL) throws {
        guard let root = host.editProjectRoot else { throw Failure.noProject }
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { throw Failure.outsideProject }

        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { throw Failure.notUTF8 }
        let updated = try WorkspaceEdit.apply(edits, to: text)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        try Data(updated.utf8).write(to: url, options: .atomic)
        if let permissions = attributes?[.posixPermissions] {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
    }
}
