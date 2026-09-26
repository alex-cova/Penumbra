import Foundation

/// Identifies an editor action that a keystroke can be bound to.
///
/// Actions are the stable vocabulary shared by ``Keymap`` (keystroke → action), the
/// command palette's "Find Action" mode (action → keystroke, via ``Keymap/stroke(for:)``),
/// and ``TextView/perform(_:)`` (action → behavior). Host apps can define their own IDs with
/// ``init(_:)`` and handle them through ``TextView/editorActionHandler``.
public struct EditorActionID: Hashable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    /// A short, human-readable title, shown by the command palette's "Find Action" mode.
    /// Falls back to a spaced-out form of ``rawValue`` for host-defined actions.
    public var title: String {
        Self.builtInTitles[self] ?? Self.humanized(rawValue)
    }

    private static func humanized(_ raw: String) -> String {
        var result = ""
        for character in raw {
            if character.isUppercase, !result.isEmpty {
                result.append(" ")
            }
            result.append(character)
        }
        return result.prefix(1).uppercased() + result.dropFirst()
    }
}

public extension EditorActionID {
    // Selection & multi-caret
    static let selectLines = EditorActionID("selectLines")
    static let selectNextOccurrence = EditorActionID("selectNextOccurrence")
    static let selectAllOccurrences = EditorActionID("selectAllOccurrences")
    static let skipCurrentOccurrence = EditorActionID("skipCurrentOccurrence")
    static let addCaretsToLineEnds = EditorActionID("addCaretsToLineEnds")
    static let addCaretAbove = EditorActionID("addCaretAbove")
    static let addCaretBelow = EditorActionID("addCaretBelow")
    static let undoLastCaretChange = EditorActionID("undoLastCaretChange")
    static let expandSelection = EditorActionID("expandSelection")
    static let shrinkSelection = EditorActionID("shrinkSelection")
    static let toggleColumnSelectionMode = EditorActionID("toggleColumnSelectionMode")

    // Line & block editing
    static let duplicateLines = EditorActionID("duplicateLines")
    static let deleteLines = EditorActionID("deleteLines")
    static let moveLineUp = EditorActionID("moveLineUp")
    static let moveLineDown = EditorActionID("moveLineDown")
    static let moveStatementUp = EditorActionID("moveStatementUp")
    static let moveStatementDown = EditorActionID("moveStatementDown")
    static let joinLines = EditorActionID("joinLines")
    static let surroundWith = EditorActionID("surroundWith")
    static let indentLines = EditorActionID("indentLines")
    static let outdentLines = EditorActionID("outdentLines")
    static let reformatCode = EditorActionID("reformatCode")
    static let toggleComment = EditorActionID("toggleComment")
    static let insertLineAbove = EditorActionID("insertLineAbove")
    static let insertLineBelow = EditorActionID("insertLineBelow")
    static let sortLinesAscending = EditorActionID("sortLinesAscending")
    static let sortLinesDescending = EditorActionID("sortLinesDescending")

    // View
    static let toggleMethodSeparators = EditorActionID("toggleMethodSeparators")
    static let toggleOccurrenceHighlighting = EditorActionID("toggleOccurrenceHighlighting")

    // Find
    static let toggleFindPanel = EditorActionID("toggleFindPanel")
    static let toggleReplacePanel = EditorActionID("toggleReplacePanel")
    /// Disk-wide project search. Presented by the command palette; hosts supply the search
    /// backend via ``EditorIntelligenceController``.
    static let findInFiles = EditorActionID("findInFiles")

