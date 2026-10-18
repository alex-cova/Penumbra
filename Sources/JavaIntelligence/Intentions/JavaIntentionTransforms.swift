import Foundation

/// The syntactic intentions. Each one looks at a single node and returns nothing when it does not apply.
enum JavaIntentionTransforms {
    static func offers(for node: SyntaxNode, options: JavaIntentionOptions, source: String) -> [JavaIntentionOffer] {
        guard !node.hasError else { return [] }
        var found: [JavaIntentionOffer] = []
        found += JavaControlFlowIntentions.offers(for: node, options: options, source: source)
        found += JavaBooleanIntentions.offers(for: node, options: options, source: source)
        found += JavaDeclarationIntentions.offers(for: node, options: options, source: source)
        found += JavaLambdaIntentions.offers(for: node, options: options, source: source)
        found += JavaCommentIntentions.offers(for: node, options: options, source: source)
        found += JavaStringIntentions.offers(for: node, options: options, source: source)
        found += JavaTypeIntentions.explicitToVar(for: node, options: options, source: source)
        return found
    }
}

enum JavaControlFlowIntentions {
    static func offers(for node: SyntaxNode, options: JavaIntentionOptions, source: String) -> [JavaIntentionOffer] {
        var found: [JavaIntentionOffer] = []
        if let offer = invertIf(node, options: options, source: source) { found.append(offer) }
        if let offer = flip(node, options: options, source: source) { found.append(offer) }
        if let offer = ifToTernary(node, options: options, source: source) { found.append(offer) }
        if let offer = ternaryToIf(node, options: options, source: source) { found.append(offer) }
        found += addBraces(node, options: options, source: source)
        if let offer = removeBraces(node, options: options, source: source) { found.append(offer) }
        if let offer = splitIf(node, options: options, source: source) { found.append(offer) }
        if let offer = mergeIf(node, options: options, source: source) { found.append(offer) }
        return found
    }

    private static func invertIf(_ node: SyntaxNode, options: JavaIntentionOptions, source: String) -> JavaIntentionOffer? {
        guard options.isEnabled(.invertIf), node.type == "if_statement",
              let condition = node.child(byFieldName: "condition"),
              let consequence = node.child(byFieldName: "consequence"),
              let alternative = node.child(byFieldName: "alternative") else { return nil }
        let indent = JavaIntentionSyntax.indent(of: node)
        let negated = JavaBooleanSyntax.negation(of: condition.unparenthesized)
        let thenText = branchText(alternative, indent: indent)
        let elseText = branchText(consequence, indent: indent)
        return JavaIntentionEdit.offer(
            .invertIf, replacing: node.byteRange, with: "if (\(negated)) \(thenText) else \(elseText)",
            in: node.tree, source: source
        )
    }

    /// A branch that is itself an if is wrapped, so the surrounding else does not bind to it.
    private static func branchText(_ statement: SyntaxNode, indent: String) -> String {
        if statement.type == "block" { return statement.text }
        if statement.type == "if_statement" {
            return "{\n\(JavaIntentionSyntax.indentLines(statement.text, by: indent + "    "))\n\(indent)}"
        }
        return statement.text
    }

    private static let flippedOperators = ["==": "==", "!=": "!=", "<": ">", ">": "<", "<=": ">=", ">=": "<="]

    private static func flip(_ node: SyntaxNode, options: JavaIntentionOptions, source: String) -> JavaIntentionOffer? {
        guard options.isEnabled(.flipComparison), node.type == "binary_expression",
              let op = node.operatorText, let flipped = flippedOperators[op],
              let left = node.child(byFieldName: "left"), let right = node.child(byFieldName: "right"),
              let operatorNode = node.child(byFieldName: "operator") else { return nil }
        let edits = [
            JavaIntentionEdit.replacing(left.byteRange, with: right.text, in: node.tree),
            JavaIntentionEdit.replacing(operatorNode.byteRange, with: flipped, in: node.tree),
            JavaIntentionEdit.replacing(right.byteRange, with: left.text, in: node.tree),
        ]
        return JavaIntentionEdit.offer(.flipComparison, title: "Flip '\(op)'", edits: edits, source: source)
    }

