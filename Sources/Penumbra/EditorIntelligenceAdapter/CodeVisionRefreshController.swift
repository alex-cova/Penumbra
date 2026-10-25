@preconcurrency import AppKit
import EditorIntelligence
import Foundation

/// Owns code-vision lenses and refresh for one ``EditorIntelligenceController``.
///
/// Lenses render through `TextView.codeVisionLenses`; this controller reserves room for every
/// declaration, then fills in the labels for the viewport, and routes lens clicks (usages and
/// implementations through navigation, anything else to the host). Extracted from
/// `EditorIntelligenceController` so the feature has one home; the controller keeps thin
/// forwarding API (`refreshCodeVision()`, `codeVisionEnabled`, `codeVisionConfiguration`,
/// `onCodeVisionClick`) that hosts already call.
@MainActor
final class CodeVisionRefreshController {
    /// Whether lenses are shown. Off clears them; hosts flip it from a preference.
    var isEnabled = false {
        didSet {
            if isEnabled != oldValue { refresh() }
        }
    }
    /// Identifies which labels the host asked the provider for. A change while lenses are on
    /// asks for them again, since `isEnabled` alone does not notice.
    var configuration = "" {
        didSet {
            if configuration != oldValue, isEnabled { refresh(delay: 0.1) }
        }
    }
    /// Called when a lens label is clicked and this controller has no action of its own for it.
    /// Usage counts open Find Usages and implementation counts go to the implementations.
    var onUnknownClick: ((CodeVisionEntry, Int) -> Void)?

    private let provider: (any CodeVisionProviding)?
    private weak var textView: TextView?
    /// Snapshot for the caret's document, read when a debounced refresh fires — not when it is
    /// scheduled. Wired by the owning controller after init (mirroring `InlineCompletionController.engine`).
    var makeDocument: @MainActor () -> Document? = { nil }
    /// Navigation for the built-in lens kinds, wired by the owning controller after init.
    var navigate: @MainActor (NavigationKind, Int) -> Bool = { _, _ in false }
    private var task: Task<Void, Never>?
    /// Vertical range of content the last code vision request covered.
    private var requestedYRange: ClosedRange<CGFloat>?

    init(textView: TextView?, provider: (any CodeVisionProviding)?) {
        self.textView = textView
        self.provider = provider
    }

    /// Shows the lenses above declarations in two steps: first the room for every declaration (so the
    /// text does not move when numbers arrive), then the labels for the declarations on screen (a
    /// viewport above and below included).
    func refresh(delay: TimeInterval = 0.4) {
        task?.cancel()
        guard let textView else { return }
        guard isEnabled, let provider else {
            requestedYRange = nil
            if !textView.codeVisionLenses.isEmpty { textView.codeVisionLenses = [] }
            return
        }
        textView.codeVisionHandler = { [weak self] entry, offset in
            self?.handleClick(entry, declarationOffset: offset)
        }
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            let request: (Document, UInt64)? = await MainActor.run {
                guard let self, let textView = self.textView, let document = self.makeDocument() else { return nil }
                return (document, textView.contentGeneration)
            }
            guard let (document, generation) = request else { return }
            let anchors = await provider.codeVisionAnchors(for: document).sorted()
            guard !Task.isCancelled else { return }
            // Step 1: room for every declaration, keeping the labels already shown on the same lines.
            let visible: [Int]? = await MainActor.run {
                guard let self, let textView = self.textView, textView.contentGeneration == generation else { return nil }
                let shownByLine = Dictionary(
                    textView.codeVisionLenses.compactMap { lens in
                        textView.textLocation(at: lens.utf16Offset).map { ($0.lineNumber, lens.entries) }
                    },
                    uniquingKeysWith: { first, _ in first }
                )
                textView.codeVisionLenses = anchors.map { anchor in
                    let line = textView.textLocation(at: anchor)?.lineNumber
                    return CodeVisionLens(utf16Offset: anchor, entries: line.flatMap { shownByLine[$0] } ?? [])
                }
                let height = textView.bounds.height
                let top = textView.characterIndex(at: CGPoint(x: 0, y: -height)) ?? 0
                let bottom = textView.characterIndex(at: CGPoint(x: textView.bounds.width, y: height * 2)) ?? textView.documentLength
                let offsetY = textView.contentOffset.y
                self.requestedYRange = (offsetY - height)...(offsetY + height * 2)
                return anchors.filter { $0 >= top && $0 <= bottom }
            }
            guard let visible, !visible.isEmpty else { return }
            // Step 2: the numbers for what is on screen.
            let lenses = await provider.codeVision(for: document, anchors: visible)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, let textView = self.textView, textView.contentGeneration == generation else { return }
                let entriesByAnchor = Dictionary(lenses.map { ($0.utf16Offset, $0.entries) }, uniquingKeysWith: { first, _ in first })
                let shown = Dictionary(textView.codeVisionLenses.map { ($0.utf16Offset, $0) }, uniquingKeysWith: { first, _ in first })
                textView.codeVisionLenses = anchors.map { anchor in
                    if let entries = entriesByAnchor[anchor] { return CodeVisionLens(utf16Offset: anchor, entries: entries) }
                    return shown[anchor] ?? CodeVisionLens(utf16Offset: anchor)
                }
            }
        }
    }

    /// Labels are computed for the viewport plus a screen above and below. Scrolling past that asks
    /// again, once scrolling pauses.
    func refreshIfViewportLeftRange() {
        guard isEnabled, provider != nil, let textView else { return }
        let top = textView.contentOffset.y
        let bottom = top + textView.bounds.height
        if let range = requestedYRange, range.contains(top), range.contains(bottom) {
            return
        }
        refresh(delay: 0.2)
    }

    private func handleClick(_ entry: CodeVisionEntry, declarationOffset: Int) {
        switch entry.id {
        case "usages":
            _ = navigate(.references, declarationOffset)
        case "implementations":
            _ = navigate(.implementation, declarationOffset)
        default:
            onUnknownClick?(entry, declarationOffset)
        }
    }

    deinit {
        task?.cancel()
    }
}
