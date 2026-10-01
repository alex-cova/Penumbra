import EditorIntelligence
import Foundation

enum JavaRoundingOfIntegersInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.roundingOfIntegers
    static let nodeTypes: Set<String> = ["method_invocation"]
    private static let rounding: Set<String> = ["round", "floor", "ceil", "rint"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let name = node.child(byFieldName: "name")?.text, rounding.contains(name),
              let object = node.child(byFieldName: "object"), object.text == "Math" || object.text == "java.lang.Math",
              let arguments = node.child(byFieldName: "arguments"), arguments.namedChildCount == 1,
              let argument = arguments.namedChild(at: 0)?.unparenthesized else { return }
        if let type = JavaDeclaredTypes.type(of: argument), type.isIntegral {
            report(JavaInspectionSupport.inspection(rule, message: "'Math.\(name)()' of an integer does nothing", node: node))
        } else if JavaIntegerDivision.isIntegerDivision(argument) {
            report(JavaInspectionSupport.inspection(rule, message: "'Math.\(name)()' of an integer division: the division has already truncated", node: node))
        }
    }
}

enum JavaIntegerDivision {
    /// `a / b` where both sides are declared integral.
    static func isIntegerDivision(_ node: SyntaxNode) -> Bool {
        let inner = node.unparenthesized
        guard inner.type == "binary_expression", inner.operatorText == "/",
              let left = inner.child(byFieldName: "left"), let right = inner.child(byFieldName: "right"),
              let leftType = JavaDeclaredTypes.type(of: left), let rightType = JavaDeclaredTypes.type(of: right) else { return false }
        return leftType.isIntegral && rightType.isIntegral
    }
}

enum JavaIntegerDivisionInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.integerDivisionInFloatingContext
    static let nodeTypes: Set<String> = ["local_variable_declaration", "assignment_expression", "cast_expression"]

    /// The division and the floating type its result goes into.
    private static func targets(of node: SyntaxNode) -> [(division: SyntaxNode, floating: String)] {
        switch node.type {
        case "local_variable_declaration":
            guard let type = node.child(byFieldName: "type"), type.type == "floating_point_type" else { return [] }
            return node.namedChildren(ofType: "variable_declarator").compactMap { declarator in
                guard declarator.child(byFieldName: "dimensions") == nil, let value = declarator.child(byFieldName: "value") else { return nil }
                return (value.unparenthesized, type.text)
            }.filter { JavaIntegerDivision.isIntegerDivision($0.division) }
        case "assignment_expression":
            guard let op = node.operatorText, ["=", "+=", "-="].contains(op), let left = node.child(byFieldName: "left"),
                  let value = node.child(byFieldName: "right"), let type = JavaDeclaredTypes.type(of: left),
                  type.isFloatingPoint, JavaIntegerDivision.isIntegerDivision(value) else { return [] }
            return [(value.unparenthesized, type.name.lowercased())]
        default:
            guard let type = node.child(byFieldName: "type"), type.type == "floating_point_type",
                  let value = node.child(byFieldName: "value"), JavaIntegerDivision.isIntegerDivision(value) else { return [] }
            return [(value.unparenthesized, type.text)]
        }
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        for (division, floating) in targets(of: node) {
            report(JavaInspectionSupport.inspection(
                rule, message: "Integer division '\(division.text)' is truncated before it becomes a '\(floating)'", node: division,
                fixTitle: "Cast the dividend to '\(floating)'"
            ))
        }
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let division = JavaInspectionSupport.node(of: "binary_expression", for: diagnostic, tree: tree, source: source),
              let left = division.child(byFieldName: "left") else { return [] }
        // The declaration, assignment or cast the division feeds into tells float from double.
        var holder = division.parent
        while let current = holder, !nodeTypes.contains(current.type) { holder = current.parent }
        let floating = holder.flatMap { targets(of: $0).first { $0.division.byteRange == division.byteRange }?.floating } ?? "double"
        let simple: Set<String> = ["identifier", "field_access", "method_invocation", "array_access", "parenthesized_expression"]
        let cast = simple.contains(left.type) || left.type.hasSuffix("literal") ? "(\(floating)) \(left.text)" : "(\(floating)) (\(left.text))"
        let edit = JavaInspectionSupport.edit(replacingBytes: left.byteRange, with: cast, in: tree)
        return [CodeAction(title: "Cast the dividend to '\(floating)'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

enum JavaConcatenationInFormatInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.stringConcatenationInFormat
    static let nodeTypes: Set<String> = ["method_invocation"]

    private static func isFormatCall(_ node: SyntaxNode) -> Bool {
        guard let name = node.child(byFieldName: "name")?.text, let object = node.child(byFieldName: "object") else { return false }
        return (name == "format" && object.text == "String") || name == "printf" || (name == "format" && ["System.out", "System.err"].contains(object.text))
    }

    /// `"a" + x + "b"`: a chain of `+` with a literal and something that is not.
    private static func isDynamicConcatenation(_ node: SyntaxNode) -> Bool {
        let inner = node.unparenthesized
        guard inner.type == "binary_expression", inner.operatorText == "+" else { return false }
        var operands: [SyntaxNode] = []
        var stack = [inner]
        while let current = stack.popLast() {
            if current.type == "binary_expression", current.operatorText == "+",
               let left = current.child(byFieldName: "left"), let right = current.child(byFieldName: "right") {
                stack.append(left)
                stack.append(right)
            } else {
                operands.append(current)
            }
        }
        return operands.contains { $0.type == "string_literal" } && operands.contains { !$0.type.hasSuffix("literal") }
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard isFormatCall(node), let arguments = node.child(byFieldName: "arguments")?.namedChildren, let first = arguments.first else { return }
        // `format(Locale, String, ...)`: the format string is the second argument.
        let candidate = first.text.hasPrefix("Locale") || first.text.lowercased().contains("locale") ? arguments.dropFirst().first : first
        guard let format = candidate, isDynamicConcatenation(format) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "String concatenation in the format string: a '%' in the data breaks the call; pass it as an argument", node: format
        ))
    }
}

enum JavaCollectionAddedToItselfInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.collectionAddedToItself
    static let nodeTypes: Set<String> = ["method_invocation"]
    private static let collections: Set<String> = [
        "Collection", "List", "ArrayList", "LinkedList", "Set", "HashSet", "LinkedHashSet", "TreeSet", "SortedSet", "Deque", "ArrayDeque",
        "Queue", "PriorityQueue", "Vector", "Stack", "CopyOnWriteArrayList",
    ]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let name = node.child(byFieldName: "name")?.text, name == "add" || name == "addAll",
              let object = node.child(byFieldName: "object"), JavaSelfComparison.isSimpleReference(object),
              let type = JavaDeclaredTypes.type(of: object), !type.isArray, collections.contains(type.name),
              let arguments = node.child(byFieldName: "arguments"), arguments.namedChildCount == 1,
              arguments.namedChild(at: 0)?.text == object.text else { return }
        report(JavaInspectionSupport.inspection(rule, message: "'\(object.text)' is added to itself", node: node))
    }
}

enum JavaResultOfCallIgnoredInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.resultOfCallIgnored
    static let nodeTypes: Set<String> = ["expression_statement"]
    private static let stringMethods: Set<String> = [
        "trim", "strip", "stripLeading", "stripTrailing", "toLowerCase", "toUpperCase", "replace", "replaceAll", "replaceFirst",
        "substring", "concat", "repeat", "intern", "toCharArray", "length", "isEmpty", "charAt", "indent", "formatted",
    ]
    private static let bigNumberMethods: Set<String> = [
        "add", "subtract", "multiply", "divide", "remainder", "mod", "pow", "negate", "abs", "max", "min", "setScale",
        "stripTrailingZeros", "round", "movePointLeft", "movePointRight",
    ]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        // `case A -> Math.min(a, b);` yields the value.
        guard node.parent?.type != "switch_rule", node.namedChildCount == 1, let call = node.namedChild(at: 0), call.type == "method_invocation",
              let name = call.child(byFieldName: "name")?.text, let object = call.child(byFieldName: "object") else { return }
        let type = JavaDeclaredTypes.type(of: object)
        let ignored: Bool
        if object.text == "Math" || object.text == "java.lang.Math" {
            ignored = true
        } else if let type, !type.isArray, type.name == "String" {
            ignored = stringMethods.contains(name)
        } else if let type, !type.isArray, type.name == "BigDecimal" || type.name == "BigInteger" {
            ignored = bigNumberMethods.contains(name)
        } else {
            ignored = false
        }
        guard ignored else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Result of '\(name)()' is ignored; the receiver is not modified", node: call))
    }
}

