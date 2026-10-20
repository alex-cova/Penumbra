import EditorIntelligence
import Foundation

private let commentTypes: Set<String> = ["line_comment", "block_comment"]

private func argumentList(of call: SyntaxNode) -> [SyntaxNode] {
    (call.child(byFieldName: "arguments")?.namedChildren ?? []).filter { !commentTypes.contains($0.type) }
}

/// A `switch` statement over an enum declared in this file that names some constants and not all.
enum JavaSwitchEnumMissingCasesInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.switchEnumMissingCases
    static let nodeTypes: Set<String> = ["switch_expression"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        // A switch that yields a value must be exhaustive for the compiler already.
        guard let parent = node.parent, parent.type == "block" || parent.type == "switch_block_statement_group",
              let condition = node.child(byFieldName: "condition"), let block = node.child(byFieldName: "body") else { return }
        // The labels are the cheap part; the selector's type is only looked up when they qualify.
        var labels: [SyntaxNode] = []
        for child in block.namedChildren { labels.append(contentsOf: child.namedChildren(ofType: "switch_label")) }
        guard !labels.isEmpty else { return }
        var covered = Set<String>()
        for label in labels {
            let text = label.text.trimmingCharacters(in: .whitespaces)
            // `default`, `case null`, qualified names and patterns make exhaustiveness the compiler's business.
            guard text.hasPrefix("case ") else { return }
            for item in text.dropFirst(5).split(separator: ",") {
                let name = item.trimmingCharacters(in: .whitespaces)
                guard let first = name.first, first.isLetter || first == "_", !name.contains(".") else { return }
                covered.insert(name)
            }
        }
        guard let type = JavaDeclaredTypes.type(of: condition.unparenthesized), !type.isArray,
              let enumeration = JavaDeclaredTypes.typeDeclaration(named: type.name, from: node),
              enumeration.type == "enum_declaration", let body = enumeration.child(byFieldName: "body") else { return }
        let constants = body.namedChildren(ofType: "enum_constant").compactMap { $0.child(byFieldName: "name")?.text }
        guard !constants.isEmpty, covered.isSubset(of: Set(constants)) else { return }
        let missing = constants.filter { !covered.contains($0) }
        guard !missing.isEmpty else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "This 'switch' on '\(type.name)' does not cover \(missing.joined(separator: ", ")) and has no default",
            node: condition
        ))
    }
}

/// `synchronized (x) { }`.
enum JavaEmptySynchronizedBlockInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.emptySynchronizedBlock
    static let nodeTypes: Set<String> = ["synchronized_statement"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let body = node.child(byFieldName: "body"),
              body.namedChildren.allSatisfy({ commentTypes.contains($0.type) }) else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Empty 'synchronized' block", node: node))
    }
}

/// `Thread.sleep()` while a monitor is held.
enum JavaSleepWhileHoldingLockInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.sleepWhileHoldingLock
    static let nodeTypes: Set<String> = ["method_invocation"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard node.child(byFieldName: "name")?.text == "sleep", node.child(byFieldName: "object")?.text == "Thread" else { return }
        var current = node.parent
        while let scope = current {
            switch scope.type {
            case "synchronized_statement":
                report(JavaInspectionSupport.inspection(
                    rule, message: "'Thread.sleep()' is called while holding a lock", node: node
                ))
                return
            case "method_declaration":
                if scope.hasModifier("synchronized") {
                    report(JavaInspectionSupport.inspection(
                        rule, message: "'Thread.sleep()' is called while holding a lock", node: node
                    ))
                }
                return
            case "lambda_expression", "constructor_declaration", "class_body", "static_initializer":
                return
            default:
                break
            }
            current = scope.parent
        }
    }
}

/// `a.equals(b)` where both declared types are different wrapper types, or a String and a number.
enum JavaEqualsIncompatibleTypesInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.equalsIncompatibleTypes
    static let nodeTypes: Set<String> = ["method_invocation"]
    private static let boxes: [String: String] = [
        "int": "Integer", "long": "Long", "short": "Short", "byte": "Byte", "double": "Double", "float": "Float",
        "char": "Character", "boolean": "Boolean",
        "Integer": "Integer", "Long": "Long", "Short": "Short", "Byte": "Byte", "Double": "Double", "Float": "Float",
        "Character": "Character", "Boolean": "Boolean", "String": "String",
    ]

    private static func boxed(_ node: SyntaxNode) -> String? {
        guard let type = JavaDeclaredTypes.type(of: node), !type.isArray else { return nil }
        return boxes[type.name]
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard node.child(byFieldName: "name")?.text == "equals" else { return }
        let args = argumentList(of: node)
        let pair: (SyntaxNode, SyntaxNode)
        if args.count == 1, let object = node.child(byFieldName: "object"), object.type != "this" {
            pair = (object, args[0])
        } else if args.count == 2, node.child(byFieldName: "object")?.text == "Objects" {
            pair = (args[0], args[1])
        } else {
            return
        }
        guard let left = boxed(pair.0), let right = boxed(pair.1), left != right else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "'equals()' between '\(left)' and '\(right)' is always false", node: node
        ))
    }
}

