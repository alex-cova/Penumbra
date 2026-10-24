import EditorIntelligence
import Foundation
import Penumbra

/// What the window paints over an editor after the text has settled: semantic colours, the gutter's
/// line markers, and the name index's view of an open Java buffer. Each is computed off the main
/// actor after a pause, a newer request replaces the pending one, and a result for text that has
/// changed since is dropped, so none of it blocks typing or paints stale offsets.
///
/// It is given the providers and the user's choices on every call and reaches nothing else of the
/// window; what a marker click does is the caller's.
@MainActor
final class IDEEditorOverlayController {
    private let semanticHighlights = KeyedDebouncer<ObjectIdentifier>()
    private let markerRefreshes = KeyedDebouncer<ObjectIdentifier>()
    private let nameIndexOverlays = KeyedDebouncer<ObjectIdentifier>()
    /// The markers last painted for an editor and the text generation they were computed for.
    private var shownMarkers: [ObjectIdentifier: (generation: UInt64, markers: [LineMarker])] = [:]

    func cancelAll() {
        semanticHighlights.cancelAll()
        markerRefreshes.cancelAll()
        nameIndexOverlays.cancelAll()
        shownMarkers.removeAll()
    }

    // MARK: Semantic highlighting

    /// Recolours the editor once typing pauses. With no provider (a language without semantic tokens,
    /// or the setting off) the semantic colours are cleared. `delay` debounces typing; opening a file
    /// or switching to one passes zero so the colours land with the first frames.
    func scheduleSemanticHighlighting(
        for textView: TextView, provider: (any SemanticTokenProviding)?, delay: Duration
    ) {
        let key = ObjectIdentifier(textView)
        guard let provider else {
            semanticHighlights.cancel(key)
            textView.setSemanticHighlights([])
            return
        }
        semanticHighlights.schedule(key, after: delay) { [weak textView] in
            guard let textView else { return }
            let generation = textView.contentGeneration
            let export = textView.exportDocumentText()
            let highlights = await Task.detached(priority: .utility) {
                await provider.semanticHighlights(forSource: export.materializeUTF16Text())
            }.value
            guard !Task.isCancelled, let highlights, textView.contentGeneration == generation else { return }
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
            markerRefreshes.cancel(key)
            shownMarkers[key] = nil
            textView.setLineMarkers([])
            textView.lineMarkerHandler = nil
            return
        }
        markerRefreshes.schedule(key, after: delay) { [weak self, weak textView] in
            guard let textView else { return }
            let generation = textView.contentGeneration
            let url = textView.documentURL
            let export = textView.exportDocumentText()
            let work = Task.detached(priority: .utility) {
                await provider.lineMarkers(source: export.materializeUTF16Text(), fileURL: url, kinds: kinds)
            }
            let markers = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, let self, let markers, textView.contentGeneration == generation else { return }
            self.shownMarkers[key] = (generation, markers)
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

    /// Keeps the name index's view of an open file in step with its buffer once typing pauses, so
    /// Find Usages sees unsaved edits. `apply` receives the file and its current text.
    func scheduleNameIndexOverlay(
        for textView: TextView, delay: Duration, apply: @escaping (URL, String) async -> Void
    ) {
        guard let url = textView.documentURL else { return }
        nameIndexOverlays.schedule(ObjectIdentifier(textView), after: delay) { [weak textView] in
            guard let textView, textView.documentURL == url else { return }
            await apply(url, textView.text)
        }
    }
}
