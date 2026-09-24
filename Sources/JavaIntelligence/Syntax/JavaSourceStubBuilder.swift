import Foundation

/// One `import` declaration from a source file.
public struct JavaImportDeclaration: Hashable, Sendable {
    /// The dotted path as written: a class (`java.util.List`), a package for an on-demand import
    /// (`java.util` for `import java.util.*;`), or a member for a static import
    /// (`java.lang.Math.max`, or `java.lang.Math` for `import static java.lang.Math.*;`).
    public let qualifiedName: String
    public let isStatic: Bool
    public let isOnDemand: Bool

    public init(qualifiedName: String, isStatic: Bool, isOnDemand: Bool) {
        self.qualifiedName = qualifiedName
        self.isStatic = isStatic
        self.isOnDemand = isOnDemand
    }
}

/// Everything ``JavaSourceStubBuilder`` extracts from one `.java` file: its package, imports, and
/// every type it declares (top-level and nested, flattened into one list -- each stub carries its
/// own `outerQualifiedName`, matching how class-file-derived stubs represent nesting).
public struct JavaSourceFileStubs: Sendable {
    public let packageName: String
    public let imports: [JavaImportDeclaration]
    public let classes: [JavaClassStub]

    public init(packageName: String, imports: [JavaImportDeclaration], classes: [JavaClassStub]) {
        self.packageName = packageName
        self.imports = imports
        self.classes = classes
    }
}

/// Builds ``JavaClassStub``s directly from a tree-sitter-java parse, the source-file equivalent of
/// ``ClassFileReader`` for `.class` files. Unlike the class-file reader, nothing is filtered by
/// visibility here (a source file's private/package-private members matter for same-file/same-
/// package completion), and every type reference is left as `.unresolved`/`.classType` rather than
/// checked against a real classpath -- see ``JavaTypeNodeConverter``.
public enum JavaSourceStubBuilder {
    public static func build(source: String, url: URL) -> JavaSourceFileStubs {
        guard let tree = JavaSyntaxParser().parse(source) else {
            return JavaSourceFileStubs(packageName: "", imports: [], classes: [])
        }
        return build(tree: tree, url: url)
    }

    public static func build(tree: JavaSyntaxTree, url: URL) -> JavaSourceFileStubs {
        let root = tree.rootNode
        var packageName = ""
        var imports: [JavaImportDeclaration] = []
        var classes: [JavaClassStub] = []

        let topLevel = root.namedChildren
        for (index, node) in topLevel.enumerated() {
            switch node.type {
            case "package_declaration":
                if let nameNode = node.namedChildren.first {
                    packageName = JavaTypeNodeConverter.dottedName(nameNode)
                }
            case "import_declaration":
                if let decl = parseImport(node) {
                    imports.append(decl)
                }
            case declarationTypeNames:
                let javadoc = javadocText(precedingSiblingOf: index, in: topLevel)
                buildType(node, packageName: packageName, outerQualifiedName: nil, javadoc: javadoc, url: url, into: &classes)
            default:
                break
            }
        }

        return JavaSourceFileStubs(packageName: packageName, imports: imports, classes: classes)
    }

    /// The node types that introduce a type declaration, usable both as a `switch` pattern (via
    /// the `~=` overload below) and as a plain membership check.
    private static let declarationTypeNames: Set<String> = [
        "class_declaration", "interface_declaration", "enum_declaration",
        "record_declaration", "annotation_type_declaration"
    ]

    private static func parseImport(_ node: SyntaxNode) -> JavaImportDeclaration? {
        let isStatic = node.children.contains { $0.type == "static" }
        let isOnDemand = node.namedChildren.contains { $0.type == "asterisk" }
        guard let pathNode = node.namedChildren.first(where: { $0.type == "scoped_identifier" || $0.type == "identifier" }) else {
            return nil
        }
        return JavaImportDeclaration(qualifiedName: JavaTypeNodeConverter.dottedName(pathNode), isStatic: isStatic, isOnDemand: isOnDemand)
    }