/// `long x = a * b;` with `int` operands.
enum JavaIntegerOverflowInLongAssignmentInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.integerOverflowInLongAssignment
    static let nodeTypes: Set<String> = ["variable_declarator", "assignment_expression"]
    private static let narrow: Set<String> = ["int", "short", "byte", "char", "Integer", "Short", "Byte", "Character"]

    private static func isNarrow(_ node: SyntaxNode) -> Bool {
        guard let type = JavaDeclaredTypes.type(of: node), !type.isArray else { return false }
        return narrow.contains(type.name)
    }

    /// The operands of a `*` chain, or nil when the expression is not one.
    private static func factors(_ node: SyntaxNode) -> [SyntaxNode]? {
        let inner = node.unparenthesized
        guard inner.type == "binary_expression", inner.operatorText == "*",
              let left = inner.child(byFieldName: "left"), let right = inner.child(byFieldName: "right") else { return nil }
        return (factors(left) ?? [left.unparenthesized]) + [right.unparenthesized]
    }

    private static let intRange: Int64 = 2_147_483_648

    private static func literal(_ node: SyntaxNode) -> Int64? {
        guard node.type == "decimal_integer_literal" else { return nil }
        return Int64(node.text.replacingOccurrences(of: "_", with: ""))
    }

    private static func saturatingMultiply(_ a: Int64, _ b: Int64) -> Int64 {
        let (product, overflow) = a.multipliedReportingOverflow(by: b)
        return overflow ? Int64.max : product
    }

    /// The value of a `final` field of this file whose initializer is a constant expression.
    private static func constantBound(ofField name: String, at node: SyntaxNode, depth: Int) -> Int64? {
        var current = node.parent
        while let scope = current {
            if scope.type == "class_body" {
                for member in scope.namedChildren where member.type == "field_declaration" && member.hasModifier("final") {
                    for declarator in member.namedChildren(ofType: "variable_declarator")
                    where declarator.child(byFieldName: "name")?.text == name {
                        guard let value = declarator.child(byFieldName: "value") else { return nil }
                        return bound(value, depth: depth + 1)
                    }
                }
            }
            current = scope.parent
        }
        return nil
    }

    /// An upper bound of the absolute value of an int expression; a variable of unknown value is
    /// as large as an int can be.
    private static func bound(_ node: SyntaxNode, depth: Int = 0) -> Int64 {
        let inner = node.unparenthesized
        if depth > 4 { return intRange }
        if let value = literal(inner) { return abs(value) }
        switch inner.type {
        case "binary_expression":
            guard let op = inner.operatorText, let left = inner.child(byFieldName: "left"),
                  let right = inner.child(byFieldName: "right") else { return intRange }
            switch op {
            case "*": return min(intRange, saturatingMultiply(bound(left, depth: depth + 1), bound(right, depth: depth + 1)))
            case "+", "-": return min(intRange, bound(left, depth: depth + 1) + bound(right, depth: depth + 1))
            case "%":
                if let divisor = literal(right.unparenthesized) { return abs(divisor) }
                return min(bound(left, depth: depth + 1), intRange)
            case "&":
                if let mask = literal(right.unparenthesized), mask >= 0 { return mask }
                if let mask = literal(left.unparenthesized), mask >= 0 { return mask }
                return intRange
            case ">>", ">>>", "/": return bound(left, depth: depth + 1)
            default: return intRange
            }
        case "identifier":
            if let declared = JavaDeclaredTypes.type(of: inner), !declared.isArray {
                switch declared.name {
                case "byte", "Byte": return 128
                case "short", "Short": return 32_768
                case "char", "Character": return 65_535
                default: break
                }
            }
            return constantBound(ofField: inner.text, at: inner, depth: depth) ?? intRange
        default:
            return intRange
        }
    }

    /// The expression assigned to a `long`, when it is an int product or int shift that can overflow.
    private static func overflowing(_ value: SyntaxNode) -> SyntaxNode? {
        let inner = value.unparenthesized
        guard inner.type == "binary_expression", let op = inner.operatorText else { return nil }
        if op == "*", let parts = factors(inner), parts.count >= 2, parts.allSatisfy(isNarrow) {
            let product = parts.reduce(Int64(1)) { saturatingMultiply($0, bound($1)) }
            return product >= intRange ? inner : nil
        }
        if op == "<<", let left = inner.child(byFieldName: "left"), isNarrow(left) {
            if let right = inner.child(byFieldName: "right"), let distance = literal(right.unparenthesized), distance >= 0, distance < 32 {
                let shifted = bound(left).multipliedReportingOverflow(by: Int64(1) << distance)
                return !shifted.overflow && shifted.partialValue < intRange ? nil : inner
            }
            return inner
        }
        return nil
    }

    private static func target(of node: SyntaxNode) -> SyntaxNode? {
        if node.type == "variable_declarator" {
            guard let declaration = node.parent, declaration.type == "local_variable_declaration" || declaration.type == "field_declaration",
                  declaration.child(byFieldName: "type")?.text == "long" else { return nil }
            return node.child(byFieldName: "value")
        }
        // Cheap tests first: most assignments are not a product or a shift.
        guard node.operatorText == "=", let right = node.child(byFieldName: "right"),
              right.unparenthesized.type == "binary_expression",
              ["*", "<<"].contains(right.unparenthesized.operatorText ?? ""),
              let left = node.child(byFieldName: "left"),
              let type = JavaDeclaredTypes.type(of: left), type.name == "long", !type.isArray else { return nil }
        return right
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let value = target(of: node), let product = overflowing(value) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "'\(product.text)' is computed in 'int' and can overflow before it is widened to 'long'", node: product,
            fixTitle: "Cast the first operand to 'long'"
        ))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "binary_expression", for: diagnostic, tree: tree, source: source),
              overflowing(node) != nil else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: node.startByte..<node.startByte, with: "(long) ", in: tree)
        return [CodeAction(title: "Cast the first operand to 'long'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}
