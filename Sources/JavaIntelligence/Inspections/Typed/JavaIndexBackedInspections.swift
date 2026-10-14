import EditorIntelligence
import Foundation

private let commentTypes: Set<String> = ["line_comment", "block_comment"]

/// Whether `node` sits inside a declaration that is itself `@Deprecated`: the library's own business.
private func isInsideDeprecatedDeclaration(_ node: SyntaxNode) -> Bool {
    var current = node.parent
    while let ancestor = current {
        if ["method_declaration", "constructor_declaration", "class_declaration", "interface_declaration", "enum_declaration", "field_declaration"]
            .contains(ancestor.type), JavaNameShape.modifierWords(of: ancestor).contains("@Deprecated") { return true }
        current = ancestor.parent
    }
    return false
}

/// `new Date(2020, 1, 1)` where every constructor that fits is deprecated. One resolution per
/// (type, argument count) in a file.
enum JavaDeprecatedConstructorUsageInspection: JavaTypedInspection {
    static let rule = JavaInspectionRule.deprecatedConstructorUsage
    static let nodeTypes: Set<String> = ["object_creation_expression"]
    private static let maxResolutions = 300

    static func check(nodes: [SyntaxNode], context: JavaInspectionContext, report: (JavaInspection) -> Void) async {
        var verdicts: [String: Bool] = [:]
        for node in nodes where !node.isQualifiedCreation {
            guard let type = node.child(byFieldName: "type") else { continue }
            let named = type.type == "generic_type" ? (type.namedChild(at: 0) ?? type) : type
            guard ["type_identifier", "scoped_type_identifier"].contains(named.type) else { continue }
            let components = named.text.split(separator: ".").map(String.init)
            let arity = node.child(byFieldName: "arguments")?.namedChildCount ?? 0
            let key = "\(components.joined(separator: "."))/\(arity)"
            let deprecated: Bool
            if let known = verdicts[key] {
                deprecated = known
            } else if verdicts.count >= maxResolutions {
                continue
            } else {
                deprecated = await onlyDeprecatedConstructors(components, arity: arity, node: node, context: context)
                verdicts[key] = deprecated
            }
            guard deprecated, !isInsideDeprecatedDeclaration(node) else { continue }
            report(JavaInspectionSupport.inspection(
                rule, message: "The constructor of '\(named.text)' is deprecated", node: named
            ))
        }
    }

    private static func onlyDeprecatedConstructors(
        _ components: [String], arity: Int, node: SyntaxNode, context: JavaInspectionContext
    ) async -> Bool {
        let session = JavaInspectionSupport.session(for: context, at: node.startByte)
        guard let resolved = await session.resolveType(components: components), case .classType = resolved else { return false }
        let fitting = await JavaMemberLookup.constructors(of: resolved, context: session.context, index: session.index).filter {
            $0.parameters.count == arity || ($0.modifiers.contains(.varargs) && arity >= $0.parameters.count - 1)
        }
        return !fitting.isEmpty && fitting.allSatisfy { $0.modifiers.contains(.deprecatedFlag) }
    }
}

/// `Foo.OLD_CONSTANT` and `variable.legacyField` where the library marks the field deprecated.
enum JavaDeprecatedFieldUsageInspection: JavaTypedInspection {
    static let rule = JavaInspectionRule.deprecatedFieldUsage
    static let nodeTypes: Set<String> = ["field_access"]
    private static let maxResolutions = 300

    private static func key(for node: SyntaxNode) -> String? {
        guard let object = node.child(byFieldName: "object"), let field = node.child(byFieldName: "field")?.text else { return nil }
        if let declared = JavaDeclaredTypes.type(of: object), !declared.isArray { return "\(declared.name).\(field)" }
        if object.type == "identifier", object.text.first?.isUppercase == true { return "\(object.text).\(field)" }
        return nil
    }

    static func check(nodes: [SyntaxNode], context: JavaInspectionContext, report: (JavaInspection) -> Void) async {
        var verdicts: [String: Bool] = [:]
        for node in nodes {
            guard let key = key(for: node), let field = node.child(byFieldName: "field") else { continue }
            let deprecated: Bool
            if let known = verdicts[key] {
                deprecated = known
            } else if verdicts.count >= maxResolutions {
                continue
            } else {
                let session = JavaInspectionSupport.session(for: context, at: node.startByte)
                deprecated = await session.fieldAccessTarget(node)?.field.modifiers.contains(.deprecatedFlag) == true
                verdicts[key] = deprecated
            }
            guard deprecated, !isInsideDeprecatedDeclaration(node) else { continue }
            report(JavaInspectionSupport.inspection(rule, message: "The field '\(field.text)' is deprecated", node: field))
        }
    }
}

/// `List<String> l; l.contains(1)`, `Map<String, V> m; m.get(1)`: a wrapper type the collection
/// can never hold, so the answer is always "no".
enum JavaSuspiciousCollectionArgumentInspection: JavaTypedInspection {
    static let rule = JavaInspectionRule.suspiciousCollectionArgument
    static let nodeTypes: Set<String> = ["method_invocation"]
    private static let maxResolutions = 400
    private static let collections: Set<String> = [
        "java.util.Collection", "java.util.List", "java.util.ArrayList", "java.util.LinkedList", "java.util.Set",
        "java.util.HashSet", "java.util.LinkedHashSet", "java.util.TreeSet", "java.util.Queue", "java.util.Deque",
        "java.util.ArrayDeque", "java.util.PriorityQueue", "java.util.Vector", "java.util.Stack",
    ]
    private static let maps: Set<String> = [
        "java.util.Map", "java.util.HashMap", "java.util.TreeMap", "java.util.LinkedHashMap", "java.util.concurrent.ConcurrentHashMap",
    ]
    private static let collectionMethods: Set<String> = ["contains", "remove", "indexOf", "lastIndexOf"]
    private static let mapKeyMethods: Set<String> = ["get", "containsKey", "remove", "getOrDefault"]
    private static let wrappers: [String: String] = [
        "int": "Integer", "long": "Long", "short": "Short", "byte": "Byte", "double": "Double", "float": "Float",
        "char": "Character", "boolean": "Boolean",
        "Integer": "Integer", "Long": "Long", "Short": "Short", "Byte": "Byte", "Double": "Double", "Float": "Float",
        "Character": "Character", "Boolean": "Boolean", "String": "String",
    ]

