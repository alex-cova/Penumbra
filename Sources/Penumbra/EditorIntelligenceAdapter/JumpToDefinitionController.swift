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

    /// Called for the resolved single target.
    public var onNavigate: ((Location) -> Void)?
    /// Called with the candidates when a request resolves to more than one location. Wire this
    /// to a picker (e.g. `CommandPaletteController.presentList`). If unset, the first location
    /// is used.
    public var onPresentChoices: ((NavigationKind, [Location]) -> Void)?
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
        clearHover()
        guard let document = navigationDocument(cursor: Cursor(position: position)) else {
            return
        }
        let context = NavigationContext(
            document: document,
            cursor: Cursor(position: position),
            selection: Selection(range: TextRange(start: position, end: position)),
            trigger: .manual,
            kind: kind
        )
        Task {
            guard let result = await navigationEngine.navigate(context: context) else {
                return
            }
            await MainActor.run {
                switch result {
                case .single(let location):
                    self.go(to: location)
                case .multiple(let locations) where locations.count == 1:
                    self.go(to: locations[0])
                case .multiple(let locations):
                    if let onPresentChoices = self.onPresentChoices {
                        onPresentChoices(kind, locations)
                    } else if let first = locations.first {
                        self.go(to: first)
                    }
                }
            }
        }
    }

    private func go(to location: Location) {
        onNavigate?(location)
        guard let textView else {
            return
        }
        if let url = location.url, url != textView.documentURL,
           onOpenInOtherDocument?(location) == true {
            return
        }
        textView.recordNavigationCheckpoint()
        let range = TextEditApplicator.nsRange(for: location.range, in: textView)
        textView.selectedRanges = [range]
        textView.scrollRangeToVisible(range)
    }

    /// The adapter's document snapshot lags the live buffer (content refresh is debounced), and a
    /// Cmd-click's caret is the click point, not whatever cursor the snapshot still has. Navigation
    /// reads this copy.
    private func navigationDocument(cursor: Cursor) -> Document? {
        guard let document = adapter.currentDocument, let textView else { return nil }
        let snapshot = TextSnapshot(version: document.version, text: textView.text)
        let selection = Selection(range: TextRange(start: cursor.position, end: cursor.position))
        return Document(
            id: document.id,
            url: textView.documentURL ?? document.url,
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
              let range = identifierRange(in: textView.text as NSString, at: index) else {
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

    private func resolveHover(at position: TextPosition, identifier: NSRange) async {
        guard let document = navigationDocument(cursor: Cursor(position: position)) else {
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
        guard result != nil, let textView else {
            clearHover()
            return
        }
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
           let textLocation = textView.textLocation(at: index) {
            navigate(at: TextPosition(
                line: textLocation.lineNumber,
                column: textLocation.column,
                utf16Offset: index
            ), kind: .definition)
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
