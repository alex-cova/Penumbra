import Foundation

/// The value of one annotation element, read from source text. Anything that is not a string,
/// class literal or array stays an expression (`true`, `Foo.BAR`, `"a" + B`), because evaluating it
/// is not this layer's job.
public indirect enum JavaAnnotationValue: Hashable, Sendable {
    case string(String)
    /// `Foo.class`: the type text as written (`Foo`).
    case classLiteral(String)
    case array([JavaAnnotationValue])
    case expression(String)

    /// Every string in this value (a single string counts as one), in source order.
    public var strings: [String] {
        switch self {
        case .string(let s): return [s]
        case .array(let items): return items.flatMap(\.strings)
        case .classLiteral, .expression: return []
        }
    }

    /// Every class literal in this value, in source order.
    public var classLiterals: [String] {
        switch self {
        case .classLiteral(let c): return [c]
        case .array(let items): return items.flatMap(\.classLiterals)
        case .string, .expression: return []
        }
    }

    /// The text of an expression value, or the value of a string, for flags like `true`.
    public var scalarText: String? {
        switch self {
        case .string(let s): return s
        case .expression(let e): return e
        case .array(let items) where items.count == 1: return items[0].scalarText
        default: return nil
        }
    }
}

/// One `@Name(key = value, ...)` use on a declaration or parameter.
public struct JavaAnnotationUse: Hashable, Sendable {
    /// The name as written: `GetMapping` or `org.springframework.web.bind.annotation.GetMapping`.
    public let name: String
    /// Elements in source order. A lone `@A("x")` argument is recorded under `value`.
    public let arguments: [String: JavaAnnotationValue]
    /// UTF-8 byte range of the whole annotation in its file.
    public let byteRange: Range<Int>

    public init(name: String, arguments: [String: JavaAnnotationValue], byteRange: Range<Int>) {
        self.name = name
        self.arguments = arguments
        self.byteRange = byteRange
    }

    public subscript(_ key: String) -> JavaAnnotationValue? { arguments[key] }
    public var simpleName: String { name.split(separator: ".").last.map(String.init) ?? name }
}

public struct JavaDeclaredParameter: Hashable, Sendable {
    public let name: String
    public let type: JavaTypeRef
    public let annotations: [JavaAnnotationUse]
    /// The whole parameter (modifiers, annotations, type and name).
    public let byteRange: Range<Int>
    public let nameRange: Range<Int>
}

public struct JavaDeclaredField: Hashable, Sendable {
    public let name: String
    public let type: JavaTypeRef
    public let modifiers: JavaModifiers
    public let annotations: [JavaAnnotationUse]
    public let nameRange: Range<Int>
    /// Start of the whole declaration (its first modifier or annotation), where a new annotation goes.
    public let declarationStart: Int
}

public struct JavaDeclaredMethod: Hashable, Sendable {
    public let name: String
    public let returnType: JavaTypeRef
    public let parameters: [JavaDeclaredParameter]
    public let modifiers: JavaModifiers
    public let annotations: [JavaAnnotationUse]
    public let isConstructor: Bool
    public let nameRange: Range<Int>
    /// Start of the declaration (first modifier or annotation), where a new annotation goes.
    public let declarationStart: Int
}

/// One element of an annotation type (`String[] path() default {}`): its own annotations (`@AliasFor`) and default value.
public struct JavaDeclaredAnnotationElement: Hashable, Sendable {
    public let name: String
    public let annotations: [JavaAnnotationUse]
    public let defaultValue: JavaAnnotationValue?
}

public struct JavaAnnotatedType: Hashable, Sendable {
    public let qualifiedName: String
    public let simpleName: String
    public let kind: JavaTypeKind
    public let modifiers: JavaModifiers
    public let annotations: [JavaAnnotationUse]
    public let superclass: JavaTypeRef?
    public let interfaces: [JavaTypeRef]
    public let fields: [JavaDeclaredField]
    public let methods: [JavaDeclaredMethod]
    /// Elements of an annotation type; empty for every other kind.
    public let annotationElements: [JavaDeclaredAnnotationElement]
    public let nameRange: Range<Int>
    /// Start of the declaration (first modifier or annotation), where a new annotation goes.
    public let declarationStart: Int
}

/// What the Java stubs leave out: annotations (with their arguments), parameter names and member
/// positions, for every type of one source file. Spring, JPA and other annotation-driven
/// frameworks read it; it carries no framework knowledge itself.
///
/// It walks the same cached parse the stub builder does, so a framework layer never parses Java
/// on its own. Types are the stub builder's `JavaTypeRef`s (simple names stay `.unresolved`;
/// qualify them with `imports` and `packageName`).
public struct JavaFileDeclarations: Hashable, Sendable {
    public let packageName: String
    public let imports: [JavaImportDeclaration]
    /// Top-level and member types, flattened (member types are named `Outer.Inner`).
    public let types: [JavaAnnotatedType]

