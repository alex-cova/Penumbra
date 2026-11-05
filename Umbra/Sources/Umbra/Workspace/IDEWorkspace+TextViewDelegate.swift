import AppKit
import EditorIntelligence
import Penumbra
import SwiftUI

extension IDEWorkspace: TextViewDelegate {
    public func textViewDidChangeSelection(_ textView: TextView) {
        updateStatus(from: textView)
        noteStructureCaretMoved(in: textView)
    }

    public func textView(_ textView: TextView, didChangeContent change: TextContentChange) {
        noteJavaAutoImportPaste(change)
        guard hostedPaneIDs.count > 1 else { return }
        pendingMirrorChanges[ObjectIdentifier(textView), default: []].append(change)
    }

    public func textViewDidChange(_ textView: TextView) {
        scheduleJavaAutoImport(for: textView)
        mirrorEdits(from: textView)
        if let pane = workbench.panes.first(where: { hostCache.peek($0.id)?.textView === textView }) {
            hostCache.peek(pane.id)?.noteJSONDiagramEdited()
            hostCache.peek(pane.id)?.noteCSVTableEdited()
        }
        scheduleSemanticHighlighting(forEditedTextView: textView)
        scheduleNameIndexOverlay(for: textView)
        noteCoverageEdit(in: textView)
        refreshJavaRunAvailability(from: textView)
        noteStructureEdited()
        recordRecentlyEdited()
        // The tab dot and window chrome do not change on the second character. Rebuilding every
        // tab row here re-renders the SwiftUI shell, which lays the editor out again.
        noteActiveDocumentEdited()
        autosave.noteEdit()
        changeMarkers.refresh(textView: textView, url: textView.documentURL, git: gitStatus)
    }

    /// A multi-character replacement that equals the pasteboard is a paste. One character never
    /// reads the pasteboard. The planner runs later, from ``textViewDidChange(_:)``.
    private func noteJavaAutoImportPaste(_ change: TextContentChange) {
        guard change.replacementText.utf16.count > 1,
              change.replacementText == NSPasteboard.general.string(forType: .string) else { return }
        javaAutoImportPaste = change.replacementText
    }

    /// After a pause, import the one class that resolves a name in this Java buffer. The keystroke
    /// itself only cancels the previous pause. Parsing and `textView.text` happen once it has elapsed.
    private func scheduleJavaAutoImport(for textView: TextView) {
        if javaAutoImportApplying {
            javaAutoImportPaste = nil
            return
        }
        let paste = javaAutoImportPaste
        javaAutoImportPaste = nil
        guard textView.languageIdentifier == "java" else { return }
        let policy = preferences.javaImportPolicy
        let pasting = paste != nil && policy.insertImportsOnPaste == .always
        guard policy.addUnambiguousImportsOnTheFly || pasting else { return }
        let delay = preferences.autoreparseDelayMilliseconds
        let documentID = textView.documentIdentifier
        let url = textView.documentURL
        javaAutoImport.schedule(after: .milliseconds(delay)) { [weak self, weak textView] in
            guard let self, let textView else { return }
            guard textView.languageIdentifier == "java",
                  textView.documentIdentifier == documentID,
                  textView.documentURL == url else { return }
            let caret = textView.selectedRange.location
            guard let snapshot = await textView.snapshotText() else { return }
            let text = snapshot.text
            let edits: [TextEdit]
            if pasting, let paste {
                edits = await self.javaSupport.importEdits(forPastedText: paste, in: text, file: url, policy: policy)
            } else {
                edits = await self.javaSupport.importEdits(
                    in: text, caretUTF16: caret, file: url, policy: policy
                )
            }
            guard !Task.isCancelled, textView.contentGeneration == snapshot.generation,
                  textView.documentURL == url, !edits.isEmpty else { return }
            self.javaAutoImportApplying = true
            TextEditApplicator.apply(edits, in: textView)
            self.javaAutoImportApplying = false
        }
    }

    public func textView(
        _ textView: TextView,
        didChangeDistractionFreeChromeVisibility isVisible: Bool,
        transitionDuration: TimeInterval
    ) {
        withAnimation(isVisible ? .spring(duration: transitionDuration, bounce: 0.1) : .easeOut(duration: transitionDuration)) {
            chromeOpacity = isVisible ? 1 : 0
        }
    }
}
