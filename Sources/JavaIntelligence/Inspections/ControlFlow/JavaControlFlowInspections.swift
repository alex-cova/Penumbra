import EditorIntelligence
import Foundation

enum JavaBooleanSyntax {
    static func isLiteral(_ node: SyntaxNode, _ value: Bool) -> Bool {
        node.unparenthesized.type == (value ? "true" : "false")
    }

    static func isBooleanLiteral(_ node: SyntaxNode) -> Bool { isLiteral(node, true) || isLiteral(node, false) }

    /// Source text for `!node`: a leading `!` is removed instead of doubled, and anything that is not
    /// a primary expression is parenthesized.
    static func negation(of node: SyntaxNode) -> String {
        let inner = node.unparenthesized
        if inner.type == "unary_expression", inner.text.hasPrefix("!"), let operand = inner.namedChild(at: 0) { return operand.text }
        if inner.type == "true" { return "false" }
        if inner.type == "false" { return "true" }
        let primary: Set<String> = ["identifier", "method_invocation", "field_access", "array_access", "this"]
        return primary.contains(inner.type) ? "!\(inner.text)" : "!(\(inner.text))"
    }

    static func hasComment(_ node: SyntaxNode) -> Bool {
        var found = false
        node.forEachDescendant { if $0.type == "line_comment" || $0.type == "block_comment" { found = true } }
        return found
    }

    /// Source with every whitespace character removed, to compare two pieces of code.
    static func squeezed(_ node: SyntaxNode) -> String {
        node.text.filter { !$0.isWhitespace }
    }
}

/// `if (c) return true; else return false;`, or the same with the `else` as the next statement.
enum JavaRedundantIfStatementInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.redundantIfStatement
    static let nodeTypes: Set<String> = ["if_statement"]

    /// `true`/`false` when `statement` is `return <literal>;`, also inside a block of just that.
    private static func returnedLiteral(_ statement: SyntaxNode?) -> Bool? {
        guard var current = statement else { return nil }
        if current.type == "block", current.namedChildCount == 1, let only = current.namedChild(at: 0) { current = only }
        guard current.type == "return_statement", current.namedChildCount == 1, let value = current.namedChild(at: 0) else { return nil }
        if value.type == "true" { return true }
        if value.type == "false" { return false }
        return nil
    }

    /// The statements the `if` stands for, the condition, and whether it returns `true` when it holds.
    private static func analyze(_ node: SyntaxNode) -> (end: Int, condition: SyntaxNode, returnsTrue: Bool)? {
        guard let condition = node.child(byFieldName: "condition")?.unparenthesized,
              let first = returnedLiteral(node.child(byFieldName: "consequence")) else { return nil }
        if let alternative = node.child(byFieldName: "alternative") {
            guard let second = returnedLiteral(alternative), second != first else { return nil }
            return (node.endByte, condition, first)
        }
        guard node.parent?.type == "block", let next = node.nextNamedSibling, let second = returnedLiteral(next), second != first else { return nil }
        return (next.endByte, condition, first)
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let (_, condition, returnsTrue) = analyze(node) else { return }
        // Another branch of an `else if` chain is part of a larger decision.
        guard node.parent?.type != "if_statement" else { return }
        let replacement = returnsTrue ? "return \(condition.text);" : "return \(JavaBooleanSyntax.negation(of: condition));"
        report(JavaInspectionSupport.inspection(
            rule, message: "'if' statement can be replaced with '\(replacement)'", node: node,
            fixTitle: JavaBooleanSyntax.hasComment(node) ? nil : "Replace with '\(replacement)'"
        ))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "if_statement", for: diagnostic, tree: tree, source: source),
              let (end, condition, returnsTrue) = analyze(node), !JavaBooleanSyntax.hasComment(node) else { return [] }
        let replacement = returnsTrue ? "return \(condition.text);" : "return \(JavaBooleanSyntax.negation(of: condition));"
        let edit = JavaInspectionSupport.edit(replacingBytes: node.startByte..<end, with: replacement, in: tree)
        return [CodeAction(title: "Replace with '\(replacement)'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

enum JavaSimplifiableConditionalInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.simplifiableConditional
    static let nodeTypes: Set<String> = ["ternary_expression"]

    private static func replacement(for node: SyntaxNode) -> String? {
        guard let condition = node.child(byFieldName: "condition"), let yes = node.child(byFieldName: "consequence"),
              let no = node.child(byFieldName: "alternative") else { return nil }
        if JavaBooleanSyntax.isLiteral(yes, true), JavaBooleanSyntax.isLiteral(no, false) { return condition.unparenthesized.text }
        if JavaBooleanSyntax.isLiteral(yes, false), JavaBooleanSyntax.isLiteral(no, true) { return JavaBooleanSyntax.negation(of: condition) }
        return nil
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let replacement = replacement(for: node) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Conditional expression can be simplified to '\(replacement)'", node: node, fixTitle: "Simplify to '\(replacement)'"
        ))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "ternary_expression", for: diagnostic, tree: tree, source: source),
              let replacement = replacement(for: node) else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: node.byteRange, with: replacement, in: tree)
        return [CodeAction(title: "Simplify to '\(replacement)'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

enum JavaIdenticalBranchesInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.identicalBranches
    static let nodeTypes: Set<String> = ["if_statement", "ternary_expression"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let first = node.child(byFieldName: "consequence"), let second = node.child(byFieldName: "alternative"), !JavaBooleanSyntax.hasComment(node),
              JavaBooleanSyntax.squeezed(first) == JavaBooleanSyntax.squeezed(second) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: node.type == "if_statement" ? "'if' statement has identical branches" : "Conditional expression has identical branches",
            node: second
        ))
    }
}

enum JavaDuplicateSwitchBranchesInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.duplicateSwitchBranches
    static let nodeTypes: Set<String> = ["switch_expression"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let block = node.child(byFieldName: "body") else { return }
        var firstWithBody: [String: String] = [:]
        for switchRule in block.namedChildren(ofType: "switch_rule") {
            guard let label = switchRule.firstNamedChild(ofType: "switch_label"),
                  let body = switchRule.namedChildren.last(where: { $0.type != "switch_label" }), !JavaBooleanSyntax.hasComment(switchRule) else { continue }
            let labelText = label.text
            // `null` may only be combined with `default`, so it cannot join a case list.
            guard labelText.hasPrefix("case"), !labelText.contains("("), !labelText.contains(" when "), !labelText.contains("null") else { continue }
            let squeezed = JavaBooleanSyntax.squeezed(body)
            guard squeezed != "{}" else { continue }
            if let earlier = firstWithBody[squeezed] {
                report(JavaInspectionSupport.inspection(
                    rule, message: "Branch duplicates '\(earlier)': merge the labels into one 'case' list", node: label
                ))
            } else {
                firstWithBody[squeezed] = labelText.trimmingCharacters(in: .whitespaces)
            }
        }
    }
}

enum JavaPointlessBooleanInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.pointlessBooleanExpression
    static let nodeTypes: Set<String> = ["binary_expression"]

    private enum Outcome {
        case operand(SyntaxNode)
        case negated(SyntaxNode)
        case constant(Bool, other: SyntaxNode)
    }

    private static func outcome(of node: SyntaxNode) -> Outcome? {
        guard let op = node.operatorText, ["&&", "||", "==", "!="].contains(op),
              let left = node.child(byFieldName: "left"), let right = node.child(byFieldName: "right") else { return nil }
        let literalOnLeft = JavaBooleanSyntax.isBooleanLiteral(left)
        let literalOnRight = JavaBooleanSyntax.isBooleanLiteral(right)
        guard literalOnLeft != literalOnRight else { return nil }
        let literal = literalOnLeft ? left : right
        let other = literalOnLeft ? right : left
        let value = JavaBooleanSyntax.isLiteral(literal, true)
        switch op {
        case "&&": return value ? .operand(other) : .constant(false, other: other)
        case "||": return value ? .constant(true, other: other) : .operand(other)
        case "==": return value ? .operand(other) : .negated(other)
        default: return value ? .negated(other) : .operand(other)
        }
    }

    private static func replacement(for outcome: Outcome) -> String? {
        switch outcome {
        case .operand(let other): return other.text
        case .negated(let other): return JavaBooleanSyntax.negation(of: other)
        case .constant(let value, let other):
            // Dropping `foo() || true` would drop the call.
            return JavaSelfComparison.isSimpleReference(other) || JavaBooleanSyntax.isBooleanLiteral(other) ? String(value) : nil
        }
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let outcome = outcome(of: node) else { return }
        let replacement = replacement(for: outcome)
        let message: String
        switch outcome {
        case .constant(let value, _): message = "Expression is always '\(value)'"
        default: message = "Pointless boolean expression"
        }
        report(JavaInspectionSupport.inspection(
            rule, message: message, node: node, fixTitle: replacement.map { "Simplify to '\($0)'" }
        ))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "binary_expression", for: diagnostic, tree: tree, source: source),
              let outcome = outcome(of: node), let replacement = replacement(for: outcome) else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: node.byteRange, with: replacement, in: tree)
        return [CodeAction(title: "Simplify to '\(replacement)'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

enum JavaConstantConditionInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.constantCondition
    static let nodeTypes: Set<String> = ["if_statement", "while_statement", "for_statement", "ternary_expression"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let condition = node.child(byFieldName: "condition")?.unparenthesized, JavaBooleanSyntax.isBooleanLiteral(condition) else { return }
        let value = condition.type == "true"
        // `while (true)` and `for (;true;)` are how an endless loop is written.
        if value, node.type == "while_statement" || node.type == "for_statement" { return }
        report(JavaInspectionSupport.inspection(rule, message: "Condition '\(condition.type)' is always \(value)", node: condition))
    }
}

/// Statements inside `node`, not counting those in a lambda, a local or anonymous class.
private func ownDescendants(of node: SyntaxNode, stopAtLoops: Bool, visit: (SyntaxNode) -> Void) {
    var stack = Array(node.namedChildren.reversed())
    while let current = stack.popLast() {
        if ["lambda_expression", "class_body", "method_declaration"].contains(current.type) { continue }
        visit(current)
        if stopAtLoops, JavaJumpStatements.loops.contains(current.type) || current.type == "switch_expression" { continue }
        stack.append(contentsOf: current.namedChildren.reversed())
    }
}

enum JavaInfiniteLoopInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.infiniteLoop
    static let nodeTypes: Set<String> = ["while_statement", "for_statement", "do_statement"]

    private static func isEndless(_ node: SyntaxNode) -> Bool {
        let condition = node.child(byFieldName: "condition")
        switch node.type {
        case "for_statement": return condition == nil || JavaBooleanSyntax.isLiteral(condition!, true)
        default: return condition.map { JavaBooleanSyntax.isLiteral($0, true) } ?? false
        }
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard isEndless(node), let body = node.child(byFieldName: "body") else { return }
        // `return`, `throw` and `System.exit` always leave. A `break` leaves this loop unless a nested
        // loop or switch takes it; a labelled one may aim further out, so any label counts.
        var pending: [(node: SyntaxNode, insideNested: Bool)] = [(body, false)]
        while let (current, insideNested) = pending.popLast() {
            if ["lambda_expression", "class_body", "method_declaration"].contains(current.type) { continue }
            switch current.type {
            case "return_statement", "throw_statement":
                return
            case "break_statement":
                if JavaJumpStatements.label(of: current) != nil || !insideNested { return }
            case "method_invocation":
                if current.child(byFieldName: "name")?.text == "exit", current.child(byFieldName: "object")?.text == "System" { return }
            default:
                break
            }
            let takesBreak = JavaJumpStatements.loops.contains(current.type) || current.type == "switch_expression"
            for child in current.namedChildren.reversed() { pending.append((child, insideNested || takesBreak)) }
        }
        report(JavaInspectionSupport.inspection(rule, message: "Infinite loop: nothing leaves it", node: node))
    }
}

enum JavaLoopDoesNotLoopInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.loopDoesNotLoop
    static let nodeTypes: Set<String> = ["while_statement", "for_statement"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let body = node.child(byFieldName: "body"), body.type == "block",
              let last = body.namedChildren.last(where: { $0.type != "line_comment" && $0.type != "block_comment" }) else { return }
        let jump: String
        switch last.type {
        case "break_statement": guard JavaJumpStatements.label(of: last) == nil else { return }; jump = "break"
        case "return_statement": jump = "return"
        case "throw_statement": jump = "throw"
        default: return
        }
        var continues = false
        ownDescendants(of: body, stopAtLoops: false) { if $0.type == "continue_statement" { continues = true } }
        guard !continues else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Loop does not loop: its body always ends with '\(jump)'", node: last))
    }
}
