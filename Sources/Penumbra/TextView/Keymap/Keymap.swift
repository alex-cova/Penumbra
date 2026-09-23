import Foundation

/// A set of keystroke → action bindings. Assign one to ``TextView/keymap``.
///
/// Two presets ship: ``default_`` reproduces Penumbra's historical shortcuts exactly, and
/// ``intelliJ`` layers on an IntelliJ-style set (Search Everywhere, Extend Selection,
/// statement movement, Surround With, navigation history, …). Bindings can also be edited
/// piecemeal with ``bind(_:to:)`` / ``unbind(_:)``.
public struct Keymap: Sendable {
    public private(set) var bindings: [KeyStroke: EditorActionID]

    public init(bindings: [KeyStroke: EditorActionID] = [:]) {
        self.bindings = bindings
    }

    public mutating func bind(_ stroke: KeyStroke, to action: EditorActionID) {
        bindings[stroke] = action
    }

    public mutating func unbind(_ stroke: KeyStroke) {
        bindings.removeValue(forKey: stroke)
    }

    /// Removes every binding pointing at `action` (both single and chorded).
    public mutating func unbindAll(_ action: EditorActionID) {
        for (stroke, boundAction) in bindings where boundAction == action {
            bindings.removeValue(forKey: stroke)
        }
    }

    public func action(for stroke: KeyStroke) -> EditorActionID? {
        bindings[stroke]
    }

    /// The first keystroke bound to `action`, preferring a single-chord stroke. Used by the
    /// command palette to show a shortcut next to each action.
    public func stroke(for action: EditorActionID) -> KeyStroke? {
        let matches = bindings.filter { $0.value == action }.map(\.key)
        return matches.min { lhs, rhs in
            if lhs.chords.count != rhs.chords.count { return lhs.chords.count < rhs.chords.count }
            return lhs.displayString < rhs.displayString
        }
    }

    /// Whether `chord` begins some chorded binding — i.e. pressing it should arm the chord
    /// window rather than fall through to default handling.
    public func isChordPrefix(_ chord: KeyChord) -> Bool {
        bindings.keys.contains { $0.prefix == chord }
    }

    /// The action a chorded binding `prefix chord` + `second` resolves to, if any.
    public func chordedAction(prefix: KeyChord, second: KeyChord) -> EditorActionID? {
        bindings[KeyStroke(prefix, second)]
    }
}

public extension Keymap {
    /// Penumbra's historical shortcut set — the bindings hard-coded before ``Keymap`` existed,
    /// plus ⌥⇧↑/↓ to move lines (previously documented but unwired).
    static let default_: Keymap = {
        var map = Keymap()
        map.bind(KeyStroke(KeyChord("k", .command), KeyChord("d", .command)), to: .skipCurrentOccurrence)
        map.bind(KeyStroke(KeyChord(code: 0x33, .command)), to: .deleteLines)
        map.bind(KeyStroke(KeyChord("f", .command)), to: .toggleFindPanel)
        map.bind(KeyStroke(KeyChord("f", [.command, .option])), to: .toggleReplacePanel)
        map.bind(KeyStroke(KeyChord("l", [.command, .shift])), to: .selectAllOccurrences)
        map.bind(KeyStroke(KeyChord("l", [.command, .option])), to: .addCaretsToLineEnds)
        map.bind(KeyStroke(KeyChord("l", .command)), to: .goToLine)
        map.bind(KeyStroke(KeyChord("d", [.command, .shift])), to: .selectNextOccurrence)
        map.bind(KeyStroke(KeyChord("d", .command)), to: .duplicateLines)
        map.bind(KeyStroke(KeyChord("u", .command)), to: .undoLastCaretChange)
        map.bind(KeyStroke(KeyChord(code: 0x7E, [.command, .option])), to: .addCaretAbove)
        map.bind(KeyStroke(KeyChord(code: 0x7D, [.command, .option])), to: .addCaretBelow)
        map.bind(KeyStroke(KeyChord(code: 0x7E, [.option, .shift])), to: .moveLineUp)
        map.bind(KeyStroke(KeyChord(code: 0x7D, [.option, .shift])), to: .moveLineDown)
        // Space is always a key-code chord (`KeyChord(event:)` never matches it as `" "`), so
        // Control-Space must be bound by 0x31 — the VS Code / Xcode / IntelliJ complete shortcut.
        map.bind(KeyStroke(KeyChord(code: 0x31, .control)), to: .triggerCompletion)
        map.bind(KeyStroke(KeyChord(code: 0x31, [.control, .shift])), to: .triggerSmartCompletion)
        map.bind(KeyStroke(KeyChord("/", .command)), to: .toggleComment)
        // Return is always a key-code chord, like Space above — 0x24 is kVK_Return.
        map.bind(KeyStroke(KeyChord(code: 0x24, .command)), to: .insertLineBelow)
        map.bind(KeyStroke(KeyChord(code: 0x24, [.command, .shift])), to: .insertLineAbove)
        map.bind(KeyStroke(KeyChord("b", .command)), to: .toggleMarkdownPreview)
        return map
    }()

