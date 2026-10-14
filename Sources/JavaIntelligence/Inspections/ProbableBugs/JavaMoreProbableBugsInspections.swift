import EditorIntelligence
import Foundation

private let commentTypes: Set<String> = ["line_comment", "block_comment"]

/// The member (method, constructor, initializer) or lambda body `node` sits in; the file otherwise.
private func enclosingMember(of node: SyntaxNode) -> SyntaxNode {
    var current = node.parent
    while let scope = current {
        if ["method_declaration", "constructor_declaration", "static_initializer", "initializer"].contains(scope.type)
            || scope.type.hasSuffix("_declaration") && scope.type != "local_variable_declaration" && scope.type != "field_declaration" {
            return scope
        }
        current = scope.parent
    }
    return node.tree.rootNode
}

/// `optional.get()` on a variable declared `Optional<…>` that is never tested in the member.
enum JavaOptionalGetWithoutCheckInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.optionalGetWithoutCheck
    static let nodeTypes: Set<String> = ["method_invocation"]
    private static let guards: Set<String> = ["isPresent", "isEmpty", "ifPresent", "ifPresentOrElse"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard node.child(byFieldName: "name")?.text == "get", node.child(byFieldName: "arguments")?.namedChildCount == 0,
              let object = node.child(byFieldName: "object"), object.type == "identifier",
              let type = JavaDeclaredTypes.variableType(named: object.text, at: object), type.name == "Optional", !type.isArray
        else { return }
        var guarded = false
        enclosingMember(of: node).forEachDescendant { candidate in
            guard !guarded, candidate.type == "method_invocation",
                  let receiver = candidate.child(byFieldName: "object"), receiver.type == "identifier", receiver.text == object.text,
                  let name = candidate.child(byFieldName: "name"), guards.contains(name.text) else { return }
            guarded = true
        }
        guard !guarded else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "'\(object.text).get()' is called without checking '\(object.text).isPresent()'", node: node
        ))
    }
}

/// A `case` group that runs into the next one.
enum JavaSwitchFallThroughInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.switchFallThrough
    static let nodeTypes: Set<String> = ["switch_block"]
    private static let simpleStatements: Set<String> = ["expression_statement", "local_variable_declaration"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        var previous: SyntaxNode?
        var commented = false
        for child in node.namedChildren {
            if commentTypes.contains(child.type) {
                if previous != nil, isFallThroughComment(child.text) { commented = true }
            } else if child.type == "switch_block_statement_group" {
                if let previous, !commented, !hasLeadingFallThroughComment(child), fallsThrough(previous),
                   let label = child.firstNamedChild(ofType: "switch_label") {
                    report(JavaInspectionSupport.inspection(rule, message: "Fall-through in 'switch' statement", node: label))
                }
                previous = child
                commented = false
            }
        }
    }

    /// `case 2: // fall through`: the comment follows the label of the group that is fallen into.
    private static func hasLeadingFallThroughComment(_ group: SyntaxNode) -> Bool {
        for child in group.namedChildren {
            if child.type == "switch_label" { continue }
            if commentTypes.contains(child.type) {
                if isFallThroughComment(child.text) { return true }
                continue
            }
            return false
        }
        return false
    }

    private static func fallsThrough(_ group: SyntaxNode) -> Bool {
        let parts = group.namedChildren.filter { $0.type != "switch_label" }
        if let last = parts.last, commentTypes.contains(last.type), isFallThroughComment(last.text) { return false }
        guard let last = parts.last(where: { !commentTypes.contains($0.type) }) else { return false }
        return simpleStatements.contains(last.type)
    }

    private static func isFallThroughComment(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("fall") && (lowered.contains("through") || lowered.contains("thru"))
    }
}

/// `if (a) … else if (a) …`: the second branch is dead.
enum JavaDuplicateConditionInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.duplicateCondition
    static let nodeTypes: Set<String> = ["if_statement"]
    private static let impure: Set<String> = [
        "method_invocation", "assignment_expression", "update_expression", "object_creation_expression", "lambda_expression",
    ]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        if let parent = node.parent, parent.type == "if_statement",
           parent.child(byFieldName: "alternative")?.byteRange == node.byteRange { return }
        var seen = Set<String>()
        var current: SyntaxNode? = node
        while let branch = current, branch.type == "if_statement" {
            if let condition = branch.child(byFieldName: "condition"), isPure(condition) {
                let key = condition.text.filter { !$0.isWhitespace }
                if !seen.insert(key).inserted {
                    report(JavaInspectionSupport.inspection(
                        rule, message: "Duplicate condition '\(condition.unparenthesized.text)': this branch is never reached", node: condition
                    ))
                }
            }
            current = branch.child(byFieldName: "alternative")
        }
    }

    private static func isPure(_ node: SyntaxNode) -> Bool {
        if impure.contains(node.type) { return false }
        var pure = true
        node.forEachDescendant { if impure.contains($0.type) { pure = false } }
        return pure
    }
}

