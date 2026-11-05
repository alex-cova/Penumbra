import EditorIntelligence
import Foundation
import Penumbra

/// What the window paints over an editor after the text has settled: semantic colours, the gutter's
/// line markers, and the name index's view of an open Java buffer. They register on
/// ``settle`` and share its one pause and one copy of the text. A result for text that has
/// changed since is dropped, so none of it blocks typing or paints stale offsets.
///
/// It is given the providers and the user's choices on every call and reaches nothing else of the
/// window; what a marker click does is the caller's.
@MainActor
final class IDEEditorOverlayController {
    private static let semanticID = "semantic"
    private static let markerID = "markers"
    private static let nameIndexID = "nameIndex"

    let settle: DocumentSettleCoordinator
    /// The markers last painted for an editor and the text generation they were computed for.
    private var shownMarkers: [ObjectIdentifier: (generation: UInt64, markers: [LineMarker])] = [:]

    init(settle: DocumentSettleCoordinator = DocumentSettleCoordinator()) {
        self.settle = settle
    }

    func cancelAll() {
        settle.cancelAll()
        shownMarkers.removeAll()
    }

    // MARK: Semantic highlighting

    /// Recolours the editor once typing pauses. With no provider (a language without semantic tokens,
    /// or the setting off) the semantic colours are cleared. `delay` debounces typing; opening a file
    /// or switching to one passes zero so the colours land with the first frames.
    func scheduleSemanticHighlighting(
        for textView: TextView, provider: (any SemanticTokenProviding)?, delay: Duration
    ) {
        guard let provider else {
            settle.cancel(Self.semanticID, for: textView)
            textView.setSemanticHighlights([])
            return
        }
        settle.schedule(textView: textView, id: Self.semanticID, phase: .visible, after: delay) { textView, snapshot in
            let highlights = await runDetached(priority: .utility) { () -> [SemanticHighlight]? in
                guard !Task.isCancelled else { return nil }
                return await provider.semanticHighlights(forSource: snapshot.text)
            }
            guard !Task.isCancelled, let highlights, textView.contentGeneration == snapshot.generation else { return }
            textView.setSemanticHighlights(highlights.map {
                SyntaxHighlightRange(range: NSRange(location: $0.range.lowerBound, length: $0.range.count), highlightName: $0.highlightName)
            })
        }
    }

    // MARK: Gutter line markers

    /// Slots the line-marker column keeps for a language. Java reserves the most markers can take;
    /// an `.http` file reserves one for its send buttons, so the text does not move when the first
    /// request is detected (the buttons arrive a debounce after the file opens).
    static func reservedLineMarkerSlots(languageIdentifier: String?, hasMarkerProvider: Bool) -> Int {
        if hasMarkerProvider { return TextView.maximumLineMarkerSlots }
        return languageIdentifier == "http" ? 1 : 0
    }

    /// Refreshes the gutter icons once typing pauses. The column is reserved from the first layout so
    /// the text stays put while the icons arrive; run buttons share it, so it is kept even with every
    /// marker kind turned off. `onClick` receives the marker for a click on fresh markers only.
    func scheduleLineMarkers(
        for textView: TextView, provider: (any LineMarkerProviding)?, kinds: Set<LineMarkerKind>,
        languageIdentifier: String?, delay: Duration, onClick: @escaping (LineMarker) -> Void
    ) {
        let key = ObjectIdentifier(textView)
        textView.reservedLineMarkerSlots = Self.reservedLineMarkerSlots(
            languageIdentifier: languageIdentifier, hasMarkerProvider: provider != nil)
        guard let provider, !kinds.isEmpty else {
            settle.cancel(Self.markerID, for: textView)
            shownMarkers[key] = nil
            textView.setLineMarkers([])
            textView.lineMarkerHandler = nil
            return
        }
        let url = textView.documentURL
        settle.schedule(textView: textView, id: Self.markerID, phase: .visible, after: delay) { [weak self] textView, snapshot in
            let markers = await runDetached(priority: .utility) { () -> [LineMarker]? in
                guard !Task.isCancelled else { return nil }
                return await provider.lineMarkers(source: snapshot.text, fileURL: url, kinds: kinds)
            }
            guard !Task.isCancelled, let self, let markers, textView.contentGeneration == snapshot.generation else { return }
            self.shownMarkers[key] = (snapshot.generation, markers)
            textView.setLineMarkers(markers.enumerated().map { index, marker in
                GutterLineMarker(id: index, line: marker.line, icon: marker.kind.gutterIcon, tooltip: marker.tooltip)
            })
            textView.lineMarkerHandler = { [weak self, weak textView] gutterMarker, _ in
                guard let self, let textView, let marker = self.marker(for: gutterMarker, in: textView) else { return }
                onClick(marker)
            }
        }
    }

    /// The marker a gutter icon stands for, or nil when the markers are older than the buffer: their
    /// anchor offsets are stale, and fresh markers are already on the way.
    func marker(for gutterMarker: GutterLineMarker, in textView: TextView) -> LineMarker? {
        guard let entry = shownMarkers[ObjectIdentifier(textView)], entry.generation == textView.contentGeneration,
              entry.markers.indices.contains(gutterMarker.id) else { return nil }
        return entry.markers[gutterMarker.id]
    }

    // MARK: Name index

    /// Keeps an open file's index overlay in step with its buffer once typing pauses. The window's
    /// Java path does this through ``LanguageService/bufferDidSettle(_:)``; this remains for a host
    /// that applies the text itself. `apply` receives the file and its current text.
    func scheduleNameIndexOverlay(
        for textView: TextView, delay: Duration, apply: @escaping (URL, String) async -> Void
    ) {
        guard let url = textView.documentURL else {
            settle.cancel(Self.nameIndexID, for: textView)
            return
        }
        settle.schedule(textView: textView, id: Self.nameIndexID, phase: .language, after: delay) { textView, snapshot in
            guard textView.documentURL == url, textView.contentGeneration == snapshot.generation else { return }
            await apply(url, snapshot.text)
        }
    }
}
