import EditorIntelligence
import Foundation

private let commentTypes: Set<String> = ["line_comment", "block_comment"]

/// `for (int i = 0; i < a.length; i++) … a[i] …` and `for (Iterator<T> it = c.iterator(); it.hasNext();) { T x = it.next(); … }`.
enum JavaForCanBeForeachInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.forCanBeForeach
    static let nodeTypes: Set<String> = ["for_statement"]

    private struct Conversion {
        let message: String
        /// Replacement for `startByte..<headerEnd`, or nil when the element type cannot be read.
        let header: String?
        let headerEnd: Int
        let edits: [(Range<Int>, String)]
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let conversion = conversion(for: node, context: context) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: conversion.message, startByte: node.startByte, endByte: conversion.headerEnd, tree: node.tree,
            fixTitle: conversion.header == nil ? nil : "Replace with enhanced 'for'"
        ))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        let range = ProblemLocator.nsRange(for: diagnostic.range, in: source)
        let start = JavaNavigationText.utf8ByteOffset(forUTF16Offset: range.location, in: source)
        var current: SyntaxNode? = tree.node(atByteOffset: start)
        while let node = current, node.type != "for_statement" || node.startByte != start { current = node.parent }
        guard let node = current, let context = JavaInspectionContext(source: source, tree: tree, url: URL(fileURLWithPath: "/fix.java"), index: JavaIndex()),
              let conversion = conversion(for: node, context: context), let header = conversion.header else { return [] }
        var edits = [JavaInspectionSupport.edit(replacingBytes: node.startByte..<conversion.headerEnd, with: header, in: tree)]
        for (range, text) in conversion.edits { edits.append(JavaInspectionSupport.edit(replacingBytes: range, with: text, in: tree)) }
        return [CodeAction(title: "Replace with enhanced 'for'", kind: "quickfix", edits: edits, isPreferred: true)]
    }

    private static func conversion(for node: SyntaxNode, context: JavaInspectionContext) -> Conversion? {
        guard let body = node.child(byFieldName: "body"), let initializer = node.child(byFieldName: "init"),
              initializer.type == "local_variable_declaration", initializer.namedChildren(ofType: "variable_declarator").count == 1,
              let declarator = initializer.firstNamedChild(ofType: "variable_declarator"),
              let variable = declarator.child(byFieldName: "name"), let value = declarator.child(byFieldName: "value"),
              let condition = node.child(byFieldName: "condition") else { return nil }
        let table = context.tree.declarationCache.fileSymbols(context: context)
        let update = node.child(byFieldName: "update")
        if let update {
            // Exactly one update expression: the token before ')' is the update itself.
            guard let close = node.children.last(where: { $0.type == ")" && $0.endByte <= body.startByte }),
                  let before = node.children.last(where: { $0.endByte <= close.startByte }), before.byteRange == update.byteRange else { return nil }
            return indexLoop(node, body: body, variable: variable, value: value, condition: condition, update: update, table: table, context: context)
        }
        return iteratorLoop(node, body: body, variable: variable, value: value, condition: condition, initializer: initializer, table: table)
    }

    // MARK: Index loops

    private static func indexLoop(
        _ node: SyntaxNode, body: SyntaxNode, variable: SyntaxNode, value: SyntaxNode, condition: SyntaxNode, update: SyntaxNode,
        table: JavaFileSymbolTable, context: JavaInspectionContext
    ) -> Conversion? {
        guard value.type == "decimal_integer_literal", value.text == "0",
              condition.type == "binary_expression", condition.operatorText == "<",
              let left = condition.child(byFieldName: "left"), left.type == "identifier", left.text == variable.text,
              let bound = condition.child(byFieldName: "right"), isIncrement(update, of: variable.text),
              let local = table.locals[variable.byteRange] else { return nil }
        let collection: SyntaxNode
        let isArray: Bool
        switch bound.type {
        case "field_access":
            guard bound.child(byFieldName: "field")?.text == "length", let object = bound.child(byFieldName: "object"), object.type == "identifier" else { return nil }
            collection = object
            isArray = true
        case "method_invocation":
            guard bound.child(byFieldName: "name")?.text == "size", bound.child(byFieldName: "arguments")?.namedChildCount == 0,
                  let object = bound.child(byFieldName: "object"), object.type == "identifier" else { return nil }
            collection = object
            isArray = false
        default:
            return nil
        }
        guard let declared = JavaDeclaredTypes.type(of: collection), declared.isArray == isArray,
              isArray || ["List", "ArrayList", "LinkedList", "Vector", "CopyOnWriteArrayList"].contains(declared.name) else { return nil }
        // Every use of the index in the body must be a plain read of `collection[i]` / `collection.get(i)`.
        var elements: [SyntaxNode] = []
        for use in local.uses where body.byteRange.contains(use.lowerBound) {
            let identifier = context.tree.node(inByteRange: use)
            guard let element = elementExpression(of: identifier, collection: collection.text, isArray: isArray) else { return nil }
            elements.append(element)
        }
        let headerUses = local.uses.filter { !body.byteRange.contains($0.lowerBound) }
        guard !elements.isEmpty, headerUses.count == 2 else { return nil }
        // Nothing else in the body may touch the collection, so it cannot change under the loop.
        var mentions = 0
        var stack = [body]
        while let current = stack.popLast() {
            if current.type == "identifier", current.text == collection.text { mentions += 1 }
            stack.append(contentsOf: current.namedChildren)
        }
        guard mentions == elements.count else { return nil }
        let message = "'for' loop over '\(collection.text)' can be replaced with enhanced 'for'"
        let elementType = elementTypeText(collection: collection, isArray: isArray, table: table, tree: context.tree)
        guard let elementType else { return Conversion(message: message, header: nil, headerEnd: body.startByte, edits: []) }
        let name = freshName(for: collection.text, table: table)
        return Conversion(
            message: message, header: "for (\(elementType) \(name) : \(collection.text)) ", headerEnd: body.startByte,
            edits: elements.map { ($0.byteRange, name) }
        )
    }

    private static func isIncrement(_ update: SyntaxNode, of name: String) -> Bool {
        if update.type == "update_expression" { return update.text.filter { !$0.isWhitespace } == "\(name)++" || update.text.filter { !$0.isWhitespace } == "++\(name)" }
        if update.type == "assignment_expression" { return update.operatorText == "+=" && update.child(byFieldName: "left")?.text == name && update.child(byFieldName: "right")?.text == "1" }
        return false
    }

    /// The `a[i]` / `a.get(i)` expression an index use belongs to, when it is only read.
    private static func elementExpression(of use: SyntaxNode, collection: String, isArray: Bool) -> SyntaxNode? {
        guard let parent = use.parent else { return nil }
        if isArray {
            guard parent.type == "array_access", parent.child(byFieldName: "index")?.byteRange == use.byteRange,
                  parent.child(byFieldName: "array")?.text == collection, !isWriteTarget(parent) else { return nil }
            return parent
        }
        guard parent.type == "argument_list", parent.namedChildCount == 1, let call = parent.parent, call.type == "method_invocation",
              call.child(byFieldName: "name")?.text == "get", call.child(byFieldName: "object")?.text == collection else { return nil }
        return call
    }

    private static func isWriteTarget(_ element: SyntaxNode) -> Bool {
        guard let parent = element.parent else { return false }
        if parent.type == "assignment_expression" { return parent.child(byFieldName: "left")?.byteRange == element.byteRange }
        return parent.type == "update_expression"
    }

    private static func freshName(for collection: String, table: JavaFileSymbolTable) -> String {
        var candidates = ["item", "element", "entry", "value"]
        if collection.count > 2, collection.hasSuffix("s"), collection.last == "s" {
            let singular = String(collection.dropLast())
            if singular != collection { candidates.insert(singular, at: 0) }
        }
        return candidates.first { table.occurrences[$0] == nil && !javaKeywords.contains($0) } ?? "element\(collection.count)"
    }

    private static let javaKeywords: Set<String> = ["int", "long", "char", "byte", "short", "double", "float", "boolean", "var", "new", "this", "case", "default"]

    /// The element type spelled in the collection's local declaration, if it has one.
    private static func elementTypeText(collection: SyntaxNode, isArray: Bool, table: JavaFileSymbolTable, tree: JavaSyntaxTree) -> String? {
        guard let local = table.locals.values.first(where: { $0.uses.contains(collection.byteRange) }) else { return nil }
        let declaration = tree.node(inByteRange: local.declaration)
        guard let owner = declaration.parent else { return nil }
        let type: SyntaxNode?
        var extraDimensions = ""
        switch owner.type {
        case "variable_declarator":
            type = owner.parent?.child(byFieldName: "type")
            extraDimensions = owner.child(byFieldName: "dimensions")?.text ?? ""
        case "formal_parameter":
            type = owner.child(byFieldName: "type")
            extraDimensions = owner.child(byFieldName: "dimensions")?.text ?? ""
        default:
            return nil
        }
        guard let type else { return nil }
        if isArray {
            guard extraDimensions.isEmpty, type.type == "array_type", let element = type.child(byFieldName: "element"),
                  let dimensions = type.child(byFieldName: "dimensions") else { return nil }
            let rest = String(dimensions.text.filter { !$0.isWhitespace }.dropFirst(2))
            return element.text + rest
        }
        guard type.type == "generic_type", let arguments = type.firstNamedChild(ofType: "type_arguments"), arguments.namedChildCount == 1,
              let argument = arguments.namedChild(at: 0), argument.type != "wildcard" else { return nil }
        return argument.text
    }

    // MARK: Iterator loops

    private static func iteratorLoop(
        _ node: SyntaxNode, body: SyntaxNode, variable: SyntaxNode, value: SyntaxNode, condition: SyntaxNode,
        initializer: SyntaxNode, table: JavaFileSymbolTable
    ) -> Conversion? {
        guard value.type == "method_invocation", value.child(byFieldName: "name")?.text == "iterator",
              value.child(byFieldName: "arguments")?.namedChildCount == 0, let source = value.child(byFieldName: "object"),
              condition.type == "method_invocation", condition.child(byFieldName: "name")?.text == "hasNext",
              condition.child(byFieldName: "object")?.text == variable.text,
              body.type == "block", let first = body.namedChildren.first(where: { !commentTypes.contains($0.type) }),
              first.type == "local_variable_declaration", first.namedChildren(ofType: "variable_declarator").count == 1,
              let element = first.firstNamedChild(ofType: "variable_declarator"), let elementName = element.child(byFieldName: "name"),
              let call = element.child(byFieldName: "value"), call.type == "method_invocation",
              call.child(byFieldName: "name")?.text == "next", call.child(byFieldName: "object")?.text == variable.text,
              let elementType = first.child(byFieldName: "type"), elementType.text != "var",
              let local = table.locals[variable.byteRange] else { return nil }
        // The iterator may appear only in the header's `hasNext()` and that one `next()`.
        guard local.uses.filter({ body.byteRange.contains($0.lowerBound) }).count == 1 else { return nil }
        let prefix = first.hasModifier("final") ? "final " : ""
        return Conversion(
            message: "'for' loop over iterator can be replaced with enhanced 'for'",
            header: "for (\(prefix)\(elementType.text) \(elementName.text) : \(source.text)) ", headerEnd: body.startByte,
            edits: [(JavaSourceBytes.removalRange(of: first), "")]
        )
    }
}

