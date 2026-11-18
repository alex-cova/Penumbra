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
    private var shownMarkers: [ObjectIdentifier: (generation: UInt64, stacks: [LineMarkerStack])] = [:]

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
        disabledDescriptors: Set<LineMarkerDescriptor.ID> = [],
        languageIdentifier: String?, delay: Duration, onClick: @escaping (LineMarkerStack) -> Void
    ) {
        let key = ObjectIdentifier(textView)
        textView.reservedLineMarkerSlots = Self.reservedLineMarkerSlots(
            languageIdentifier: languageIdentifier, hasMarkerProvider: provider != nil)
        // Extension markers (Spring…) are filtered by descriptor below, so the provider still runs when every Java kind is off.
        guard let provider else {
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
            let visible = markers.filter { marker in
                if let descriptor = marker.descriptor { return !disabledDescriptors.contains(descriptor.id) }
                return kinds.contains(marker.kind)
            }
            // Several markers on one line stay reachable: the highest priority is drawn with a count, a click lists them all.
            let stacks = LineMarkerPresentation.stacks(from: visible)
            self.shownMarkers[key] = (snapshot.generation, stacks)
            textView.setLineMarkers(stacks.enumerated().map { index, stack in Self.gutterMarker(id: index, stack: stack) })
            textView.lineMarkerHandler = { [weak self, weak textView] gutterMarker, _ in
                guard let self, let textView, let stack = self.stack(for: gutterMarker, in: textView) else { return }
                onClick(stack)
            }
        }
    }

    /// The marker a gutter icon stands for, or nil when the markers are older than the buffer: their
    /// anchor offsets are stale, and fresh markers are already on the way.
    func stack(for gutterMarker: GutterLineMarker, in textView: TextView) -> LineMarkerStack? {
        guard let entry = shownMarkers[ObjectIdentifier(textView)], entry.generation == textView.contentGeneration,
              entry.stacks.indices.contains(gutterMarker.id) else { return nil }
        return entry.stacks[gutterMarker.id]
    }

    /// The gutter icon for a stack: the visible marker's glyph or symbol, a count when more share the line, and a tooltip that
    /// says so.
    static func gutterMarker(id: Int, stack: LineMarkerStack) -> GutterLineMarker {
        let marker = stack.visible
        var tooltip = marker.tooltip
        if stack.isStacked { tooltip += "\n+\(stack.markers.count - 1) more: click to choose" }
        if let descriptor = marker.descriptor {
            let tint = GutterLineMarkerTint(rawValue: descriptor.tint.rawValue) ?? .neutral
            return GutterLineMarker(
                id: id, line: marker.line, icon: .custom, tooltip: tooltip,
                symbol: GutterLineMarkerSymbol(name: descriptor.symbolName, tint: tint, accessibilityLabel: descriptor.accessibilityLabel),
                stackCount: stack.markers.count)
        }
        return GutterLineMarker(id: id, line: marker.line, icon: marker.kind.gutterIcon, tooltip: tooltip, stackCount: stack.markers.count)
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
