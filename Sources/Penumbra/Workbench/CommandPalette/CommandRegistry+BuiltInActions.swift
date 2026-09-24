@preconcurrency import AppKit

public extension CommandRegistry {
    /// The actions offered by "Find Action" in the default build: every ``EditorActionID`` with
    /// a built-in title. Navigation/palette actions are included so a host that wires
    /// ``TextView/editorActionHandler`` gets them too.
    static let findActionIDs: [EditorActionID] = [
        .expandSelection, .shrinkSelection, .selectLines, .selectNextOccurrence,
        .selectAllOccurrences, .skipCurrentOccurrence, .addCaretsToLineEnds,
        .addCaretAbove, .addCaretBelow, .undoLastCaretChange, .toggleColumnSelectionMode,
        .duplicateLines, .deleteLines, .moveLineUp, .moveLineDown,
        .moveStatementUp, .moveStatementDown, .joinLines, .surroundWith,
        .indentLines, .outdentLines, .reformatCode,
        .toggleComment, .insertLineAbove, .insertLineBelow,
        .sortLinesAscending, .sortLinesDescending,
        .toggleMethodSeparators, .toggleOccurrenceHighlighting,
        .toggleFindPanel, .toggleReplacePanel, .findInFiles,
        .searchEverywhere, .findAction, .quickOpenFile, .recentFiles, .goToSymbol, .goToLine,
        .toggleMarkdownPreview,
        .goToDefinition, .goToImplementation, .findUsages, .navigateBack, .navigateForward,
        .triggerCompletion, .triggerSmartCompletion,
        .quickDocumentation, .showContextActions, .optimizeImports
    ]

    /// Registers one command per ``findActionIDs`` entry, each performing the action through
    /// `textView` and displaying its current shortcut from `textView.keymap`.
    func registerBuiltInActions(for textView: TextView, group: String = "Editor") {
        for id in Self.findActionIDs {
            let shortcut = textView.keymap.stroke(for: id)?.displayString
            register(EditorCommand(
                id: "action.\(id.rawValue)",
                title: id.title,
                group: group,
                shortcutDisplay: shortcut,
                action: { [weak textView] in textView?.perform(id) }
            ))
        }
    }
}