    private enum Branch {
        case returns(SyntaxNode)
        case assigns(target: String, value: SyntaxNode)
    }

    private static func branch(_ statement: SyntaxNode) -> Branch? {
        var current = statement
        if current.type == "block", let only = JavaIntentionSyntax.singleStatement(in: current) { current = only }
        if current.type == "return_statement", let value = current.namedChild(at: 0) { return .returns(value) }
        guard current.type == "expression_statement",
              let assignment = current.namedChild(at: 0), assignment.type == "assignment_expression",
              assignment.operatorText == "=",
              let left = assignment.child(byFieldName: "left"),
              let right = assignment.child(byFieldName: "right") else { return nil }
        return .assigns(target: left.text, value: right)
    }

    private static func ifToTernary(_ node: SyntaxNode, options: JavaIntentionOptions, source: String) -> JavaIntentionOffer? {
        guard options.isEnabled(.ifToTernary), node.type == "if_statement",
              let condition = node.child(byFieldName: "condition"),
              let consequence = node.child(byFieldName: "consequence"),
              let alternative = node.child(byFieldName: "alternative"),
              let yes = branch(consequence), let no = branch(alternative) else { return nil }
        let cond = "(\(condition.unparenthesized.text))"
        let replacement: String
        switch (yes, no) {
        case (.returns(let left), .returns(let right)):
            replacement = "return \(cond) ? \(operand(left)) : \(operand(right));"
        case (.assigns(let target, let left), .assigns(let other, let right)) where target == other:
            replacement = "\(target) = \(cond) ? \(operand(left)) : \(operand(right));"
        default:
            return nil
        }
        return JavaIntentionEdit.offer(.ifToTernary, replacing: node.byteRange, with: replacement, in: node.tree, source: source)
    }

    private static func operand(_ node: SyntaxNode) -> String {
        switch node.unparenthesized.type {
        case "ternary_expression", "assignment_expression", "lambda_expression": return "(\(node.text))"
        default: return node.text
        }
    }

    private static func ternaryToIf(_ node: SyntaxNode, options: JavaIntentionOptions, source: String) -> JavaIntentionOffer? {
        guard options.isEnabled(.ternaryToIf), node.type == "ternary_expression",
              let condition = node.child(byFieldName: "condition"),
              let yes = node.child(byFieldName: "consequence"),
              let no = node.child(byFieldName: "alternative"),
              let parent = node.parent else { return nil }
        let cond = condition.unparenthesized.text
        let replacement: String
        let range: Range<Int>
        if parent.type == "return_statement", parent.namedChild(at: 0)?.byteRange == node.byteRange {
            replacement = "if (\(cond)) return \(operand(yes)); else return \(operand(no));"
            range = parent.byteRange
        } else if parent.type == "assignment_expression", parent.operatorText == "=",
                  parent.child(byFieldName: "right")?.byteRange == node.byteRange,
                  let statement = parent.parent, statement.type == "expression_statement",
                  let left = parent.child(byFieldName: "left") {
            replacement = "if (\(cond)) \(left.text) = \(operand(yes)); else \(left.text) = \(operand(no));"
            range = statement.byteRange
        } else {
            return nil
        }
        return JavaIntentionEdit.offer(.ternaryToIf, replacing: range, with: replacement, in: node.tree, source: source)
    }