    // Palette / navigation
    static let searchEverywhere = EditorActionID("searchEverywhere")
    static let findAction = EditorActionID("findAction")
    static let quickOpenFile = EditorActionID("quickOpenFile")
    static let recentFiles = EditorActionID("recentFiles")
    static let recentLocations = EditorActionID("recentLocations")
    static let goToSymbol = EditorActionID("goToSymbol")
    static let goToLine = EditorActionID("goToLine")
    static let toggleMarkdownPreview = EditorActionID("toggleMarkdownPreview")
    static let goToDefinition = EditorActionID("goToDefinition")
    static let goToImplementation = EditorActionID("goToImplementation")
    static let goToSuperMethod = EditorActionID("goToSuperMethod")
    static let findUsages = EditorActionID("findUsages")
    static let navigateBack = EditorActionID("navigateBack")
    static let navigateForward = EditorActionID("navigateForward")
    /// Show completions at the caret. Bound to Control-Space in the shipped keymaps.
    static let triggerCompletion = EditorActionID("triggerCompletion")
    /// Shows the documentation of the symbol at the caret right away (F1, ⌃J), instead of waiting
    /// for the caret to rest.
    static let quickDocumentation = EditorActionID("quickDocumentation")
    /// Shows the supertype/subtype hierarchy of the type at the caret (⌃H in the IntelliJ keymap).
    /// The host presents it: see ``EditorIntelligenceController/onRequestTypeHierarchy``.
    static let typeHierarchy = EditorActionID("typeHierarchy")
    /// Quick fixes and refactorings at the caret. Bound to Option-Return.
    static let showContextActions = EditorActionID("showContextActions")
    /// Removes unused imports and sorts the rest (and whatever else the language's organize-imports action does).
    static let optimizeImports = EditorActionID("optimizeImports")
    /// Renames the symbol at the caret across the project, after a preview. Bound to ⇧F6 in the
    /// IntelliJ keymap; needs a ``RenameProviding`` and the host hooks on
    /// ``EditorIntelligenceController`` (`onRequestRename`, `onPresentRenamePlan`).
    static let rename = EditorActionID("rename")
    /// Extracts the selected expression into a local variable. Bound to ⌥⌘V in the IntelliJ keymap.
    static let extractVariable = EditorActionID("extractVariable")
    /// Extracts the selected expression into an instance field (⌥⌘F in the IntelliJ keymap).
    static let extractField = EditorActionID("extractField")
    /// Extracts the selected expression into a static final constant (⌥⌘C in the IntelliJ keymap).
    static let extractConstant = EditorActionID("extractConstant")
    /// Extracts the selection into a new private method (⌥⌘M in the IntelliJ keymap).
    static let extractMethod = EditorActionID("extractMethod")
    /// Inlines a local variable at the caret (⌥⌘N in the IntelliJ keymap).
    static let inlineVariable = EditorActionID("inlineVariable")
    /// Inlines a private method at the caret (⌥⌘N in the IntelliJ keymap).
    static let inlineMethod = EditorActionID("inlineMethod")
    /// Changes the method signature at the caret (⌃F6 in the IntelliJ keymap).
    static let changeSignature = EditorActionID("changeSignature")
    /// Encapsulates the field at the caret (⌥⌘E in the IntelliJ keymap).
    static let encapsulateField = EditorActionID("encapsulateField")
    /// Inserts getter/setter methods for the field at the caret.
    static let generateAccessors = EditorActionID("generateAccessors")
    /// Moves the top-level class at the caret to another package (F6 in the IntelliJ keymap).
    static let moveClass = EditorActionID("moveClass")
    /// Deletes the symbol at the caret when it has no usages.
    static let safeDelete = EditorActionID("safeDelete")
    /// Completions of the expected type. Bound to Control-Shift-Space.
    static let triggerSmartCompletion = EditorActionID("triggerSmartCompletion")

    internal static let builtInTitles: [EditorActionID: String] = [
        .selectLines: "Select Line(s)",
        .selectNextOccurrence: "Select Next Occurrence",
        .selectAllOccurrences: "Select All Occurrences",
        .skipCurrentOccurrence: "Skip Current Occurrence",
        .addCaretsToLineEnds: "Add Carets to Line Ends",
        .addCaretAbove: "Add Caret Above",
        .addCaretBelow: "Add Caret Below",
        .undoLastCaretChange: "Undo Last Caret Change",
        .expandSelection: "Extend Selection",
        .shrinkSelection: "Shrink Selection",
        .toggleColumnSelectionMode: "Column Selection Mode",
        .duplicateLines: "Duplicate Line(s)",
        .deleteLines: "Delete Line(s)",
        .moveLineUp: "Move Line Up",
        .moveLineDown: "Move Line Down",
        .moveStatementUp: "Move Statement Up",
        .moveStatementDown: "Move Statement Down",
        .joinLines: "Join Lines",
        .surroundWith: "Surround With…",
        .indentLines: "Indent Line(s)",
        .outdentLines: "Unindent Line(s)",
        .reformatCode: "Reformat Code",
        .toggleComment: "Toggle Line Comment",
        .insertLineAbove: "Insert Line Above",
        .insertLineBelow: "Insert Line Below",
        .sortLinesAscending: "Sort Lines Ascending",
        .sortLinesDescending: "Sort Lines Descending",
        .toggleMethodSeparators: "Method Separators",
        .toggleOccurrenceHighlighting: "Highlight Occurrences of Selection",
        .toggleFindPanel: "Find…",
        .toggleReplacePanel: "Replace…",
        .findInFiles: "Find in Files…",
        .searchEverywhere: "Search Everywhere",
        .findAction: "Find Action…",
        .quickOpenFile: "Go to File…",
        .recentFiles: "Recent Files",
        .recentLocations: "Recent Locations",
        .goToSymbol: "Go to Symbol…",
        .goToLine: "Go to Line…",
        .toggleMarkdownPreview: "Markdown Preview",
        .goToDefinition: "Go to Definition",
        .goToImplementation: "Go to Implementation(s)",
        .goToSuperMethod: "Go to Super Method",
        .findUsages: "Find Usages",
        .navigateBack: "Back",
        .navigateForward: "Forward",
        .triggerCompletion: "Complete",
        .triggerSmartCompletion: "Smart Type Completion",
        .rename: "Rename…",
        .extractVariable: "Extract Variable…",
        .extractField: "Extract Field…",
        .extractConstant: "Extract Constant…",
        .extractMethod: "Extract Method…",
        .inlineVariable: "Inline Variable",
        .inlineMethod: "Inline Method",
        .changeSignature: "Change Method Signature…",
        .encapsulateField: "Encapsulate Field",
        .generateAccessors: "Generate Getter and Setter",
        .moveClass: "Move Class…",
        .safeDelete: "Safe Delete",
        .typeHierarchy: "Type Hierarchy",
        .quickDocumentation: "Quick Documentation",
        .showContextActions: "Show Context Actions",
        .optimizeImports: "Optimize Imports"
    ]
}
