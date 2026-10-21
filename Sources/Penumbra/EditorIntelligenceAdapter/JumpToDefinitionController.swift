@preconcurrency import AppKit
import EditorIntelligence

/// Handles ⌘-click navigation to symbol definitions (and, on request, implementations /
/// references).
@MainActor
public final class JumpToDefinitionController {
    private weak var textView: TextView?
    private let navigationEngine: NavigationEngine
    private let adapter: EditorAdapter
    private var hoverTask: Task<Void, Never>?
    private var hoverIdentifierStart: Int?
    private var showingLinkCursor = false
    /// The buffer as of one `generation`: ⌘-hover asks about every word the pointer stops on, and
    /// copying a large buffer out of the piece tree for each is wasted work. Only the piece-tree
    /// export is taken on the main thread; the string is built by whoever needs it, off it.
    private var bufferText: BufferText?
    /// What ⌘-hover found for one word, so a click on that word right after does not ask again.
    private var hoverResult: (generation: UInt64, identifier: NSRange, result: NavigationResult)?

    /// Called for the resolved single target.
    public var onNavigate: ((Location) -> Void)?
    /// Called with the candidates when a request resolves to more than one location. Wire this
    /// to a picker (e.g. `CommandPaletteController.presentList`). If unset, the first location
    /// is used.
    public var onPresentChoices: ((NavigationKind, [Location]) -> Void)?
    /// Called instead of ``onPresentChoices`` when a ⌘-click resolves to more than one location,
    /// with the clicked identifier's range and text, so the choices can pop up next to it.
    public var onPresentChoicesAtClick: ((NavigationKind, [Location], _ identifier: NSRange, _ name: String) -> Void)?
    /// Called when a target belongs to a different document (`Location.url` set and different
    /// from `textView.documentURL`). Return `true` if the host opened it; otherwise the target
    /// is focused in the current text view.
    public var onOpenInOtherDocument: ((Location) -> Bool)?

    public init(textView: TextView, adapter: EditorAdapter, navigationEngine: NavigationEngine) {
        self.textView = textView
        self.adapter = adapter
        self.navigationEngine = navigationEngine
        installGesture(on: textView)
        textView.onHoverEvent = { [weak self] event in
            self?.handleHover(event)
        }
    }

    /// Jump to the definition of the symbol at the current cursor.
    public func jumpToDefinition() {
        guard let document = adapter.currentDocument else {
            return
        }
        navigate(at: document.cursor.position, kind: .definition)
    }

    public func jumpToDefinition(at position: TextPosition) {
        navigate(at: position, kind: .definition)
    }

    /// Jump to the implementation(s) of the symbol at `position`.
    public func jumpToImplementation(at position: TextPosition) {
        navigate(at: position, kind: .implementation)
    }

    /// Find references to the symbol at `position`.
    public func findReferences(at position: TextPosition) {
        navigate(at: position, kind: .references)
    }

    public func navigate(at position: TextPosition, kind: NavigationKind) {
        navigate(at: position, kind: kind, clickedIdentifier: nil)
    }

    private func navigate(at position: TextPosition, kind: NavigationKind, clickedIdentifier: NSRange?) {
        clearHover()
        guard adapter.currentDocument != nil, let textView else {
            return
        }
        let text = currentBufferText(of: textView)
        Task {
            guard let document = await navigationDocument(cursor: Cursor(position: position), text: text) else {
                return
            }
            let context = NavigationContext(
                document: document,
                cursor: Cursor(position: position),
                selection: Selection(range: TextRange(start: position, end: position)),
                trigger: .manual,
                kind: kind
            )
            guard let result = await navigationEngine.navigate(context: context) else {
                return
            }
            self.deliver(result, kind: kind, clickedIdentifier: clickedIdentifier)
        }
    }

    /// What ⌘-hover found for `identifier`, when the text is still the one it was asked about.
    func cachedHoverResult(for identifier: NSRange) -> NavigationResult? {
        guard let textView, let hover = hoverResult,
              hover.generation == textView.contentGeneration, hover.identifier == identifier else { return nil }
        return hover.result
    }