    private static func addBraces(_ node: SyntaxNode, options: JavaIntentionOptions, source: String) -> [JavaIntentionOffer] {
        guard options.isEnabled(.addBraces) else { return [] }
        let bodies: [SyntaxNode]
        switch node.type {
        case "if_statement":
            var found: [SyntaxNode] = []
            if let body = node.child(byFieldName: "consequence"), body.type != "block" { found.append(body) }
            if let alternative = node.child(byFieldName: "alternative"),
               alternative.type != "block", alternative.type != "if_statement" { found.append(alternative) }
            bodies = found
        case "for_statement", "enhanced_for_statement", "while_statement", "do_statement":
            if let body = node.child(byFieldName: "body"), body.type != "block" { bodies = [body] } else { bodies = [] }
        default:
            return []
        }
        let indent = JavaIntentionSyntax.indent(of: node)
        return bodies.compactMap { body in
            let wrapped = "{\n\(JavaIntentionSyntax.indentLines(body.text, by: indent + "    "))\n\(indent)}"
            return JavaIntentionEdit.offer(.addBraces, replacing: body.byteRange, with: wrapped, in: node.tree, source: source)
        }
    }

    private static let braceParents: Set<String> = [
        "if_statement", "for_statement", "enhanced_for_statement", "while_statement", "do_statement",
    ]

    private static func removeBraces(_ node: SyntaxNode, options: JavaIntentionOptions, source: String) -> JavaIntentionOffer? {
        guard options.isEnabled(.removeBraces), node.type == "block",
              let parent = node.parent, braceParents.contains(parent.type), isBody(node, of: parent),
              let statement = JavaIntentionSyntax.singleStatement(in: node) else { return nil }
        return JavaIntentionEdit.offer(.removeBraces, replacing: node.byteRange, with: statement.text, in: node.tree, source: source)
    }

    private static func isBody(_ block: SyntaxNode, of parent: SyntaxNode) -> Bool {
        for field in ["body", "consequence", "alternative"] {
            if parent.child(byFieldName: field)?.byteRange == block.byteRange { return true }
        }
        return false
    }

    private static func splitIf(_ node: SyntaxNode, options: JavaIntentionOptions, source: String) -> JavaIntentionOffer? {
        guard options.isEnabled(.splitIf), node.type == "if_statement", node.child(byFieldName: "alternative") == nil,
              let condition = node.child(byFieldName: "condition")?.unparenthesized,
              condition.type == "binary_expression", condition.operatorText == "&&",
              let left = condition.child(byFieldName: "left"), let right = condition.child(byFieldName: "right"),
              let body = node.child(byFieldName: "consequence") else { return nil }
        let indent = JavaIntentionSyntax.indent(of: node)
        let nested = "if (\(JavaIntentionSyntax.andOperand(right))) \(body.text)"
        let replacement = """
        if (\(JavaIntentionSyntax.andOperand(left))) {
        \(JavaIntentionSyntax.indentLines(nested, by: indent + "    "))
        \(indent)}
        """
        return JavaIntentionEdit.offer(.splitIf, replacing: node.byteRange, with: replacement, in: node.tree, source: source)
    }

    private static func mergeIf(_ node: SyntaxNode, options: JavaIntentionOptions, source: String) -> JavaIntentionOffer? {
        guard options.isEnabled(.mergeIf), node.type == "if_statement", node.child(byFieldName: "alternative") == nil,
              let consequence = node.child(byFieldName: "consequence"), consequence.type == "block",
              let inner = JavaIntentionSyntax.singleStatement(in: consequence), inner.type == "if_statement",
              inner.child(byFieldName: "alternative") == nil,
              let outerCond = node.child(byFieldName: "condition"),
              let innerCond = inner.child(byFieldName: "condition"),
              let innerBody = inner.child(byFieldName: "consequence") else { return nil }
        let replacement = "if (\(JavaIntentionSyntax.andOperand(outerCond)) && \(JavaIntentionSyntax.andOperand(innerCond))) \(innerBody.text)"
        return JavaIntentionEdit.offer(.mergeIf, replacing: node.byteRange, with: replacement, in: node.tree, source: source)
    }
}

enum JavaBooleanIntentions {
    static func offers(for node: SyntaxNode, options: JavaIntentionOptions, source: String) -> [JavaIntentionOffer] {
        guard options.isEnabled(.deMorgan), !node.hasError, let offer = deMorgan(node, source: source) else { return [] }
        return [offer]
    }

