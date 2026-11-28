@preconcurrency import AppKit
import EditorIntelligence

/// What VoiceOver gets of inlay hints, which are drawn between characters and are not text: a rotor
/// to move between them and hear what each says, and an announcement when the caret steps in front of one.
extension TextInputView {
    /// How a hint reads aloud: its kind, then its label without the punctuation that only makes sense drawn.
    static func accessibilityDescription(of hint: InlayHint) -> String {
        let label = hint.label.trimmingCharacters(in: .whitespacesAndNewlines)
        switch hint.kind {
        case .parameter:
            return "Parameter name hint: " + label.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        case .type:
            return "Type hint: " + label.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        default:
            return "Hint: " + label
        }
    }

    /// The hints a user can move between, in document order. Ghost text is a suggestion, not a hint.
    func accessibleInlayHints() -> [InlayHint] {
        inlayHints.filter { $0.kind != .inlineCompletion && !$0.label.isEmpty }.sorted { $0.utf16Offset < $1.utf16Offset }
    }

    override func accessibilityCustomRotors() -> [NSAccessibilityCustomRotor] {
        guard hasInlayHints else { return super.accessibilityCustomRotors() }
        let rotor = NSAccessibilityCustomRotor(label: "Inlay Hints", itemSearchDelegate: inlayRotorDelegate)
        return super.accessibilityCustomRotors() + [rotor]
    }

    /// Says what is in front of the caret, when it has just stopped in front of a chip.
    func announceInlayHint(atCaret location: Int) {
        guard let hint = inlayHint(atAnchor: location) else { return }
        NSAccessibility.post(
            element: self, notification: .announcementRequested,
            userInfo: [.announcement: Self.accessibilityDescription(of: hint), .priority: NSAccessibilityPriorityLevel.medium.rawValue]
        )
    }
}

/// Finds the next or previous inlay hint from the current rotor item, or from the caret when there is none.
@MainActor
final class InlayHintRotorDelegate: NSObject, @preconcurrency NSAccessibilityCustomRotorItemSearchDelegate {
    private weak var input: TextInputView?

    init(input: TextInputView) {
        self.input = input
    }

    func rotor(
        _ rotor: NSAccessibilityCustomRotor, resultFor parameters: NSAccessibilityCustomRotor.SearchParameters
    ) -> NSAccessibilityCustomRotor.ItemResult? {
        result(for: parameters)
    }

    func result(for parameters: NSAccessibilityCustomRotor.SearchParameters) -> NSAccessibilityCustomRotor.ItemResult? {
        guard let input else { return nil }
        let filter = parameters.filterString.trimmingCharacters(in: .whitespaces).lowercased()
        let candidates = input.accessibleInlayHints().filter {
            filter.isEmpty || TextInputView.accessibilityDescription(of: $0).lowercased().contains(filter)
        }
        guard !candidates.isEmpty else { return nil }
        let isNext = parameters.searchDirection == .next
        let found: InlayHint?
        if let current = parameters.currentItem?.targetRange {
            // Moving from a rotor item: strictly past it.
            found = isNext ? candidates.first { $0.utf16Offset > current.location } : candidates.last { $0.utf16Offset < current.location }
        } else {
            let caret = input.selection?.location ?? 0
            found = isNext ? candidates.first { $0.utf16Offset >= caret } : candidates.last { $0.utf16Offset < caret }
        }
        guard let hint = found else { return nil }
        let item = NSAccessibilityCustomRotor.ItemResult(targetElement: input)
        item.targetRange = NSRange(location: hint.utf16Offset, length: 0)
        item.customLabel = TextInputView.accessibilityDescription(of: hint)
        return item
    }
}
