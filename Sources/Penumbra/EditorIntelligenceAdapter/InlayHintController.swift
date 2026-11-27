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

    private nonisolated static let maximumHints = 512
    private nonisolated static let maximumLabelLength = 512

    private let provider: (any InlayHintProviding)?
    private weak var textView: TextView?
    /// Snapshot for the caret's document, read when a debounced refresh fires — not when it is
    /// scheduled — so typing during the delay still resolves the fresh document. Wired by the
    /// owning controller after init (mirroring `InlineCompletionController.engine`).
    var makeDocument: @MainActor () async -> Document? = { nil }
    private var task: Task<Void, Never>?
    private var publishedGeneration: UInt64?
    private var publishedBuffer: ObjectIdentifier?
    /// Vertical range of content the last hint request covered.
    private var requestedYRange: ClosedRange<CGFloat>?

    init(textView: TextView?, provider: (any InlayHintProviding)?) {
        self.textView = textView
        self.provider = provider
    }

    /// Asks the inlay hint provider for the hints around what is on screen (a viewport above and
    /// below included) and shows them, after a short pause so typing does not resolve every call.
    /// Scrolling out of the requested range asks again (see ``refreshIfViewportLeftRange()``).
    func refresh(delay: TimeInterval = 0.08) {
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
            let request: (EditorIntelligence.TextRange, UInt64, ObjectIdentifier)? = {
                guard let textView = self?.textView else { return nil }
                let generation = textView.contentGeneration
                let height = textView.bounds.height
                guard height > 0,
                      let range = textView.inlayRequestRange(overscan: height) else { return nil }
                let start = range.lowerBound
                let end = range.upperBound
                // Line and column come from the line index, not from scanning the text.
                @MainActor
                func position(_ offset: Int) -> TextPosition {
                    let location = textView.textLocation(at: offset)
                    return TextPosition(line: location?.lineNumber ?? 0, column: location?.column ?? offset, utf16Offset: offset)
                }
                let offsetY = textView.contentOffset.y
                self?.requestedYRange = (offsetY - height)...(offsetY + height * 2)
                return (EditorIntelligence.TextRange(start: position(start), end: position(end)), generation, textView.stringViewObjectIdentifier)
            }()
            guard let (range, generation, bufferIdentity) = request,
                  let document = await self?.makeDocument(),
                  !Task.isCancelled else { return }
            let provided = await provider.inlayHints(for: document, in: range)
            guard !Task.isCancelled else { return }
            let hints = Self.validated(provided, in: range)
            await MainActor.run {
                guard let self, let textView = self.textView, textView.contentGeneration == generation,
                      textView.stringViewObjectIdentifier == bufferIdentity else { return }
                self.publishedGeneration = generation
                self.publishedBuffer = bufferIdentity
                textView.inlayHints = hints.filter { textView.isCharacterBoundary(at: $0.utf16Offset) }
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


    func accept(_ hint: InlayHint) -> Bool {
        guard !hint.edits.isEmpty, let textView, textView.isEditable,
              textView.inlayHints.contains(hint), publishedGeneration == textView.contentGeneration,
              publishedBuffer == textView.stringViewObjectIdentifier,
              hint.edits.allSatisfy({ edit in
                  edit.range.start.utf16Offset <= edit.range.end.utf16Offset
                      && textView.isCharacterBoundary(at: edit.range.start.utf16Offset)
                      && textView.isCharacterBoundary(at: edit.range.end.utf16Offset)
              }) else { return false }
        let replacements = hint.edits.map { edit in
            (range: NSRange(
                location: edit.range.start.utf16Offset,
                length: edit.range.end.utf16Offset - edit.range.start.utf16Offset
            ), text: edit.replacement)
        }.sorted { $0.range.location < $1.range.location }
        guard zip(replacements, replacements.dropFirst()).allSatisfy({ first, next in
            first.range.location < next.range.location && first.range.upperBound <= next.range.location
        }) else { return false }
        TextEditApplicator.apply(replacements: replacements, in: textView)
        return true
    }

    func tooltip(for hint: InlayHint) async -> String? {
        if let tooltip = hint.tooltip { return tooltip }
        guard let provider, let textView, textView.inlayHints.contains(hint),
              publishedGeneration == textView.contentGeneration,
              publishedBuffer == textView.stringViewObjectIdentifier else { return nil }
        let buffer = textView.stringViewObjectIdentifier
        let generation = textView.contentGeneration
        guard let document = await makeDocument() else { return nil }
        let tooltip = await provider.resolveInlayTooltip(for: hint, in: document)
        guard textView.stringViewObjectIdentifier == buffer, textView.contentGeneration == generation,
              textView.inlayHints.contains(hint) else { return nil }
        return tooltip
    }

    nonisolated static func validated(_ hints: [InlayHint], in range: EditorIntelligence.TextRange) -> [InlayHint] {
        var seen: Set<InlayHint> = []
        var result: [InlayHint] = []
        for hint in hints.prefix(maximumHints * 4) {
            guard hint.utf16Offset >= range.start.utf16Offset,
                  hint.utf16Offset <= range.end.utf16Offset,
                  hint.kind != .inlineCompletion,
                  !hint.label.isEmpty, hint.label.utf16.count <= maximumLabelLength,
                  hint.label.rangeOfCharacter(from: .newlines) == nil,
                  seen.insert(hint).inserted else { continue }
            result.append(hint)
            if result.count == maximumHints { break }
        }
        return result
    }

    deinit {
        task?.cancel()
    }
}