    private static func deMorgan(_ node: SyntaxNode, source: String) -> JavaIntentionOffer? {
        if let pushed = pushNegation(node, source: source) { return pushed }
        return pullNegation(node, source: source)
    }

    /// `!(a && b)` becomes `!a || !b`.
    private static func pushNegation(_ node: SyntaxNode, source: String) -> JavaIntentionOffer? {
        guard let operand = negatedOperand(node)?.unparenthesized, operand.type == "binary_expression",
              let op = operand.operatorText, op == "&&" || op == "||",
              let left = operand.child(byFieldName: "left"), let right = operand.child(byFieldName: "right") else { return nil }
        let joined = op == "&&" ? "||" : "&&"
        let text = "\(JavaBooleanSyntax.negation(of: left)) \(joined) \(JavaBooleanSyntax.negation(of: right))"
        return JavaIntentionEdit.offer(.deMorgan, replacing: node.byteRange, with: text, in: node.tree, source: source)
    }

    /// `!a && !b` becomes `!(a || b)`.
    private static func pullNegation(_ node: SyntaxNode, source: String) -> JavaIntentionOffer? {
        guard node.type == "binary_expression", let op = node.operatorText, op == "&&" || op == "||",
              let left = node.child(byFieldName: "left"), let right = node.child(byFieldName: "right"),
              let leftPositive = negatedOperand(left), let rightPositive = negatedOperand(right) else { return nil }
        let joined = op == "&&" ? "||" : "&&"
        let text = "!(\(leftPositive.text) \(joined) \(rightPositive.text))"
        return JavaIntentionEdit.offer(.deMorgan, replacing: node.byteRange, with: text, in: node.tree, source: source)
    }

    /// The expression under a leading `!`, parentheses included in the walk.
    private static func negatedOperand(_ node: SyntaxNode) -> SyntaxNode? {
        let inner = node.unparenthesized
        guard inner.type == "unary_expression" else { return nil }
        let op = inner.child(byFieldName: "operator")?.text ?? inner.children.first { !$0.isNamed }?.text
        guard op == "!" else { return nil }
        return inner.child(byFieldName: "operand") ?? inner.namedChild(at: 0)
    }
}

enum JavaDeclarationIntentions {
    static func offers(for node: SyntaxNode, options: JavaIntentionOptions, source: String) -> [JavaIntentionOffer] {
        var found: [JavaIntentionOffer] = []
        if let offer = split(node, options: options, source: source) { found.append(offer) }
        if let offer = join(node, options: options, source: source) { found.append(offer) }
        return found
    }

    private static func split(_ node: SyntaxNode, options: JavaIntentionOptions, source: String) -> JavaIntentionOffer? {
        guard options.isEnabled(.splitDeclaration), node.type == "local_variable_declaration",
              node.parent?.type != "for_statement",
              let type = node.child(byFieldName: "type"), type.text != "var",
              node.namedChildren(ofType: "variable_declarator").count == 1,
              let declarator = node.firstNamedChild(ofType: "variable_declarator"),
              let name = declarator.child(byFieldName: "name"),
              let value = declarator.child(byFieldName: "value"),
              let equals = initializerRange(of: declarator, value: value) else { return nil }
        let indent = JavaIntentionSyntax.indent(of: node)
        let edits = [
            JavaIntentionEdit.replacing(equals, with: "", in: node.tree),
            JavaIntentionEdit.replacing(node.endByte..<node.endByte, with: "\n\(indent)\(name.text) = \(value.text);", in: node.tree),
        ]
        return JavaIntentionEdit.offer(.splitDeclaration, edits: edits, source: source)
    }

