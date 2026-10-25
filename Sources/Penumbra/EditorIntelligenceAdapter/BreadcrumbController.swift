@preconcurrency import AppKit
import EditorIntelligence
import Foundation

/// Owns the breadcrumb refresh pipeline for one ``EditorIntelligenceController``.
///
/// After typing pauses, snapshots the on-screen buffer (reusing the text while its content
/// generation is unchanged), asks the language provider for segments — falling back to the
/// symbol index — and publishes the capped trail. Extracted from `EditorIntelligenceController`
/// so the feature has one home; the bar view and host callback stay with the controller, which
/// receives segments through ``publish``.
@MainActor
final class BreadcrumbController {
    /// Called with the refreshed trail. The controller updates the bar and notifies the host.
    var publish: ([BreadcrumbSegment]) -> Void = { _ in }

    private weak var textView: TextView?
    private let adapter: (any EditorAdapter)?
    private let symbolIndex: SymbolIndex?
    private let provider: (any BreadcrumbProviding)?
    private var task: Task<Void, Never>?
    /// Buffer text exported for one content generation, so consecutive passes over an unchanged
    /// buffer do not copy the piece tree again.
    private var source: (generation: UInt64, text: String)?

    init(
        textView: TextView?,
        adapter: (any EditorAdapter)?,
        symbolIndex: SymbolIndex?,
        provider: (any BreadcrumbProviding)?
    ) {
        self.textView = textView
        self.adapter = adapter
        self.symbolIndex = symbolIndex
        self.provider = provider
    }

    /// Refresh breadcrumb segments for the current cursor.
    func refresh() {
        guard textView?.languageConfiguration.showsBreadcrumbs ?? true else {
            publish([])
            return
        }
        guard symbolIndex != nil || provider != nil else {
            publish([])
            return
        }
        // `liveDocument()` used to copy the whole file here, on the caret, and Java then parsed
        // that copy. The outline only needs to catch up after typing pauses.
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled, let self else { return }
            guard let document = await self.breadcrumbDocument() else { return }
            var segments = await self.provider?.breadcrumbs(for: document)
            if segments == nil, let symbolIndex = self.symbolIndex {
                let symbols = await symbolIndex.symbols(in: document.id)
                let cursorOffset = document.cursor.position.utf16Offset
                let locations = BreadcrumbProvider.breadcrumbLocations(from: symbols, cursorOffset: cursorOffset)
                segments = locations.map { BreadcrumbSegment(title: $0.displayName, range: $0.range) }
            }
            guard !Task.isCancelled else { return }
            self.publish(BreadcrumbBarModel.capped(segments ?? []))
        }
    }

    /// The on-screen buffer for a breadcrumb pass. A piece-tree file is copied off the main actor.
    private func breadcrumbDocument() async -> Document? {
        guard let textView, let base = adapter?.currentDocument else { return nil }
        let generation = textView.contentGeneration
        let caret = textView.selectedRange.location
        let location = textView.textLocation(at: caret)
        let position = TextPosition(
            line: location?.lineNumber ?? 0,
            column: location?.column ?? caret,
            utf16Offset: caret
        )
        let text: String
        if let cached = source, cached.generation == generation {
            text = cached.text
        } else if textView.pieceTreeContentSnapshot() != nil {
            let export = textView.exportDocumentText()
            text = await Task.detached(priority: .utility) {
                export.materializeUTF16Text()
            }.value
            guard !Task.isCancelled, textView.contentGeneration == generation else { return nil }
            source = (generation, text)
        } else {
            text = textView.text
            source = (generation, text)
        }
        return Document(
            id: base.id,
            url: textView.documentURL ?? base.url,
            displayName: base.displayName,
            contentSnapshot: TextSnapshot(version: base.version, text: text),
            selection: Selection(range: EditorIntelligence.TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: base.viewport,
            languageIdentifier: base.languageIdentifier ?? textView.languageIdentifier
        )
    }

    deinit {
        task?.cancel()
    }
}
