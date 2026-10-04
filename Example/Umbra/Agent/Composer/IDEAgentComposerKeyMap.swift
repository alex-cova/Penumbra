import AppKit

/// What a key press does in the composer. Pure, so the rules are tested without a view.
enum IDEAgentComposerAction: Equatable {
    case send
    case newline
    case acceptSuggestion
    case nextSuggestion
    case previousSuggestion
    case dismissSuggestions
    /// Esc with nothing to dismiss: stop the run.
    case stop
    /// ⇧Tab: the next permission mode.
    case cycleMode
    /// ↑ on the first line, ↓ on the last: walk the prompts sent before.
    case historyPrevious
    case historyNext
    case passThrough
}

enum IDEAgentComposerKeyMap {
    struct Context: Equatable {
        var suggestionsVisible = false
        var caretOnFirstLine = true
        var caretOnLastLine = true
        /// Text is being composed by an input method; every key belongs to it.
        var hasMarkedText = false
        /// The caret is a single insertion point, not a selection.
        var selectionIsEmpty = true
    }

    enum KeyCode {
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let tab: UInt16 = 48
        static let escape: UInt16 = 53
        static let downArrow: UInt16 = 125
        static let upArrow: UInt16 = 126
    }

    static func action(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, context: Context) -> IDEAgentComposerAction {
        guard !context.hasMarkedText else { return .passThrough }
        let flags = modifiers.intersection([.shift, .option, .command, .control])

        switch keyCode {
        case KeyCode.returnKey, KeyCode.keypadEnter:
            if flags.contains(.shift) || flags.contains(.option) { return .newline }
            guard flags.isEmpty else { return .passThrough }
            return context.suggestionsVisible ? .acceptSuggestion : .send

        case KeyCode.tab:
            if flags == [.shift] { return .cycleMode }
            guard flags.isEmpty else { return .passThrough }
            return context.suggestionsVisible ? .acceptSuggestion : .passThrough

        case KeyCode.escape:
            guard flags.isEmpty else { return .passThrough }
            return context.suggestionsVisible ? .dismissSuggestions : .stop

        case KeyCode.upArrow:
            guard flags.isEmpty else { return .passThrough }
            if context.suggestionsVisible { return .previousSuggestion }
            return context.caretOnFirstLine && context.selectionIsEmpty ? .historyPrevious : .passThrough

        case KeyCode.downArrow:
            guard flags.isEmpty else { return .passThrough }
            if context.suggestionsVisible { return .nextSuggestion }
            return context.caretOnLastLine && context.selectionIsEmpty ? .historyNext : .passThrough

        default:
            return .passThrough
        }
    }
}
