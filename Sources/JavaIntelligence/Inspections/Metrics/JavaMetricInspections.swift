import Foundation

private let methodTypes: Set<String> = ["method_declaration", "constructor_declaration", "compact_constructor_declaration"]

private enum JavaMetrics {
    static let branchingStatements: Set<String> = [
        "if_statement", "for_statement", "enhanced_for_statement", "while_statement", "do_statement", "catch_clause", "ternary_expression",
    ]
    /// Statements that open a nesting level. An `else if` continues its chain instead of nesting.
    static let nestingStatements: Set<String> = [
        "if_statement", "for_statement", "enhanced_for_statement", "while_statement", "do_statement", "switch_expression",
        "switch_statement", "try_statement", "try_with_resources_statement", "synchronized_statement",
    ]

    static func complexity(of body: SyntaxNode) -> Int {
        var count = 1
        var stack = [body]
        while let node = stack.popLast() {
            switch node.type {
            case let type where branchingStatements.contains(type):
                count += 1
            case "binary_expression":
                if let op = node.operatorText, op == "&&" || op == "||" { count += 1 }
            case "switch_rule":
                if node.firstNamedChild(ofType: "switch_label")?.text.hasPrefix("default") == false { count += 1 }
            case "switch_block_statement_group":
                if node.firstNamedChild(ofType: "switch_label")?.text.hasPrefix("default") == false { count += 1 }
            default:
                break
            }
            stack.append(contentsOf: node.namedChildren)
        }
        return count
    }

    /// The deepest nesting of control structures in `body`, and the node where it first reaches it.
    static func deepestNesting(of body: SyntaxNode) -> (depth: Int, node: SyntaxNode?) {
        var best = (depth: 0, node: SyntaxNode?.none)
        var stack: [(SyntaxNode, Int)] = [(body, 0)]
        while let (node, depth) = stack.popLast() {
            var childDepth = depth
            if nestingStatements.contains(node.type) {
                let continuesChain = node.type == "if_statement" && node.parent?.type == "if_statement"
                    && node.parent?.child(byFieldName: "alternative")?.byteRange == node.byteRange
                if !continuesChain { childDepth = depth + 1 }
                if childDepth > best.depth { best = (childDepth, node) }
            }
            for child in node.namedChildren { stack.append((child, childDepth)) }
        }
        return best
    }

    static func lineCount(_ node: SyntaxNode) -> Int {
        let bytes = node.tree.sourceBytes
        let end = min(node.endByte, bytes.count)
        var lines = 1
        for index in node.startByte..<end where bytes[index] == JavaSourceBytes.newline { lines += 1 }
        return lines
    }
}

enum JavaCyclomaticComplexityInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.cyclomaticComplexity
    static let nodeTypes = methodTypes

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let body = node.child(byFieldName: "body"), let name = node.child(byFieldName: "name") else { return }
        let limit = context.thresholds.value(for: rule)
        let complexity = JavaMetrics.complexity(of: body)
        guard complexity > limit else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Method '\(name.text)' has cyclomatic complexity \(complexity), above the limit of \(limit)", node: name))
    }
}

enum JavaNestingDepthInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.nestingDepth
    static let nodeTypes = methodTypes

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let body = node.child(byFieldName: "body"), let name = node.child(byFieldName: "name") else { return }
        let limit = context.thresholds.value(for: rule)
        let (depth, deepest) = JavaMetrics.deepestNesting(of: body)
        guard depth > limit, let deepest else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Method '\(name.text)' nests control structures \(depth) deep, above the limit of \(limit)",
            startByte: deepest.startByte, endByte: min(deepest.endByte, deepest.startByte + 1), tree: node.tree
        ))
    }
}

enum JavaParameterCountInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.parameterCount
    static let nodeTypes = methodTypes

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let parameters = node.child(byFieldName: "parameters"), let name = node.child(byFieldName: "name") else { return }
        let limit = context.thresholds.value(for: rule)
        let count = parameters.namedChildren.filter { $0.type == "formal_parameter" || $0.type == "spread_parameter" }.count
        guard count > limit else { return }
        report(JavaInspectionSupport.inspection(rule, message: "'\(name.text)' has \(count) parameters, above the limit of \(limit)", node: name))
    }
}

enum JavaMethodLengthInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.methodLength
    static let nodeTypes = methodTypes

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let body = node.child(byFieldName: "body"), let name = node.child(byFieldName: "name") else { return }
        let limit = context.thresholds.value(for: rule)
        let lines = JavaMetrics.lineCount(body)
        guard lines > limit else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Method '\(name.text)' is \(lines) lines long, above the limit of \(limit)", node: name))
    }
}

enum JavaClassLengthInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.classLength
    static let nodeTypes: Set<String> = ["class_declaration", "interface_declaration", "enum_declaration", "record_declaration"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let name = node.child(byFieldName: "name") else { return }
        let limit = context.thresholds.value(for: rule)
        let lines = JavaMetrics.lineCount(node)
        guard lines > limit else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Type '\(name.text)' is \(lines) lines long, above the limit of \(limit)", node: name))
    }
}
