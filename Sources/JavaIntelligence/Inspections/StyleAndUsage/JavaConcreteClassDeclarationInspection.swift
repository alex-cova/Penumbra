import EditorIntelligence
import Foundation

/// `ArrayList<String> x` -> `List<String> x`, for locals and private fields whose every use works through the interface.
enum JavaDeclarationUsesConcreteClassInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.declarationUsesConcreteClass
    static let nodeTypes: Set<String> = ["local_variable_declaration", "field_declaration"]
    private static let interfaces: [String: String] = [
        "ArrayList": "List", "LinkedList": "List", "HashMap": "Map", "LinkedHashMap": "Map", "HashSet": "Set", "LinkedHashSet": "Set",
    ]
    /// Methods only the concrete classes (or their `Deque` / sequenced-collection side) have.
    private static let concreteOnly: Set<String> = [
        "clone", "ensureCapacity", "trimToSize", "removeEldestEntry",
        "addFirst", "addLast", "getFirst", "getLast", "removeFirst", "removeLast", "push", "pop", "peek", "peekFirst", "peekLast",
        "poll", "pollFirst", "pollLast", "offer", "offerFirst", "offerLast", "element", "descendingIterator",
        "removeFirstOccurrence", "removeLastOccurrence", "reversed", "putFirst", "putLast", "firstEntry", "lastEntry",
        "pollFirstEntry", "pollLastEntry", "sequencedKeySet", "sequencedValues", "sequencedEntrySet",
    ]

    /// The identifier of the concrete class in the declared type.
    private static func concreteIdentifier(of declaration: SyntaxNode) -> SyntaxNode? {
        guard let type = declaration.child(byFieldName: "type") else { return nil }
        let identifier = type.type == "generic_type" ? type.namedChild(at: 0) : type
        guard let identifier, identifier.type == "type_identifier", interfaces[identifier.text] != nil else { return nil }
        return identifier
    }

    private static func isInterfaceUse(_ use: SyntaxNode) -> Bool {
        var reference = use
        if let parent = reference.parent, parent.type == "field_access", parent.child(byFieldName: "object")?.type == "this",
           parent.child(byFieldName: "field")?.byteRange == reference.byteRange {
            reference = parent
        }
        guard let parent = reference.parent else { return false }
        switch parent.type {
        case "method_invocation":
            guard parent.child(byFieldName: "object")?.byteRange == reference.byteRange,
                  let name = parent.child(byFieldName: "name")?.text else { return false }
            return !concreteOnly.contains(name)
        case "enhanced_for_statement":
            return parent.child(byFieldName: "value")?.byteRange == reference.byteRange
        case "assignment_expression":
            return parent.child(byFieldName: "left")?.byteRange == reference.byteRange && parent.operatorText == "="
        default:
            return false
        }
    }

    /// Whether `interface` names `java.util.<interface>` at `node` (imported, or no import says otherwise).
    /// A visible same-named type of this file clashes: the fix must not add the import.
    /// An external supertype clashes only when it (transitively) brings a nested type of
    /// that name; a file-wide "any external supertype clashes" would silence the rule for
    /// every class that extends anything (everything implementing `Serializable`).
    private static func importState(of interface: String, from node: SyntaxNode) -> (clash: Bool, imported: Bool) {
        var imported = false
        for declaration in node.tree.rootNode.namedChildren(ofType: "import_declaration") {
            let text = declaration.text.replacingOccurrences(of: " ", with: "")
            if text == "importjava.util.*;" || text == "importjava.util.\(interface);" { imported = true }
            else if text.hasSuffix(".\(interface);") { return (true, false) }
        }
        if JavaDeclaredTypes.isFileTypeVisible(named: interface, from: node) { return (true, imported) }
        return (externalSupertypeBrings(interface, from: node), imported)
    }

    /// Whether an external supertype of an enclosing type may declare a nested type
    /// called `name`, from the prepass tables. An `.open` table — or no prepass over a
    /// body with an external supertype — clashes, as before.
    private static func externalSupertypeBrings(_ name: String, from node: SyntaxNode) -> Bool {
        let cache = node.tree.declarationCache
        var current: SyntaxNode? = node
        while let scope = current {
            if ["class_body", "interface_body", "enum_body"].contains(scope.type) {
                switch (cache.externalFieldsPrepared, cache.externalFields(forBodyAt: scope.startByte)) {
                case (_, .open):
                    return true
                case (true, .known(_, let nested)):
                    if nested.contains(name) { return true }
                case (true, nil):
                    break
                case (false, _):
                    if JavaInheritedFields.hasExternalSupertypes(body: scope) { return true }
                }
            }
            current = scope.parent
        }
        return false
    }

    private static func candidate(_ node: SyntaxNode, context: JavaInspectionContext) -> (identifier: SyntaxNode, interface: String, needsImport: Bool)? {
        if node.type == "field_declaration", !node.hasModifier("private") { return nil }
        let declarators = node.namedChildren(ofType: "variable_declarator")
        guard declarators.count == 1, let declarator = declarators.first, declarator.child(byFieldName: "dimensions") == nil,
              let name = declarator.child(byFieldName: "name"), let identifier = concreteIdentifier(of: node),
              let interface = interfaces[identifier.text] else { return nil }
        let table = context.tree.declarationCache.fileSymbols(context: context)
        let uses = node.type == "field_declaration"
            ? table.nonLocalOccurrences(of: name.text, excluding: name.byteRange)
            : (table.locals[name.byteRange]?.uses ?? [])
        guard uses.allSatisfy({ isInterfaceUse(context.tree.node(inByteRange: $0)) }) else { return nil }
        let (clash, imported) = importState(of: interface, from: node)
        guard !clash else { return nil }
        return (identifier, interface, !imported)
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let (identifier, interface, _) = candidate(node, context: context),
              let name = node.firstNamedChild(ofType: "variable_declarator")?.child(byFieldName: "name") else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "'\(name.text)' is declared as '\(identifier.text)'; '\(interface)' would do", node: identifier,
            fixTitle: "Change type to '\(interface)'"
        ))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let identifier = JavaInspectionSupport.node(of: "type_identifier", for: diagnostic, tree: tree, source: source),
              let interface = interfaces[identifier.text] else { return [] }
        var edits = [JavaInspectionSupport.edit(replacingBytes: identifier.byteRange, with: interface, in: tree)]
        let root = tree.rootNode
        if !importState(of: interface, from: identifier).imported {
            let line = "import java.util.\(interface);"
            if let last = root.namedChildren(ofType: "import_declaration").last {
                edits.append(JavaInspectionSupport.edit(replacingBytes: last.endByte..<last.endByte, with: "\n\(line)", in: tree))
            } else if let package = root.firstNamedChild(ofType: "package_declaration") {
                edits.append(JavaInspectionSupport.edit(replacingBytes: package.endByte..<package.endByte, with: "\n\n\(line)", in: tree))
            } else {
                edits.append(JavaInspectionSupport.edit(replacingBytes: 0..<0, with: "\(line)\n\n", in: tree))
            }
        }
        return [CodeAction(title: "Change type to '\(interface)'", kind: "quickfix", edits: edits, isPreferred: true)]
    }
}
