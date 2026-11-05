import AppKit
import EditorIntelligence
import Penumbra

/// What a language does once typing pauses, owned apart from the window.
///
/// The text view delegate used to name Java: an auto-import pass and a name-index overlay, each
/// with its own timer. A keystroke now only tells this object. It remembers a paste, registers one
/// consumer on ``DocumentSettleCoordinator``, and asks ``LanguageService/bufferDidSettle(_:)`` for
/// the active language. A language with nothing to do returns no edits. Applying those edits does
/// not propose another round.
@MainActor
final class IDELanguageSettle {
    /// The replacement of the edit about to be reported, when it is a multi-character paste.
    private var pastedText: String?
    /// True while settle edits are being applied, so that change does not propose more edits.
    private var applyingEdits = false

    /// A multi-character replacement that equals the pasteboard is a paste. One character never
    /// reads the pasteboard. The settle runs later, from ``schedule(for:delay:settle:languages:)``.
    func noteContentChange(_ change: TextContentChange) {
        guard !applyingEdits,
              change.replacementText.utf16.count > 1,
              change.replacementText == NSPasteboard.general.string(forType: .string) else { return }
        pastedText = change.replacementText
    }

    /// Register the active language's settle work. `proposesEdits` is false when the buffer was
    /// shown rather than edited (opening a file still refreshes overlays).
    func schedule(
        for textView: TextView,
        delay: Duration,
        settle: DocumentSettleCoordinator,
        languages: LanguageServiceRegistry,
        proposesEdits: Bool = true
    ) {
        let paste = pastedText
        pastedText = nil
        let suppressEdits = applyingEdits || !proposesEdits
        let language = textView.languageIdentifier
        let documentID = textView.documentIdentifier
        let url = textView.documentURL
        settle.schedule(textView: textView, id: "language", phase: .language, after: delay) { [weak self] textView, snapshot in
            guard let self else { return }
            guard textView.languageIdentifier == language,
                  textView.documentIdentifier == documentID,
                  textView.documentURL == url,
                  textView.contentGeneration == snapshot.generation else { return }
            let request = BufferSettleRequest(
                text: snapshot.text,
                url: url,
                caretUTF16: snapshot.caretUTF16,
                pastedText: paste,
                suppressEdits: suppressEdits
            )
            let edits = await languages.bufferDidSettle(request, language: language)
            guard !Task.isCancelled, !edits.isEmpty,
                  textView.contentGeneration == snapshot.generation,
                  textView.documentURL == url else { return }
            self.applyingEdits = true
            TextEditApplicator.apply(edits, in: textView)
            self.applyingEdits = false
        }
    }
}
