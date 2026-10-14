import EditorIntelligence
import Foundation

private let commentTypes: Set<String> = ["line_comment", "block_comment"]

private func argumentList(of call: SyntaxNode) -> [SyntaxNode] {
    (call.child(byFieldName: "arguments")?.namedChildren ?? []).filter { !commentTypes.contains($0.type) }
}

/// `if (x instanceof Foo) { Foo f = (Foo) x; … }` → `if (x instanceof Foo f) { … }`.
enum JavaInstanceOfPatternInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.instanceOfPattern
    static let nodeTypes: Set<String> = ["if_statement"]

    private struct Match {
        let test: SyntaxNode
        let subject: SyntaxNode
        let type: SyntaxNode
        let declaration: SyntaxNode
        let name: String
    }

    private static func match(_ node: SyntaxNode) -> Match? {
        guard let test = node.child(byFieldName: "condition")?.unparenthesized, test.type == "instanceof_expression",
              test.child(byFieldName: "name") == nil,
              let subject = test.child(byFieldName: "left"), subject.type == "identifier",
              let type = test.child(byFieldName: "right"),
              let block = node.child(byFieldName: "consequence"), block.type == "block",
              let declaration = block.namedChildren.first(where: { !commentTypes.contains($0.type) }),
              declaration.type == "local_variable_declaration" else { return nil }
        let declarators = declaration.namedChildren(ofType: "variable_declarator")
        guard declarators.count == 1, let declarator = declarators.first,
              let name = declarator.child(byFieldName: "name"),
              let value = declarator.child(byFieldName: "value")?.unparenthesized, value.type == "cast_expression",
              value.child(byFieldName: "value")?.text == subject.text,
              value.child(byFieldName: "type")?.text == type.text,
              let declared = declaration.child(byFieldName: "type"), declared.text == type.text || declared.text == "var" else { return nil }
        return Match(test: test, subject: subject, type: type, declaration: declaration, name: name.text)
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard context.supports(16), let found = match(node) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "'instanceof' followed by a cast to '\(found.type.text)' can use the pattern '\(found.type.text) \(found.name)'",
            node: found.test, fixTitle: "Replace with pattern variable '\(found.name)'"
        ))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let test = JavaInspectionSupport.node(of: "instanceof_expression", for: diagnostic, tree: tree, source: source),
              let parenthesized = test.parent, parenthesized.type == "parenthesized_expression",
              let ifStatement = parenthesized.parent, ifStatement.type == "if_statement",
              let found = match(ifStatement) else { return [] }
        let edits = [
            JavaInspectionSupport.edit(
                replacingBytes: found.test.byteRange, with: "\(found.subject.text) instanceof \(found.type.text) \(found.name)", in: tree
            ),
            JavaInspectionSupport.edit(replacingBytes: JavaSourceBytes.removalRange(of: found.declaration), with: "", in: tree),
        ]
        return [CodeAction(title: "Replace with pattern variable '\(found.name)'", kind: "quickfix", edits: edits, isPreferred: true)]
    }
}