    /// From the `=` through the initializer, including the spaces around the `=`.
    private static func initializerRange(of declarator: SyntaxNode, value: SyntaxNode) -> Range<Int>? {
        let bytes = declarator.tree.sourceBytes
        var start = value.startByte
        while start > declarator.startByte, bytes[start - 1] == JavaSourceBytes.space || bytes[start - 1] == JavaSourceBytes.tab {
            start -= 1
        }
        guard start > declarator.startByte, bytes[start - 1] == UInt8(ascii: "=") else { return nil }
        start -= 1
        while start > declarator.startByte, bytes[start - 1] == JavaSourceBytes.space || bytes[start - 1] == JavaSourceBytes.tab {
            start -= 1
        }
        return start..<value.endByte
    }

    private static func join(_ node: SyntaxNode, options: JavaIntentionOptions, source: String) -> JavaIntentionOffer? {
        guard options.isEnabled(.joinDeclaration), node.type == "local_variable_declaration",
              node.parent?.type != "for_statement",
              let type = node.child(byFieldName: "type"),
              node.namedChildren(ofType: "variable_declarator").count == 1,
              let declarator = node.firstNamedChild(ofType: "variable_declarator"),
              declarator.child(byFieldName: "value") == nil,
              let name = declarator.child(byFieldName: "name"),
              let next = node.nextNamedSibling, next.type == "expression_statement",
              let assignment = next.namedChild(at: 0), assignment.type == "assignment_expression",
              assignment.operatorText == "=",
              let left = assignment.child(byFieldName: "left"), left.type == "identifier", left.text == name.text,
              let value = assignment.child(byFieldName: "right") else { return nil }
        let modifiers = node.firstNamedChild(ofType: "modifiers").map { $0.text + " " } ?? ""
        let text = "\(modifiers)\(type.text) \(name.text) = \(value.text);"
        return JavaIntentionEdit.offer(.joinDeclaration, replacing: node.startByte..<next.endByte, with: text, in: node.tree, source: source)
    }
}

enum JavaLambdaIntentions {
    private static let statementExpressions: Set<String> = [
        "method_invocation", "assignment_expression", "update_expression", "object_creation_expression",
    ]

    static func offers(for node: SyntaxNode, options: JavaIntentionOptions, source: String) -> [JavaIntentionOffer] {
        var found: [JavaIntentionOffer] = []
        if let offer = expand(node, options: options, source: source) { found.append(offer) }
        if let offer = collapse(node, options: options, source: source) { found.append(offer) }
        return found
    }

    private static func expand(_ node: SyntaxNode, options: JavaIntentionOptions, source: String) -> JavaIntentionOffer? {
        guard options.isEnabled(.expandLambda), node.type == "lambda_expression",
              let body = node.child(byFieldName: "body"), body.type != "block" else { return nil }
        let inner = body.unparenthesized
        let text = statementExpressions.contains(inner.type) ? "{ \(inner.text); }" : "{ return \(inner.text); }"
        return JavaIntentionEdit.offer(.expandLambda, replacing: body.byteRange, with: text, in: node.tree, source: source)
    }

    private static func collapse(_ node: SyntaxNode, options: JavaIntentionOptions, source: String) -> JavaIntentionOffer? {
        guard options.isEnabled(.collapseLambda), node.type == "block",
              node.parent?.type == "lambda_expression",
              node.parent?.child(byFieldName: "body")?.byteRange == node.byteRange,
              let only = JavaIntentionSyntax.singleStatement(in: node) else { return nil }
        let value: SyntaxNode?
        switch only.type {
        case "return_statement":
            value = only.namedChild(at: 0)
        case "expression_statement":
            if let expression = only.namedChild(at: 0), statementExpressions.contains(expression.type) { value = expression } else { value = nil }
        default:
            value = nil
        }
        guard let value else { return nil }
        return JavaIntentionEdit.offer(.collapseLambda, replacing: node.byteRange, with: value.text, in: node.tree, source: source)
    }
}

enum JavaCommentIntentions {
    static func offers(for node: SyntaxNode, options: JavaIntentionOptions, source: String) -> [JavaIntentionOffer] {
        var found: [JavaIntentionOffer] = []
        if let offer = toBlock(node, options: options, source: source) { found.append(offer) }
        if let offer = toLines(node, options: options, source: source) { found.append(offer) }
        return found
    }

