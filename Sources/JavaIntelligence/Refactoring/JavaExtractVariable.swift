import EditorIntelligence
import Foundation

enum JavaExtractVariable {
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
        let title = "Extract Variable"
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
        let locals = JavaLocalScope.locals(
            in: typed.context.tree, atByteOffset: typed.context.expression.startByte
        )
        let resolvedLocals = await JavaExpressionTyper.resolvingVarLocals(
            locals, context: typed.context.resolutionContext, index: index
        )
        if resolvedLocals.contains(where: { $0.name == name }) {
            return WorkspaceEditPlan(blockingError: "A local named \(name) already exists here.", title: title)
        }
        guard let statement = JavaExtractExpression.enclosingStatement(for: typed.context.expression) else {
            return WorkspaceEditPlan(blockingError: "Could not find a place to insert the variable.", title: title)
        }

        var entries: [WorkspaceEditPlanEntry] = []
        if let importEntry = await JavaExtractExpression.importEntryIfNeeded(
            type: typed.resolvedType, fileStubs: typed.context.fileStubs, tree: typed.context.tree,
            url: url, source: source, index: index
        ) {
            entries.append(importEntry)
        }

        let indent = JavaExtractExpression.leadingIndent(forNode: statement, in: source)
        let declaration = "\(indent)final \(typed.typeText) \(name) = \(typed.expressionText);\n"
        entries.append(JavaRefactoringText.planEntry(
            url: url, byteRange: statement.startByte..<statement.startByte, oldText: "", newText: declaration,
            source: source, description: "Insert declaration"
        ))
        entries.append(JavaRefactoringText.planEntry(
            url: url, byteRange: typed.context.expression.byteRange, oldText: typed.expressionText, newText: name,
            source: source, description: "Replace expression"
        ))
        return WorkspaceEditPlan(entries: entries, warnings: typed.warnings, title: title)
    }
}
