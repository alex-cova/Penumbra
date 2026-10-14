import EditorIntelligence
import Foundation

private let commentTypes: Set<String> = ["line_comment", "block_comment"]

private func argumentList(of call: SyntaxNode) -> [SyntaxNode] {
    (call.child(byFieldName: "arguments")?.namedChildren ?? []).filter { !commentTypes.contains($0.type) }
}

private func integerValue(_ node: SyntaxNode) -> Int? {
    let inner = node.unparenthesized
    if inner.type == "decimal_integer_literal" { return Int(inner.text.replacingOccurrences(of: "_", with: "")) }
    if inner.type == "unary_expression", inner.child(byFieldName: "operator")?.text == "-",
       let operand = inner.child(byFieldName: "operand"), let value = integerValue(operand) {
        return -value
    }
    return nil
}

/// The operands of a `a + b + c` chain.
private func concatenationOperands(_ node: SyntaxNode) -> [SyntaxNode] {
    let inner = node.unparenthesized
    guard inner.type == "binary_expression", inner.operatorText == "+",
          let left = inner.child(byFieldName: "left"), let right = inner.child(byFieldName: "right") else { return [inner] }
    return concatenationOperands(left) + concatenationOperands(right)
}

/// `java.util.` unless the file imports `Arrays` (or all of `java.util`) already.
private func arraysQualifier(for tree: JavaSyntaxTree) -> String {
    for child in tree.rootNode.namedChildren where child.type == "import_declaration" {
        let text = child.text.replacingOccurrences(of: " ", with: "")
        if text.contains("java.util.Arrays;") || text.contains("java.util.*;") { return "" }
    }
    return "java.util."
}