    /// Acts on a definition result: goes to the one target, or offers the several.
    private func deliver(_ result: NavigationResult, kind: NavigationKind, clickedIdentifier: NSRange?) {
        switch result {
        case .single(let location):
            go(to: location)
        case .multiple(let locations) where locations.count == 1:
            go(to: locations[0])
        case .multiple(let locations):
            if let clickedIdentifier, let onPresentChoicesAtClick, let textView,
               NSMaxRange(clickedIdentifier) <= textView.documentLength,
               let name = textView.text(in: clickedIdentifier) {
                onPresentChoicesAtClick(kind, locations, clickedIdentifier, name)
            } else if let onPresentChoices {
                onPresentChoices(kind, locations)
            } else if let first = locations.first {
                go(to: first)
            }
        }
    }

    /// The buffer's current state, captured without building its string.
    private func currentBufferText(of textView: TextView) -> BufferText {
        let generation = textView.contentGeneration
        if let cached = bufferText, cached.generation == generation { return cached }
        let captured = BufferText(generation: generation, export: textView.exportDocumentText())
        bufferText = captured
        return captured
    }

    private func go(to location: Location) {
        onNavigate?(location)
        guard let textView else {
            return
        }
        // A folder or a package has no text to select: only the host can show it.
        if location.target != .source {
            _ = onOpenInOtherDocument?(location)
            return
        }
        if let url = location.url, url != textView.documentURL,
           onOpenInOtherDocument?(location) == true {
            return
        }
        textView.recordNavigationCheckpoint()
        let range = TextEditApplicator.nsRange(for: location.range, in: textView)
        textView.selectedRanges = [range]
        textView.scrollRangeToCenter(range)
    }

    /// The adapter's document snapshot lags the live buffer (content refresh is debounced), and a
    /// Cmd-click's caret is the click point, not whatever cursor the snapshot still has. Navigation
    /// reads this copy.
    private func navigationDocument(cursor: Cursor, text: BufferText) async -> Document? {
        guard let document = adapter.currentDocument, let textView else { return nil }
        let url = textView.documentURL ?? document.url
        let version = document.version
        let snapshot = await Task.detached(priority: .userInitiated) {
            TextSnapshot(version: version, text: text.string())
        }.value
        guard !Task.isCancelled else { return nil }
        let selection = Selection(range: TextRange(start: cursor.position, end: cursor.position))
        return Document(
            id: document.id,
            url: url,
            displayName: document.displayName,
            contentSnapshot: snapshot,
            selection: selection,
            cursor: cursor,
            viewport: document.viewport,
            languageIdentifier: document.languageIdentifier
        )
    }

    private func installGesture(on textView: TextView) {
        let clickGesture = CmdClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        textView.addTextInputGestureRecognizer(clickGesture)
    }

