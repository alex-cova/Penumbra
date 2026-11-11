import Foundation

/// A set of keystroke → action bindings. Assign one to ``TextView/keymap``.
///
/// Four presets ship: ``default_`` (Penumbra's historical shortcuts plus the navigation, folding
/// and rename keys every preset should have), ``sublime``, ``vsCode`` and ``intelliJ`` (Search
/// Everywhere, Extend Selection, statement movement, Surround With, navigation history, …).
/// Bindings can also be edited piecemeal with ``bind(_:to:)`` / ``unbind(_:)``.
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
    /// plus ⌥⇧↑/↓ to move lines (previously documented but unwired). ``intelliJ`` starts from
    /// this, not from ``default_``: it has its own keys for what ``default_`` adds below.
    private static let historical: Keymap = {
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
        map.bind(KeyStroke(KeyChord("u", [.command, .shift])), to: .toggleCase)
        // Return is always a key-code chord, like Space above — 0x24 is kVK_Return.
        map.bind(KeyStroke(KeyChord(code: 0x24, .command)), to: .insertLineBelow)
        map.bind(KeyStroke(KeyChord(code: 0x24, [.command, .shift])), to: .insertLineAbove)
        map.bind(KeyStroke(KeyChord("b", .command)), to: .toggleMarkdownPreview)
        map.bind(KeyStroke(KeyChord(code: 0x24, .option)), to: .showContextActions)
        map.bind(KeyStroke(KeyChord(code: 0x7A /* F1 */)), to: .quickDocumentation)
        map.bind(KeyStroke(KeyChord(code: 0x7A /* F1 */, .command)), to: .showErrorDescription)
        // File Structure lists the current file's declarations; Go to Symbol searches every open one.
        map.bind(KeyStroke(KeyChord(code: 0x6F /* F12 */, .command)), to: .goToFileSymbol)
        return map
    }()

    /// ``historical`` plus the keys the audit found missing (F28): the command palette, Back and
    /// Forward, code folding (Sublime's and VS Code's chords), Rename, and next / previous problem.
    /// Every key here is free in the menus of the Sublime and Default columns of Umbra.
    static let default_: Keymap = {
        var map = historical
        map.bind(KeyStroke(KeyChord("p", [.command, .shift])), to: .findAction)
        map.bind(KeyStroke(KeyChord("p", .command)), to: .quickOpenFile)
        map.bind(KeyStroke(KeyChord("g", .command)), to: .findNext)
        map.bind(KeyStroke(KeyChord("g", [.command, .shift])), to: .findPrevious)
        map.bind(KeyStroke(KeyChord(code: 0x6F /* F12 */)), to: .goToDefinition)
        map.bind(KeyStroke(KeyChord(code: 0x21 /* [ */, .command)), to: .navigateBack)
        map.bind(KeyStroke(KeyChord(code: 0x1E /* ] */, .command)), to: .navigateForward)
        map.bind(KeyStroke(KeyChord(code: 0x61 /* F6 */, .shift)), to: .rename)
        map.bind(KeyStroke(KeyChord(code: 0x76 /* F4 */)), to: .goToNextProblem)
        map.bind(KeyStroke(KeyChord(code: 0x76 /* F4 */, .shift)), to: .goToPreviousProblem)
        bindFoldingChords(&map)
        bindSourceChangeKeys(&map)
        return map
    }()

    /// F7 and ⇧F7 walk the gutter's change stripes.
    ///
    /// These are keymap bindings, not menu shortcuts. A menu key equivalent runs before the diff
    /// view, and that view already uses F7 to move between its own hunks. IntelliJ's menu uses F7
    /// for Step Into and ⇧F7 for Smart Step Into, so that preset keeps ⌃⌥⇧↓ and ⌃⌥⇧↑.
    private static func bindSourceChangeKeys(_ map: inout Keymap) {
        map.bind(KeyStroke(KeyChord(code: 0x62 /* F7 */)), to: .nextChange)
        map.bind(KeyStroke(KeyChord(code: 0x62 /* F7 */, .shift)), to: .previousChange)
    }

    /// Fold and unfold: ⌥⌘[ / ⌥⌘] for the region at the caret (Sublime, VS Code), and ⌘K chords for
    /// the rest.
    ///
    /// The second key of a chord is a ⌘ key, and a menu key equivalent is handled before the editor
    /// sees it, so it must not also be a menu shortcut. Umbra's Sublime and Default menus use ⌘0
    /// (sidebar), ⌘[ and ⌘] (Back, Forward), which is why those two get ⌘K ⌘1 / ⌘K ⌘J (Sublime's
    /// own fold-level-1 and unfold-all) and no recursive chords; VS Code's menu column moves those
    /// three keys away, so it gets VS Code's ⌘K ⌘0, ⌘K ⌘J, ⌘K ⌘[ and ⌘K ⌘].
    private static func bindFoldingChords(_ map: inout Keymap, vsCodeChords: Bool = false) {
        map.bind(KeyStroke(KeyChord(code: 0x21 /* [ */, [.command, .option])), to: .collapseRegion)
        map.bind(KeyStroke(KeyChord(code: 0x1E /* ] */, [.command, .option])), to: .expandRegion)
        map.bind(KeyStroke(KeyChord("k", .command), KeyChord("j", .command)), to: .expandAllRegions)
        if vsCodeChords {
            map.bind(KeyStroke(KeyChord("k", .command), KeyChord("0", .command)), to: .collapseAllRegions)
            map.bind(KeyStroke(KeyChord("k", .command), KeyChord(code: 0x21 /* [ */, .command)), to: .collapseRegionRecursively)
            map.bind(KeyStroke(KeyChord("k", .command), KeyChord(code: 0x1E /* ] */, .command)), to: .expandRegionRecursively)
        } else {
            map.bind(KeyStroke(KeyChord("k", .command), KeyChord("1", .command)), to: .collapseAllRegions)
        }
    }

    /// IntelliJ IDEA's macOS keymap for the actions Penumbra implements. Starts from
    /// ``default_`` and overrides the conflicting bindings (⌥↑/↓, ⌘⇧L, …).
    static let intelliJ: Keymap = {
        var map = Keymap.historical

        // ⌘K is Commit in IntelliJ (Umbra shows the Changes sidebar from its menu), so it can't
        // also be the prefix of the ⌘K ⌘D chord, which a menu key equivalent would shadow anyway.
        map.unbindAll(.skipCurrentOccurrence)

        // Go to File is also double-Shift, handled out of band by DoubleModifierDetector.
        map.bind(KeyStroke(KeyChord("a", [.command, .shift])), to: .findAction)
        map.bind(KeyStroke(KeyChord("o", [.command, .shift])), to: .quickOpenFile)
        map.bind(KeyStroke(KeyChord("e", .command)), to: .recentFiles)
        map.bind(KeyStroke(KeyChord("e", [.command, .shift])), to: .recentLocations)
        map.bind(KeyStroke(KeyChord("f", [.command, .shift])), to: .findInFiles)
        map.bind(KeyStroke(KeyChord("g", .command)), to: .findNext)
        map.bind(KeyStroke(KeyChord("g", [.command, .shift])), to: .findPrevious)
        map.bind(KeyStroke(KeyChord("o", [.command, .option])), to: .goToSymbol)

        // Navigation
        map.unbindAll(.selectLines)
        map.bind(KeyStroke(KeyChord("l", .command)), to: .goToLine)
        map.bind(KeyStroke(KeyChord("b", .command)), to: .toggleMarkdownPreview)
        map.bind(KeyStroke(KeyChord(code: 0x6F /* F12 */)), to: .goToDefinition)
        map.bind(KeyStroke(KeyChord("b", [.command, .option])), to: .goToImplementation)
        map.bind(KeyStroke(KeyChord("b", [.control, .shift])), to: .goToTypeDefinition)
        map.bind(KeyStroke(KeyChord("b", [.command, .option, .shift])), to: .findUsages)
        // ⌘U is Go to Super Method in IntelliJ, so it replaces the default keymap's
        // Undo Last Caret Change binding (still reachable through Find Action).
        map.unbindAll(.undoLastCaretChange)
        map.bind(KeyStroke(KeyChord("u", .command)), to: .goToSuperMethod)
        map.bind(KeyStroke(KeyChord(code: 0x21 /* [ */, .command)), to: .navigateBack)
        map.bind(KeyStroke(KeyChord(code: 0x1E /* ] */, .command)), to: .navigateForward)
        map.bind(KeyStroke(KeyChord(code: 0x33 /* ⌫ */, [.command, .shift])), to: .lastEditLocation)
        map.bind(KeyStroke(KeyChord(code: 0x7D /* ↓ */, .control)), to: .nextMethod)
        map.bind(KeyStroke(KeyChord(code: 0x7E /* ↑ */, .control)), to: .previousMethod)
        map.bind(KeyStroke(KeyChord(code: 0x7D /* ↓ */, [.control, .option, .shift])), to: .nextChange)
        map.bind(KeyStroke(KeyChord(code: 0x7E /* ↑ */, [.control, .option, .shift])), to: .previousChange)
        map.bind(KeyStroke(KeyChord(code: 0x21 /* [ */, [.command, .option])), to: .moveToCodeBlockStart)
        map.bind(KeyStroke(KeyChord(code: 0x1E /* ] */, [.command, .option])), to: .moveToCodeBlockEnd)
        map.bind(KeyStroke(KeyChord(code: 0x21 /* [ */, [.command, .option, .shift])), to: .selectToCodeBlockStart)
        map.bind(KeyStroke(KeyChord(code: 0x1E /* ] */, [.command, .option, .shift])), to: .selectToCodeBlockEnd)
        map.bind(KeyStroke(KeyChord(code: 0x78 /* F2 */)), to: .goToNextProblem)
        map.bind(KeyStroke(KeyChord(code: 0x78 /* F2 */, .shift)), to: .goToPreviousProblem)

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
        map.bind(KeyStroke(KeyChord("g", [.control, .shift])), to: .unselectLastOccurrence)
        map.bind(KeyStroke(KeyChord("m", .control)), to: .goToMatchingBracket)
        map.bind(KeyStroke(KeyChord("g", [.control, .command])), to: .selectAllOccurrences)
        map.bind(KeyStroke(KeyChord("8", [.command, .shift])), to: .toggleColumnSelectionMode)

        // Editing
        map.bind(KeyStroke(KeyChord("/", [.command, .option])), to: .toggleBlockComment)
        map.bind(KeyStroke(KeyChord(code: 0x24, .shift)), to: .startNewLine)
        map.bind(KeyStroke(KeyChord(code: 0x24, [.command, .shift])), to: .completeStatement)
        // IntelliJ's Start New Line Before Current is ⌥⌘↵. ⌘↵ / ⇧⌘↵ (the default keymap's line
        // inserts) go unbound; ⇧⌘↵ is Complete Current Statement there.
        map.unbindAll(.insertLineBelow)
        map.unbindAll(.insertLineAbove)
        map.bind(KeyStroke(KeyChord(code: 0x24, [.command, .option])), to: .insertLineAbove)
        map.bind(KeyStroke(KeyChord("j", [.control, .shift])), to: .joinLines)
        map.bind(KeyStroke(KeyChord("t", [.command, .option])), to: .surroundWith)
        map.bind(KeyStroke(KeyChord("l", [.command, .option])), to: .reformatCode)
        map.bind(KeyStroke(KeyChord("d", .command)), to: .duplicateLines)
        map.bind(KeyStroke(KeyChord("o", [.control, .option])), to: .optimizeImports)
        map.bind(KeyStroke(KeyChord("j", .control)), to: .quickDocumentation)
        map.bind(KeyStroke(KeyChord("j", .command)), to: .insertLiveTemplate)
        map.bind(KeyStroke(KeyChord("p", .command)), to: .showParameterInfo)
        map.bind(KeyStroke(KeyChord("h", .control)), to: .typeHierarchy)
        map.bind(KeyStroke(KeyChord("h", [.command, .shift])), to: .methodHierarchy)
        map.bind(KeyStroke(KeyChord("h", [.control, .option])), to: .callHierarchy)
        map.bind(KeyStroke(KeyChord(code: 0x61 /* F6 */, .shift)), to: .rename)
        map.bind(KeyStroke(KeyChord("v", [.command, .option])), to: .extractVariable)
        map.bind(KeyStroke(KeyChord("f", [.command, .option, .shift])), to: .extractField)
        map.bind(KeyStroke(KeyChord("c", [.command, .option])), to: .extractConstant)
        map.bind(KeyStroke(KeyChord("m", [.command, .option])), to: .extractMethod)
        map.bind(KeyStroke(KeyChord("n", [.command, .option])), to: .inlineVariable)
        map.bind(KeyStroke(KeyChord("e", [.command, .option])), to: .encapsulateField)
        map.bind(KeyStroke(KeyChord(code: 0x61 /* F6 */, .control)), to: .changeSignature)

        // Code folding
        map.bind(KeyStroke(KeyChord("-", .command)), to: .collapseRegion)
        map.bind(KeyStroke(KeyChord("=", .command)), to: .expandRegion)
        map.bind(KeyStroke(KeyChord("-", [.command, .shift])), to: .collapseAllRegions)
        map.bind(KeyStroke(KeyChord("=", [.command, .shift])), to: .expandAllRegions)
        map.bind(KeyStroke(KeyChord("-", [.command, .option])), to: .collapseRegionRecursively)
        map.bind(KeyStroke(KeyChord("=", [.command, .option])), to: .expandRegionRecursively)

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

        // ⌘G is Go to Line here, so Find Next / Previous take ⌥⌘G / ⇧⌥⌘G rather than ⌘G / ⇧⌘G.
        map.unbindAll(.findPrevious)
        map.bind(KeyStroke(KeyChord("g", [.command, .option])), to: .findNext)
        map.bind(KeyStroke(KeyChord("g", [.command, .option, .shift])), to: .findPrevious)

        return map
    }()

    /// Visual Studio Code's macOS keys for the actions Penumbra implements (F28). Starts from
    /// nothing, not from ``default_``: VS Code shares few of its keys.
    static let vsCode: Keymap = {
        var map = Keymap()
        // Find and navigate.
        map.bind(KeyStroke(KeyChord("f", .command)), to: .toggleFindPanel)
        map.bind(KeyStroke(KeyChord("f", [.command, .option])), to: .toggleReplacePanel)
        map.bind(KeyStroke(KeyChord("g", .command)), to: .findNext)
        map.bind(KeyStroke(KeyChord("g", [.command, .shift])), to: .findPrevious)
        map.bind(KeyStroke(KeyChord("f", [.command, .shift])), to: .findInFiles)
        map.bind(KeyStroke(KeyChord("p", .command)), to: .quickOpenFile)
        map.bind(KeyStroke(KeyChord("p", [.command, .shift])), to: .findAction)
        map.bind(KeyStroke(KeyChord("e", .command)), to: .recentFiles)
        map.bind(KeyStroke(KeyChord("g", .control)), to: .goToLine)
        map.bind(KeyStroke(KeyChord("t", .command)), to: .goToSymbol)
        map.bind(KeyStroke(KeyChord("o", [.command, .shift])), to: .goToFileSymbol)
        map.bind(KeyStroke(KeyChord(code: 0x6F /* F12 */)), to: .goToDefinition)
        map.bind(KeyStroke(KeyChord(code: 0x6F /* F12 */, .command)), to: .goToImplementation)
        map.bind(KeyStroke(KeyChord(code: 0x6F /* F12 */, .shift)), to: .findUsages)
        map.bind(KeyStroke(KeyChord("-", .control)), to: .navigateBack)
        map.bind(KeyStroke(KeyChord("-", [.control, .shift])), to: .navigateForward)
        map.bind(KeyStroke(KeyChord(code: 0x64 /* F8 */)), to: .goToNextProblem)
        map.bind(KeyStroke(KeyChord(code: 0x64 /* F8 */, .shift)), to: .goToPreviousProblem)
        map.bind(KeyStroke(KeyChord("\\", [.command, .shift])), to: .goToMatchingBracket)
        // Code intelligence.
        map.bind(KeyStroke(KeyChord(code: 0x31, .control)), to: .triggerCompletion)
        map.bind(KeyStroke(KeyChord(code: 0x31, [.command, .shift])), to: .showParameterInfo)
        map.bind(KeyStroke(KeyChord(".", .command)), to: .showContextActions)
        map.bind(KeyStroke(KeyChord(code: 0x78 /* F2 */)), to: .rename)
        map.bind(KeyStroke(KeyChord("f", [.option, .shift])), to: .reformatCode)
        map.bind(KeyStroke(KeyChord("o", [.option, .shift])), to: .optimizeImports)
        map.bind(KeyStroke(KeyChord("k", .command), KeyChord("i", .command)), to: .quickDocumentation)
        map.bind(KeyStroke(KeyChord("h", [.option, .shift])), to: .callHierarchy)
        // Editing.
        map.bind(KeyStroke(KeyChord("/", .command)), to: .toggleComment)
        map.bind(KeyStroke(KeyChord("a", [.option, .shift])), to: .toggleBlockComment)
        map.bind(KeyStroke(KeyChord(code: 0x7E, .option)), to: .moveLineUp)
        map.bind(KeyStroke(KeyChord(code: 0x7D, .option)), to: .moveLineDown)
        map.bind(KeyStroke(KeyChord(code: 0x7D, [.option, .shift])), to: .duplicateLines)
        map.bind(KeyStroke(KeyChord("k", [.command, .shift])), to: .deleteLines)
        map.bind(KeyStroke(KeyChord(code: 0x24, .command)), to: .insertLineBelow)
        map.bind(KeyStroke(KeyChord(code: 0x24, [.command, .shift])), to: .insertLineAbove)
        map.bind(KeyStroke(KeyChord("j", .control)), to: .joinLines)
        map.bind(KeyStroke(KeyChord("l", .command)), to: .selectLines)
        map.bind(KeyStroke(KeyChord(code: 0x21 /* [ */, .command)), to: .outdentLines)
        map.bind(KeyStroke(KeyChord(code: 0x1E /* ] */, .command)), to: .indentLines)
        // Selection and carets.
        map.bind(KeyStroke(KeyChord("d", .command)), to: .selectNextOccurrence)
        map.bind(KeyStroke(KeyChord("k", .command), KeyChord("d", .command)), to: .skipCurrentOccurrence)
        map.bind(KeyStroke(KeyChord("l", [.command, .shift])), to: .selectAllOccurrences)
        map.bind(KeyStroke(KeyChord(code: 0x7E, [.command, .option])), to: .addCaretAbove)
        map.bind(KeyStroke(KeyChord(code: 0x7D, [.command, .option])), to: .addCaretBelow)
        map.bind(KeyStroke(KeyChord("u", .command)), to: .undoLastCaretChange)
        map.bind(KeyStroke(KeyChord(code: 0x7C, [.control, .shift, .command])), to: .expandSelection)
        map.bind(KeyStroke(KeyChord(code: 0x7B, [.control, .shift, .command])), to: .shrinkSelection)
        map.bind(KeyStroke(KeyChord("v", [.command, .shift])), to: .toggleMarkdownPreview)
        // Folding: ⌥⌘[ / ⌥⌘] at the caret, ⌘K chords for the rest.
        bindFoldingChords(&map, vsCodeChords: true)
        bindSourceChangeKeys(&map)
        return map
    }()
}