/// `thread.run()` where `start()` was meant.
enum JavaThreadRunCallInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.threadRunCall
    static let nodeTypes: Set<String> = ["method_invocation"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let name = node.child(byFieldName: "name"), name.text == "run", node.child(byFieldName: "arguments")?.namedChildCount == 0,
              let object = node.child(byFieldName: "object") else { return }
        let isThread: Bool
        switch object.type {
        case "object_creation_expression":
            isThread = object.child(byFieldName: "type")?.text == "Thread" && object.firstNamedChild(ofType: "class_body") == nil
        case "identifier":
            let type = JavaDeclaredTypes.type(of: object)
            isThread = type?.name == "Thread" && type?.isArray == false
        default:
            isThread = false
        }
        guard isThread else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Call to 'run()' runs the thread's body in the current thread; use 'start()'", node: name,
            fixTitle: "Replace with 'start()'"
        ))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let name = JavaInspectionSupport.node(of: "identifier", for: diagnostic, tree: tree, source: source),
              name.text == "run" else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: name.byteRange, with: "start", in: tree)
        return [CodeAction(title: "Replace with 'start()'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// `String.format("%s %s", a)`: conversions and arguments that do not line up.
enum JavaFormatArgumentCountInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.formatArgumentCount
    static let nodeTypes: Set<String> = ["method_invocation"]

    /// `%[index$][flags][width][.precision]conversion`; `%n` and `%%` take no argument.
    private static let specifier = try! NSRegularExpression(
        pattern: #"%(?:(\d+)\$)?([-#+ 0,(<]*)(\d+)?(?:\.\d+)?([tT][a-zA-Z]|[a-zA-Z%])"#
    )

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let name = node.child(byFieldName: "name")?.text, let arguments = node.child(byFieldName: "arguments") else { return }
        let all = arguments.namedChildren.filter { !commentTypes.contains($0.type) }
        let object = node.child(byFieldName: "object")
        var format: SyntaxNode?
        var provided: [SyntaxNode] = []
        if let object, object.text == "String", name == "format", let first = all.first {
            format = first
            provided = Array(all.dropFirst())
        } else if let object, ["System.out", "System.err"].contains(object.text), ["printf", "format"].contains(name), let first = all.first {
            format = first
            provided = Array(all.dropFirst())
        } else if let object, object.type == "string_literal", name == "formatted" {
            format = object
            provided = all
        }
        guard let format, format.type == "string_literal" else { return }
        let literal = format.text
        guard literal.count >= 2 else { return }
        let body = String(literal.dropFirst().dropLast())
        let ns = body as NSString
        var expected = 0
        for match in specifier.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            if match.range(at: 1).location != NSNotFound { return }
            if ns.substring(with: match.range(at: 2)).contains("<") { return }
            let conversion = ns.substring(with: match.range(at: 4))
            if conversion == "n" || conversion == "%" { continue }
            expected += 1
        }
        guard provided.count != expected else { return }
        // A single argument of unknown type may be an `Object[]` spread into the varargs.
        if provided.count == 1, expected != 1 {
            let argument = provided[0]
            let scalarLiteral = ["string_literal", "decimal_integer_literal", "true", "false", "character_literal"].contains(argument.type)
            let declared = JavaDeclaredTypes.type(of: argument)
            guard scalarLiteral || (declared != nil && declared?.isArray == false) else { return }
        }
        let plural: (Int) -> String = { "\($0) argument\($0 == 1 ? "" : "s")" }
        report(JavaInspectionSupport.inspection(
            rule, message: "The format string has \(plural(expected)) to fill but \(provided.isEmpty ? "none are" : "\(provided.count) \(provided.count == 1 ? "is" : "are")") supplied",
            node: format
        ))
    }
}

/// `BigDecimal.equals()` compares scale as well as value.
enum JavaBigDecimalEqualsInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.bigDecimalEquals
    static let nodeTypes: Set<String> = ["method_invocation"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let name = node.child(byFieldName: "name"), name.text == "equals", node.child(byFieldName: "arguments")?.namedChildCount == 1,
              let object = node.child(byFieldName: "object"), ["identifier", "field_access"].contains(object.type),
              let type = JavaDeclaredTypes.type(of: object), type.name == "BigDecimal", !type.isArray else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "'BigDecimal.equals()' also compares the scale, so 1.0 and 1.00 differ; use 'compareTo()'", node: name
        ))
    }
}