    private func handleHover(_ event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            clearHover()
            return
        }
        guard let textView else {
            clearHover()
            return
        }
        let windowPoint: NSPoint
        if event.type == .mouseMoved {
            windowPoint = event.locationInWindow
        } else if let window = textView.window {
            windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        } else {
            clearHover()
            return
        }
        let point = textView.convert(windowPoint, from: nil)
        guard textView.bounds.contains(point),
              let index = textView.characterIndex(at: point),
              let range = identifierRange(at: index, in: textView) else {
            clearHover()
            return
        }
        if hoverIdentifierStart == range.location, showingLinkCursor {
            return
        }
        hoverIdentifierStart = range.location
        hoverTask?.cancel()
        let position = TextPosition(line: 0, column: index, utf16Offset: index)
        hoverTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard !Task.isCancelled else { return }
            await self?.resolveHover(at: position, identifier: range)
        }
    }

    func resolveHover(at position: TextPosition, identifier: NSRange) async {
        guard let textView else {
            clearHover()
            return
        }
        // The state this request is about: the answer is only kept while the buffer is still in it.
        let text = currentBufferText(of: textView)
        guard let document = await navigationDocument(cursor: Cursor(position: position), text: text) else {
            clearHover()
            return
        }
        let context = NavigationContext(
            document: document,
            cursor: Cursor(position: position),
            selection: Selection(range: TextRange(start: position, end: position)),
            trigger: .idle,
            kind: .definition
        )
        let result = await navigationEngine.navigate(context: context)
        guard !Task.isCancelled else { return }
        guard let result else {
            clearHover()
            return
        }
        hoverResult = (text.generation, identifier, result)
        textView.emphasisManager.replaceEmphases(
            [Emphasis(range: identifier, style: .underline(color: .controlAccentColor))],
            for: EmphasisGroup.navigation,
            color: .controlAccentColor
        )
        NSCursor.pointingHand.set()
        showingLinkCursor = true
    }

    private func clearHover() {
        hoverTask?.cancel()
        hoverTask = nil
        hoverIdentifierStart = nil
        if showingLinkCursor {
            NSCursor.iBeam.set()
            showingLinkCursor = false
        }
        textView?.emphasisManager.removeEmphases(for: EmphasisGroup.navigation)
    }

    /// The identifier at `index`, read from a window around it: the whole buffer is never copied
    /// out on the main thread for a pointer move. The window grows while the identifier runs to
    /// its edge, so a long name is still found whole.
    func identifierRange(at index: Int, in textView: TextView) -> NSRange? {
        let length = textView.documentLength
        guard index >= 0, index < length else { return nil }
        var radius = 128
        while true {
            let lower = max(0, index - radius)
            let upper = min(length, index + radius + 1)
            guard let window = textView.text(in: NSRange(location: lower, length: upper - lower)) else { return nil }
            let text = window as NSString
            guard let local = identifierRange(in: text, at: index - lower) else { return nil }
            let runsPastLeft = local.location == 0 && lower > 0
            let runsPastRight = NSMaxRange(local) == text.length && upper < length
            if !runsPastLeft, !runsPastRight {
                return NSRange(location: lower + local.location, length: local.length)
            }
            radius *= 4
        }
    }

    private func identifierRange(in text: NSString, at offset: Int) -> NSRange? {
        guard offset >= 0, offset < text.length, isIdentifierCharacter(text.character(at: offset)) else { return nil }
        var start = offset
        while start > 0, isIdentifierCharacter(text.character(at: start - 1)) {
            start -= 1
        }
        let first = text.character(at: start)
        if first >= 48 && first <= 57 { return nil }
        var end = offset + 1
        while end < text.length, isIdentifierCharacter(text.character(at: end)) {
            end += 1
        }
        return NSRange(location: start, length: end - start)
    }

    private func isIdentifierCharacter(_ unit: unichar) -> Bool {
        if unit == 95 || unit == 36 { return true }
        if unit >= 65 && unit <= 90 { return true }
        if unit >= 97 && unit <= 122 { return true }
        if unit >= 48 && unit <= 57 { return true }
        return unit > 127
    }

    @objc private func handleClick(_ gesture: NSClickGestureRecognizer) {
        guard let textView else {
            return
        }
        let point = gesture.location(in: textView)
        if let index = textView.characterIndex(at: point),
           let identifier = identifierRange(at: index, in: textView),
           let cached = cachedHoverResult(for: identifier) {
            // ⌘-hover already resolved this word in this text: the click is its answer.
            clearHover()
            deliver(cached, kind: .definition, clickedIdentifier: identifier)
            return
        }
        if let index = textView.characterIndex(at: point),
           let textLocation = textView.textLocation(at: index) {
            navigate(at: TextPosition(
                line: textLocation.lineNumber,
                column: textLocation.column,
                utf16Offset: index
            ), kind: .definition, clickedIdentifier: identifierRange(at: index, in: textView))
            return
        }
        guard let document = adapter.currentDocument else {
            return
        }
        navigate(at: document.cursor.position, kind: .definition)
    }
}

private final class CmdClickGestureRecognizer: NSClickGestureRecognizer {
    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            return
        }
        super.mouseDown(with: event)
    }
}

/// A buffer state whose string is built the first time somebody asks, once, on the caller's thread.
private final class BufferText: @unchecked Sendable {
    let generation: UInt64
    private let export: DocumentTextExport
    private let lock = NSLock()
    private var built: String?

    init(generation: UInt64, export: DocumentTextExport) {
        self.generation = generation
        self.export = export
    }

    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        if let built { return built }
        let text = export.materializeUTF16Text()
        built = text
        return text
    }
}