    private static func buildType(
        _ node: SyntaxNode, packageName: String, outerQualifiedName: String?, javadoc: String?, url: URL,
        into result: inout [JavaClassStub]
    ) {
        guard let nameNode = node.child(byFieldName: "name") else { return }
        let simpleName = nameNode.text
        let qualifiedName = outerQualifiedName.map { "\($0).\(simpleName)" } ?? (packageName.isEmpty ? simpleName : "\(packageName).\(simpleName)")
        let binaryName = qualifiedName // source-derived stubs use '.' throughout; callers that need
            // the class-file '$' form (e.g. writing this into the same shard format) can derive it
            // from `outerQualifiedName` -- kept as '.' here since nothing downstream depends on '$'.

        let modifiersNode = node.namedChildren.first { $0.type == "modifiers" }
        var modifiers = parseModifiers(modifiersNode)

        let kind: JavaTypeKind
        switch node.type {
        case "class_declaration": kind = .classKind
        case "interface_declaration": kind = .interfaceKind
        case "enum_declaration": kind = .enumKind
        case "record_declaration": kind = .recordKind
        case "annotation_type_declaration": kind = .annotationKind
        default: return
        }
        if kind == .interfaceKind || kind == .annotationKind {
            modifiers.insert(.abstractFlag)
        }

        let typeParameters = parseTypeParameters(node.child(byFieldName: "type_parameters"))

        var superclass: JavaTypeRef?
        if let superclassNode = node.child(byFieldName: "superclass")?.namedChildren.first {
            superclass = JavaTypeNodeConverter.convert(superclassNode)
        }
        var interfaces: [JavaTypeRef] = []
        if let list = node.child(byFieldName: "interfaces")?.firstNamedChild(ofType: "type_list") {
            interfaces = list.namedChildren.map(JavaTypeNodeConverter.convert)
        }
        // An interface's `extends A, B` is an `extends_interfaces` child, not the `interfaces`
        // field classes use for `implements`.
        if let list = node.firstNamedChild(ofType: "extends_interfaces")?.firstNamedChild(ofType: "type_list") {
            interfaces += list.namedChildren.map(JavaTypeNodeConverter.convert)
        }

        var fields: [JavaFieldStub] = []
        var methods: [JavaMethodStub] = []
        var innerTypeNames: [String] = []

        // Records implicitly declare a canonical constructor and per-component accessors that
        // never appear in the source AST (javac synthesizes them); surface them here so record
        // completion behaves the same as it does when reading a compiled record's .class file.
        if kind == .recordKind, let componentsNode = node.child(byFieldName: "parameters") {
            let components = componentsNode.namedChildren.filter { $0.type == "formal_parameter" }
            var recordFields: [JavaFieldStub] = []
            var accessors: [JavaMethodStub] = []
            for component in components {
                guard let typeNode = component.child(byFieldName: "type"), let nameNode = component.child(byFieldName: "name") else { continue }
                let type = JavaTypeNodeConverter.convert(typeNode)
                recordFields.append(JavaFieldStub(name: nameNode.text, type: type, modifiers: [.privateFlag, .finalFlag]))
                accessors.append(JavaMethodStub(name: nameNode.text, parameters: [], returnType: type, modifiers: [.publicFlag]))
            }
            fields.append(contentsOf: recordFields)
            methods.append(contentsOf: accessors)
        }

        if let body = node.child(byFieldName: "body") {
            collectMembers(body.namedChildren, packageName: packageName, outerQualifiedName: qualifiedName, url: url,
                            declaringKind: kind, fields: &fields, methods: &methods, innerTypeNames: &innerTypeNames, nestedTypes: &result)
        }
        if kind == .enumKind, let body = node.child(byFieldName: "body") {
            let constants = body.namedChildren.filter { $0.type == "enum_constant" }
            for constant in constants {
                guard let constantName = constant.child(byFieldName: "name") else { continue }
                fields.append(JavaFieldStub(
                    name: constantName.text,
                    type: .classType(qualifiedName: qualifiedName, arguments: [], outer: nil),
                    modifiers: [.publicFlag, .staticFlag, .finalFlag, .enumConstant]
                ))
            }
            if let declarations = body.firstNamedChild(ofType: "enum_body_declarations") {
                collectMembers(declarations.namedChildren, packageName: packageName, outerQualifiedName: qualifiedName, url: url,
                                declaringKind: kind, fields: &fields, methods: &methods, innerTypeNames: &innerTypeNames, nestedTypes: &result)
            }
        }
        // javac gives every enum `Enum<Self>` as superclass plus static `values()`/`valueOf(String)`,
        // and every record `Record`; a compiled class file shows them, so the source stub does too.
        let selfType = JavaTypeRef.classType(qualifiedName: qualifiedName, arguments: [], outer: nil)
        if kind == .enumKind {
            superclass = .classType(qualifiedName: "java.lang.Enum", arguments: [.type(selfType)], outer: nil)
            if !methods.contains(where: { $0.name == "values" && $0.parameters.isEmpty }) {
                methods.append(JavaMethodStub(name: "values", parameters: [], returnType: .array(element: selfType), modifiers: [.publicFlag, .staticFlag]))
            }
            if !methods.contains(where: { $0.name == "valueOf" && $0.parameters.count == 1 }) {
                methods.append(JavaMethodStub(
                    name: "valueOf",
                    parameters: [JavaParameterStub(name: "name", type: .classType(qualifiedName: "java.lang.String", arguments: [], outer: nil))],
                    returnType: selfType, modifiers: [.publicFlag, .staticFlag]
                ))
            }
        } else if kind == .recordKind, superclass == nil {
            superclass = .classType(qualifiedName: "java.lang.Record", arguments: [], outer: nil)
        }
        if outerKind(of: node) == .interfaceKind {
            // Member types of an interface are implicitly `public static`.
            modifiers.formUnion([.publicFlag, .staticFlag])
        }
        if kind == .annotationKind, let body = node.child(byFieldName: "body") {
            for element in body.namedChildren where element.type == "annotation_type_element_declaration" {
                guard let typeNode = element.child(byFieldName: "type"), let elementName = element.child(byFieldName: "name") else { continue }
                methods.append(JavaMethodStub(name: elementName.text, parameters: [], returnType: JavaTypeNodeConverter.convert(typeNode), modifiers: [.publicFlag, .abstractFlag]))
            }
        }

        let stub = JavaClassStub(
            binaryName: binaryName, qualifiedName: qualifiedName, simpleName: simpleName, packageName: packageName,
            outerQualifiedName: outerQualifiedName, kind: kind, modifiers: modifiers, typeParameters: typeParameters,
            superclass: superclass, interfaces: interfaces, fields: fields, methods: methods, innerTypeNames: innerTypeNames,
            origin: .source(url, nameRange: nameNode.byteRange), javadoc: javadoc
        )
        result.append(stub)
    }

