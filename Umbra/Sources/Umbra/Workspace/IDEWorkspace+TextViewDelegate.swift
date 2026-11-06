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
        languageSettle.noteContentChange(change)
        guard hostedPaneIDs.count > 1 else { return }
        pendingMirrorChanges[ObjectIdentifier(textView), default: []].append(change)
    }

    public func textViewDidChange(_ textView: TextView) {
        languageSettle.schedule(for: textView, delay: settleDelay, settle: documentSettle, languages: languages)
        mirrorEdits(from: textView)
        if let pane = workbench.panes.first(where: { hostCache.peek($0.id)?.textView === textView }) {
            hostCache.peek(pane.id)?.noteJSONDiagramEdited()
            hostCache.peek(pane.id)?.noteCSVTableEdited()
        }
        scheduleSemanticHighlighting(forEditedTextView: textView)
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

    public func textView(
        _ textView: TextView,
        didChangeDistractionFreeChromeVisibility isVisible: Bool,
        transitionDuration: TimeInterval
    ) {
        IDEAppearance.Motion.animate(isVisible ? .spring(duration: transitionDuration, bounce: 0.1) : .easeOut(duration: transitionDuration)) {
            chromeOpacity = isVisible ? 1 : 0
        }
    }
}
