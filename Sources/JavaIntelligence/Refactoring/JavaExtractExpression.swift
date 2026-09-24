import EditorIntelligence
import Foundation

/// Shared selection analysis for extract refactorings.
enum JavaExtractExpression {
    struct PlanContext {
        let tree: JavaSyntaxTree
        let fileStubs: JavaSourceFileStubs
        let resolutionContext: JavaResolutionContext
        let expression: SyntaxNode
    }

    struct TypedExpression {
        let context: PlanContext
        let resolvedType: JavaTypeRef
        let typeText: String
        let expressionText: String
        let warnings: [String]
    }

    private static let typeDeclarationTypes: Set<String> = [
        "class_declaration", "interface_declaration", "enum_declaration", "record_declaration", "annotation_type_declaration"
    ]

    private static let statementTypes: Set<String> = [
        "expression_statement", "return_statement", "local_variable_declaration", "if_statement",
        "for_statement", "enhanced_for_statement", "while_statement", "do_statement", "switch_expression",
        "throw_statement", "assert_statement", "synchronized_statement", "try_statement", "try_with_resources_statement"
    ]

    private static let memberTypes: Set<String> = [
        "method_declaration", "constructor_declaration", "static_initializer", "field_declaration",
        "constant_declaration", "class_declaration", "interface_declaration", "enum_declaration",
        "record_declaration", "annotation_type_declaration"
    ]

    static func suggestedName(
        source: String, selection: Selection, url: URL
    ) -> String? {
        parseContext(source: source, selection: selection, url: url)
            .map { JavaRefactoringText.suggestedName(for: $0.expression) }
    }

    static func suggestedConstantName(
        source: String, selection: Selection, url: URL
    ) -> String? {
        guard let base = suggestedName(source: source, selection: selection, url: url) else { return nil }
        return constantName(from: base)
    }

