@preconcurrency import AppKit
import EditorIntelligence

/// Handles ⌘-click navigation to symbol definitions (and, on request, implementations /
/// references).
@MainActor
public final class JumpToDefinitionController {
    private weak var textView: TextView?
    private let navigationEngine: NavigationEngine
    private let adapter: PenumbraEditorAdapter

    /// Called for the resolved single target.
    public var onNavigate: ((Location) -> Void)?
    /// Called with the candidates when a request resolves to more than one location. Wire this
    /// to a picker (e.g. `CommandPaletteController.presentList`). If unset, the first location
    /// is used.
    public var onPresentChoices: (([Location]) -> Void)?
    /// Called when a target belongs to a different document (`Location.url` set and different
    /// from `textView.documentURL`). Return `true` if the host opened it; otherwise the target
    /// is focused in the current text view.
    public var onOpenInOtherDocument: ((Location) -> Bool)?

    public init(textView: TextView, adapter: PenumbraEditorAdapter, navigationEngine: NavigationEngine) {
        self.textView = textView
        self.adapter = adapter
        self.navigationEngine = navigationEngine
        installGesture(on: textView)
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
        guard let document = adapter.currentDocument else {
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
                        onPresentChoices(locations)
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

    private func installGesture(on textView: TextView) {
        let clickGesture = CmdClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        textView.addGestureRecognizer(clickGesture)
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
