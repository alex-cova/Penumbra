import EditorIntelligence
import Foundation

enum JavaExpressionShape {
    private static let effectful: Set<String> = ["method_invocation", "assignment_expression", "update_expression", "object_creation_expression"]

    /// Whether evaluating `node` could do anything beyond computing a value.
    static func hasSideEffects(_ node: SyntaxNode) -> Bool {
        if effectful.contains(node.type) { return true }
        var found = false
        node.forEachDescendant { if effectful.contains($0.type) { found = true } }
        return found
    }

    /// Whether `node` is evidently a boolean: a literal, a comparison, `!x`, `instanceof`, or a
    /// variable declared `boolean`.
    static func isBoolean(_ node: SyntaxNode) -> Bool {
        let inner = node.unparenthesized
        switch inner.type {
        case "true", "false", "instanceof_expression":
            return true
        case "unary_expression":
            return inner.text.hasPrefix("!")
        case "binary_expression":
            return ["==", "!=", "<", ">", "<=", ">=", "&&", "||"].contains(inner.operatorText ?? "")
        default:
            guard let type = JavaDeclaredTypes.type(of: inner), !type.isArray else { return false }
            return type.name == "boolean" || type.name == "Boolean"
        }
    }

    /// The literal's text between its quotes; `nil` for a text block.
    static func stringBody(_ node: SyntaxNode) -> String? {
        let literal = node.unparenthesized
        guard literal.type == "string_literal", !literal.text.hasPrefix("\"\"\"") else { return nil }
        return String(literal.text.dropFirst().dropLast())
    }
}

enum JavaAssertSideEffectsInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.assertWithSideEffects
    static let nodeTypes: Set<String> = ["assert_statement"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let condition = node.namedChild(at: 0) else { return }
        var effects: [SyntaxNode] = []
        if ["assignment_expression", "update_expression"].contains(condition.type) { effects.append(condition) }
        condition.forEachDescendant { if ["assignment_expression", "update_expression"].contains($0.type) { effects.append($0) } }
        for effect in effects {
            report(JavaInspectionSupport.inspection(
                rule, message: "'assert' has a side effect ('\(effect.text)') that disappears when assertions are disabled", node: effect
            ))
        }
    }
}

enum JavaConstantAssertInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.constantAssertCondition
    static let nodeTypes: Set<String> = ["assert_statement"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let condition = node.namedChild(at: 0), JavaBooleanSyntax.isLiteral(condition, true) else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Condition of 'assert' is always true", node: node, fixTitle: "Remove 'assert'"))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "assert_statement", for: diagnostic, tree: tree, source: source) else { return [] }
        return JavaJumpStatements.removeFix(title: "Remove 'assert'", node: node, in: tree)
    }
}

enum JavaNonShortCircuitInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.nonShortCircuitBoolean
    static let nodeTypes: Set<String> = ["binary_expression", "assignment_expression"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let op = node.operatorText, ["&", "|", "&=", "|="].contains(op),
              let left = node.child(byFieldName: "left"), let right = node.child(byFieldName: "right"),
              JavaExpressionShape.isBoolean(left) || JavaExpressionShape.isBoolean(right) else { return }
        // `flag |= check()` is the way to run a call and keep the result, so a right side with
        // effects is deliberate.
        guard !JavaExpressionShape.hasSideEffects(right) else { return }
        let isAssignment = op.hasSuffix("=")
        let shortForm = op == "&" || op == "&=" ? "&&" : "||"
        report(JavaInspectionSupport.inspection(
            rule, message: "Non-short-circuit '\(op)' evaluates both operands; '\(shortForm)' may be intended", node: node,
            fixTitle: isAssignment ? nil : "Replace '\(op)' with '\(shortForm)'"
        ))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "binary_expression", for: diagnostic, tree: tree, source: source),
              let token = node.child(byFieldName: "operator"), let right = node.child(byFieldName: "right"),
              !JavaExpressionShape.hasSideEffects(right) else { return [] }
        let replacement = token.text == "&" ? "&&" : "||"
        let edit = JavaInspectionSupport.edit(replacingBytes: token.byteRange, with: replacement, in: tree)
        return [CodeAction(title: "Replace '\(token.text)' with '\(replacement)'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

enum JavaComparableWithoutEqualsInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.comparableWithoutEquals
    static let nodeTypes: Set<String> = ["class_declaration"]

    static func implements(_ type: SyntaxNode, _ name: String) -> Bool {
        guard let list = type.child(byFieldName: "interfaces")?.firstNamedChild(ofType: "type_list") else { return false }
        return list.namedChildren.contains { JavaDeclaredTypes.simpleName(of: $0) == name }
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        // A superclass may supply `equals()`.
        guard node.child(byFieldName: "superclass") == nil, implements(node, "Comparable"), let name = node.child(byFieldName: "name") else { return }
        let methods = JavaTypeMembers.methods(of: node)
        guard methods.contains(where: { JavaTypeMembers.name(of: $0) == "compareTo" }),
              !methods.contains(where: JavaTypeMembers.isEqualsObject) else { return }
        report(JavaInspectionSupport.inspection(rule, message: "'\(name.text)' implements 'Comparable' but does not override 'equals()'", node: name))
    }
}

enum JavaIteratorHasNextInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.iteratorHasNextCallsNext
    static let nodeTypes: Set<String> = ["method_declaration"]

    private static func isIteratorBody(_ body: SyntaxNode) -> Bool {
        guard let owner = body.parent else { return false }
        if owner.type == "class_declaration" { return JavaComparableWithoutEqualsInspection.implements(owner, "Iterator") }
        if owner.type == "object_creation_expression", let type = owner.child(byFieldName: "type") {
            return JavaDeclaredTypes.simpleName(of: type) == "Iterator"
        }
        return false
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard JavaTypeMembers.name(of: node) == "hasNext", node.child(byFieldName: "parameters")?.namedChildCount == 0,
              let classBody = node.parent, isIteratorBody(classBody), let body = node.child(byFieldName: "body") else { return }
        body.forEachDescendant { call in
            guard call.type == "method_invocation", call.child(byFieldName: "name")?.text == "next",
                  call.child(byFieldName: "arguments")?.namedChildCount == 0 else { return }
            let object = call.child(byFieldName: "object")
            guard object == nil || object?.type == "this" else { return }
            report(JavaInspectionSupport.inspection(rule, message: "'hasNext()' calls 'next()', so asking advances the iterator", node: call))
        }
    }
}

enum JavaMismatchedStringCaseInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.mismatchedStringCase
    static let nodeTypes: Set<String> = ["method_invocation"]
    private static let comparing: Set<String> = ["contains", "indexOf", "lastIndexOf", "startsWith", "endsWith", "equals"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let name = node.child(byFieldName: "name")?.text, comparing.contains(name),
              let converted = node.child(byFieldName: "object")?.unparenthesized, converted.type == "method_invocation",
              let conversion = converted.child(byFieldName: "name")?.text, conversion == "toLowerCase" || conversion == "toUpperCase",
              let argument = node.child(byFieldName: "arguments")?.namedChild(at: 0), let body = JavaExpressionShape.stringBody(argument) else { return }
        let lower = conversion == "toLowerCase"
        // Skip escapes such as É and \n, which are not letters as written.
        let letters = body.replacingOccurrences(of: "\\\\.", with: "", options: .regularExpression)
        guard letters.contains(where: { lower ? $0.isUppercase : $0.isLowercase }) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "'\(conversion)()' result can never match a literal containing \(lower ? "upper" : "lower")case letters", node: argument
        ))
    }
}

enum JavaMissingWhitespaceInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.missingWhitespaceInConcatenation
    static let nodeTypes: Set<String> = ["binary_expression"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard node.operatorText == "+", let left = node.child(byFieldName: "left"), let right = node.child(byFieldName: "right"),
              right.type == "string_literal", let rightBody = JavaExpressionShape.stringBody(right) else { return }
        let leftLiteral: SyntaxNode?
        if left.type == "string_literal" {
            leftLiteral = left
        } else if left.type == "binary_expression", left.operatorText == "+", let inner = left.child(byFieldName: "right"), inner.type == "string_literal" {
            leftLiteral = inner
        } else {
            leftLiteral = nil
        }
        // A literal ending in an escape (`...\n`) ends in whitespace, not in the letter after the backslash.
        guard let leftLiteral, let leftBody = JavaExpressionShape.stringBody(leftLiteral),
              leftBody.range(of: "\\\\[A-Za-z0-9]$", options: .regularExpression) == nil,
              let last = leftBody.last, let first = rightBody.first, last.isLetter || last.isNumber, first.isLetter,
              leftBody.contains(where: \.isWhitespace),  // a table of codes ("IO" + "IOT") is not prose
              JavaSourceBytes.hasLineBreak(between: leftLiteral.endByte, and: right.startByte, in: context.tree.sourceBytes) else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Whitespace may be missing between '\(leftBody.suffix(8))' and '\(rightBody.prefix(8))'", node: right))
    }
}

enum JavaClassNewInstanceInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.classNewInstance
    static let nodeTypes: Set<String> = ["method_invocation"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard node.child(byFieldName: "name")?.text == "newInstance", node.child(byFieldName: "arguments")?.namedChildCount == 0,
              let object = node.child(byFieldName: "object")?.unparenthesized else { return }
        let isClass: Bool
        switch object.type {
        case "class_literal": isClass = true
        case "method_invocation": isClass = object.child(byFieldName: "name")?.text == "forName" && object.child(byFieldName: "object")?.text == "Class"
        default: isClass = JavaDeclaredTypes.type(of: object)?.name == "Class"
        }
        guard isClass else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "'Class.newInstance()' propagates checked constructor exceptions; use 'getDeclaredConstructor().newInstance()'", node: node
        ))
    }
}