/// A stray `;` between members or after a type.
enum JavaUnnecessarySemicolonInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.unnecessarySemicolon
    static let nodeTypes: Set<String> = ["class_body", "interface_body", "program"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        for child in node.children where child.type == ";" {
            report(JavaInspectionSupport.inspection(rule, message: "Unnecessary semicolon", node: child, fixTitle: "Remove unnecessary semicolon"))
        }
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        let range = ProblemLocator.nsRange(for: diagnostic.range, in: source)
        let start = JavaNavigationText.utf8ByteOffset(forUTF16Offset: range.location, in: source)
        let node = tree.node(atByteOffset: start)
        guard node.type == ";", node.startByte == start, let parent = node.parent, nodeTypes.contains(parent.type) else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: JavaSourceBytes.removalRange(of: node), with: "", in: tree)
        return [CodeAction(title: "Remove unnecessary semicolon", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// `"a" + x.toString()`.
enum JavaUnnecessaryToStringInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.unnecessaryToString
    static let nodeTypes: Set<String> = ["method_invocation"]

    private static func receiver(of node: SyntaxNode) -> SyntaxNode? {
        guard node.child(byFieldName: "name")?.text == "toString", node.child(byFieldName: "arguments")?.namedChildCount == 0,
              let object = node.child(byFieldName: "object"), object.type != "super",
              let parent = node.parent, parent.type == "binary_expression", parent.operatorText == "+",
              let left = parent.child(byFieldName: "left"), let right = parent.child(byFieldName: "right") else { return nil }
        // The other operand must be a String, or `1 + x.toString()` would turn into numeric addition.
        let other = left.byteRange == node.byteRange ? right : left
        guard JavaDeclaredTypes.type(of: other) == .string else { return nil }
        return object
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let object = receiver(of: node) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "'\(object.text).toString()' is converted by the concatenation anyway", node: node,
            fixTitle: "Remove 'toString()'"
        ))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "method_invocation", for: diagnostic, tree: tree, source: source),
              let object = receiver(of: node) else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: node.byteRange, with: object.text, in: tree)
        return [CodeAction(title: "Remove 'toString()'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// `s.indexOf(x) != -1`, `s.indexOf(x) >= 0`.
enum JavaStringIndexOfContainsInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.stringIndexOfContains
    static let nodeTypes: Set<String> = ["binary_expression"]

    private struct Match {
        let receiver: SyntaxNode
        let argument: SyntaxNode
        let isNegated: Bool
    }

    private static func match(_ node: SyntaxNode) -> Match? {
        guard var op = node.operatorText, let left = node.child(byFieldName: "left"), let right = node.child(byFieldName: "right") else { return nil }
        var call = left
        var number = right
        if integerValue(left) != nil {
            call = right
            number = left
            switch op {
            case ">": op = "<"
            case "<": op = ">"
            case ">=": op = "<="
            case "<=": op = ">="
            default: break
            }
        }
        guard call.type == "method_invocation", call.child(byFieldName: "name")?.text == "indexOf",
              let receiver = call.child(byFieldName: "object"), ["identifier", "field_access"].contains(receiver.type),
              JavaDeclaredTypes.type(of: receiver) == .string,
              argumentList(of: call).count == 1, let argument = argumentList(of: call).first,
              argument.type == "string_literal" || JavaDeclaredTypes.type(of: argument) == .string,
              let value = integerValue(number) else { return nil }
        switch (op, value) {
        case ("!=", -1), (">", -1), (">=", 0): return Match(receiver: receiver, argument: argument, isNegated: false)
        case ("==", -1), ("<", 0), ("<=", -1): return Match(receiver: receiver, argument: argument, isNegated: true)
        default: return nil
        }
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let found = match(node) else { return }
        let text = (found.isNegated ? "!" : "") + "\(found.receiver.text).contains(\(found.argument.text))"
        report(JavaInspectionSupport.inspection(rule, message: "'\(node.text)' can be replaced with '\(text)'", node: node, fixTitle: "Replace with '\(text)'"))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "binary_expression", for: diagnostic, tree: tree, source: source),
              let found = match(node) else { return [] }
        let text = (found.isNegated ? "!" : "") + "\(found.receiver.text).contains(\(found.argument.text))"
        let edit = JavaInspectionSupport.edit(replacingBytes: node.byteRange, with: text, in: tree)
        return [CodeAction(title: "Replace with '\(text)'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// The shape both array-loop rules share: `for (int i = 0; i < n; i++) target[i] = value;`.
private struct ArrayLoop {
    let index: String
    let bound: SyntaxNode
    let target: SyntaxNode
    let value: SyntaxNode

    init?(_ node: SyntaxNode) {
        guard let initializer = node.child(byFieldName: "init"), initializer.type == "local_variable_declaration",
              initializer.child(byFieldName: "type")?.text == "int",
              let declarator = initializer.firstNamedChild(ofType: "variable_declarator"),
              initializer.namedChildren(ofType: "variable_declarator").count == 1,
              let name = declarator.child(byFieldName: "name")?.text, declarator.child(byFieldName: "value")?.text == "0",
              let condition = node.child(byFieldName: "condition"), condition.type == "binary_expression", condition.operatorText == "<",
              condition.child(byFieldName: "left")?.text == name, let bound = condition.child(byFieldName: "right"),
              ["identifier", "field_access", "decimal_integer_literal"].contains(bound.type),
              let update = node.child(byFieldName: "update"), update.type == "update_expression",
              update.text == "\(name)++" || update.text == "++\(name)",
              let body = node.child(byFieldName: "body") else { return nil }
        let statements = body.type == "block" ? body.namedChildren.filter { !commentTypes.contains($0.type) } : [body]
        guard statements.count == 1, statements[0].type == "expression_statement",
              let assignment = statements[0].namedChild(at: 0), assignment.type == "assignment_expression", assignment.operatorText == "=",
              let left = assignment.child(byFieldName: "left"), left.type == "array_access",
              let target = left.child(byFieldName: "array"), ["identifier", "field_access"].contains(target.type),
              left.child(byFieldName: "index")?.text == name,
              let value = assignment.child(byFieldName: "right") else { return nil }
        index = name
        self.bound = bound
        self.target = target
        self.value = value
    }
}

enum JavaManualArrayCopyInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.manualArrayCopy
    static let nodeTypes: Set<String> = ["for_statement"]

    private static func source(of loop: ArrayLoop) -> SyntaxNode? {
        let value = loop.value.unparenthesized
        guard value.type == "array_access", value.child(byFieldName: "index")?.text == loop.index,
              let array = value.child(byFieldName: "array"), ["identifier", "field_access"].contains(array.type),
              array.text != loop.target.text else { return nil }
        return array
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let loop = ArrayLoop(node), source(of: loop) != nil else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "This loop copies an array element by element", node: node, fixTitle: "Replace with 'System.arraycopy()'"
        ))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source text: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "for_statement", for: diagnostic, tree: tree, source: text),
              let loop = ArrayLoop(node), let from = source(of: loop) else { return [] }
        let call = "System.arraycopy(\(from.text), 0, \(loop.target.text), 0, \(loop.bound.text));"
        let edit = JavaInspectionSupport.edit(replacingBytes: node.byteRange, with: call, in: tree)
        return [CodeAction(title: "Replace with 'System.arraycopy()'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

enum JavaArraysFillLoopInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.arraysFillLoop
    static let nodeTypes: Set<String> = ["for_statement"]
    private static let inert: Set<String> = [
        "string_literal", "character_literal", "decimal_integer_literal", "hex_integer_literal", "decimal_floating_point_literal",
        "true", "false", "null_literal", "identifier", "field_access",
    ]

    private static func value(of loop: ArrayLoop) -> SyntaxNode? {
        let value = loop.value.unparenthesized
        guard inert.contains(value.type), value.text != loop.index else { return nil }
        // The element must not depend on the loop index.
        var usesIndex = false
        value.forEachDescendant { if $0.type == "identifier", $0.text == loop.index { usesIndex = true } }
        return usesIndex ? nil : value
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let loop = ArrayLoop(node), value(of: loop) != nil else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "This loop stores the same value in every element: use 'Arrays.fill()'", node: node,
            fixTitle: "Replace with 'Arrays.fill()'"
        ))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source text: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "for_statement", for: diagnostic, tree: tree, source: text),
              let loop = ArrayLoop(node), let value = value(of: loop) else { return [] }
        let prefix = arraysQualifier(for: tree)
        let call: String
        if loop.bound.text == "\(loop.target.text).length" {
            call = "\(prefix)Arrays.fill(\(loop.target.text), \(value.text));"
        } else {
            call = "\(prefix)Arrays.fill(\(loop.target.text), 0, \(loop.bound.text), \(value.text));"
        }
        let edit = JavaInspectionSupport.edit(replacingBytes: node.byteRange, with: call, in: tree)
        return [CodeAction(title: "Replace with 'Arrays.fill()'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// `Collections.sort(list)` → `list.sort(null)`.
enum JavaCollectionsSortToListSortInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.collectionsSortToListSort
    static let nodeTypes: Set<String> = ["method_invocation"]
    private static let lists: Set<String> = ["List", "ArrayList", "LinkedList"]

    private static func replacement(for node: SyntaxNode) -> String? {
        guard node.child(byFieldName: "object")?.text == "Collections", node.child(byFieldName: "name")?.text == "sort" else { return nil }
        let args = argumentList(of: node)
        guard (1...2).contains(args.count), ["identifier", "field_access"].contains(args[0].type),
              let type = JavaDeclaredTypes.type(of: args[0]), !type.isArray, lists.contains(type.name) else { return nil }
        return "\(args[0].text).sort(\(args.count == 2 ? args[1].text : "null"))"
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard context.supports(8), let text = replacement(for: node) else { return }
        report(JavaInspectionSupport.inspection(rule, message: "'\(node.text)' can be replaced with '\(text)'", node: node, fixTitle: "Replace with '\(text)'"))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "method_invocation", for: diagnostic, tree: tree, source: source),
              let text = replacement(for: node) else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: node.byteRange, with: text, in: tree)
        return [CodeAction(title: "Replace with '\(text)'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// `sb.append("a" + b)`.
enum JavaAppendConcatenationInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.appendConcatenation
    static let nodeTypes: Set<String> = ["method_invocation"]
    private static let builders: Set<String> = ["StringBuilder", "StringBuffer"]
    private static let constants: Set<String> = [
        "string_literal", "decimal_integer_literal", "character_literal", "true", "false", "decimal_floating_point_literal",
    ]

    private static func parts(of node: SyntaxNode) -> (receiver: SyntaxNode, operands: [SyntaxNode])? {
        guard node.child(byFieldName: "name")?.text == "append", let receiver = node.child(byFieldName: "object"),
              ["identifier", "field_access"].contains(receiver.type),
              let type = JavaDeclaredTypes.type(of: receiver), !type.isArray, builders.contains(type.name),
              argumentList(of: node).count == 1, let argument = argumentList(of: node).first else { return nil }
        let operands = concatenationOperands(argument)
        // Only a chain that starts as a String is a concatenation all the way: `1 + 2 + "x"` is "3x".
        guard operands.count > 1, operands[0].type == "string_literal",
              operands.contains(where: { !constants.contains($0.type) }) else { return nil }
        return (receiver, operands)
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard parts(of: node) != nil else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "String concatenation as the argument of 'append()' builds a temporary String", node: node,
            fixTitle: "Append the parts separately"
        ))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "method_invocation", for: diagnostic, tree: tree, source: source),
              let found = parts(of: node) else { return [] }
        let chain = found.operands.map { ".append(\($0.text))" }.joined()
        let edit = JavaInspectionSupport.edit(replacingBytes: node.byteRange, with: found.receiver.text + chain, in: tree)
        return [CodeAction(title: "Append the parts separately", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// `100l`.
enum JavaLowercaseLongLiteralInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.lowercaseLongLiteral
    static let nodeTypes: Set<String> = ["decimal_integer_literal", "hex_integer_literal", "octal_integer_literal", "binary_integer_literal"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard node.text.hasSuffix("l") else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "The suffix of '\(node.text)' is easily mistaken for the digit 1", node: node, fixTitle: "Use 'L'"
        ))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        let range = ProblemLocator.nsRange(for: diagnostic.range, in: source)
        let start = JavaNavigationText.utf8ByteOffset(forUTF16Offset: range.location, in: source)
        let node = tree.node(atByteOffset: start)
        guard nodeTypes.contains(node.type), node.startByte == start, node.text.hasSuffix("l") else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: node.byteRange, with: String(node.text.dropLast()) + "L", in: tree)
        return [CodeAction(title: "Use 'L'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// Javadoc `@deprecated` without the annotation.
enum JavaDeprecatedTagWithoutAnnotationInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.deprecatedTagWithoutAnnotation
    /// Looked at per body, pairing each comment with the member after it, so a class of n members
    /// costs n and not n sibling scans.
    static let nodeTypes: Set<String> = ["class_body", "interface_body", "enum_body_declarations", "program"]
    private static let declarations: Set<String> = [
        "method_declaration", "constructor_declaration", "field_declaration", "class_declaration", "interface_declaration",
        "enum_declaration", "record_declaration", "constant_declaration",
    ]
    private static let tag = try! NSRegularExpression(pattern: #"@deprecated\b"#)

    private static func isMissingAnnotation(_ declaration: SyntaxNode, comment: SyntaxNode) -> Bool {
        guard comment.type == "block_comment", comment.text.hasPrefix("/**"), comment.text.contains("@deprecated") else { return false }
        let text = comment.text as NSString
        guard tag.firstMatch(in: comment.text, range: NSRange(location: 0, length: text.length)) != nil else { return false }
        let annotations = declaration.firstNamedChild(ofType: "modifiers")?.namedChildren
            .filter { $0.type == "marker_annotation" || $0.type == "annotation" } ?? []
        return !annotations.contains { ["Deprecated", "java.lang.Deprecated"].contains($0.child(byFieldName: "name")?.text ?? "") }
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        var previous: SyntaxNode?
        for child in node.namedChildren {
            defer { previous = child }
            guard let comment = previous, declarations.contains(child.type), isMissingAnnotation(child, comment: comment) else { continue }
            let target = child.child(byFieldName: "name") ?? child.firstNamedChild(ofType: "variable_declarator")?.child(byFieldName: "name") ?? child
            report(JavaInspectionSupport.inspection(
                rule, message: "The Javadoc has '@deprecated' but the declaration is not annotated '@Deprecated'", node: target,
                fixTitle: "Add '@Deprecated'"
            ))
        }
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        let range = ProblemLocator.nsRange(for: diagnostic.range, in: source)
        let start = JavaNavigationText.utf8ByteOffset(forUTF16Offset: range.location, in: source)
        var current: SyntaxNode? = tree.node(atByteOffset: start)
        while let node = current, !declarations.contains(node.type) { current = node.parent }
        guard let declaration = current, let comment = declaration.previousNamedSibling,
              isMissingAnnotation(declaration, comment: comment) else { return [] }
        let indent = JavaSourceBytes.leadingWhitespace(ofLineContaining: declaration.startByte, in: tree.sourceBytes)
        let edit = JavaInspectionSupport.edit(replacingBytes: declaration.startByte..<declaration.startByte, with: "@Deprecated\n\(indent)", in: tree)
        return [CodeAction(title: "Add '@Deprecated'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}