    /// The kind of the type declaration `node` is directly nested in, if any.
    private static func outerKind(of node: SyntaxNode) -> JavaTypeKind? {
        guard let body = node.parent, let owner = body.parent else { return nil }
        switch owner.type {
        case "interface_declaration": return .interfaceKind
        case "annotation_type_declaration": return .annotationKind
        default: return nil
        }
    }

    /// Shared by `class_body`, `interface_body`, and enum `enum_body_declarations`: scans a
    /// declaration list for fields, methods/constructors, and nested types, recursing into
    /// `buildType` for the latter (which appends to `nestedTypes`, the flattened result list).
    private static func collectMembers(
        _ members: [SyntaxNode], packageName: String, outerQualifiedName: String, url: URL, declaringKind: JavaTypeKind,
        fields: inout [JavaFieldStub], methods: inout [JavaMethodStub], innerTypeNames: inout [String],
        nestedTypes: inout [JavaClassStub]
    ) {
        for (index, member) in members.enumerated() {
            let javadoc = javadocText(precedingSiblingOf: index, in: members)
            switch member.type {
            case "field_declaration":
                fields.append(contentsOf: parseFields(member, declaringKind: declaringKind, javadoc: javadoc))
            case "method_declaration":
                if let method = parseMethod(member, declaringKind: declaringKind, javadoc: javadoc) {
                    methods.append(method)
                }
            case "constructor_declaration":
                if let ctor = parseConstructor(member, javadoc: javadoc) {
                    methods.append(ctor)
                }
            case declarationTypeNames:
                let before = nestedTypes.count
                buildType(member, packageName: packageName, outerQualifiedName: outerQualifiedName, javadoc: javadoc, url: url, into: &nestedTypes)
                if nestedTypes.count > before {
                    innerTypeNames.append(nestedTypes[before].qualifiedName)
                }
            default:
                break
            }
        }
    }

