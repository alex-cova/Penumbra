import EditorIntelligence
import Foundation

private let commentTypes: Set<String> = ["line_comment", "block_comment"]

/// The characters of a string literal's content, without the quotes; nil for a text block.
private func literalContent(_ literal: SyntaxNode) -> String? {
    guard literal.type == "string_literal", literal.text.count >= 2 else { return nil }
    return String(literal.text.dropFirst().dropLast())
}

private func arguments(of call: SyntaxNode) -> [SyntaxNode] {
    (call.child(byFieldName: "arguments")?.namedChildren ?? []).filter { !commentTypes.contains($0.type) }
}

private func integerValue(_ node: SyntaxNode) -> Int? {
    if node.type == "decimal_integer_literal" {
        var text = node.text.replacingOccurrences(of: "_", with: "")
        if text.hasSuffix("L") || text.hasSuffix("l") { text.removeLast() }
        return Int(text)
    }
    if node.type == "unary_expression", node.operatorText == "-" || node.children.first?.type == "-",
       let operand = node.namedChild(at: 0), let value = integerValue(operand) {
        return -value
    }
    return nil
}

/// `s.split(".")`, `s.split("|")`, `s.replaceAll(".", "")`: a metacharacter as the whole regular expression.
enum JavaSplitRegexSpecialCharInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.splitRegexSpecialChar
    static let nodeTypes: Set<String> = ["method_invocation"]
    private static let splitMeta = Set(".|*+?$^([{)")
    private static let replaceMeta = Set(".|*+?")

    private static func literalArgument(of node: SyntaxNode) -> (literal: SyntaxNode, character: Character, method: String)? {
        guard let name = node.child(byFieldName: "name")?.text, ["split", "replaceAll", "replaceFirst"].contains(name),
              let object = node.child(byFieldName: "object"),
              let first = arguments(of: node).first, let content = literalContent(first), content.count == 1,
              let character = content.first else { return nil }
        let isString = object.type == "string_literal"
            || (["identifier", "field_access"].contains(object.type) && JavaDeclaredTypes.type(of: object) == .string)
        guard isString else { return nil }
        let meta = name == "split" ? splitMeta : replaceMeta
        guard meta.contains(character) else { return nil }
        return (first, character, name)
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let found = literalArgument(of: node) else { return }
        report(JavaInspectionSupport.inspection(
            rule,
            message: "'\(found.method)(\(found.literal.text))' takes a regular expression, in which '\(found.character)' is a metacharacter",
            node: found.literal, fixTitle: "Escape the character"
        ))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let literal = JavaInspectionSupport.node(of: "string_literal", for: diagnostic, tree: tree, source: source),
              let call = literal.parent?.parent, call.type == "method_invocation",
              let found = literalArgument(of: call), found.literal.byteRange == literal.byteRange else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: literal.byteRange, with: "\"\\\\\(found.character)\"", in: tree)
        return [CodeAction(title: "Escape the character", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// `catch (IOException e) { throw new IllegalStateException("x"); }`: the cause is dropped.
enum JavaExceptionCauseLostInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.exceptionCauseLost
    static let nodeTypes: Set<String> = ["throw_statement"]
    private static let ignoredNames: Set<String> = ["ignored", "ignore", "expected", "unused", "_"]
    /// JDK exceptions that cannot take a cause in their constructor.
    private static let withoutCauseConstructor: Set<String> = [
        "UnknownHostException", "SocketTimeoutException", "UnsupportedEncodingException", "InstantiationException",
        "NumberFormatException", "InputMismatchException", "FileNotFoundException", "EOFException", "MalformedURLException",
        "ConnectException", "NoRouteToHostException", "ProtocolException", "NullPointerException", "IndexOutOfBoundsException",
        "ArrayIndexOutOfBoundsException", "StringIndexOutOfBoundsException", "NoSuchElementException", "ArithmeticException",
        "IllegalMonitorStateException", "ArrayStoreException", "ClassCastException", "NegativeArraySizeException",
        "OutOfMemoryError", "StackOverflowError", "InterruptedException", "CloneNotSupportedException",
    ]
    private static let boundaries: Set<String> = [
        "method_declaration", "constructor_declaration", "lambda_expression", "class_body", "static_initializer",
    ]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let creation = node.namedChild(at: 0), creation.type == "object_creation_expression",
              creation.firstNamedChild(ofType: "class_body") == nil,
              let type = creation.child(byFieldName: "type"), type.text.hasSuffix("Exception") || type.text.hasSuffix("Error"),
              !withoutCauseConstructor.contains(type.text) else { return }
        var clause: SyntaxNode?
        var current = node.parent
        while let scope = current, !boundaries.contains(scope.type) {
            if scope.type == "catch_clause" { clause = scope; break }
            current = scope.parent
        }
        guard let clause, let parameter = clause.firstNamedChild(ofType: "catch_formal_parameter"),
              let name = parameter.child(byFieldName: "name"), !ignoredNames.contains(name.text),
              let body = clause.child(byFieldName: "body") else { return }
        var used = false
        body.forEachDescendant { if $0.type == "identifier", $0.text == name.text { used = true } }
        guard !used else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "The caught exception '\(name.text)' is not passed as the cause, so its stack trace is lost", node: node
        ))
    }
}

