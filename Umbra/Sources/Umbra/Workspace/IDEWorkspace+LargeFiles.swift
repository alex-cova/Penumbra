import Foundation
import Penumbra

/// Large-file safe mode (F25). `LargeFilePolicy.standard` decides by size: above 50 MB a file opens
/// as plain text (no tree-sitter highlighting, folding, language services or semantic colours), above
/// 500 MB it is also read-only. The banner (`IDELargeFileBanner`) names what is off and offers Enable
/// Anyway, which reloads the file with full service for the rest of the session.
extension IDEWorkspace {
    func largeFilePolicy(for url: URL) -> LargeFilePolicy {
        liftedLargeFilePaths.contains(url.standardizedFileURL.path) ? .disabled : largeFileBasePolicy
    }

    /// Enable Anyway: reload `document` under `.disabled`. Unsaved edits would be dropped by the
    /// reload, so the banner offers this only for a clean tab.
    func enableLargeFileFeatures(for document: WorkbenchDocument) {
        guard document.largeFileNotice != nil, !document.isDirty, let url = document.url else { return }
        let path = url.standardizedFileURL.path
        liftedLargeFilePaths.insert(path)
        Task {
            do {
                try await reloadDocumentFromDisk(document)
                guard !isTornDown else { return }
                // The index and the language services only learn of a document through the bridge.
                await workspaceBridge.syncWorkbench(workbench)
            } catch {
                liftedLargeFilePaths.remove(path)
                presentError(error)
            }
        }
    }

    /// Source files an index walk left out for being over its size limit: one notice per set.
    func noteOversizedSourceFiles(_ urls: [URL], language: String) {
        let key = language + ":" + urls.map(\.path).sorted().joined(separator: "\n")
        guard postedOversizedNotices.insert(key).inserted else { return }
        let limit = ByteCountFormatter.string(fromByteCount: 1_048_576, countStyle: .file)
        let names = urls.map(\.lastPathComponent).sorted().prefix(3).joined(separator: ", ")
        let more = urls.count > 3 ? " and \(urls.count - 3) more" : ""
        notifications.post(
            "\(urls.count) \(language) file\(urls.count == 1 ? "" : "s") over \(limit) not indexed",
            detail: "\(names)\(more). They open normally, but go to definition, usages and completion do not see them.",
            category: .general,
            severity: .info
        )
    }
}