/// `R r = new R(); try { … } finally { r.close(); }`.
enum JavaTryFinallyCanBeTryWithResourcesInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.tryFinallyCanBeTryWithResources
    static let nodeTypes: Set<String> = ["try_statement"]

    private static let closeableNames: Set<String> = [
        "Scanner", "Connection", "Statement", "PreparedStatement", "CallableStatement", "ResultSet", "Socket", "ServerSocket",
        "RandomAccessFile", "Formatter", "ZipFile", "JarFile", "Closeable", "AutoCloseable", "Stream", "Process",
        "PrintWriter", "PrintStream", "ExecutorService",
    ]
    private static let closeableSuffixes = ["Stream", "Reader", "Writer", "Channel"]

    private struct Shape {
        let declaration: SyntaxNode
        let resource: SyntaxNode
        let finally: SyntaxNode
        let body: SyntaxNode
    }

    private static func shape(of node: SyntaxNode, context: JavaInspectionContext) -> Shape? {
        guard let body = node.child(byFieldName: "body"), let finally = node.firstNamedChild(ofType: "finally_clause"),
              let block = finally.firstNamedChild(ofType: "block"), block.namedChildCount == 1, let statement = block.namedChild(at: 0),
              let parent = node.parent, parent.type == "block" else { return nil }
        let siblings = parent.namedChildren.filter { !commentTypes.contains($0.type) }
        guard let index = siblings.firstIndex(where: { $0.byteRange == node.byteRange }), index > 0 else { return nil }
        let declaration = siblings[index - 1]
        guard declaration.type == "local_variable_declaration", declaration.namedChildren(ofType: "variable_declarator").count == 1,
              let declarator = declaration.firstNamedChild(ofType: "variable_declarator"), let name = declarator.child(byFieldName: "name"),
              declarator.child(byFieldName: "value") != nil, isCloseable(declaration, declarator: declarator),
              closes(statement, name: name.text) else { return nil }
        let table = node.tree.declarationCache.fileSymbols(context: context)
        guard let local = table.locals[name.byteRange] else { return nil }
        // Later code (or a reassignment) would no longer see the variable once it is a resource.
        for use in local.uses {
            if use.lowerBound >= node.endByte { return nil }
            if use.lowerBound >= body.startByte, JavaLocalUsages.isWrite(node.tree.node(inByteRange: use)) { return nil }
        }
        return Shape(declaration: declaration, resource: name, finally: finally, body: body)
    }

    private static func isCloseable(_ declaration: SyntaxNode, declarator: SyntaxNode) -> Bool {
        var typeNode = declaration.child(byFieldName: "type")
        if typeNode?.text == "var" { typeNode = declarator.child(byFieldName: "value")?.child(byFieldName: "type") }
        guard let typeNode else { return false }
        let simple = JavaDeclaredTypes.simpleName(of: typeNode)
        return closeableNames.contains(simple) || closeableSuffixes.contains { simple.hasSuffix($0) && simple.count > $0.count }
    }

    /// `r.close();`, or the same inside `if (r != null) …`.
    private static func closes(_ statement: SyntaxNode, name: String) -> Bool {
        func isClose(_ node: SyntaxNode) -> Bool {
            guard node.type == "expression_statement", let call = node.namedChild(at: 0), call.type == "method_invocation" else { return false }
            return call.child(byFieldName: "name")?.text == "close" && call.child(byFieldName: "object")?.text == name
                && call.child(byFieldName: "arguments")?.namedChildCount == 0
        }
        if isClose(statement) { return true }
        guard statement.type == "if_statement", statement.child(byFieldName: "alternative") == nil,
              let condition = statement.child(byFieldName: "condition"),
              condition.unparenthesized.text.filter({ !$0.isWhitespace }) == "\(name)!=null",
              var inner = statement.child(byFieldName: "consequence") else { return false }
        if inner.type == "block", inner.namedChildCount == 1, let only = inner.namedChild(at: 0) { inner = only }
        return isClose(inner)
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let shape = shape(of: node, context: context) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "'\(shape.resource.text)' is closed in 'finally': use try-with-resources", node: shape.finally,
            fixTitle: "Convert to try-with-resources"
        ))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let finally = JavaInspectionSupport.node(of: "finally_clause", for: diagnostic, tree: tree, source: source),
              let node = finally.parent, node.type == "try_statement",
              let context = JavaInspectionContext(source: source, tree: tree, url: URL(fileURLWithPath: "/fix.java"), index: JavaIndex()),
              let shape = shape(of: node, context: context), !JavaBooleanSyntax.hasComment(finally) else { return [] }
        var declarationText = shape.declaration.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if declarationText.hasSuffix(";") { declarationText.removeLast() }
        // The finally clause goes, with the whitespace before it.
        let previousEnd = node.namedChildren.last { $0.endByte <= finally.startByte }?.endByte ?? finally.startByte
        let edits = [
            JavaInspectionSupport.edit(replacingBytes: shape.declaration.startByte..<shape.body.startByte, with: "try (\(declarationText)) ", in: tree),
            JavaInspectionSupport.edit(replacingBytes: previousEnd..<finally.endByte, with: "", in: tree),
        ]
        return [CodeAction(title: "Convert to try-with-resources", kind: "quickfix", edits: edits, isPreferred: true)]
    }
}
