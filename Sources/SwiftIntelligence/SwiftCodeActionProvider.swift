import EditorIntelligence
import Foundation

/// The native Swift code actions: the quick fixes of the inspections at the caret
/// (``SwiftInspectionService``), the syntax-only refactorings that need no name or choice (add an explicit type,
/// `if let` ↔ `guard let`, inline a constant, move a member to an extension, introduce a variable for the
/// selection under a suggested name) and organize imports, which SourceKit-LSP does not provide.
public struct SwiftCodeActionProvider: CodeActionProviding {
    private let inspections: SwiftInspectionService?

    public init(inspections: SwiftInspectionService? = nil) {
        self.inspections = inspections
    }

    public func codeActions(
        for document: Document,
        at position: TextPosition,
        diagnostics: [Diagnostic]
    ) async -> [CodeAction] {
        guard document.languageIdentifier == SwiftAnalysis.languageIdentifier else { return [] }
        var actions = inspections?.codeActions(for: document, at: position) ?? []
        actions += Self.refactorings(in: document, at: position)
        let edits = SwiftImportOrganizer.edits(in: document.text)
        if !edits.isEmpty {
            actions.append(CodeAction(title: "Organize Imports", kind: CodeAction.organizeImportsKind, edits: edits))
        }
        return actions
    }

    /// ⌥↩ refactorings at the caret or the selection. Each is computed, so one that does not apply is simply absent.
    static func refactorings(in document: Document, at position: TextPosition) -> [CodeAction] {
        guard let text = SwiftRefactoringProvider.text(of: document) else { return [] }
        let map = SourceTextMap(text)
        let caret = map.byteOffset(utf16: position.utf16Offset)
        var actions: [CodeAction] = []
        func add(_ title: String, _ result: SwiftRefactoringResult) {
            guard case .success(let edits) = result, !edits.isEmpty else { return }
            actions.append(CodeAction(
                title: title, kind: "refactor.rewrite",
                edits: edits.map { TextEdit(range: map.range(bytes: $0.bytes), replacement: $0.replacement) }
            ))
        }
        if let selection = SwiftRefactoringProvider.selectionBytes(document.selection, map: map),
           let name = SwiftIntroduceVariable.suggestedName(in: text, selection: selection) {
            add("Introduce variable '\(name)'", SwiftIntroduceVariable.edits(in: text, selection: selection, name: name))
        }
        add("Inline variable", SwiftInlineVariable.edits(in: text, caret: caret))
        add("Add explicit type", SwiftAddExplicitType.edits(in: text, caret: caret))
        add("Move to extension", SwiftMoveToExtension.edits(in: text, caret: caret))
        if let direction = SwiftConditionalConversion.available(in: text, caret: caret) {
            add(direction == .ifToGuard ? "Convert to guard" : "Convert to if", SwiftConditionalConversion.edits(in: text, caret: caret))
        }
        return actions
    }
}