    private static func parseFields(_ node: SyntaxNode, declaringKind: JavaTypeKind, javadoc: String?) -> [JavaFieldStub] {
        guard let typeNode = node.child(byFieldName: "type") else { return [] }
        let type = JavaTypeNodeConverter.convert(typeNode)
        var modifiers = parseModifiers(node.namedChildren.first { $0.type == "modifiers" })
        if declaringKind == .interfaceKind || declaringKind == .annotationKind {
            // Interface fields are implicitly `public static final` constants.
            modifiers.formUnion([.publicFlag, .staticFlag, .finalFlag])
        }
        return node.namedChildren(ofType: "variable_declarator").compactMap { declarator in
            guard let nameNode = declarator.child(byFieldName: "name") else { return nil }
            return JavaFieldStub(name: nameNode.text, type: type, modifiers: modifiers, javadoc: javadoc)
        }
    }

    private static func parseMethod(_ node: SyntaxNode, declaringKind: JavaTypeKind, javadoc: String?) -> JavaMethodStub? {
        guard let nameNode = node.child(byFieldName: "name") else { return nil }
        var modifiers = parseModifiers(node.namedChildren.first { $0.type == "modifiers" })
        let returnType = node.child(byFieldName: "type").map(JavaTypeNodeConverter.convert) ?? .void
        let (parameters, hasVarargs) = parseParameters(node.child(byFieldName: "parameters"))
        if hasVarargs { modifiers.insert(.varargs) }
        // Interface/annotation methods with no body and no explicit modifier are implicitly
        // `public abstract`; `default`/`static` interface methods do have bodies and keep whatever
        // modifiers the parser found.
        if (declaringKind == .interfaceKind || declaringKind == .annotationKind), node.child(byFieldName: "body") == nil {
            modifiers.insert(.publicFlag)
            modifiers.insert(.abstractFlag)
        }
        // Default and static interface methods are implicitly public too (only an explicit
        // `private` opts out), as a compiled interface's class file records.
        if declaringKind == .interfaceKind, !modifiers.contains(.privateFlag) {
            modifiers.insert(.publicFlag)
        }
        let typeParameters = parseTypeParameters(node.child(byFieldName: "type_parameters"))
        return JavaMethodStub(
            name: nameNode.text, typeParameters: typeParameters, parameters: parameters, returnType: returnType,
            modifiers: modifiers, isConstructor: false, javadoc: javadoc
        )
    }

    private static func parseConstructor(_ node: SyntaxNode, javadoc: String?) -> JavaMethodStub? {
        guard let nameNode = node.child(byFieldName: "name") else { return nil }
        let modifiers = parseModifiers(node.namedChildren.first { $0.type == "modifiers" })
        let (parameters, hasVarargs) = parseParameters(node.child(byFieldName: "parameters"))
        var finalModifiers = modifiers
        if hasVarargs { finalModifiers.insert(.varargs) }
        return JavaMethodStub(
            name: nameNode.text, parameters: parameters, returnType: .void, modifiers: finalModifiers,
            isConstructor: true, javadoc: javadoc
        )
    }

