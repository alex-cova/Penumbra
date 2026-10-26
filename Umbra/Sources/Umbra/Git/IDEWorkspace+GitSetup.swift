import AppKit
import Foundation
import GitIntelligence

/// Starting a repository: Clone Repository…, Create Git Repository…, and adding files to an
/// ignore file.
extension IDEWorkspace {
    /// File ▸ Clone Repository…. The address is taken from the clipboard when it holds one.
    func promptClone() {
        gitStatus.registerAskPass(active: true)
        let model = IDEGitCloneModel(
            networkSession: gitStatus.askPassSession,
            clipboard: NSPasteboard.general.string(forType: .string))
        let windowID = windowID
        let sheets = gitStatus.sheets
        let request = IDEGitCloneRequest(model: model)
        model.onFinished = { destination in
            sheets.finish(IDEGitSheet.clone(request).id)
            IDEWindowRegistry.shared.open(urls: [destination], origin: .window(windowID))
        }
        sheets.present(.clone(request))
    }

    /// Git ▸ Create Git Repository…: `git init` in the project folder.
    func promptCreateRepository() {
        guard let root = project.rootURL, !gitStatus.isRepository else { return }
        gitStatus.sheets.present(.confirm(IDEGitConfirmation(
            title: "Create a Git Repository?",
            message: "\(root.lastPathComponent) has no version control yet. This runs git init in the folder, with main as the first branch.",
            confirmTitle: "Create",
            action: { [weak self] in
                Task { [weak self] in
                    do {
                        _ = try await GitRepository.initialize(at: root, runner: IDEGitSupport.runner)
                        self?.gitStatus.noteRefsChanged()
                        self?.gitStatus.refresh()
                        self?.gitStatus.succeed("\(root.lastPathComponent) is now a git repository")
                    } catch {
                        self?.gitStatus.fail(IDEGitSupport.describe(error))
                    }
                }
            }
        )))
    }

    enum IgnoreTarget {
        /// The `.gitignore` at the repository root.
        case root
        /// The nearest `.gitignore` above the file, else the root's.
        case nearest
        /// `.git/info/exclude`: ignored for you only, never committed.
        case localExclude
    }

    /// Writes patterns for `urls` (absolute) into an ignore file and refreshes status.
    func addToIgnoreFile(_ urls: [URL], target: IgnoreTarget) {
        guard let rootPath = gitStatus.repositoryRootPath, !urls.isEmpty else { return }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        var written: [String] = []
        var failure: String?
        for url in urls {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let file = ignoreFile(for: url, target: target, root: root)
            let base = file.deletingLastPathComponent().standardizedFileURL.path
            // `.git/info/exclude` patterns are relative to the work tree, like the root's.
            let anchor = target == .localExclude ? rootPath : base
            guard path.hasPrefix(anchor + "/") else { continue }
            let relative = String(path.dropFirst(anchor.count + 1))
            let pattern = GitIgnoreWriter.pattern(forRelativePath: relative, isDirectory: isDirectory)
            let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            guard let updated = GitIgnoreWriter.appending(pattern, to: existing) else { continue }
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try updated.write(to: file, atomically: true, encoding: .utf8)
                written.append(pattern)
            } catch {
                failure = error.localizedDescription
            }
        }
        if let failure {
            gitStatus.fail("Could not update the ignore file: \(failure)")
        } else if written.isEmpty {
            gitStatus.succeed("Already ignored: the ignore file has a line for this")
        } else {
            gitStatus.succeed(written.count == 1 ? "Ignored \(written[0])" : "Ignored \(written.count) paths")
        }
        gitStatus.refresh()
    }

    private func ignoreFile(for url: URL, target: IgnoreTarget, root: URL) -> URL {
        switch target {
        case .root:
            return root.appendingPathComponent(".gitignore")
        case .localExclude:
            return root.appendingPathComponent(".git/info/exclude")
        case .nearest:
            var directory = url.deletingLastPathComponent().standardizedFileURL
            while directory.path.hasPrefix(root.path), directory.path != root.deletingLastPathComponent().path {
                let candidate = directory.appendingPathComponent(".gitignore")
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
                if directory.path == root.path { break }
                directory = directory.deletingLastPathComponent()
            }
            return root.appendingPathComponent(".gitignore")
        }
    }
}