/// An old-style `switch` statement whose groups each end in `break`, `return` or `throw`.
enum JavaEnhancedSwitchInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.enhancedSwitch
    static let nodeTypes: Set<String> = ["switch_expression"]
    private static let terminators: Set<String> = ["return_statement", "throw_statement", "continue_statement"]
    private static let nestedBreakable: Set<String> = [
        "for_statement", "enhanced_for_statement", "while_statement", "do_statement", "switch_expression", "lambda_expression",
        "class_body",
    ]

    private struct Group {
        let labels: [String]
        let body: [SyntaxNode]
        let endsWithBreak: Bool
        let start: Int
        let end: Int
    }

    /// The case groups with stacked labels merged, or nil when the switch cannot become arrows.
    private static func groups(of block: SyntaxNode) -> [Group]? {
        guard block.namedChildren.allSatisfy({ $0.type == "switch_block_statement_group" }) else { return nil }
        var result: [Group] = []
        var labels: [String] = []
        var start: Int?
        for group in block.namedChildren {
            start = start ?? group.startByte
            for label in group.namedChildren(ofType: "switch_label") { labels.append(label.text) }
            let statements = group.namedChildren.filter { $0.type != "switch_label" }
            guard !statements.contains(where: { commentTypes.contains($0.type) }) else { return nil }
            guard !statements.isEmpty else { continue }
            guard !labels.contains("default") || labels.count == 1 else { return nil }
            var body = statements
            var endsWithBreak = false
            if let last = body.last, last.type == "break_statement" {
                guard last.namedChildCount == 0 else { return nil }
                body.removeLast()
                endsWithBreak = true
            } else if let last = body.last, !terminators.contains(last.type) {
                // Only the final group may simply end; anything else falls through.
                guard group.byteRange == block.namedChildren.last?.byteRange else { return nil }
            }
            // A `break` left in the body would have left the switch; an arrow body cannot say that.
            var bad = false
            func scan(_ node: SyntaxNode) {
                if node.type == "break_statement", node.namedChildCount == 0 { bad = true }
                if nestedBreakable.contains(node.type) { return }
                node.namedChildren.forEach(scan)
            }
            body.forEach(scan)
            guard !bad, !body.isEmpty || endsWithBreak else { return nil }
            result.append(Group(labels: labels, body: body, endsWithBreak: endsWithBreak, start: start!, end: group.endByte))
            labels = []
            start = nil
        }
        guard labels.isEmpty, result.count >= 2 else { return nil }
        // A local declared in one group is in scope in the later ones of an old-style switch; each
        // arrow gets a block of its own, so such a switch cannot be converted.
        var declared: [Int: Set<String>] = [:]
        for (index, part) in result.enumerated() {
            for statement in part.body where statement.type == "local_variable_declaration" {
                for declarator in statement.namedChildren(ofType: "variable_declarator") {
                    if let name = declarator.child(byFieldName: "name") { declared[index, default: []].insert(name.text) }
                }
            }
        }
        if !declared.isEmpty {
            for (index, part) in result.enumerated() {
                var mentioned = Set<String>()
                for statement in part.body {
                    if statement.type == "identifier" { mentioned.insert(statement.text) }
                    statement.forEachDescendant { if $0.type == "identifier" { mentioned.insert($0.text) } }
                }
                for (owner, names) in declared where owner != index && !names.isDisjoint(with: mentioned) { return nil }
            }
        }
        return result
    }

    private static func caseLine(for labels: [String]) -> String? {
        if labels == ["default"] { return "default" }
        var values: [String] = []
        for label in labels {
            guard label.hasPrefix("case ") else { return nil }
            values.append(String(label.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        }
        return "case " + values.joined(separator: ", ")
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard context.supports(14), let block = node.child(byFieldName: "body"), block.type == "switch_block",
              let condition = node.child(byFieldName: "condition"), let parts = groups(of: block),
              parts.allSatisfy({ caseLine(for: $0.labels) != nil }) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Statement 'switch' can be replaced with enhanced 'switch'", node: condition,
            fixTitle: "Replace with enhanced 'switch'"
        ))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let condition = JavaInspectionSupport.node(of: "parenthesized_expression", for: diagnostic, tree: tree, source: source),
              let statement = condition.parent, statement.type == "switch_expression",
              let block = statement.child(byFieldName: "body"), let parts = groups(of: block) else { return [] }
        let bytes = tree.sourceBytes
        let indent = JavaSourceBytes.leadingWhitespace(ofLineContaining: parts[0].start, in: bytes)
        var lines: [String] = []
        for (index, part) in parts.enumerated() {
            guard let head = caseLine(for: part.labels), let first = part.body.first, let last = part.body.last else { return [] }
            let prefix = index == 0 ? "" : indent
            if part.body.count == 1, first.type == "expression_statement" {
                lines.append("\(prefix)\(head) -> \(first.text)")
            } else if part.body.count == 1, first.type == "throw_statement" {
                lines.append("\(prefix)\(head) -> \(first.text)")
            } else {
                let text = String(decoding: bytes[first.startByte..<last.endByte], as: UTF8.self)
                lines.append("\(prefix)\(head) -> {\n\(indent)    \(text)\n\(indent)}")
            }
        }
        let edit = JavaInspectionSupport.edit(replacingBytes: parts[0].start..<parts[parts.count - 1].end, with: lines.joined(separator: "\n"), in: tree)
        return [CodeAction(title: "Replace with enhanced 'switch'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// `"a\n" + "b\n" + "c"` → a text block.
enum JavaTextBlockInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.textBlock
    static let nodeTypes: Set<String> = ["binary_expression"]

    private static func operands(of node: SyntaxNode) -> [SyntaxNode]? {
        let inner = node.unparenthesized
        if inner.type == "string_literal" { return [inner] }
        guard inner.type == "binary_expression", inner.operatorText == "+",
              let left = inner.child(byFieldName: "left"), let right = inner.child(byFieldName: "right"),
              let leftOperands = operands(of: left), let rightOperands = operands(of: right) else { return nil }
        return leftOperands + rightOperands
    }

    /// The lines the literals spell, and whether the text ends with a line break; nil when an
    /// escape or trailing whitespace would not survive in a text block.
    private static func lines(of literals: [SyntaxNode]) -> (lines: [String], endsWithNewline: Bool)? {
        var result: [String] = []
        var current = ""
        var newlines = 0
        for literal in literals {
            guard literal.text.count >= 2 else { return nil }
            let characters = Array(literal.text.dropFirst().dropLast())
            var index = 0
            while index < characters.count {
                let character = characters[index]
                if character == "\\" {
                    guard index + 1 < characters.count else { return nil }
                    let next = characters[index + 1]
                    switch next {
                    case "n":
                        guard !current.hasSuffix(" "), !current.hasSuffix("\t") else { return nil }
                        result.append(current)
                        current = ""
                        newlines += 1
                    case "\\", "\"", "'", "t":
                        current.append(character)
                        current.append(next)
                    default:
                        return nil
                    }
                    index += 2
                } else {
                    current.append(character)
                    index += 1
                }
            }
        }
        guard newlines >= 2 else { return nil }
        if !current.isEmpty {
            guard !current.hasSuffix(" "), !current.hasSuffix("\t") else { return nil }
            result.append(current)
            return (result, false)
        }
        return (result, true)
    }

    private static func conversion(for node: SyntaxNode, context: JavaInspectionContext) -> String? {
        guard node.operatorText == "+", let literals = operands(of: node), literals.count >= 3,
              !(node.parent?.type == "binary_expression" && node.parent?.operatorText == "+"),
              let found = lines(of: literals) else { return nil }
        let bytes = node.tree.sourceBytes
        let indent = JavaSourceBytes.leadingWhitespace(ofLineContaining: node.startByte, in: bytes) + "    "
        var text = "\"\"\"\n"
        text += found.lines.map { $0.isEmpty ? "" : indent + $0 }.joined(separator: "\n")
        text += found.endsWithNewline ? "\n\(indent)\"\"\"" : "\"\"\""
        return text
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard context.supports(15), conversion(for: node, context: context) != nil else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "String concatenation can be replaced with a text block", node: node, fixTitle: "Replace with text block"
        ))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "binary_expression", for: diagnostic, tree: tree, source: source),
              let context = JavaInspectionContext(source: source, tree: tree, url: URL(fileURLWithPath: "/fix.java"), index: JavaIndex(), languageLevel: 15),
              let text = conversion(for: node, context: context) else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: node.byteRange, with: text, in: tree)
        return [CodeAction(title: "Replace with text block", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// `Foo f = new Foo();`, `Foo f = (Foo) o;`, `String s = "x";` → `var`. Primitives with a literal are
/// left alone: `int i = 0` reads better than `var i = 0`.
enum JavaLocalVariableTypeCanBeVarInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.localVariableTypeCanBeVar
    static let nodeTypes: Set<String> = ["local_variable_declaration"]

    private static func isObvious(value: SyntaxNode, for type: SyntaxNode) -> Bool {
        let declared = type.text
        guard declared != "var", !declared.contains("<>"), type.type != "array_type" else { return false }
        switch value.type {
        case "object_creation_expression":
            return value.child(byFieldName: "object") == nil && value.firstNamedChild(ofType: "class_body") == nil
                && value.child(byFieldName: "type")?.text == declared
        case "cast_expression":
            return value.child(byFieldName: "type")?.text == declared
        case "string_literal":
            return declared == "String"
        default:
            return false
        }
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard context.supports(10), let type = node.child(byFieldName: "type"),
              node.namedChildren(ofType: "variable_declarator").count == 1,
              let declarator = node.firstNamedChild(ofType: "variable_declarator"),
              declarator.child(byFieldName: "dimensions") == nil,
              let value = declarator.child(byFieldName: "value")?.unparenthesized, isObvious(value: value, for: type) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Type '\(type.text)' can be replaced with 'var'", node: type, fixTitle: "Replace with 'var'"
        ))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        let range = ProblemLocator.nsRange(for: diagnostic.range, in: source)
        let start = JavaNavigationText.utf8ByteOffset(forUTF16Offset: range.location, in: source)
        var current: SyntaxNode? = tree.node(atByteOffset: start)
        while let node = current, node.type != "local_variable_declaration" { current = node.parent }
        guard let declaration = current, let type = declaration.child(byFieldName: "type") else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: type.byteRange, with: "var", in: tree)
        return [CodeAction(title: "Replace with 'var'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// `Collections.emptyList()` → `List.of()`.
enum JavaCollectionsEmptyFactoryInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.collectionsEmptyFactory
    static let nodeTypes: Set<String> = ["method_invocation"]
    private static let replacements: [String: String] = ["emptyList": "List", "emptySet": "Set", "emptyMap": "Map"]

    private static func replacement(for node: SyntaxNode) -> String? {
        guard node.child(byFieldName: "object")?.text == "Collections", let name = node.child(byFieldName: "name")?.text,
              let owner = replacements[name], node.firstNamedChild(ofType: "type_arguments") == nil,
              node.child(byFieldName: "arguments")?.namedChildCount == 0 else { return nil }
        return "\(owner).of()"
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard context.supports(9), let text = replacement(for: node) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "'\(node.text)' can be replaced with '\(text)'", node: node, fixTitle: "Replace with '\(text)'"
        ))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "method_invocation", for: diagnostic, tree: tree, source: source),
              let text = replacement(for: node) else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: node.byteRange, with: text, in: tree)
        return [CodeAction(title: "Replace with '\(text)'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// `s.trim().isEmpty()` → `s.isBlank()`.
enum JavaStringIsBlankInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.stringIsBlank
    static let nodeTypes: Set<String> = ["method_invocation"]

    private static func receiver(of node: SyntaxNode) -> SyntaxNode? {
        guard node.child(byFieldName: "name")?.text == "isEmpty", node.child(byFieldName: "arguments")?.namedChildCount == 0,
              let trimmed = node.child(byFieldName: "object"), trimmed.type == "method_invocation",
              ["trim", "strip"].contains(trimmed.child(byFieldName: "name")?.text ?? ""),
              trimmed.child(byFieldName: "arguments")?.namedChildCount == 0,
              let object = trimmed.child(byFieldName: "object"), ["identifier", "field_access"].contains(object.type),
              JavaDeclaredTypes.type(of: object) == .string else { return nil }
        return object
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard context.supports(11), let object = receiver(of: node) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "'\(node.text)' can be replaced with '\(object.text).isBlank()'", node: node,
            fixTitle: "Replace with 'isBlank()'"
        ))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "method_invocation", for: diagnostic, tree: tree, source: source),
              let object = receiver(of: node) else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: node.byteRange, with: "\(object.text).isBlank()", in: tree)
        return [CodeAction(title: "Replace with 'isBlank()'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// `!optional.isPresent()` → `optional.isEmpty()`.
enum JavaOptionalIsEmptyInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.optionalIsEmpty
    static let nodeTypes: Set<String> = ["unary_expression"]

    private static func receiver(of node: SyntaxNode) -> SyntaxNode? {
        guard node.child(byFieldName: "operator")?.text == "!",
              let call = node.child(byFieldName: "operand")?.unparenthesized, call.type == "method_invocation",
              call.child(byFieldName: "name")?.text == "isPresent", call.child(byFieldName: "arguments")?.namedChildCount == 0,
              let object = call.child(byFieldName: "object"), object.type == "identifier",
              let type = JavaDeclaredTypes.type(of: object), type.name == "Optional", !type.isArray else { return nil }
        return object
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard context.supports(11), let object = receiver(of: node) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "'!\(object.text).isPresent()' can be replaced with '\(object.text).isEmpty()'", node: node,
            fixTitle: "Replace with 'isEmpty()'"
        ))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "unary_expression", for: diagnostic, tree: tree, source: source),
              let object = receiver(of: node) else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: node.byteRange, with: "\(object.text).isEmpty()", in: tree)
        return [CodeAction(title: "Replace with 'isEmpty()'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// `.collect(Collectors.toList())` → `.toList()`.
enum JavaStreamToListInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.streamToList
    static let nodeTypes: Set<String> = ["method_invocation"]

    private static func isMatch(_ node: SyntaxNode) -> Bool {
        guard node.child(byFieldName: "name")?.text == "collect", node.child(byFieldName: "object") != nil else { return false }
        let args = argumentList(of: node)
        return args.count == 1 && args[0].text == "Collectors.toList()"
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard context.supports(16), isMatch(node), let name = node.child(byFieldName: "name") else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "'collect(Collectors.toList())' can be replaced with 'toList()', which returns an unmodifiable list",
            node: name, fixTitle: "Replace with 'toList()'"
        ))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let name = JavaInspectionSupport.node(of: "identifier", for: diagnostic, tree: tree, source: source),
              let call = name.parent, call.type == "method_invocation", isMatch(call) else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: name.startByte..<call.endByte, with: "toList()", in: tree)
        return [CodeAction(title: "Replace with 'toList()'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// `list.get(0)` → `list.getFirst()`, `list.get(list.size() - 1)` → `list.getLast()`.
enum JavaSequencedCollectionAccessInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.sequencedCollectionAccess
    static let nodeTypes: Set<String> = ["method_invocation"]
    private static let sequenced: Set<String> = ["List", "ArrayList", "LinkedList"]

    private static func replacement(for node: SyntaxNode) -> (text: String, label: String)? {
        guard node.child(byFieldName: "name")?.text == "get", let object = node.child(byFieldName: "object"),
              object.type == "identifier", let type = JavaDeclaredTypes.type(of: object), !type.isArray,
              sequenced.contains(type.name) else { return nil }
        let args = argumentList(of: node)
        guard args.count == 1 else { return nil }
        let argument = args[0].unparenthesized
        if argument.type == "decimal_integer_literal", argument.text == "0" { return ("\(object.text).getFirst()", "getFirst()") }
        if argument.type == "binary_expression", argument.operatorText == "-",
           let left = argument.child(byFieldName: "left"), let right = argument.child(byFieldName: "right"),
           right.text == "1", left.type == "method_invocation", left.child(byFieldName: "name")?.text == "size",
           left.child(byFieldName: "arguments")?.namedChildCount == 0, left.child(byFieldName: "object")?.text == object.text {
            return ("\(object.text).getLast()", "getLast()")
        }
        return nil
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard context.supports(21), let found = replacement(for: node) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "'\(node.text)' can be replaced with '\(found.text)'", node: node, fixTitle: "Replace with '\(found.label)'"
        ))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "method_invocation", for: diagnostic, tree: tree, source: source),
              let found = replacement(for: node) else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: node.byteRange, with: found.text, in: tree)
        return [CodeAction(title: "Replace with '\(found.label)'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// `String.format("%d items", n)` → `"%d items".formatted(n)`.
enum JavaStringFormattedInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.stringFormatted
    static let nodeTypes: Set<String> = ["method_invocation"]

    private static func parts(of node: SyntaxNode) -> (format: SyntaxNode, rest: [SyntaxNode])? {
        guard node.child(byFieldName: "name")?.text == "format", node.child(byFieldName: "object")?.text == "String" else { return nil }
        let args = argumentList(of: node)
        guard let format = args.first, format.type == "string_literal" else { return nil }
        return (format, Array(args.dropFirst()))
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard context.supports(15), parts(of: node) != nil else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "'String.format()' can be replaced with 'formatted()'", node: node, fixTitle: "Replace with 'formatted()'"
        ))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "method_invocation", for: diagnostic, tree: tree, source: source),
              let found = parts(of: node) else { return [] }
        let text = "\(found.format.text).formatted(\(found.rest.map(\.text).joined(separator: ", ")))"
        let edit = JavaInspectionSupport.edit(replacingBytes: node.byteRange, with: text, in: tree)
        return [CodeAction(title: "Replace with 'formatted()'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// `m.containsKey(k) ? m.get(k) : d` → `m.getOrDefault(k, d)`.
enum JavaMapGetOrDefaultInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.mapGetOrDefault
    static let nodeTypes: Set<String> = ["ternary_expression"]
    /// `getOrDefault` evaluates its default every time; the conditional only when the key is
    /// missing. Only a default that costs nothing and has no effect can move into the call.
    private static let cheapFallbacks: Set<String> = [
        "string_literal", "decimal_integer_literal", "hex_integer_literal", "decimal_floating_point_literal",
        "character_literal", "true", "false", "identifier", "field_access",
    ]

    private static func replacement(for node: SyntaxNode) -> String? {
        guard let condition = node.child(byFieldName: "condition")?.unparenthesized,
              let value = node.child(byFieldName: "consequence")?.unparenthesized,
              let fallback = node.child(byFieldName: "alternative"),
              condition.type == "method_invocation", condition.child(byFieldName: "name")?.text == "containsKey",
              value.type == "method_invocation", value.child(byFieldName: "name")?.text == "get",
              let map = condition.child(byFieldName: "object"), let valueMap = value.child(byFieldName: "object"),
              map.type == "identifier" || map.type == "field_access", map.text == valueMap.text,
              let key = argumentList(of: condition).first, argumentList(of: condition).count == 1,
              argumentList(of: value).count == 1, argumentList(of: value)[0].text == key.text,
              cheapFallbacks.contains(fallback.unparenthesized.type) else { return nil }
        return "\(map.text).getOrDefault(\(key.text), \(fallback.text))"
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard context.supports(8), replacement(for: node) != nil else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Conditional can be replaced with 'getOrDefault()'", node: node, fixTitle: "Replace with 'getOrDefault()'"
        ))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "ternary_expression", for: diagnostic, tree: tree, source: source),
              let text = replacement(for: node) else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: node.byteRange, with: text, in: tree)
        return [CodeAction(title: "Replace with 'getOrDefault()'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}
