import Foundation

/// Finds the declaration name's UTF-8 byte range inside one compilation unit.
enum JavaDeclarationLocator {
    private static let typeDeclarations: Set<String> = [
        "class_declaration", "interface_declaration", "enum_declaration",
        "record_declaration", "annotation_type_declaration"
    ]

    static func typeName(qualifiedName: String, relaxedSimpleName: String? = nil, in tree: JavaSyntaxTree) -> Range<Int>? {
        var found: Range<Int>?
        let package = packageName(in: tree)
        for node in tree.rootNode.namedChildren where typeDeclarations.contains(node.type) {
            visitType(node, package: package, outer: nil, target: qualifiedName, relaxedSimpleName: relaxedSimpleName, found: &found)
        }
        return found
    }

    static func fieldRanges(declaringClass: String, name: String, relaxedSimpleName: String? = nil, in tree: JavaSyntaxTree) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        let package = packageName(in: tree)
        for node in tree.rootNode.namedChildren where typeDeclarations.contains(node.type) {
            collect(
                type: node, package: package, outer: nil,
                targetClass: declaringClass, relaxedSimpleName: relaxedSimpleName,
                accept: { typeNode in
                    ranges.append(contentsOf: fieldNames(named: name, in: typeNode))
                }
            )
        }
        return ranges
    }

    /// Methods or constructors on `declaringClass` whose parameter simple-name keys match.
    /// Key matches win; otherwise every declaration with the same arity is returned so the caller
    /// can show a chooser instead of guessing.
    static func methodRanges(
        declaringClass: String, name: String, parameterKeys: [String], isConstructor: Bool,
        relaxedSimpleName: String? = nil, in tree: JavaSyntaxTree
    ) -> [Range<Int>] {
        var matches: [(range: Range<Int>, keys: [String])] = []
        let package = packageName(in: tree)
        for node in tree.rootNode.namedChildren where typeDeclarations.contains(node.type) {
            collect(
                type: node, package: package, outer: nil,
                targetClass: declaringClass, relaxedSimpleName: relaxedSimpleName,
                accept: { typeNode in
                    matches.append(contentsOf: methods(
                        named: name, isConstructor: isConstructor, in: typeNode
                    ))
                }
            )
        }
        let keyed = matches.filter { $0.keys == parameterKeys }
        if !keyed.isEmpty { return keyed.map(\.range) }
        let sameArity = matches.filter { $0.keys.count == parameterKeys.count }
        if !sameArity.isEmpty { return sameArity.map(\.range) }
        return matches.map(\.range)
    }

    static func localDeclarationRange(name: String, in tree: JavaSyntaxTree, atByteOffset offset: Int) -> Range<Int>? {
        var current: SyntaxNode? = tree.node(atByteOffset: offset)
        while let node = current {
            switch node.type {
            case "block", "constructor_body":
                var found: Range<Int>?
                for statement in node.namedChildren where statement.type == "local_variable_declaration" && statement.endByte <= offset {
                    for declarator in statement.namedChildren(ofType: "variable_declarator") {
                        if let nameNode = declarator.child(byFieldName: "name"), nameNode.text == name {
                            found = nameNode.byteRange
                        }
                    }
                }
                if let found { return found }
            case "method_declaration", "constructor_declaration":
                if let range = formalParameterRange(named: name, in: node.child(byFieldName: "parameters")) {
                    return range
                }
            case "lambda_expression":
                if let parameters = node.child(byFieldName: "parameters") {
                    if parameters.type == "identifier", parameters.text == name {
                        return parameters.byteRange
                    }
                    if let range = formalParameterRange(named: name, in: parameters) {
                        return range
                    }
                }
            case "enhanced_for_statement":
                if let body = node.child(byFieldName: "body"), offset >= body.startByte,
                   let nameNode = node.child(byFieldName: "name"), nameNode.text == name {
                    return nameNode.byteRange
                }
            case "try_with_resources_statement":
                if let spec = node.firstNamedChild(ofType: "resource_specification") {
                    for resource in spec.namedChildren where resource.type == "resource" {
                        if let nameNode = resource.child(byFieldName: "name"), nameNode.text == name {
                            return nameNode.byteRange
                        }
                    }
                }
            case "ERROR":
                if let parameters = node.namedChildren.first(where: { $0.type == "formal_parameters" }),
                   let range = formalParameterRange(named: name, in: parameters) {
                    return range
                }
            default:
                break
            }
            current = node.parent
        }
        return nil
    }

    /// The type-parameter declaration in scope at `offset` (`<T>` on the enclosing method or type).
    static func typeParameterRange(name: String, in tree: JavaSyntaxTree, atByteOffset offset: Int) -> Range<Int>? {
        var current: SyntaxNode? = tree.node(atByteOffset: offset)
        while let node = current {
            if node.type == "method_declaration" || node.type == "constructor_declaration" || typeDeclarations.contains(node.type) {
                if let range = typeParameterName(name, in: node.child(byFieldName: "type_parameters")),
                   !range.contains(offset) {
                    return range
                }
            }
            current = node.parent
        }
        return nil
    }

    // MARK: - Tree walk

    private static func packageName(in tree: JavaSyntaxTree) -> String {
        for node in tree.rootNode.namedChildren where node.type == "package_declaration" {
            if let nameNode = node.namedChildren.first {
                return JavaTypeNodeConverter.dottedName(nameNode)
            }
        }
        return ""
    }

    private static func visitType(
        _ node: SyntaxNode, package: String, outer: String?, target: String, relaxedSimpleName: String?, found: inout Range<Int>?
    ) {
        guard found == nil, let nameNode = node.child(byFieldName: "name") else { return }
        let qualified = qualifiedName(simple: nameNode.text, package: package, outer: outer)
        if isTarget(qualified: qualified, simple: nameNode.text, target: target, relaxedSimpleName: relaxedSimpleName) {
            found = nameNode.byteRange
            return
        }
        visitNested(in: node, package: package, outer: qualified) { child, outerName in
            visitType(child, package: package, outer: outerName, target: target, relaxedSimpleName: relaxedSimpleName, found: &found)
        }
    }

    private static func collect(
        type node: SyntaxNode, package: String, outer: String?, targetClass: String, relaxedSimpleName: String?, accept: (SyntaxNode) -> Void
    ) {
        guard let nameNode = node.child(byFieldName: "name") else { return }
        let qualified = qualifiedName(simple: nameNode.text, package: package, outer: outer)
        if isTarget(qualified: qualified, simple: nameNode.text, target: targetClass, relaxedSimpleName: relaxedSimpleName) {
            accept(node)
        }
        visitNested(in: node, package: package, outer: qualified) { child, outerName in
            collect(type: child, package: package, outer: outerName, targetClass: targetClass, relaxedSimpleName: relaxedSimpleName, accept: accept)
        }
    }

    /// Decompiled nested classes are a single type named by the simple name (`Entry`), not the
    /// qualified `Map.Entry` the index uses. `relaxedSimpleName` accepts that file.
    private static func isTarget(qualified: String, simple: String, target: String, relaxedSimpleName: String?) -> Bool {
        if qualified == target { return true }
        if let relaxedSimpleName, simple == relaxedSimpleName { return true }
        return false
    }

    private static func visitNested(
        in node: SyntaxNode, package: String, outer: String, visit: (SyntaxNode, String) -> Void
    ) {
        guard let body = node.child(byFieldName: "body") else { return }
        for child in body.namedChildren where typeDeclarations.contains(child.type) {
            visit(child, outer)
        }
        if let declarations = body.firstNamedChild(ofType: "enum_body_declarations") {
            for child in declarations.namedChildren where typeDeclarations.contains(child.type) {
                visit(child, outer)
            }
        }
    }

    private static func qualifiedName(simple: String, package: String, outer: String?) -> String {
        if let outer { return "\(outer).\(simple)" }
        return package.isEmpty ? simple : "\(package).\(simple)"
    }

    private static func fieldNames(named name: String, in typeNode: SyntaxNode) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        if typeNode.type == "record_declaration" {
            ranges.append(contentsOf: recordComponentRanges(named: name, in: typeNode))
        }
        for member in memberNodes(in: typeNode) {
            switch member.type {
            case "field_declaration":
                for declarator in member.namedChildren(ofType: "variable_declarator") {
                    if let nameNode = declarator.child(byFieldName: "name"), nameNode.text == name {
                        ranges.append(nameNode.byteRange)
                    }
                }
            case "enum_constant":
                if let nameNode = member.child(byFieldName: "name"), nameNode.text == name {
                    ranges.append(nameNode.byteRange)
                }
            default:
                break
            }
        }
        return ranges
    }

    private static func methods(
        named name: String, isConstructor: Bool, in typeNode: SyntaxNode
    ) -> [(range: Range<Int>, keys: [String])] {
        var matches: [(range: Range<Int>, keys: [String])] = []
        if !isConstructor, typeNode.type == "record_declaration" {
            for range in recordComponentRanges(named: name, in: typeNode) {
                matches.append((range, []))
            }
        }
        for member in memberNodes(in: typeNode) {
            switch member.type {
            case "method_declaration" where !isConstructor:
                if let match = methodMatch(member, name: name) {
                    matches.append(match)
                }
            case "constructor_declaration" where isConstructor:
                if let match = methodMatch(member, name: nil) {
                    matches.append(match)
                }
            case "annotation_type_element_declaration" where !isConstructor:
                if let nameNode = member.child(byFieldName: "name"), nameNode.text == name {
                    matches.append((nameNode.byteRange, []))
                }
            default:
                break
            }
        }
        return matches
    }

    private static func methodMatch(
        _ node: SyntaxNode, name: String?
    ) -> (range: Range<Int>, keys: [String])? {
        guard let nameNode = node.child(byFieldName: "name") else { return nil }
        if let name, nameNode.text != name { return nil }
        let keys = parameterKeys(node.child(byFieldName: "parameters"))
        return (nameNode.byteRange, keys)
    }

    private static func memberNodes(in typeNode: SyntaxNode) -> [SyntaxNode] {
        guard let body = typeNode.child(byFieldName: "body") else { return [] }
        var members = body.namedChildren
        if let declarations = body.firstNamedChild(ofType: "enum_body_declarations") {
            members.append(contentsOf: declarations.namedChildren)
        }
        return members
    }

    private static func recordComponentRanges(named name: String, in typeNode: SyntaxNode) -> [Range<Int>] {
        guard let parameters = typeNode.child(byFieldName: "parameters") else { return [] }
        return parameters.namedChildren.compactMap { component in
            guard component.type == "formal_parameter" || component.type == "spread_parameter" else { return nil }
            guard let nameNode = component.child(byFieldName: "name") ?? component.firstNamedChild(ofType: "variable_declarator")?.child(byFieldName: "name"),
                  nameNode.text == name else { return nil }
            return nameNode.byteRange
        }
    }

    private static func parameterKeys(_ parameters: SyntaxNode?) -> [String] {
        guard let parameters else { return [] }
        var keys: [String] = []
        for child in parameters.namedChildren {
            switch child.type {
            case "formal_parameter":
                guard let typeNode = child.child(byFieldName: "type") else { continue }
                keys.append(JavaTypeKeys.parameterKey(JavaTypeNodeConverter.convert(typeNode)))
            case "spread_parameter":
                guard let element = child.namedChild(at: 0) else { continue }
                let elementType = JavaTypeNodeConverter.convert(element)
                keys.append(JavaTypeKeys.parameterKey(.array(element: elementType)))
            default:
                break
            }
        }
        return keys
    }

    private static func formalParameterRange(named name: String, in parameters: SyntaxNode?) -> Range<Int>? {
        guard let parameters else { return nil }
        for child in parameters.namedChildren where child.type == "formal_parameter" || child.type == "spread_parameter" {
            if let nameNode = child.child(byFieldName: "name"), nameNode.text == name {
                return nameNode.byteRange
            }
            if let declarator = child.firstNamedChild(ofType: "variable_declarator"),
               let nameNode = declarator.child(byFieldName: "name"), nameNode.text == name {
                return nameNode.byteRange
            }
        }
        return nil
    }

    private static func typeParameterName(_ name: String, in node: SyntaxNode?) -> Range<Int>? {
        guard let node else { return nil }
        for parameter in node.namedChildren(ofType: "type_parameter") {
            let nameNode = parameter.child(byFieldName: "name") ?? parameter.namedChild(at: 0)
            if nameNode?.text == name { return nameNode?.byteRange }
        }
        return nil
    }
}
