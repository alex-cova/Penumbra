import Foundation

/// What the identifier under the caret refers to, before any index lookup.
enum JavaReference {
    /// The caret is already on the declaration's name. Navigation stops.
    case declaration
    case type(SyntaxNode)
    /// `new Foo(...)` — the clicked node is the constructed type, not a type argument.
    case constructor(type: SyntaxNode, argumentCount: Int)
    case explicitConstructor(isSuper: Bool, argumentCount: Int)
    case methodCall(SyntaxNode)
    case fieldAccess(SyntaxNode)
    case bareName(SyntaxNode)
    case keywordThis
    case keywordSuper
    case `import`(declaration: SyntaxNode, clicked: SyntaxNode)
}

enum JavaReferenceClassifier {
    private static let typeDeclarations: Set<String> = [
        "class_declaration", "interface_declaration", "enum_declaration",
        "record_declaration", "annotation_type_declaration"
    ]

    static func classify(in tree: JavaSyntaxTree, atByteOffset byteOffset: Int) -> JavaReference? {
        let leaf = tree.node(atByteOffset: byteOffset)
        guard let token = nameToken(leaf, byteOffset: byteOffset) else { return nil }
        if ancestor(of: token, type: "package_declaration") != nil {
            return nil
        }
        if token.type == "this" || token.type == "super" {
            return keywordReference(token)
        }
        if isDeclarationName(token) {
            return .declaration
        }
        if let invocation = ancestor(of: token, type: "method_invocation"),
           invocation.child(byFieldName: "name")?.byteRange == token.byteRange {
            return .methodCall(invocation)
        }
        if let access = ancestor(of: token, type: "field_access"),
           access.child(byFieldName: "field")?.byteRange == token.byteRange {
            return .fieldAccess(access)
        }
        if let creation = constructorCreation(containing: token) {
            return .constructor(type: token, argumentCount: creation)
        }
        if let importDeclaration = ancestor(of: token, type: "import_declaration") {
            return .import(declaration: importDeclaration, clicked: token)
        }
        if token.type == "type_identifier" || isAnnotationName(token) {
            return .type(token)
        }
        if token.type == "identifier" {
            return .bareName(token)
        }
        return nil
    }

    /// Dotted components of the type whose final component is `token` (a middle package segment
    /// stops there: clicking `util` in `java.util.List` yields `java.util`, not `List`).
    static func typeComponents(endingAt token: SyntaxNode) -> [String] {
        var top = token
        while let parent = top.parent {
            if parent.type == "generic_type" {
                guard parent.namedChild(at: 0)?.byteRange == top.byteRange else { break }
                top = parent
                continue
            }
            if parent.type == "array_type" {
                let element = parent.child(byFieldName: "element") ?? parent.namedChild(at: 0)
                guard element?.byteRange == top.byteRange else { break }
                top = parent
                continue
            }
            if parent.type == "scoped_type_identifier" {
                let children = parent.namedChildren
                guard children.count >= 2, children[1].byteRange == top.byteRange else { break }
                top = parent
                continue
            }
            if parent.type == "scoped_identifier" {
                guard parent.child(byFieldName: "name")?.byteRange == top.byteRange else { break }
                top = parent
                continue
            }
            break
        }
        return pathComponents(top).map(\.name)
    }

    static func pathComponents(_ node: SyntaxNode) -> [(name: String, range: Range<Int>)] {
        switch node.type {
        case "identifier", "type_identifier":
            return [(node.text, node.byteRange)]
        case "scoped_identifier":
            guard let scope = node.child(byFieldName: "scope"), let name = node.child(byFieldName: "name") else {
                return [(node.text, node.byteRange)]
            }
            return pathComponents(scope) + pathComponents(name)
        case "scoped_type_identifier":
            let children = node.namedChildren
            guard children.count >= 2 else { return [(node.text, node.byteRange)] }
            return pathComponents(children[0]) + pathComponents(children[1])
        case "generic_type":
            guard let base = node.namedChild(at: 0) else { return [] }
            return pathComponents(base)
        case "array_type":
            guard let element = node.child(byFieldName: "element") ?? node.namedChild(at: 0) else { return [] }
            return pathComponents(element)
        default:
            return []
        }
    }

    private static func nameToken(_ leaf: SyntaxNode, byteOffset: Int) -> SyntaxNode? {
        let type = leaf.type
        let isName = type == "identifier" || type == "type_identifier" || type == "this" || type == "super"
        guard isName, leaf.byteRange.contains(byteOffset) else { return nil }
        return leaf
    }

    private static func keywordReference(_ token: SyntaxNode) -> JavaReference {
        let isSuper = token.type == "super"
        if let parent = token.parent, parent.type == "explicit_constructor_invocation" {
            let count = parent.child(byFieldName: "arguments")?.namedChildCount ?? 0
            return .explicitConstructor(isSuper: isSuper, argumentCount: count)
        }
        return isSuper ? .keywordSuper : .keywordThis
    }

    private static func isDeclarationName(_ token: SyntaxNode) -> Bool {
        guard token.type == "identifier", let parent = token.parent else { return false }
        switch parent.type {
        case "class_declaration", "interface_declaration", "enum_declaration", "record_declaration",
             "annotation_type_declaration", "method_declaration", "constructor_declaration",
             "enum_constant", "variable_declarator", "formal_parameter", "enhanced_for_statement",
             "resource", "catch_formal_parameter":
            return parent.child(byFieldName: "name")?.byteRange == token.byteRange
        case "type_parameter":
            return parent.namedChild(at: 0)?.byteRange == token.byteRange
                || parent.child(byFieldName: "name")?.byteRange == token.byteRange
        case "lambda_expression":
            return parent.child(byFieldName: "parameters")?.byteRange == token.byteRange
        default:
            if typeDeclarations.contains(parent.type) {
                return parent.child(byFieldName: "name")?.byteRange == token.byteRange
            }
            return false
        }
    }

    private static func isAnnotationName(_ token: SyntaxNode) -> Bool {
        var current: SyntaxNode? = token
        while let node = current {
            if node.type == "marker_annotation" || node.type == "annotation" {
                let name = node.child(byFieldName: "name") ?? node.namedChild(at: 0)
                return name?.byteRange.contains(token.startByte) == true
            }
            if node.type == "method_invocation" || node.type == "field_access" || node.type == "local_variable_declaration" {
                return false
            }
            current = node.parent
        }
        return false
    }

    /// Argument count of the `new` expression whose constructed type contains `token`, or nil when
    /// the click is a type argument (`new Foo<Bar>` → Bar) or not inside a creation.
    private static func constructorCreation(containing token: SyntaxNode) -> Int? {
        var current: SyntaxNode? = token
        var insideTypeArguments = false
        while let node = current {
            if node.type == "type_arguments" {
                insideTypeArguments = true
            }
            if node.type == "object_creation_expression" {
                if insideTypeArguments { return nil }
                if let arguments = node.child(byFieldName: "arguments"), token.startByte >= arguments.startByte {
                    return nil
                }
                return node.child(byFieldName: "arguments")?.namedChildCount ?? 0
            }
            current = node.parent
        }
        return nil
    }

    private static func ancestor(of node: SyntaxNode, type: String) -> SyntaxNode? {
        var current = node.parent
        while let next = current {
            if next.type == type { return next }
            current = next.parent
        }
        return nil
    }
}