    private static func toBlock(_ node: SyntaxNode, options: JavaIntentionOptions, source: String) -> JavaIntentionOffer? {
        guard options.isEnabled(.lineCommentsToBlock), node.type == "line_comment",
              let run = commentRun(around: node), run.count >= 2 else { return nil }
        let indent = JavaIntentionSyntax.indent(of: run[0])
        var text = "/*\n"
        for comment in run {
            text += "\(indent) * \(lineBody(comment))\n"
        }
        text += "\(indent) */"
        return JavaIntentionEdit.offer(
            .lineCommentsToBlock, replacing: run[0].startByte..<run[run.count - 1].endByte, with: text, in: node.tree, source: source
        )
    }

    private static func lineBody(_ comment: SyntaxNode) -> String {
        var text = comment.text
        if text.hasPrefix("//") { text.removeFirst(2) }
        if text.hasPrefix(" ") { text.removeFirst() }
        return text
    }

    /// Consecutive line comments with only whitespace between them, the one under the caret included.
    private static func commentRun(around node: SyntaxNode) -> [SyntaxNode]? {
        guard let parent = node.parent else { return nil }
        let kids = parent.children
        guard let index = kids.firstIndex(where: { $0.type == "line_comment" && $0.byteRange == node.byteRange }) else { return nil }
        var start = index
        var end = index
        while start > 0, kids[start - 1].type == "line_comment", onlyWhitespace(from: kids[start - 1], to: kids[start]) { start -= 1 }
        while end + 1 < kids.count, kids[end + 1].type == "line_comment", onlyWhitespace(from: kids[end], to: kids[end + 1]) { end += 1 }
        return Array(kids[start...end])
    }

    private static func onlyWhitespace(from: SyntaxNode, to: SyntaxNode) -> Bool {
        let bytes = from.tree.sourceBytes
        let range = from.endByte..<to.startByte
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else { return false }
        return bytes[range].allSatisfy {
            $0 == JavaSourceBytes.space || $0 == JavaSourceBytes.tab || $0 == JavaSourceBytes.newline || $0 == JavaSourceBytes.carriageReturn
        }
    }

    private static func toLines(_ node: SyntaxNode, options: JavaIntentionOptions, source: String) -> JavaIntentionOffer? {
        guard options.isEnabled(.blockCommentToLines), node.type == "block_comment" else { return nil }
        let raw = node.text
        guard raw.hasPrefix("/*"), raw.hasSuffix("*/"), !raw.hasPrefix("/**"), raw.count >= 4 else { return nil }
        let inner = String(raw.dropFirst(2).dropLast(2))
        var lines = inner.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        if lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        guard !lines.isEmpty else { return nil }
        let bodies = lines.map { line -> String in
            var text = line
            if let range = text.range(of: #"^\s*\*( |$)"#, options: .regularExpression) {
                text.removeSubrange(range)
            }
            return text.trimmingCharacters(in: .whitespaces)
        }
        let indent = JavaIntentionSyntax.indent(of: node)
        let text = bodies.enumerated().map { index, body in
            let line = "//\(body.isEmpty ? "" : " \(body)")"
            return index == 0 ? line : "\(indent)\(line)"
        }.joined(separator: "\n")
        return JavaIntentionEdit.offer(.blockCommentToLines, replacing: node.byteRange, with: text, in: node.tree, source: source)
    }
}

enum JavaStringIntentions {
    static func offers(for node: SyntaxNode, options: JavaIntentionOptions, source: String) -> [JavaIntentionOffer] {
        guard options.isEnabled(.textBlock), node.type == "binary_expression",
              let text = JavaTextBlockInspection.textBlockReplacement(for: node) else { return [] }
        return JavaIntentionEdit.offer(.textBlock, replacing: node.byteRange, with: text, in: node.tree, source: source).map { [$0] } ?? []
    }
}
