@preconcurrency import AppKit
import EditorIntelligence
import Foundation

/// Owns inlay-hint state and refresh for one ``EditorIntelligenceController``.
///
/// Hints render through `TextView.inlayHints`; this controller decides when to ask the provider
/// and remembers which viewport range the last request covered. Extracted from
/// `EditorIntelligenceController` so the feature has one home; the controller keeps thin
/// forwarding API (`refreshInlayHints()`, `inlayHintsEnabled`) that hosts already call.
@MainActor
final class InlayHintController {
    /// Whether hints are shown. Off clears them; hosts flip it from a preference.
    var isEnabled = true {
        didSet {
            if isEnabled != oldValue { refresh() }
        }
    }

    private let provider: (any InlayHintProviding)?
    private weak var textView: TextView?
    /// Snapshot for the caret's document, read when a debounced refresh fires — not when it is
    /// scheduled — so typing during the delay still resolves the fresh document. Wired by the
    /// owning controller after init (mirroring `InlineCompletionController.engine`).
    var makeDocument: @MainActor () -> Document? = { nil }
    private var task: Task<Void, Never>?
    /// Vertical range of content the last hint request covered.
    private var requestedYRange: ClosedRange<CGFloat>?

    init(textView: TextView?, provider: (any InlayHintProviding)?) {
        self.textView = textView
        self.provider = provider
    }

    /// Asks the inlay hint provider for the hints around what is on screen (a viewport above and
    /// below included) and shows them, after a short pause so typing does not resolve every call.
    /// Scrolling out of the requested range asks again (see ``refreshIfViewportLeftRange()``).
    func refresh(delay: TimeInterval = 0.25) {
        task?.cancel()
        guard let textView else { return }
        guard isEnabled, let provider else {
            requestedYRange = nil
            if !textView.inlayHints.isEmpty { textView.inlayHints = [] }
            return
        }
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            let request: (Document, EditorIntelligence.TextRange, UInt64)? = await MainActor.run {
                guard let self, let textView = self.textView, let document = self.makeDocument() else { return nil }
                let generation = textView.contentGeneration
                let length = textView.documentLength
                let height = textView.bounds.height
                let top = textView.characterIndex(at: CGPoint(x: 0, y: -height)) ?? 0
                let bottom = textView.characterIndex(at: CGPoint(x: textView.bounds.width, y: height * 2)) ?? length
                let start = min(max(0, top), length)
                let end = min(max(start, bottom), length)
                // Line and column come from the line index, not from scanning the text.
                @MainActor
                func position(_ offset: Int) -> TextPosition {
                    let location = textView.textLocation(at: offset)
                    return TextPosition(line: location?.lineNumber ?? 0, column: location?.column ?? offset, utf16Offset: offset)
                }
                let offsetY = textView.contentOffset.y
                self.requestedYRange = (offsetY - height)...(offsetY + height * 2)
                return (document, EditorIntelligence.TextRange(start: position(start), end: position(end)), generation)
            }
            guard let (document, range, generation) = request else { return }
            let hints = await provider.inlayHints(for: document, in: range)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, let textView = self.textView, textView.contentGeneration == generation else { return }
                textView.inlayHints = hints
            }
        }
    }

    /// Hints are requested for the viewport plus a screen above and below. Scrolling past that asks
    /// again, once scrolling pauses, so hints appear in the part of the file that scrolled into view.
    func refreshIfViewportLeftRange() {
        guard isEnabled, provider != nil, let textView else { return }
        let top = textView.contentOffset.y
        let bottom = top + textView.bounds.height
        if let range = requestedYRange, range.contains(top), range.contains(bottom) {
            return
        }
        refresh(delay: 0.15)
    }

    deinit {
        task?.cancel()
    }
}
