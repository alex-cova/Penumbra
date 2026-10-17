import EditorIntelligence
import Foundation

/// Mutable settings shared between a controller and its command provider on a shared engine.
public final class CommandCompletionSettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CommandCompletionSettings

    public init(_ value: CommandCompletionSettings = .standard) { self.value = value }

    public var settings: CommandCompletionSettings {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// Generic command completion: refactorings, quick fixes, Generate… and fixed editor
/// actions, offered as a `Commands` section after `..` (commands only), after a single `.`
/// (a section under the regular items) and in read-only files (navigation only).
public struct EditorCommandCompletionProvider: CommandCompletionProviding {
    public let name = "Commands"
    private let refactoringProvider: (any RefactoringProviding)?
    private let codeActionProvider: (any CodeActionProviding)?
    private let codeGenerationProvider: (any CodeGenerationProviding)?
    private let settingsBox: CommandCompletionSettingsBox

    public init(
        refactoringProvider: (any RefactoringProviding)? = nil,
        codeActionProvider: (any CodeActionProviding)? = nil,
        codeGenerationProvider: (any CodeGenerationProviding)? = nil,
        settingsBox: CommandCompletionSettingsBox = CommandCompletionSettingsBox()
    ) {
        self.refactoringProvider = refactoringProvider
        self.codeActionProvider = codeActionProvider
        self.codeGenerationProvider = codeGenerationProvider
        self.settingsBox = settingsBox
    }

    /// Editor actions offered in an editable file.
    static let editableActions: [EditorActionID] = [
        .rename, .goToDefinition, .goToImplementation, .goToTypeDefinition, .findUsages,
        .typeHierarchy, .quickDocumentation, .showParameterInfo, .reformatCode,
        .toggleComment, .surroundWith, .optimizeImports
    ]

    /// Navigation-only actions offered in a read-only file, plus Copy Reference.
    static let readOnlyActions: [EditorActionID] = [
        .goToDefinition, .goToImplementation, .goToTypeDefinition, .findUsages,
        .typeHierarchy, .quickDocumentation, .copyReference
    ]

    public func commandItems(context: CompletionContext) async -> [CompletionItem] {
        let settings = settingsBox.settings
        guard settings.isEnabled else { return [] }
        if context.commandMode == .singleDot, !settings.showsSeparateGroup { return [] }
        if context.commandMode == .readOnly, !settings.readOnlyEnabled { return [] }

        func item(_ action: EditorActionID, detail: String? = nil) -> CompletionItem {
            CompletionItem(
                label: action.title, insertText: "", kind: .command, range: context.range,
                source: name, detail: detail, allowsAutoInsert: false,
                command: .editorAction(id: action.rawValue, selecting: nil), section: .commands
            )
        }

        if context.commandMode == .readOnly {
            return Self.readOnlyActions.map { item($0) }
        }

        var items: [CompletionItem] = []
        let refactoringContext = RefactoringContext(
            document: context.document, cursor: context.cursor, selection: context.document.selection
        )
        if let refactoringProvider {
            for descriptor in await refactoringProvider.availableRefactorings(refactoringContext) {
                items.append(CompletionItem(
                    label: descriptor.title, insertText: "", kind: .command, range: context.range,
                    source: name, allowsAutoInsert: false,
                    command: .editorAction(id: descriptor.id.rawValue, selecting: nil), section: .commands
                ))
            }
        }
        if let codeActionProvider {
            for action in await codeActionProvider.codeActions(
                for: context.document, at: context.cursor.position, diagnostics: []
            ) {
                items.append(CompletionItem(
                    label: action.title, insertText: "", kind: .command, range: context.range,
                    source: name, documentation: Self.preview(of: action, in: context.document),
                    allowsAutoInsert: false, command: .codeAction(action), section: .commands
                ))
            }
        }
        if let codeGenerationProvider, await codeGenerationProvider.generationMenu(refactoringContext) != nil {
            items.append(item(.generate))
        }
        // Refactoring items above already cover extract/inline/…; the fixed list adds the rest.
        let covered = Set(items.compactMap { item -> String? in
            if case .editorAction(let id, _) = item.command { return id }
            return nil
        })
        items += Self.editableActions.filter { !covered.contains($0.rawValue) }.map { item($0) }
        return items
    }

    /// A short before/after preview of a code action's edits, shown in the documentation pane.
    static func preview(of action: CodeAction, in document: Document) -> String? {
        guard !action.edits.isEmpty else { return nil }
        var lines = [action.title]
        for edit in action.edits.prefix(6) {
            let range = edit.range
            let length = max(0, range.end.utf16Offset - range.start.utf16Offset)
            let before = document.substring(utf16Offset: range.start.utf16Offset, length: length)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let after = edit.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty { lines.append("- \(before)") }
            if !after.isEmpty { lines.append("+ \(after)") }
        }
        return lines.count > 1 ? lines.joined(separator: "\n") : nil
    }
}