enum JavaOverwrittenElementInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.overwrittenElement
    static let nodeTypes: Set<String> = ["expression_statement"]

    /// What a statement writes and what it writes it with: `a[i] = v` or `m.put(k, v)`.
    private static func write(of statement: SyntaxNode) -> (key: String, value: SyntaxNode)? {
        guard statement.namedChildCount == 1, let expression = statement.namedChild(at: 0) else { return nil }
        if expression.type == "assignment_expression", expression.operatorText == "=",
           let left = expression.child(byFieldName: "left"), left.type == "array_access",
           let array = left.child(byFieldName: "array"), let index = left.child(byFieldName: "index"),
           JavaSelfComparison.isSimpleReference(array), isStable(index), let value = expression.child(byFieldName: "right") {
            return (left.text, value)
        }
        if expression.type == "method_invocation", expression.child(byFieldName: "name")?.text == "put",
           let object = expression.child(byFieldName: "object"), JavaSelfComparison.isSimpleReference(object),
           let arguments = expression.child(byFieldName: "arguments"), arguments.namedChildCount == 2,
           let key = arguments.namedChild(at: 0), isStable(key), let value = arguments.namedChild(at: 1) {
            return ("\(object.text).put(\(key.text))", value)
        }
        return nil
    }

    /// An index or key that evaluates to the same thing each time.
    private static func isStable(_ node: SyntaxNode) -> Bool {
        node.type.hasSuffix("literal") || JavaSelfComparison.isSimpleReference(node)
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard node.parent?.type == "block", let first = write(of: node), let next = node.nextNamedSibling,
              let second = write(of: next), first.key == second.key else { return }
        // The second write must not read what the first stored.
        let target = first.key.components(separatedBy: ".put(").first ?? first.key
        let arrayName = target.components(separatedBy: "[").first ?? target
        var readsIt = second.value.text.contains(arrayName)
        second.value.forEachDescendant { if $0.text == first.key { readsIt = true } }
        guard !readsIt else { return }
        report(JavaInspectionSupport.inspection(rule, message: "'\(first.key)' is overwritten by the next statement without being read", node: node))
    }
}

enum JavaInfiniteRecursionInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.infiniteRecursion
    static let nodeTypes: Set<String> = ["method_declaration"]
    private static let simpleStatements: Set<String> = ["expression_statement", "return_statement", "local_variable_declaration", "line_comment", "block_comment"]

    /// A call that passes the method's own parameters straight back in.
    private static func isSelfCall(_ call: SyntaxNode, name: String, parameters: [String]) -> Bool {
        guard call.type == "method_invocation", call.child(byFieldName: "name")?.text == name else { return false }
        if let object = call.child(byFieldName: "object"), object.type != "this" { return false }
        guard let arguments = call.child(byFieldName: "arguments") else { return false }
        return arguments.namedChildren.map(\.text) == parameters
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let name = JavaTypeMembers.name(of: node), let body = node.child(byFieldName: "body"),
              let parameterList = node.child(byFieldName: "parameters") else { return }
        let parameters = parameterList.namedChildren.compactMap { $0.child(byFieldName: "name")?.text }
        guard parameters.count == parameterList.namedChildCount,
              body.namedChildren.allSatisfy({ simpleStatements.contains($0.type) }) else { return }
        for statement in body.namedChildren {
            let call: SyntaxNode?
            switch statement.type {
            case "expression_statement", "return_statement": call = statement.namedChild(at: 0)
            default: call = nil
            }
            guard let call, isSelfCall(call, name: name, parameters: parameters) else { continue }
            report(JavaInspectionSupport.inspection(rule, message: "'\(name)()' calls itself with the same arguments and never stops", node: call))
            return
        }
    }
}

enum JavaDuplicatedDelimitersInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.duplicatedDelimiters
    static let nodeTypes: Set<String> = ["object_creation_expression", "method_invocation"]

    /// The delimiter argument, for `new StringTokenizer(text, delimiters)` and `tokenizer.nextToken(delimiters)`.
    private static func delimiterArgument(of node: SyntaxNode) -> SyntaxNode? {
        if node.type == "object_creation_expression" {
            guard let type = node.child(byFieldName: "type"), JavaDeclaredTypes.simpleName(of: type) == "StringTokenizer" else { return nil }
            return node.child(byFieldName: "arguments")?.namedChild(at: 1)
        }
        guard node.child(byFieldName: "name")?.text == "nextToken" else { return nil }
        return node.child(byFieldName: "arguments")?.namedChild(at: 0)
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let argument = delimiterArgument(of: node), let body = JavaExpressionShape.stringBody(argument) else { return }
        // An escape such as `\n` is one delimiter, so read the literal as escapes and single characters.
        var units: [String] = []
        var pending = body.makeIterator()
        while let character = pending.next() {
            if character == "\\", let escaped = pending.next() { units.append("\\\(escaped)") } else { units.append(String(character)) }
        }
        var seen = Set<String>()
        guard let repeated = units.first(where: { !seen.insert($0).inserted }) else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Delimiter '\(repeated)' appears more than once; each character is a separate delimiter", node: argument))
    }
}