    public static let empty = JavaFileDeclarations(packageName: "", imports: [], types: [])
}

public enum JavaDeclaredAnnotations {
    public static func extract(source: String) -> JavaFileDeclarations {
        guard let tree = JavaSyntaxParser().parse(source) else { return .empty }
        return extract(tree: tree)
    }

    public static func extract(tree: JavaSyntaxTree) -> JavaFileDeclarations {
        var packageName = ""
        var imports: [JavaImportDeclaration] = []
        var types: [JavaAnnotatedType] = []
        let root = tree.rootNode
        for node in root.namedChildren {
            switch node.type {
            case "package_declaration":
                if let name = node.namedChildren.first(where: { $0.type != "modifiers" && $0.type != "annotation" && $0.type != "marker_annotation" }) {
                    packageName = JavaTypeNodeConverter.dottedName(name)
                }
            case "import_declaration":
                let isStatic = node.children.contains { $0.type == "static" }
                let onDemand = node.namedChildren.contains { $0.type == "asterisk" }
                if let path = node.namedChildren.first(where: { $0.type == "scoped_identifier" || $0.type == "identifier" }) {
                    imports.append(JavaImportDeclaration(
                        qualifiedName: JavaTypeNodeConverter.dottedName(path), isStatic: isStatic, isOnDemand: onDemand))
                }
            case _ where typeNodes.contains(node.type):
                collectType(node, packageName: packageName, outer: nil, into: &types)
            default:
                break
            }
        }
        return JavaFileDeclarations(packageName: packageName, imports: imports, types: types)
    }

    private static let typeNodes: Set<String> = [
        "class_declaration", "interface_declaration", "enum_declaration",
        "record_declaration", "annotation_type_declaration"
    ]

    private static func collectType(_ node: SyntaxNode, packageName: String, outer: String?, into types: inout [JavaAnnotatedType]) {
        guard let nameNode = node.child(byFieldName: "name") else { return }
        let simple = nameNode.text
        let qualified = outer.map { "\($0).\(simple)" } ?? (packageName.isEmpty ? simple : "\(packageName).\(simple)")
        let kind: JavaTypeKind
        switch node.type {
        case "interface_declaration": kind = .interfaceKind
        case "enum_declaration": kind = .enumKind
        case "record_declaration": kind = .recordKind
        case "annotation_type_declaration": kind = .annotationKind
        default: kind = .classKind
        }
        let modifiersNode = node.namedChildren.first { $0.type == "modifiers" }
        var modifiers = modifierFlags(modifiersNode)
        if kind == .interfaceKind || kind == .annotationKind { modifiers.insert(.abstractFlag) }

        var superclass: JavaTypeRef?
        if let sc = node.child(byFieldName: "superclass")?.namedChildren.first {
            superclass = JavaTypeNodeConverter.convert(sc)
        }
        var interfaces: [JavaTypeRef] = []
        if let list = node.child(byFieldName: "interfaces")?.firstNamedChild(ofType: "type_list") {
            interfaces = list.namedChildren.map(JavaTypeNodeConverter.convert)
        }
        if let list = node.firstNamedChild(ofType: "extends_interfaces")?.firstNamedChild(ofType: "type_list") {
            interfaces += list.namedChildren.map(JavaTypeNodeConverter.convert)
        }

        var fields: [JavaDeclaredField] = []
        var methods: [JavaDeclaredMethod] = []
        var elements: [JavaDeclaredAnnotationElement] = []
        var members: [SyntaxNode] = []
        if let body = node.child(byFieldName: "body") {
            members = body.namedChildren
            if kind == .enumKind, let decls = body.firstNamedChild(ofType: "enum_body_declarations") {
                members = decls.namedChildren
            }
        }
        // Record components are the canonical constructor's parameters; keep them as fields so
        // a framework sees `record Foo(@Value("x") String a)` like a class with that field.
        if kind == .recordKind, let components = node.child(byFieldName: "parameters") {
            for c in components.namedChildren where c.type == "formal_parameter" {
                if let f = parameter(c) {
                    fields.append(JavaDeclaredField(
                        name: f.name, type: f.type, modifiers: [.privateFlag, .finalFlag],
                        annotations: f.annotations, nameRange: f.nameRange,
                        declarationStart: f.byteRange.lowerBound))
                }
            }
        }
        for member in members {
            switch member.type {
            case "field_declaration":
                let mods = member.namedChildren.first { $0.type == "modifiers" }
                guard let typeNode = member.child(byFieldName: "type") else { continue }
                let type = JavaTypeNodeConverter.convert(typeNode)
                for d in member.namedChildren where d.type == "variable_declarator" {
                    guard let n = d.child(byFieldName: "name") else { continue }
                    fields.append(JavaDeclaredField(
                        name: n.text, type: type, modifiers: modifierFlags(mods),
                        annotations: annotations(in: mods), nameRange: n.byteRange,
                        declarationStart: member.startByte))
                }
            case "method_declaration", "constructor_declaration":
                guard let n = member.child(byFieldName: "name") else { continue }
                let isCtor = member.type == "constructor_declaration"
                let mods = member.namedChildren.first { $0.type == "modifiers" }
                let returnType = member.child(byFieldName: "type").map(JavaTypeNodeConverter.convert) ?? .void
                let params = member.child(byFieldName: "parameters")?.namedChildren.compactMap(parameter) ?? []
                methods.append(JavaDeclaredMethod(
                    name: n.text, returnType: returnType, parameters: params,
                    modifiers: modifierFlags(mods), annotations: annotations(in: mods),
                    isConstructor: isCtor, nameRange: n.byteRange, declarationStart: member.startByte))
            case "annotation_type_element_declaration":
                guard let n = member.child(byFieldName: "name") else { continue }
                let mods = member.namedChildren.first { $0.type == "modifiers" }
                elements.append(JavaDeclaredAnnotationElement(
                    name: n.text, annotations: annotations(in: mods),
                    defaultValue: member.child(byFieldName: "value").map(annotationValue)))
            case _ where typeNodes.contains(member.type):
                collectType(member, packageName: packageName, outer: qualified, into: &types)
            default:
                break
            }
        }
        types.append(JavaAnnotatedType(
            qualifiedName: qualified, simpleName: simple, kind: kind, modifiers: modifiers,
            annotations: annotations(in: modifiersNode), superclass: superclass, interfaces: interfaces,
            fields: fields, methods: methods, annotationElements: elements, nameRange: nameNode.byteRange, declarationStart: node.startByte))
    }

