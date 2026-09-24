import EditorIntelligence
import Foundation

enum JavaExtractField {
    static func suggestedName(
        source: String, selection: Selection, url: URL, index: JavaIndex
    ) async -> String? {
        JavaExtractExpression.suggestedName(source: source, selection: selection, url: url)
    }

    static func plan(
        source: String,
        selection: Selection,
        url: URL,
        name: String,
        index: JavaIndex
    ) async -> WorkspaceEditPlan {
        let title = "Extract Field"
        if let problem = JavaRefactoringText.validateIdentifier(name) {
            return WorkspaceEditPlan(blockingError: problem, title: title)
        }
        let (typed, blocked) = await JavaExtractExpression.typedExpression(
            source: source, selection: selection, url: url, index: index, title: title
        )
        if let blocked { return blocked }
        guard let typed else {
            return WorkspaceEditPlan(blockingError: "Select a complete expression to extract.", title: title)
        }
        guard let typeDecl = JavaExtractExpression.enclosingTypeDeclaration(for: typed.context.expression),
              let kind = JavaExtractExpression.typeKind(of: typeDecl) else {
            return WorkspaceEditPlan(blockingError: "Could not find an enclosing type.", title: title)
        }
        if kind == .interfaceKind || kind == .annotationKind {
            return WorkspaceEditPlan(blockingError: "Interfaces cannot have instance fields.", title: title)
        }
        if kind == .recordKind {
            return WorkspaceEditPlan(blockingError: "Extract Field is not supported in records yet.", title: title)
        }
        if JavaCompletionProvider.isStaticContext(tree: typed.context.tree, offset: typed.context.expression.startByte) {
            return WorkspaceEditPlan(
                blockingError: "An instance field cannot be extracted from a static context. Try Extract Constant instead.",
                title: title
            )
        }
        if JavaExtractExpression.fieldNames(in: typeDecl).contains(name) {
            return WorkspaceEditPlan(blockingError: "A field named \(name) already exists in this type.", title: title)
        }
        guard let member = JavaExtractExpression.enclosingMember(for: typed.context.expression),
              member.type == "method_declaration" || member.type == "constructor_declaration" else {
            return WorkspaceEditPlan(blockingError: "Could not find a method to place the field near.", title: title)
        }

        var entries: [WorkspaceEditPlanEntry] = []
        if let importEntry = await JavaExtractExpression.importEntryIfNeeded(
            type: typed.resolvedType, fileStubs: typed.context.fileStubs, tree: typed.context.tree,
            url: url, source: source, index: index
        ) {
            entries.append(importEntry)
        }

        let indent = JavaExtractExpression.leadingIndent(forNode: member, in: source)
        let declaration = "\(indent)private \(typed.typeText) \(name) = \(typed.expressionText);\n"
        entries.append(JavaRefactoringText.planEntry(
            url: url, byteRange: member.startByte..<member.startByte, oldText: "", newText: declaration,
            source: source, description: "Insert field"
        ))
        entries.append(JavaRefactoringText.planEntry(
            url: url, byteRange: typed.context.expression.byteRange, oldText: typed.expressionText, newText: name,
            source: source, description: "Replace expression"
        ))
        return WorkspaceEditPlan(entries: entries, warnings: typed.warnings, title: title)
    }
}
