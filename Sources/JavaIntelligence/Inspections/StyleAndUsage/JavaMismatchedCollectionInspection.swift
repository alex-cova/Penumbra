import Foundation

/// A collection or `StringBuilder` created here that is only read or only written. A local is
/// judged over its uses in the method, a private field over its uses in the file. Anything that
/// lets the object escape (passed on, returned, assigned, used for its result) silences the rule.
enum JavaMismatchedCollectionQueryUpdateInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.mismatchedCollectionQueryUpdate
    static let nodeTypes: Set<String> = ["local_variable_declaration", "field_declaration"]

    private static let collectionTypes: Set<String> = [
        "List", "ArrayList", "LinkedList", "Set", "HashSet", "TreeSet", "LinkedHashSet", "SortedSet", "NavigableSet",
        "Map", "HashMap", "TreeMap", "LinkedHashMap", "SortedMap", "NavigableMap", "ConcurrentHashMap",
        "Collection", "Queue", "Deque", "ArrayDeque", "PriorityQueue", "Stack", "Vector",
        "StringBuilder", "StringBuffer",
    ]
    private static let builderTypes: Set<String> = ["StringBuilder", "StringBuffer"]
    private static let updateMethods: Set<String> = [
        "add", "addAll", "put", "putAll", "putIfAbsent", "remove", "removeAll", "removeIf", "retainAll", "clear", "push", "pop",
        "poll", "pollFirst", "pollLast", "offer", "offerFirst", "offerLast", "addFirst", "addLast", "removeFirst", "removeLast",
        "append", "appendCodePoint", "insert", "delete", "deleteCharAt", "replace", "reverse", "setLength", "setCharAt", "set",
        "sort", "merge", "compute", "computeIfAbsent", "computeIfPresent", "replaceAll",
    ]
    private static let queryMethods: Set<String> = [
        "get", "getOrDefault", "size", "isEmpty", "contains", "containsKey", "containsValue", "containsAll", "indexOf",
        "lastIndexOf", "peek", "peekFirst", "peekLast", "getFirst", "getLast", "element", "iterator", "listIterator", "stream",
        "parallelStream", "forEach", "toString", "length", "charAt", "codePointAt", "substring", "subSequence", "toArray",
        "keySet", "values", "entrySet", "first", "last", "equals", "hashCode", "subList", "chars",
    ]

    private enum Use { case query, update, escape }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        let isField = node.type == "field_declaration"
        if isField {
            guard node.hasModifier("private"), node.parent?.type == "class_body" else { return }
        } else if node.parent?.type == "for_statement" {
            return
        }
        guard node.namedChildren(ofType: "variable_declarator").count == 1,
              let declarator = node.firstNamedChild(ofType: "variable_declarator"),
              let name = declarator.child(byFieldName: "name"), let value = declarator.child(byFieldName: "value"),
              value.type == "object_creation_expression", value.firstNamedChild(ofType: "class_body") == nil,
              let typeName = collectionName(declaredType: node.child(byFieldName: "type"), created: value) else { return }
        let table = context.tree.declarationCache.fileSymbols(context: context)
        let tree = context.tree
        var uses: [Use] = []
        if isField {
            for range in table.nonLocalOccurrences(of: name.text, excluding: name.byteRange) {
                switch fieldUse(tree.node(inByteRange: range)) {
                case .ignore: continue
                case .ambiguous: return
                case .use(let expression): uses.append(classify(expression))
                }
            }
        } else {
            guard let local = table.locals[name.byteRange] else { return }
            uses = local.uses.map { classify(tree.node(inByteRange: $0)) }
        }
        guard !uses.isEmpty, !uses.contains(.escape) else { return }
        let hasQuery = uses.contains(.query)
        let hasUpdate = uses.contains(.update)
        let isBuilder = builderTypes.contains(typeName)
        let noun = isBuilder ? "StringBuilder" : "collection"
        if hasQuery, !hasUpdate, value.child(byFieldName: "arguments")?.namedChildCount == 0 {
            report(JavaInspectionSupport.inspection(rule, message: "Contents of \(noun) '\(name.text)' are queried, but never updated", node: name))
        } else if hasUpdate, !hasQuery {
            report(JavaInspectionSupport.inspection(rule, message: "Contents of \(noun) '\(name.text)' are updated, but never queried", node: name))
        }
    }

    private static func collectionName(declaredType: SyntaxNode?, created: SyntaxNode) -> String? {
        func simpleName(_ type: SyntaxNode?) -> String? {
            guard let type else { return nil }
            switch type.type {
            case "type_identifier": return type.text
            case "generic_type": return type.firstNamedChild(ofType: "type_identifier")?.text
            case "scoped_type_identifier": return type.namedChildren.last { $0.type == "type_identifier" }?.text
            default: return nil
            }
        }
        if let declaredType, declaredType.type != "type_identifier" || declaredType.text != "var" {
            guard let name = simpleName(declaredType), collectionTypes.contains(name) else { return nil }
            return name
        }
        guard let name = simpleName(created.child(byFieldName: "type")), collectionTypes.contains(name) else { return nil }
        return name
    }

    private enum FieldUse {
        case ignore
        case ambiguous
        case use(SyntaxNode)
    }

    /// How an identifier that has the field's name relates to the field.
    private static func fieldUse(_ node: SyntaxNode) -> FieldUse {
        guard let parent = node.parent else { return .ambiguous }
        switch parent.type {
        case "method_invocation":
            return parent.child(byFieldName: "name")?.byteRange == node.byteRange ? .ignore : .use(node)
        case "field_access":
            if parent.child(byFieldName: "field")?.byteRange == node.byteRange {
                return parent.child(byFieldName: "object")?.type == "this" ? .use(parent) : .ignore
            }
            return .ambiguous
        case "variable_declarator", "formal_parameter", "spread_parameter", "catch_formal_parameter", "resource":
            return parent.child(byFieldName: "name")?.byteRange == node.byteRange ? .ambiguous : .use(node)
        case "method_declaration", "class_declaration", "interface_declaration", "enum_declaration", "record_declaration", "constructor_declaration":
            return .ignore
        default:
            return .use(node)
        }
    }

    private static func classify(_ expression: SyntaxNode) -> Use {
        guard let parent = expression.parent else { return .escape }
        if parent.type == "method_invocation", parent.child(byFieldName: "object")?.byteRange == expression.byteRange,
           let method = parent.child(byFieldName: "name")?.text {
            if updateMethods.contains(method) { return parent.parent?.type == "expression_statement" ? .update : .escape }
            return queryMethods.contains(method) ? .query : .escape
        }
        if parent.type == "enhanced_for_statement", parent.child(byFieldName: "value")?.byteRange == expression.byteRange { return .query }
        return .escape
    }
}