    static func suggestedMethodName(
        source: String, selection: Selection, url: URL
    ) -> String? {
        guard let trimmed = trimmedSelectionRange(in: source, selection: selection),
              let tree = JavaSyntaxParser().parse(source) else { return nil }
        let selectedText = tree.text(in: trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedText.isEmpty else { return nil }
        if selectedText.hasPrefix("return ") {
            return JavaRefactoringText.suggestedMethodName(fromExpression: "compute")
        }
        if selectedText.contains("(") {
            return JavaRefactoringText.suggestedMethodName(fromExpression: "execute")
        }
        return "extractedMethod"
    }

    static func trimmedSelectionRange(in source: String, selection: Selection) -> Range<Int>? {
        guard let selectionRange = JavaRefactoringText.selectionByteRange(in: source, selection: selection) else { return nil }
        return JavaRefactoringText.trimmedByteRange(selectionRange, in: source)
    }

    struct MethodExtractionContext {
        let tree: JavaSyntaxTree
        let fileStubs: JavaSourceFileStubs
        let resolutionContext: JavaResolutionContext
        let selectedRange: Range<Int>
        let selectedText: String
        let expression: SyntaxNode?
        let statements: [SyntaxNode]
        let enclosingMethod: SyntaxNode
        let isStaticContext: Bool
    }

    static func parseMethodContext(source: String, selection: Selection, url: URL) -> MethodExtractionContext? {
        guard let trimmed = trimmedSelectionRange(in: source, selection: selection),
              let tree = JavaSyntaxParser().parse(source) else { return nil }
        let selectedText = tree.text(in: trimmed)
        let fileStubs = JavaSourceStubBuilder.build(tree: tree, url: url)
        let resolutionContext = JavaCompletionProvider.resolutionContext(
            in: tree, fileStubs: fileStubs, atByteOffset: trimmed.lowerBound
        )

        let expressionNode = tree.node(inByteRange: trimmed)
        if expressionNode.byteRange == trimmed, isExpressionNode(expressionNode),
           validateExtractable(expressionNode) == nil,
           let method = enclosingMethodDeclaration(for: expressionNode) {
            return MethodExtractionContext(
                tree: tree, fileStubs: fileStubs, resolutionContext: resolutionContext,
                selectedRange: trimmed, selectedText: selectedText, expression: expressionNode, statements: [],
                enclosingMethod: method,
                isStaticContext: JavaCompletionProvider.isStaticContext(tree: tree, offset: trimmed.lowerBound)
            )
        }

        guard let block = enclosingBlock(forByteRange: trimmed, in: tree),
              let statements = statementsMatching(trimmed, in: block, tree: tree),
              let span = normalizedStatementSpan(for: trimmed, statements: statements, tree: tree),
              let method = enclosingMethodDeclaration(for: statements[0]) else { return nil }
        if statements.contains(where: containsLocalDeclaration) {
            return nil
        }
        if statements.contains(where: { !isExtractableStatement($0) }) {
            return nil
        }
        return MethodExtractionContext(
            tree: tree, fileStubs: fileStubs, resolutionContext: resolutionContext,
            selectedRange: span, selectedText: tree.text(in: span), expression: nil, statements: statements,
            enclosingMethod: method,
            isStaticContext: JavaCompletionProvider.isStaticContext(tree: tree, offset: span.lowerBound)
        )
    }

    static func normalizedStatementSpan(
        for range: Range<Int>, statements: [SyntaxNode], tree: JavaSyntaxTree
    ) -> Range<Int>? {
        guard let first = statements.first, let last = statements.last else { return nil }
        let span = first.startByte..<last.endByte
        if span == range { return span }
        let spanText = tree.text(in: span)
        let rangeText = tree.text(in: range)
        let spanLines = spanText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let rangeLines = rangeText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard spanLines.count == rangeLines.count else { return nil }
        for (spanLine, rangeLine) in zip(spanLines, rangeLines) {
            guard spanLine.hasSuffix(rangeLine),
                  spanLine.dropLast(rangeLine.count).allSatisfy({ $0.isWhitespace }) else { return nil }
        }
        return span
    }

    private static func statementsMatching(
        _ range: Range<Int>, in block: SyntaxNode, tree: JavaSyntaxTree
    ) -> [SyntaxNode]? {
        let statements = block.namedChildren.filter { statementTypes.contains($0.type) }
        guard let first = statements.firstIndex(where: { $0.endByte > range.lowerBound && $0.startByte < range.upperBound }),
              let last = statements.lastIndex(where: { $0.endByte > range.lowerBound && $0.startByte < range.upperBound }),
              first <= last else { return nil }
        let slice = Array(statements[first...last])
        guard range.lowerBound >= slice.first!.startByte, range.upperBound <= slice.last!.endByte else { return nil }
        guard normalizedStatementSpan(for: range, statements: slice, tree: tree) != nil else { return nil }
        return slice
    }

    static func methodNames(in typeDecl: SyntaxNode) -> Set<String> {
        guard let body = typeDecl.child(byFieldName: "body") else { return [] }
        var names = Set<String>()
        for member in body.namedChildren where member.type == "method_declaration" {
            if let name = member.child(byFieldName: "name")?.text { names.insert(name) }
        }
        return names
    }

    static func capturedParameters(
        in context: MethodExtractionContext, index: JavaIndex
    ) async -> [JavaLocalVariable] {
        let locals = JavaLocalScope.locals(in: context.tree, atByteOffset: context.selectedRange.lowerBound)
        let resolved = await JavaExpressionTyper.resolvingVarLocals(
            locals, context: context.resolutionContext, index: index
        )
        let used = usedLocalNames(in: context)
        var seen = Set<String>()
        var parameters: [JavaLocalVariable] = []
        for local in resolved where used.contains(local.name) {
            guard seen.insert(local.name).inserted else { continue }
            parameters.append(local)
        }
        return parameters
    }

    static func reindentedBody(_ text: String, bodyIndent: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let minimum = lines.compactMap({ line -> Int? in
            guard let first = line.firstIndex(where: { !$0.isWhitespace }) else { return nil }
            return line.distance(from: line.startIndex, to: first)
        }).min() else {
            return bodyIndent + text.trimmingCharacters(in: .newlines) + "\n"
        }
        return lines.map { line in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
            let dropIndex = line.index(line.startIndex, offsetBy: min(minimum, line.count))
            return bodyIndent + String(line[dropIndex...])
        }.joined(separator: "\n") + "\n"
    }

    static func parseContext(source: String, selection: Selection, url: URL) -> PlanContext? {
        guard let selectionRange = JavaRefactoringText.selectionByteRange(in: source, selection: selection),
              let trimmed = JavaRefactoringText.trimmedByteRange(selectionRange, in: source),
              let tree = JavaSyntaxParser().parse(source) else { return nil }
        let node = tree.node(inByteRange: trimmed)
        guard node.byteRange == trimmed, isExpressionNode(node) else { return nil }
        let fileStubs = JavaSourceStubBuilder.build(tree: tree, url: url)
        let resolutionContext = JavaCompletionProvider.resolutionContext(
            in: tree, fileStubs: fileStubs, atByteOffset: node.startByte
        )
        return PlanContext(tree: tree, fileStubs: fileStubs, resolutionContext: resolutionContext, expression: node)
    }

    static func typedExpression(
        source: String, selection: Selection, url: URL, index: JavaIndex, title: String
    ) async -> (TypedExpression?, WorkspaceEditPlan?) {
        guard let context = parseContext(source: source, selection: selection, url: url) else {
            return (nil, blocked("Select a complete expression to extract.", title: title))
        }
        if let problem = validateExtractable(context.expression) {
            return (nil, blocked(problem, title: title))
        }
        let locals = JavaLocalScope.locals(in: context.tree, atByteOffset: context.expression.startByte)
        let resolvedLocals = await JavaExpressionTyper.resolvingVarLocals(locals, context: context.resolutionContext, index: index)
        guard let typed = await JavaExpressionTyper.typeOfExpression(
            context.expression.text, locals: resolvedLocals, context: context.resolutionContext, index: index
        ), !typed.isTypeReference else {
            return (nil, blocked("Cannot infer the expression's type.", title: title))
        }
        let resolvedType = await JavaTypeResolver.resolve(typed.type, context: context.resolutionContext, index: index)
        if case .unresolved("var", _) = resolvedType {
            return (nil, blocked("Cannot infer the type — add an explicit type first.", title: title))
        }
        var warnings: [String] = []
        if resolvedType != typed.type {
            warnings.append("The declared type is approximate.")
        }
        return (
            TypedExpression(
                context: context,
                resolvedType: resolvedType,
                typeText: JavaRefactoringText.typeSourceText(resolvedType),
                expressionText: context.expression.text,
                warnings: warnings
            ),
            nil
        )
    }

    static func enclosingStatement(for expression: SyntaxNode) -> SyntaxNode? {
        var current: SyntaxNode? = expression
        while let node = current {
            if statementTypes.contains(node.type) { return node }
            current = node.parent
        }
        return nil
    }

    static func enclosingTypeDeclaration(for expression: SyntaxNode) -> SyntaxNode? {
        var current: SyntaxNode? = expression.parent
        while let node = current {
            if typeDeclarationTypes.contains(node.type) { return node }
            current = node.parent
        }
        return nil
    }

    /// The class member (method, constructor, field…) that directly contains the expression.
    static func enclosingMember(for expression: SyntaxNode) -> SyntaxNode? {
        var current: SyntaxNode? = expression.parent
        while let node = current {
            if memberTypes.contains(node.type) { return node }
            current = node.parent
        }
        return nil
    }

    static func typeKind(of typeDecl: SyntaxNode) -> JavaTypeKind? {
        switch typeDecl.type {
        case "class_declaration": return .classKind
        case "interface_declaration": return .interfaceKind
        case "enum_declaration": return .enumKind
        case "record_declaration": return .recordKind
        case "annotation_type_declaration": return .annotationKind
        default: return nil
        }
    }

    static func fieldNames(in typeDecl: SyntaxNode) -> Set<String> {
        guard let body = typeDecl.child(byFieldName: "body") else { return [] }
        var names = Set<String>()
        for member in body.namedChildren {
            switch member.type {
            case "field_declaration", "constant_declaration":
                for declarator in member.namedChildren(ofType: "variable_declarator") {
                    if let name = declarator.child(byFieldName: "name")?.text { names.insert(name) }
                }
            case "enum_constant":
                if let name = member.child(byFieldName: "name")?.text { names.insert(name) }
            default:
                continue
            }
        }
        return names
    }

    static func leadingIndent(forNode node: SyntaxNode, in source: String) -> String {
        let ns = source as NSString
        let start = JavaNavigationText.utf16Offset(forByte: node.startByte, in: source)
        let lineStart = ns.lineRange(for: NSRange(location: start, length: 0)).location
        let prefix = ns.substring(with: NSRange(location: lineStart, length: start - lineStart))
        if let firstNonWhitespace = prefix.firstIndex(where: { !$0.isWhitespace }) {
            return String(prefix[..<firstNonWhitespace])
        }
        return prefix
    }

    static func importEntryIfNeeded(
        type: JavaTypeRef, fileStubs: JavaSourceFileStubs, tree: JavaSyntaxTree, url: URL, source: String,
        index: JavaIndex
    ) async -> WorkspaceEditPlanEntry? {
        guard case .classType(let qualifiedName, _, _) = type else { return nil }
        var stub = fileStubs.classes.first(where: { $0.qualifiedName == qualifiedName })
        if stub == nil {
            stub = await index.classStub(qualifiedName: qualifiedName)
        }
        guard let stub else { return nil }
        let inserter = JavaImportInserter(
            text: source, bytes: tree.sourceBytes, tree: tree, fileStubs: fileStubs
        )
        guard case .addImport(let edit) = inserter.decision(for: stub) else { return nil }
        let byteRange = JavaNavigationText.utf8ByteOffset(forUTF16Offset: edit.range.start.utf16Offset, in: source)
            ..< JavaNavigationText.utf8ByteOffset(forUTF16Offset: edit.range.end.utf16Offset, in: source)
        return JavaRefactoringText.planEntry(
            url: url, byteRange: byteRange, oldText: "", newText: edit.replacement, source: source,
            description: "Add import"
        )
    }

    static func constantName(from base: String) -> String {
        var parts: [String] = []
        var current = ""
        for character in base {
            if character.isUppercase, !current.isEmpty {
                parts.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { parts.append(current) }
        if parts.isEmpty { return base.uppercased() }
        return parts.map { $0.uppercased() }.joined(separator: "_")
    }

    private static func blocked(_ message: String, title: String) -> WorkspaceEditPlan {
        WorkspaceEditPlan(blockingError: message, title: title)
    }

    private static func isExpressionNode(_ node: SyntaxNode) -> Bool {
        if node.type.hasSuffix("_expression") || node.type.hasSuffix("_literal") { return true }
        switch node.type {
        case "identifier", "this", "super", "null_literal", "true", "false", "string_literal",
             "character_literal", "decimal_integer_literal", "decimal_floating_point_literal",
             "hex_integer_literal", "octal_integer_literal", "binary_integer_literal", "lambda_expression",
             "method_invocation", "field_access", "array_access", "parenthesized_expression",
             "cast_expression", "instanceof_expression", "ternary_expression", "switch_expression":
            return true
        default:
            return false
        }
    }

    private static func validateExtractable(_ expression: SyntaxNode) -> String? {
        if let parent = expression.parent {
            if parent.type == "assignment_expression", parent.child(byFieldName: "left")?.byteRange == expression.byteRange {
                return "Cannot extract the left-hand side of an assignment."
            }
            if parent.type == "variable_declarator", parent.child(byFieldName: "name")?.byteRange == expression.byteRange {
                return "Select the initializer expression, not the variable name."
            }
        }
        switch expression.type {
        case "assignment_expression", "update_expression":
            return "Cannot extract an assignment or update expression."
        case "throw_expression", "class_literal":
            return "This expression cannot be extracted."
        default:
            if expression.type == "return_statement" || expression.type == "method_declaration" {
                return "Select an expression, not a whole statement."
            }
            return nil
        }
    }

    private static func enclosingMethodDeclaration(for node: SyntaxNode) -> SyntaxNode? {
        var current: SyntaxNode? = node
        while let candidate = current {
            if candidate.type == "method_declaration" { return candidate }
            current = candidate.parent
        }
        return nil
    }

    private static func enclosingBlock(forByteRange range: Range<Int>, in tree: JavaSyntaxTree) -> SyntaxNode? {
        var node = tree.node(atByteOffset: range.lowerBound)
        while true {
            if node.type == "block" || node.type == "constructor_body" { return node }
            guard let parent = node.parent else { return nil }
            node = parent
        }
    }

    private static func containsLocalDeclaration(_ statement: SyntaxNode) -> Bool {
        statement.type == "local_variable_declaration"
    }

    private static func isExtractableStatement(_ statement: SyntaxNode) -> Bool {
        switch statement.type {
        case "break_statement", "continue_statement", "throw_statement", "try_statement", "try_with_resources_statement",
             "synchronized_statement", "switch_expression":
            return false
        default:
            return true
        }
    }

    private static func usedLocalNames(in context: MethodExtractionContext) -> Set<String> {
        let locals = JavaLocalScope.locals(in: context.tree, atByteOffset: context.selectedRange.lowerBound)
        let localNames = Set(locals.map(\.name))
        var used = Set<String>()
        collectUsedLocalNames(in: context.tree.rootNode, range: context.selectedRange, localNames: localNames, into: &used)
        return used
    }

    private static func collectUsedLocalNames(
        in node: SyntaxNode, range: Range<Int>, localNames: Set<String>, into used: inout Set<String>
    ) {
        guard node.byteRange.overlaps(range) || range.contains(node.byteRange.lowerBound) else { return }
        if node.type == "identifier", node.byteRange.overlaps(range), !isDeclarationName(node) {
            if let reference = JavaReferenceClassifier.classify(token: node) {
                switch reference {
                case .bareName where localNames.contains(node.text):
                    used.insert(node.text)
                default:
                    break
                }
            }
        }
        if node.type == "field_access", let object = node.child(byFieldName: "object"),
           object.type == "identifier", object.byteRange.overlaps(range), localNames.contains(object.text) {
            used.insert(object.text)
        }
        if node.type == "method_invocation", let object = node.child(byFieldName: "object"),
           object.type == "identifier", object.byteRange.overlaps(range), localNames.contains(object.text) {
            used.insert(object.text)
        }
        for child in node.children {
            collectUsedLocalNames(in: child, range: range, localNames: localNames, into: &used)
        }
    }

    private static func isDeclarationName(_ node: SyntaxNode) -> Bool {
        guard node.type == "identifier" || node.type == "type_identifier" else { return false }
        if let parent = node.parent {
            if parent.type == "variable_declarator", parent.child(byFieldName: "name")?.byteRange == node.byteRange { return true }
            if parent.type == "formal_parameter", parent.child(byFieldName: "name")?.byteRange == node.byteRange { return true }
            if parent.type == "catch_formal_parameter", parent.child(byFieldName: "name")?.byteRange == node.byteRange { return true }
        }
        return false
    }
}
