import EditorIntelligence
import Foundation

enum JavaConcatenationWithEmptyStringInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.concatenationWithEmptyString
    static let nodeTypes: Set<String> = ["binary_expression"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard node.operatorText == "+", let left = node.child(byFieldName: "left"), let right = node.child(byFieldName: "right") else { return }
        let empty = [left, right].first { $0.unparenthesized.type == "string_literal" && $0.unparenthesized.text == "\"\"" }
        guard let empty else { return }
        let other = empty.byteRange == left.byteRange ? right : left
        report(JavaInspectionSupport.inspection(
            rule, message: "Empty string used in concatenation", node: node, fixTitle: valueOfOperand(other) == nil ? nil : "Replace with 'String.valueOf()'"
        ))
    }

    /// The operand to pass to `String.valueOf`, when doing so cannot change the result: a number,
    /// a char or a variable declared as a non-String, non-array type.
    private static func valueOfOperand(_ operand: SyntaxNode) -> String? {
        let node = operand.unparenthesized
        guard let type = JavaDeclaredTypes.type(of: node), !type.isArray, type != .string else { return nil }
        return node.text
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "binary_expression", for: diagnostic, tree: tree, source: source),
              let left = node.child(byFieldName: "left"), let right = node.child(byFieldName: "right") else { return [] }
        let leftEmpty = left.unparenthesized.text == "\"\"" && left.unparenthesized.type == "string_literal"
        guard let operand = valueOfOperand(leftEmpty ? right : left) else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: node.byteRange, with: "String.valueOf(\(operand))", in: tree)
        return [CodeAction(title: "Replace with 'String.valueOf()'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

enum JavaManualMinMaxInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.manualMinMax
    static let nodeTypes: Set<String> = ["ternary_expression"]

    /// `max` or `min` and the two operands, for `a > b ? a : b` and its mirror images.
    private static func analyze(_ node: SyntaxNode) -> (function: String, left: SyntaxNode, right: SyntaxNode)? {
        guard let condition = node.child(byFieldName: "condition")?.unparenthesized, condition.type == "binary_expression",
              let op = condition.operatorText, ["<", "<=", ">", ">="].contains(op),
              let left = condition.child(byFieldName: "left"), let right = condition.child(byFieldName: "right"),
              let consequence = node.child(byFieldName: "consequence"), let alternative = node.child(byFieldName: "alternative"),
              JavaDeclaredTypes.type(of: left)?.isPrimitiveNumber == true, JavaDeclaredTypes.type(of: right)?.isPrimitiveNumber == true,
              JavaSelfComparison.isSimpleReference(left) || left.type.hasSuffix("literal"),
              JavaSelfComparison.isSimpleReference(right) || right.type.hasSuffix("literal") else { return nil }
        let greater = op.hasPrefix(">")
        if consequence.text == left.text, alternative.text == right.text { return (greater ? "max" : "min", left, right) }
        if consequence.text == right.text, alternative.text == left.text { return (greater ? "min" : "max", left, right) }
        return nil
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let (function, _, _) = analyze(node) else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Can be replaced with 'Math.\(function)()'", node: node, fixTitle: "Replace with 'Math.\(function)()'"))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "ternary_expression", for: diagnostic, tree: tree, source: source),
              let (function, left, right) = analyze(node) else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: node.byteRange, with: "Math.\(function)(\(left.text), \(right.text))", in: tree)
        return [CodeAction(title: "Replace with 'Math.\(function)()'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

enum JavaUnnecessarilyEscapedCharacterInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.unnecessarilyEscapedCharacter
    static let nodeTypes: Set<String> = ["string_literal", "character_literal"]

    /// The literal's text with the redundant backslashes dropped, or `nil` when there are none:
    /// `\'` is redundant in a string, `\"` in a char.
    static func unescaped(_ literal: SyntaxNode) -> String? {
        let text = literal.text
        guard !text.hasPrefix("\"\"\"") else { return nil }
        let redundant: Character = literal.type == "string_literal" ? "'" : "\""
        var result = ""
        var changed = false
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else { result.append(character); continue }
            guard let escaped = iterator.next() else { result.append(character); break }
            if escaped == redundant { changed = true; result.append(escaped) } else { result.append(character); result.append(escaped) }
        }
        return changed ? result : nil
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard unescaped(node) != nil else { return }
        let escape = node.type == "string_literal" ? "\\'" : "\\\""
        report(JavaInspectionSupport.inspection(rule, message: "Unnecessarily escaped character '\(escape)'", node: node, fixTitle: "Remove unnecessary escape"))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        for type in nodeTypes {
            guard let node = JavaInspectionSupport.node(of: type, for: diagnostic, tree: tree, source: source),
                  let replacement = unescaped(node) else { continue }
            let edit = JavaInspectionSupport.edit(replacingBytes: node.byteRange, with: replacement, in: tree)
            return [CodeAction(title: "Remove unnecessary escape", kind: "quickfix", edits: [edit], isPreferred: true)]
        }
        return []
    }
}
