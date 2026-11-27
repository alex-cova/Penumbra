import AppKit
import EditorIntelligence
import Foundation
import Penumbra

/// Show History for Method / Class: `git log -L` over the lines of the declaration around the caret.
extension IDEWorkspace {
    func showDeclarationHistory(_ kind: IDEDeclarationHistory.Kind) {
        let pane = workbench.activePane
        guard let document = pane.selectedDocument, document.contentKind == .text,
              let url = document.url?.standardizedFileURL,
              gitStatus.repositoryRelativePath(for: url.path) != nil else {
            showGitNotice("No \(kind.noun.capitalized) History", "The active file is not in a git repository.")
            return
        }
        let textView = host(for: pane.id).textView
        let caret = textView.selectedRange.location
        // The provider the Structure tab uses, so the declaration is the one it shows.
        let (provider, editorDocument) = structureOutlineSource()
        Task { [weak self, weak textView] in
            guard let snapshot = await textView?.materializedText(priority: .userInitiated) else { return }
            let text = snapshot.text
            let roots = await runDetached(priority: .userInitiated) { () -> [StructureNode]? in
                await provider.allStructure(forSource: text, document: editorDocument)
            }
            guard let self, let textView, textView.contentGeneration == snapshot.generation else { return }
            guard let node = IDEDeclarationHistory.declaration(in: roots ?? [], containing: caret, kind: kind) else {
                self.showGitNotice(kind.missingTitle, "Put the caret inside the \(kind.noun) whose history you want.")
                return
            }
            let first = textView.textLocation(at: node.bodyRange.lowerBound)?.lineNumber ?? 0
            let lastOffset = max(node.bodyRange.lowerBound, node.bodyRange.upperBound - 1)
            let last = textView.textLocation(at: lastOffset)?.lineNumber ?? first
            self.gitStatus.showLineHistory(
                path: url.path, startLine: first + 1, endLine: max(first, last) + 1,
                title: IDEDeclarationHistory.title(of: node, kind: kind))
            self.showBottomTab(.sourceControl)
        }
    }
}