    private static func parseParameters(_ parametersNode: SyntaxNode?) -> (parameters: [JavaParameterStub], hasVarargs: Bool) {
        guard let parametersNode else { return ([], false) }
        var result: [JavaParameterStub] = []
        var hasVarargs = false
        for child in parametersNode.namedChildren {
            switch child.type {
            case "formal_parameter":
                guard let typeNode = child.child(byFieldName: "type"), let nameNode = child.child(byFieldName: "name") else { continue }
                result.append(JavaParameterStub(name: nameNode.text, type: JavaTypeNodeConverter.convert(typeNode)))
            case "spread_parameter":
                // (spread_parameter <elementType> (variable_declarator name: (identifier))) -- both
                // positional, no field labels (see JavaTypeNodeConverter's doc comment).
                guard let elementTypeNode = child.namedChild(at: 0),
                      let declarator = child.firstNamedChild(ofType: "variable_declarator"),
                      let nameNode = declarator.child(byFieldName: "name") else { continue }
                hasVarargs = true
                let elementType = JavaTypeNodeConverter.convert(elementTypeNode)
                result.append(JavaParameterStub(name: nameNode.text, type: .array(element: elementType)))
            default:
                break
            }
        }
        return (result, hasVarargs)
    }

    private static func parseTypeParameters(_ node: SyntaxNode?) -> [JavaTypeParameter] {
        guard let node else { return [] }
        return node.namedChildren(ofType: "type_parameter").compactMap { param -> JavaTypeParameter? in
            guard let nameNode = param.namedChild(at: 0) else { return nil }
            let bounds = param.firstNamedChild(ofType: "type_bound")?.namedChildren.map(JavaTypeNodeConverter.convert) ?? []
            return JavaTypeParameter(name: nameNode.text, bounds: bounds)
        }
    }

    /// Scans a `(modifiers ...)` node's raw (named + anonymous) children for keyword tokens --
    /// anonymous tokens like `public`/`static` don't appear in `namedChildren`, only `children`,
    /// with their literal text as `type` -- plus any `@Deprecated` annotation.
    private static func parseModifiers(_ node: SyntaxNode?) -> JavaModifiers {
        guard let node else { return [] }
        var modifiers: JavaModifiers = []
        for child in node.children {
            switch child.type {
            case "public": modifiers.insert(.publicFlag)
            case "private": modifiers.insert(.privateFlag)
            case "protected": modifiers.insert(.protectedFlag)
            case "static": modifiers.insert(.staticFlag)
            case "final": modifiers.insert(.finalFlag)
            case "abstract": modifiers.insert(.abstractFlag)
            case "default": modifiers.insert(.defaultMethod)
            case "annotation", "marker_annotation":
                if child.child(byFieldName: "name")?.text == "Deprecated" {
                    modifiers.insert(.deprecatedFlag)
                }
            default:
                break
            }
        }
        return modifiers
    }

    /// A javadoc (`/** ... */`) comment immediately preceding a declaration is its own sibling in
    /// the same child list, not a descendant of the declaration node -- so the caller must pass the
    /// declaration's index within its parent's children to look back one position.
    private static func javadocText(precedingSiblingOf index: Int, in siblings: [SyntaxNode]) -> String? {
        guard index > 0 else { return nil }
        let previous = siblings[index - 1]
        guard previous.type == "block_comment", previous.text.hasPrefix("/**") else { return nil }
        var text = previous.text
        if text.hasPrefix("/**") { text.removeFirst(3) }
        if text.hasSuffix("*/") { text.removeLast(2) }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("*") {
                trimmed.removeFirst()
                if trimmed.hasPrefix(" ") { trimmed.removeFirst() }
            }
            return trimmed
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Lets `declarationTypeNames` (a `Set<String>`) be used directly as a `switch` pattern, e.g.
/// `case declarationTypeNames:` matching any type-declaration node.
private func ~= (pattern: Set<String>, value: String) -> Bool {
    pattern.contains(value)
}