/// `d == 0.1` and `a == b` on `double` / `float`.
enum JavaFloatingPointEqualityInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.floatingPointEquality
    static let nodeTypes: Set<String> = ["binary_expression"]
    private static let specialFields: Set<String> = ["NaN", "POSITIVE_INFINITY", "NEGATIVE_INFINITY", "MAX_VALUE", "MIN_VALUE"]

    private static func isFloating(_ node: SyntaxNode) -> Bool {
        guard let type = JavaDeclaredTypes.type(of: node), !type.isArray else { return false }
        return type.name == "double" || type.name == "float"
    }

    private static func isZero(_ node: SyntaxNode) -> Bool {
        let inner = node.unparenthesized
        guard ["decimal_integer_literal", "decimal_floating_point_literal"].contains(inner.type) else { return false }
        var text = inner.text.replacingOccurrences(of: "_", with: "").lowercased()
        while let last = text.last, "lfd".contains(last) { text.removeLast() }
        return Double(text) == 0
    }

    private static func isSpecial(_ node: SyntaxNode) -> Bool {
        let inner = node.unparenthesized
        guard inner.type == "field_access", let field = inner.child(byFieldName: "field") else { return false }
        return specialFields.contains(field.text)
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let op = node.operatorText, op == "==" || op == "!=",
              let left = node.child(byFieldName: "left"), let right = node.child(byFieldName: "right"),
              isFloating(left) || isFloating(right), !isZero(left), !isZero(right),
              !isSpecial(left), !isSpecial(right), left.text != right.text else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Floating-point values should not be compared with '\(op)'; use a tolerance", node: node
        ))
    }
}

/// `x << 32`, `l >> 64`, `x << -1`.
enum JavaShiftOutOfRangeInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.shiftOutOfRange
    static let nodeTypes: Set<String> = ["binary_expression", "assignment_expression"]
    private static let shifts: Set<String> = ["<<", ">>", ">>>", "<<=", ">>=", ">>>="]
    private static let wide: Set<String> = ["long", "Long"]
    private static let narrow: Set<String> = ["int", "short", "byte", "char", "Integer", "Short", "Byte", "Character"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let op = node.operatorText, shifts.contains(op),
              let left = node.child(byFieldName: "left"), let right = node.child(byFieldName: "right"),
              let distance = integerValue(right.unparenthesized),
              let type = JavaDeclaredTypes.type(of: left), !type.isArray else { return }
        let width: Int
        if wide.contains(type.name) { width = 64 } else if narrow.contains(type.name) { width = 32 } else { return }
        guard distance < 0 || distance >= width else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Shift by \(distance) is out of range for '\(type.name)': only the low \(width == 64 ? 6 : 5) bits are used",
            node: right
        ))
    }
}

/// `if (flag = value)`.
enum JavaAssignmentAsConditionInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.assignmentAsCondition
    static let nodeTypes: Set<String> = ["if_statement", "while_statement", "do_statement", "ternary_expression"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let condition = node.child(byFieldName: "condition")?.unparenthesized,
              condition.type == "assignment_expression", condition.operatorText == "=",
              let value = condition.child(byFieldName: "right")?.unparenthesized else { return }
        // `if (done = compute() != 0)` assigns and tests on purpose; a literal or a plain variable
        // on the right is where `=` was typed for `==`.
        guard ["true", "false", "identifier", "field_access"].contains(value.type) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Assignment '\(condition.text)' is used as a condition", node: condition, fixTitle: "Replace '=' with '=='"
        ))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let assignment = JavaInspectionSupport.node(of: "assignment_expression", for: diagnostic, tree: tree, source: source),
              let op = assignment.child(byFieldName: "operator"), op.text == "=" else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: op.byteRange, with: "==", in: tree)
        return [CodeAction(title: "Replace '=' with '=='", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// `Pattern.compile("a+")` inside a loop.
enum JavaPatternCompileInLoopInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.patternCompileInLoop
    static let nodeTypes: Set<String> = ["method_invocation"]
    private static let loops: Set<String> = ["for_statement", "enhanced_for_statement", "while_statement", "do_statement"]
    private static let boundaries: Set<String> = [
        "method_declaration", "constructor_declaration", "class_body", "static_initializer", "lambda_expression",
    ]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard node.child(byFieldName: "name")?.text == "compile", node.child(byFieldName: "object")?.text == "Pattern",
              let first = arguments(of: node).first, first.type == "string_literal" else { return }
        var current = node.parent
        while let scope = current, !boundaries.contains(scope.type) {
            if loops.contains(scope.type) {
                report(JavaInspectionSupport.inspection(
                    rule, message: "'Pattern.compile(\(first.text))' compiles the same pattern on every iteration", node: node
                ))
                return
            }
            current = scope.parent
        }
    }
}