    static func check(nodes: [SyntaxNode], context: JavaInspectionContext, report: (JavaInspection) -> Void) async {
        var resolutions = 0
        for node in nodes {
            guard let nameNode = node.child(byFieldName: "name"),
                  collectionMethods.contains(nameNode.text) || mapKeyMethods.contains(nameNode.text) || nameNode.text == "containsValue",
                  let object = node.child(byFieldName: "object"), ["identifier", "field_access"].contains(object.type),
                  let list = node.child(byFieldName: "arguments") else { continue }
            let args = list.namedChildren.filter { !commentTypes.contains($0.type) }
            guard let first = args.first, args.count == (nameNode.text == "getOrDefault" ? 2 : 1),
                  let argument = JavaDeclaredTypes.type(of: first), !argument.isArray, let boxed = wrappers[argument.name] else { continue }
            guard resolutions < maxResolutions else { return }
            resolutions += 1
            let session = JavaInspectionSupport.session(for: context, at: node.startByte)
            guard let receiver = await session.receiverInfo(of: node, nameNode: nameNode), !receiver.isTypeReference,
                  case .classType(let qualifiedName, let typeArguments, _) = receiver.type else { continue }
            let isMap = maps.contains(qualifiedName)
            guard isMap || collections.contains(qualifiedName) else { continue }
            // `List.remove(int)` removes by index; only an object argument is a lookup.
            if nameNode.text == "remove", !isMap, ["int", "short", "byte", "char"].contains(argument.name) { continue }
            let slot = nameNode.text == "containsValue" ? 1 : 0
            guard isMap || nameNode.text != "containsValue", typeArguments.count > slot,
                  case .type(let element) = typeArguments[slot] else { continue }
            // A type the index does not hold stays as the name written in the declaration.
            let elementName: String
            switch element {
            case .classType(let qualifiedName, _, _): elementName = qualifiedName
            case .unresolved(let simpleName, _): elementName = simpleName
            default: continue
            }
            guard let simple = elementName.split(separator: ".").last.map(String.init), wrappers[simple] == simple,
                  simple != boxed else { continue }
            report(JavaInspectionSupport.inspection(
                rule, message: "'\(object.text).\(nameNode.text)()' is passed a '\(boxed)' but holds '\(simple)': the result is always false",
                node: first
            ))
        }
    }
}

/// `class B extends A { int count; }` where `A` has an accessible `count`.
enum JavaFieldHidesSuperclassFieldInspection: JavaTypedInspection {
    static let rule = JavaInspectionRule.fieldHidesSuperclassField
    static let nodeTypes: Set<String> = ["field_declaration"]

    static func check(nodes: [SyntaxNode], context: JavaInspectionContext, report: (JavaInspection) -> Void) async {
        var inherited: [Range<Int>: [String: String]] = [:]
        for node in nodes {
            guard let body = node.parent, body.type == "class_body",
                  let owner = body.parent, owner.type == "class_declaration",
                  owner.child(byFieldName: "superclass") != nil else { continue }
            let names: [String: String]
            if let known = inherited[owner.byteRange] {
                names = known
            } else {
                names = await inheritedFields(of: owner, node: node, context: context)
                inherited[owner.byteRange] = names
            }
            for declarator in node.namedChildren(ofType: "variable_declarator") {
                guard let name = declarator.child(byFieldName: "name"), let declaring = names[name.text] else { continue }
                let owner = declaring.split(separator: ".").last.map(String.init) ?? declaring
                report(JavaInspectionSupport.inspection(
                    rule, message: "Field '\(name.text)' hides the field of the same name in '\(owner)'", node: name
                ))
            }
        }
    }

    /// Accessible fields of every superclass, by name, with the class that declares each. The
    /// superclass is read from the `extends` clause: the class being edited is rarely in the index.
    private static func inheritedFields(of owner: SyntaxNode, node: SyntaxNode, context: JavaInspectionContext) async -> [String: String] {
        guard let clause = owner.child(byFieldName: "superclass"), let named = clause.namedChild(at: 0) else { return [:] }
        let type = named.type == "generic_type" ? (named.namedChild(at: 0) ?? named) : named
        let session = JavaInspectionSupport.session(for: context, at: owner.startByte)
        guard let superclass = await session.resolveType(components: type.text.split(separator: ".").map(String.init)) else { return [:] }
        var result: [String: String] = [:]
        // The access check cannot tell that this class extends the one it asks about when the
        // class is not in the index, so it is off; public and protected fields are what a
        // subclass can see (a package-private one depends on the package, which is not compared).
        let members = await JavaMemberLookup.members(
            of: superclass, mode: .instance, context: session.context, index: session.index, checkAccess: false
        )
        for member in members {
            guard case .field(let field, let declaringClass) = member, result[field.name] == nil,
                  field.modifiers.contains(.publicFlag) || field.modifiers.contains(.protectedFlag) else { continue }
            result[field.name] = declaringClass
        }
        return result
    }
}