    private static func parameter(_ node: SyntaxNode) -> JavaDeclaredParameter? {
        guard node.type == "formal_parameter" || node.type == "spread_parameter" else { return nil }
        let mods = node.namedChildren.first { $0.type == "modifiers" }
        let typeNode = node.child(byFieldName: "type") ?? node.namedChildren.first {
            $0.type != "modifiers" && $0.type != "variable_declarator" && $0.type != "identifier"
        }
        let nameNode = node.child(byFieldName: "name")
            ?? node.firstNamedChild(ofType: "variable_declarator")?.child(byFieldName: "name")
        guard let typeNode, let nameNode else { return nil }
        var type = JavaTypeNodeConverter.convert(typeNode)
        if node.type == "spread_parameter" { type = .array(element: type) }
        return JavaDeclaredParameter(
            name: nameNode.text, type: type, annotations: annotations(in: mods), byteRange: node.byteRange,
            nameRange: nameNode.byteRange)
    }

    private static func modifierFlags(_ node: SyntaxNode?) -> JavaModifiers {
        guard let node else { return [] }
        var flags: JavaModifiers = []
        for child in node.children {
            switch child.type {
            case "public": flags.insert(.publicFlag)
            case "private": flags.insert(.privateFlag)
            case "protected": flags.insert(.protectedFlag)
            case "static": flags.insert(.staticFlag)
            case "final": flags.insert(.finalFlag)
            case "abstract": flags.insert(.abstractFlag)
            case "default": flags.insert(.defaultMethod)
            default: break
            }
        }
        return flags
    }

    private static func annotations(in modifiers: SyntaxNode?) -> [JavaAnnotationUse] {
        guard let modifiers else { return [] }
        return modifiers.namedChildren.compactMap { child in
            guard child.type == "annotation" || child.type == "marker_annotation",
                  let name = child.child(byFieldName: "name") else { return nil }
            var args: [String: JavaAnnotationValue] = [:]
            if let list = child.child(byFieldName: "arguments") {
                for arg in list.namedChildren {
                    if arg.type == "element_value_pair" {
                        if let key = arg.child(byFieldName: "key"), let value = arg.child(byFieldName: "value") {
                            args[key.text] = annotationValue(value)
                        }
                    } else {
                        args["value"] = annotationValue(arg)
                    }
                }
            }
            return JavaAnnotationUse(name: JavaTypeNodeConverter.dottedName(name), arguments: args, byteRange: child.byteRange)
        }
    }

    private static func annotationValue(_ node: SyntaxNode) -> JavaAnnotationValue {
        switch node.type {
        case "string_literal":
            var t = node.text
            if t.hasPrefix("\"") { t.removeFirst() }
            if t.hasSuffix("\"") { t.removeLast() }
            return .string(t)
        case "class_literal":
            let t = node.text
            return .classLiteral(t.hasSuffix(".class") ? String(t.dropLast(6)) : t)
        case "element_value_array_initializer":
            return .array(node.namedChildren.map(annotationValue))
        default:
            return .expression(node.text)
        }
    }
}
