import AppKit
import Foundation
import Penumbra

/// What the change stripe's marks offer, from the caret: put the change back to `HEAD`, or keep its
/// current text on the clipboard first.
extension IDEWorkspace {
    /// Rolls the change under the caret back to the last committed text (one undo step).
    func rollbackChangeAtCaret() {
        let pane = workbench.activePane
        guard let document = pane.selectedDocument, document.contentKind == .text, let url = document.url,
              let relative = gitStatus.repositoryRelativePath(for: url.standardizedFileURL.path) else {
            showGitNotice("No Change", "The active file is not in a git repository.")
            return
        }
        let textView = host(for: pane.id).textView
        let status = gitStatus
        Task { [weak self, weak textView] in
            let head = await status.headContents(relativePath: relative)
            guard let self, let textView else { return }
            guard head.found else { return }
            // Read after the await: the buffer may have changed while git answered.
            let buffer = textView.text
            let caret = textView.textLocation(at: textView.selectedRange.location)?.lineNumber ?? 0
            guard let edit = IDEChangeMarkerPresentation.rollback(head: head.data, buffer: buffer, caretLine: caret) else {
                self.showGitNotice("No Change Here", "The caret is not in a changed block, or the file has no committed version.")
                return
            }
            textView.replace(edit.range, withText: edit.replacement)
        }
    }
}
