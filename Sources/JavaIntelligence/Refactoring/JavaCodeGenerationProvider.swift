import EditorIntelligence
import Foundation

/// "Generate…" for Java files: constructor, getters and setters, `toString()`.
public struct JavaCodeGenerationProvider: CodeGenerationProviding {
    public init() {}

    public func generationMenu(_ context: RefactoringContext) async -> CodeGenerationMenu? {
        guard context.document.languageIdentifier == "java" else { return nil }
        let source = JavaRefactoringText.fullText(of: context.document)
        guard let menu = JavaGenerateMembers.menu(source: source, caretUTF16: context.cursor.position.utf16Offset),
              !menu.options.isEmpty else { return nil }
        return menu
    }

    public func generate(
        _ kind: CodeGenerationKind, fieldNames: [String], context: RefactoringContext
    ) async -> WorkspaceEditPlan {
        let title = "Generate"
        guard context.document.languageIdentifier == "java" else {
            return WorkspaceEditPlan(blockingError: "Generate is only available in Java files.", title: title)
        }
        guard let url = context.documentURL ?? context.document.url else {
            return WorkspaceEditPlan(blockingError: "Save the file before generating code.", title: title)
        }
        let source = JavaRefactoringText.fullText(of: context.document)
        return JavaGenerateMembers.plan(
            kind: kind, fieldNames: fieldNames, source: source, url: url,
            caretUTF16: context.cursor.position.utf16Offset
        )
    }
}
