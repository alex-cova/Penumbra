import EditorIntelligence
import Foundation

enum JavaExtractMethod {
    static func suggestedName(
        source: String, selection: Selection, url: URL, index: JavaIndex
    ) async -> String? {
        JavaExtractExpression.suggestedMethodName(source: source, selection: selection, url: url)
    }

    static func plan(
        source: String,
        selection: Selection,
        url: URL,
        name: String,
        index: JavaIndex
    ) async -> WorkspaceEditPlan {
        let title = "Extract Method"
        if let problem = JavaRefactoringText.validateIdentifier(name) {
            return WorkspaceEditPlan(blockingError: problem, title: title)
        }
        guard let context = JavaExtractExpression.parseMethodContext(
            source: source, selection: selection, url: url
        ) else {
            return WorkspaceEditPlan(
                blockingError: "Select a complete expression or one or more statements to extract.",
                title: title
            )
        }
        guard let anchor = context.expression ?? context.statements.first,
              let typeDecl = JavaExtractExpression.enclosingTypeDeclaration(for: anchor),
              let kind = JavaExtractExpression.typeKind(of: typeDecl) else {
            return WorkspaceEditPlan(blockingError: "Could not find an enclosing type.", title: title)
        }
        if kind == .annotationKind {
            return WorkspaceEditPlan(blockingError: "Extract Method is not supported in annotation types.", title: title)
        }
        if kind == .recordKind {
            return WorkspaceEditPlan(blockingError: "Extract Method is not supported in records yet.", title: title)
        }
        if JavaExtractExpression.methodNames(in: typeDecl).contains(name) {
            return WorkspaceEditPlan(blockingError: "A method named \(name) already exists in this type.", title: title)
        }

        let parameters = await JavaExtractExpression.capturedParameters(in: context, index: index)
        var resolvedParameters: [(name: String, typeText: String)] = []
        for parameter in parameters {
            let resolved = await JavaTypeResolver.resolve(parameter.type, context: context.resolutionContext, index: index)
            if case .unresolved("var", _) = resolved {
                return WorkspaceEditPlan(
                    blockingError: "Cannot infer the type of parameter \(parameter.name).",
                    title: title
                )
            }
            resolvedParameters.append((parameter.name, JavaRefactoringText.typeSourceText(resolved)))
        }

        let returnInfo = await returnType(for: context, parameters: parameters, index: index)
        if let blocking = returnInfo.blockingError {
            return WorkspaceEditPlan(blockingError: blocking, title: title)
        }

        var entries: [WorkspaceEditPlanEntry] = []
        if let importEntry = await JavaExtractExpression.importEntryIfNeeded(
            type: returnInfo.resolvedType, fileStubs: context.fileStubs, tree: context.tree,
            url: url, source: source, index: index
        ) {
            entries.append(importEntry)
        }

        let memberIndent = JavaExtractExpression.leadingIndent(forNode: context.enclosingMethod, in: source)
        let bodyIndent = memberIndent + "    "
        let staticKeyword = context.isStaticContext ? "static " : ""
        let parameterList = resolvedParameters.map { "\($0.typeText) \($0.name)" }.joined(separator: ", ")
        let signature = "\(memberIndent)private \(staticKeyword)\(returnInfo.typeText) \(name)(\(parameterList)) {\n"
        let body = methodBody(for: context, bodyIndent: bodyIndent, returnInfo: returnInfo)
        let methodSource = signature + body + "\(memberIndent)}\n"
        entries.append(JavaRefactoringText.planEntry(
            url: url, byteRange: context.enclosingMethod.endByte..<context.enclosingMethod.endByte,
            oldText: "", newText: "\n" + methodSource, source: source, description: "Insert method"
        ))

        let argumentList = parameters.map(\.name).joined(separator: ", ")
        let call = parameters.isEmpty ? "\(name)()" : "\(name)(\(argumentList))"
        let replacement = replacementCall(call, context: context)
        entries.append(JavaRefactoringText.planEntry(
            url: url, byteRange: context.selectedRange, oldText: context.selectedText, newText: replacement,
            source: source, description: "Replace selection"
        ))

        return WorkspaceEditPlan(entries: entries, warnings: returnInfo.warnings, title: title)
    }

    private struct ReturnInfo {
        var typeText: String
        var resolvedType: JavaTypeRef
        var warnings: [String] = []
        var blockingError: String?
    }

    private static func returnType(
        for context: JavaExtractExpression.MethodExtractionContext,
        parameters: [JavaLocalVariable],
        index: JavaIndex
    ) async -> ReturnInfo {
        if let expression = context.expression {
            let locals = JavaLocalScope.locals(in: context.tree, atByteOffset: context.selectedRange.lowerBound)
            let resolvedLocals = await JavaExpressionTyper.resolvingVarLocals(
                locals, context: context.resolutionContext, index: index
            )
            guard let typed = await JavaExpressionTyper.typeOfExpression(
                expression.text, locals: resolvedLocals, context: context.resolutionContext, index: index
            ), !typed.isTypeReference else {
                return ReturnInfo(typeText: "", resolvedType: .void, blockingError: "Cannot infer the expression's type.")
            }
            let resolved = await JavaTypeResolver.resolve(typed.type, context: context.resolutionContext, index: index)
            var warnings: [String] = []
            if resolved != typed.type { warnings.append("The return type is approximate.") }
            return ReturnInfo(
                typeText: JavaRefactoringText.typeSourceText(resolved), resolvedType: resolved, warnings: warnings
            )
        }

        if context.statements.count == 1, context.statements[0].type == "return_statement",
           let value = context.statements[0].child(byFieldName: "value")
               ?? context.statements[0].namedChild(at: 0) {
            let locals = JavaLocalScope.locals(in: context.tree, atByteOffset: context.selectedRange.lowerBound)
            let resolvedLocals = await JavaExpressionTyper.resolvingVarLocals(
                locals, context: context.resolutionContext, index: index
            )
            guard let typed = await JavaExpressionTyper.typeOfExpression(
                value.text, locals: resolvedLocals, context: context.resolutionContext, index: index
            ), !typed.isTypeReference else {
                return ReturnInfo(typeText: "", resolvedType: .void, blockingError: "Cannot infer the return type.")
            }
            let resolved = await JavaTypeResolver.resolve(typed.type, context: context.resolutionContext, index: index)
            return ReturnInfo(typeText: JavaRefactoringText.typeSourceText(resolved), resolvedType: resolved)
        }

        return ReturnInfo(typeText: "void", resolvedType: .void)
    }

    private static func methodBody(
        for context: JavaExtractExpression.MethodExtractionContext,
        bodyIndent: String,
        returnInfo: ReturnInfo
    ) -> String {
        if let expression = context.expression {
            return "\(bodyIndent)return \(expression.text);\n"
        }
        if context.statements.count == 1, context.statements[0].type == "return_statement",
           let value = context.statements[0].child(byFieldName: "value")
               ?? context.statements[0].namedChild(at: 0) {
            return "\(bodyIndent)return \(value.text);\n"
        }
        return JavaExtractExpression.reindentedBody(context.selectedText, bodyIndent: bodyIndent)
    }

    private static func replacementCall(
        _ call: String, context: JavaExtractExpression.MethodExtractionContext
    ) -> String {
        if context.expression != nil {
            return call
        }
        if context.statements.count == 1, context.statements[0].type == "return_statement" {
            return "return \(call);"
        }
        return call + ";"
    }
}