    /// IntelliJ IDEA's macOS keymap for the actions Penumbra implements. Starts from
    /// ``default_`` and overrides the conflicting bindings (⌥↑/↓, ⌘⇧L, …).
    static let intelliJ: Keymap = {
        var map = Keymap.default_

        // Search Everywhere is double-Shift, handled out of band by DoubleModifierDetector,
        // but a discoverable ⌘⇧A / etc. still routes through the keymap.
        map.bind(KeyStroke(KeyChord("a", [.command, .shift])), to: .findAction)
        map.bind(KeyStroke(KeyChord("o", [.command, .shift])), to: .quickOpenFile)
        map.bind(KeyStroke(KeyChord("e", .command)), to: .recentFiles)

        // Navigation
        map.unbindAll(.selectLines)
        map.bind(KeyStroke(KeyChord("l", .command)), to: .goToLine)
        map.bind(KeyStroke(KeyChord("b", .command)), to: .toggleMarkdownPreview)
        map.bind(KeyStroke(KeyChord(code: 0x6F /* F12 */)), to: .goToDefinition)
        map.bind(KeyStroke(KeyChord("b", [.command, .option])), to: .goToImplementation)
        map.bind(KeyStroke(KeyChord("b", [.command, .option, .shift])), to: .findUsages)
        map.bind(KeyStroke(KeyChord(code: 0x21 /* [ */, .command)), to: .navigateBack)
        map.bind(KeyStroke(KeyChord(code: 0x1E /* ] */, .command)), to: .navigateForward)

        // Semantic selection — replaces word-wise ⌥↑/↓ caret movement.
        map.bind(KeyStroke(KeyChord(code: 0x7E, .option)), to: .expandSelection)
        map.bind(KeyStroke(KeyChord(code: 0x7D, .option)), to: .shrinkSelection)

        // Line / statement movement
        map.bind(KeyStroke(KeyChord(code: 0x7E, [.option, .shift])), to: .moveLineUp)
        map.bind(KeyStroke(KeyChord(code: 0x7D, [.option, .shift])), to: .moveLineDown)
        map.bind(KeyStroke(KeyChord(code: 0x7E, [.command, .shift])), to: .moveStatementUp)
        map.bind(KeyStroke(KeyChord(code: 0x7D, [.command, .shift])), to: .moveStatementDown)

        // Multi-caret (Control-based, like IntelliJ on macOS)
        map.bind(KeyStroke(KeyChord("g", .control)), to: .selectNextOccurrence)
        map.bind(KeyStroke(KeyChord("g", [.control, .command])), to: .selectAllOccurrences)
        map.bind(KeyStroke(KeyChord("8", [.command, .shift])), to: .toggleColumnSelectionMode)

        // Editing
        map.bind(KeyStroke(KeyChord("j", [.control, .shift])), to: .joinLines)
        map.bind(KeyStroke(KeyChord("t", [.command, .option])), to: .surroundWith)
        map.bind(KeyStroke(KeyChord("l", [.command, .option])), to: .reformatCode)
        map.bind(KeyStroke(KeyChord("d", .command)), to: .duplicateLines)

        return map
    }()

    /// Sublime Text-style macOS keymap. Starts from ``default_`` and adds palette/navigation
    /// shortcuts familiar to Sublime users (⌘P quick open, ⌘⇧P command palette, ⌘G/⌘L go to
    /// line, ⌘R go to symbol), then corrects ⌘D / ⌘⇧D to Sublime's semantics (`default_`'s pair
    /// is inverted) and adds ⌘⇧F for Find in Files.
    static let sublime: Keymap = {
        var map = Keymap.default_

        map.bind(KeyStroke(KeyChord("p", .command)), to: .quickOpenFile)
        map.bind(KeyStroke(KeyChord("p", [.command, .shift])), to: .findAction)
        map.bind(KeyStroke(KeyChord("g", .command)), to: .goToLine)
        map.bind(KeyStroke(KeyChord("r", .command)), to: .goToSymbol)
        map.bind(KeyStroke(KeyChord("e", .command)), to: .recentFiles)
        map.bind(KeyStroke(KeyChord("b", .command)), to: .toggleMarkdownPreview)
        map.bind(KeyStroke(KeyChord(code: 0x6F /* F12 */)), to: .goToDefinition)
        map.bind(KeyStroke(KeyChord(code: 0x21 /* [ */, .command)), to: .navigateBack)
        map.bind(KeyStroke(KeyChord(code: 0x1E /* ] */, .command)), to: .navigateForward)

        map.unbindAll(.selectLines)
        map.bind(KeyStroke(KeyChord("l", .command)), to: .goToLine)
        map.bind(KeyStroke(KeyChord("l", [.command, .shift])), to: .selectAllOccurrences)

        // Sublime Text binds ⌘D to Select Next Occurrence and ⌘⇧D to Duplicate Line — the
        // opposite of `default_`'s historical pair — plus ⌘⇧F for Find in Files.
        map.unbindAll(.selectNextOccurrence)
        map.unbindAll(.duplicateLines)
        map.bind(KeyStroke(KeyChord("d", .command)), to: .selectNextOccurrence)
        map.bind(KeyStroke(KeyChord("d", [.command, .shift])), to: .duplicateLines)
        map.bind(KeyStroke(KeyChord("f", [.command, .shift])), to: .findInFiles)

        return map
    }()
}
