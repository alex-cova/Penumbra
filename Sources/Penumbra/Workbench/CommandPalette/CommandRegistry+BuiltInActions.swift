@preconcurrency import AppKit

public extension CommandRegistry {
    /// The actions offered by "Find Action" in the default build: every ``EditorActionID`` with
    /// a built-in title. Navigation/palette actions are included so a host that wires
    /// ``TextView/editorActionHandler`` gets them too.
    static let findActionIDs: [EditorActionID] = [
        .expandSelection, .shrinkSelection, .selectLines, .selectNextOccurrence,
        .selectAllOccurrences, .skipCurrentOccurrence, .addCaretsToLineEnds,
        .addCaretAbove, .addCaretBelow, .undoLastCaretChange, .unselectLastOccurrence,
        .goToMatchingBracket, .toggleColumnSelectionMode,
        .duplicateLines, .deleteLines, .moveLineUp, .moveLineDown,
        .moveStatementUp, .moveStatementDown, .joinLines, .surroundWith,
        .indentLines, .outdentLines, .reformatCode,
        .toggleComment, .toggleBlockComment, .insertLineAbove, .insertLineBelow, .startNewLine, .completeStatement,
        .sortLinesAscending, .sortLinesDescending, .toggleCase,
        .toggleMethodSeparators, .toggleOccurrenceHighlighting,
        .collapseRegion, .expandRegion, .collapseAllRegions, .expandAllRegions,
        .collapseRegionRecursively, .expandRegionRecursively,
        .toggleFindPanel, .toggleReplacePanel, .findNext, .findPrevious, .findInFiles,
        .searchEverywhere, .findAction, .quickOpenFile, .recentFiles, .recentLocations, .goToSymbol, .goToFileSymbol, .goToTool, .goToLine,
        .toggleMarkdownPreview,
        .goToDefinition, .goToImplementation, .goToSuperMethod, .goToTypeDefinition, .findUsages, .goToNextProblem, .goToPreviousProblem, .navigateBack, .navigateForward,
        .triggerCompletion, .triggerSmartCompletion,
        .quickDocumentation, .showParameterInfo, .showContextActions, .optimizeImports,
        .rename,
        .extractVariable, .extractField, .extractConstant, .extractMethod,
        .inlineVariable, .inlineMethod,
        .changeSignature, .encapsulateField, .generateAccessors, .generate,
        .moveClass, .safeDelete,
        .typeHierarchy
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
