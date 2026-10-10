import Foundation
import JavaIntelligence

/// One TypeScript file, walked once from a tree-sitter tree. Resolution is syntactic: a name binds
/// to the innermost scope that declares it, and a type is a written annotation, `new`, or `as` —
/// not an inferred return type.
struct TypeScriptFileModel: Sendable {
    enum Kind: Sendable, Equatable {
        case function
        case `class`
        case interface
        case typeAlias
        case `enum`
        case method
        case field
        case variable
        case enumMember
        case namespace

        var isType: Bool {
            switch self {
            case .class, .interface, .typeAlias, .enum, .namespace: return true
            default: return false
            }
        }
    }

    enum SymbolKind: Sendable, Equatable {
        case function
        case method
        case `class`
        case interface
        case `enum`
        case typeAlias
        case namespace
        case parameter
        case local
        case field
        case enumMember

        var highlightName: String? {
            switch self {
            case .class, .typeAlias, .namespace: return "type.class"
            case .interface: return "type.interface"
            case .enum: return "type.enum"
            case .function, .method: return "function.declaration"
            case .parameter: return "variable.parameter"
            case .local: return "variable.local"
            case .field: return "property"
            case .enumMember: return "constant.enum"
            }
        }
    }

    struct Declaration: Sendable {
        var name: String
        var nameBytes: Range<Int>
        var bodyBytes: Range<Int>
        var kind: Kind
        var exportNames: [String]
        var heritage: [String]
        var members: [Declaration]
        var signature: String
        var docComment: String?
        var isPrivate: Bool
        var typeName: String?
        var isTopLevel: Bool
    }

    struct Import: Sendable {
        var localName: String
        var importedName: String
        var localBytes: Range<Int>
        /// The original name in `import { foo as bar }`. Nil when the local name is the imported name.
        var importedNameBytes: Range<Int>?
        var specifier: String
        var isNamespace: Bool
        var isTypeOnly: Bool
    }

    struct Reexport: Sendable {
        var exportedName: String
        var specifier: String
        var importedName: String
        var nameBytes: Range<Int>
    }

    struct Binding: Sendable {
        var name: String
        var nameBytes: Range<Int>
        var scopeStart: Int
        var scopeEnd: Int
        var symbolKind: SymbolKind
        var isValue: Bool
        var isType: Bool
        var isTypeOnly: Bool
        var typeName: String?
        var signature: String
        var specifier: String?
        var importedName: String?
        var isNamespaceImport: Bool
        var isImport: Bool
    }

    struct Use: Sendable {
        var name: String
        var bytes: Range<Int>
        /// `nameBytes.lowerBound` of the binding this use resolves to. Nil when unresolved or a member.
        var bindingStart: Int?
        var inTypePosition: Bool
        var isMemberProperty: Bool
        var isCall: Bool
    }

    struct SyntaxError: Sendable {
        var bytes: Range<Int>
    }

    struct LocalExport: Sendable {
        var localName: String
        var exportedName: String
        var nameBytes: Range<Int>
    }

    var declarations: [Declaration]
    var imports: [Import]
    var reexports: [Reexport]
    var bindings: [Binding]
    var uses: [Use]
    var errors: [SyntaxError]
    var identifiers: Set<String>

    func binding(named name: String, at byte: Int) -> Binding? {
        let matches = bindings.filter { $0.name == name && $0.scopeStart <= byte && byte < $0.scopeEnd }
        return TypeScriptFileModel.innermost(matches, at: byte)
    }

    func binding(atNameBytes bytes: Range<Int>) -> Binding? {
        bindings.first { $0.nameBytes == bytes }
    }

    func binding(start: Int, name: String) -> Binding? {
        bindings.first { $0.nameBytes.lowerBound == start && $0.name == name }
    }

    func declaration(matching binding: Binding) -> Declaration? {
        func find(_ list: [Declaration]) -> Declaration? {
            for declaration in list {
                if declaration.nameBytes == binding.nameBytes { return declaration }
                if let nested = find(declaration.members) { return nested }
            }
            return nil
        }
        return find(declarations)
    }

    func topLevelDeclaration(named name: String) -> Declaration? {
        declarations.first { $0.isTopLevel && $0.name == name }
    }

    static func innermost(_ candidates: [Binding], at byte: Int) -> Binding? {
        candidates.min { lhs, rhs in
            let leftSpan = lhs.scopeEnd - lhs.scopeStart
            let rightSpan = rhs.scopeEnd - rhs.scopeStart
            if leftSpan != rightSpan { return leftSpan < rightSpan }
            let leftBefore = lhs.nameBytes.lowerBound <= byte
            let rightBefore = rhs.nameBytes.lowerBound <= byte
            if leftBefore != rightBefore { return leftBefore }
            return lhs.nameBytes.lowerBound > rhs.nameBytes.lowerBound
        }
    }

    static func build(tree: JavaSyntaxTree, text: TypeScriptText) -> TypeScriptFileModel {
        TypeScriptWalker(text: text).build(tree.rootNode)
    }
}

struct TypeScriptParsed: Sendable {
    var tree: JavaSyntaxTree
    var text: TypeScriptText
    var model: TypeScriptFileModel
}

enum TypeScriptNames {
    static let types: Set<String> = [
        "identifier", "property_identifier", "type_identifier",
        "shorthand_property_identifier", "shorthand_property_identifier_pattern",
        "private_property_identifier"
    ]

    static func isName(_ type: String) -> Bool { types.contains(type) }

    /// The identifier at `byte`. The caret usually sits on the end boundary, which is outside the
    /// half-open token, so the byte just before is tried too.
    static func name(atByte byte: Int, in tree: JavaSyntaxTree) -> SyntaxNode? {
        let count = tree.rootNode.endByte
        let probes = byte > 0 ? [min(byte, count), byte - 1] : [min(byte, count)]
        for probe in probes {
            var node = tree.node(atByteOffset: probe)
            if isName(node.type) { return node }
            for _ in 0..<8 {
                guard let parent = node.parent else { break }
                if isName(parent.type) { return parent }
                switch parent.type {
                case "program", "statement_block", "class_body", "enum_body":
                    break
                default:
                    node = parent
                    continue
                }
                break
            }
        }
        return nil
    }
}

enum TypeScriptKeywords {
    static let statements = [
        "const", "let", "var", "function", "class", "interface", "type", "enum",
        "import", "export", "return", "if", "else", "for", "while", "switch", "case",
        "break", "continue", "new", "async", "await", "try", "catch", "finally",
        "throw", "typeof", "instanceof", "as", "extends", "implements", "from", "of",
        "in", "void", "delete", "yield", "static", "public", "private", "protected",
        "readonly", "declare", "namespace", "module", "abstract"
    ]
    static let types = [
        "string", "number", "boolean", "any", "unknown", "never", "void", "object",
        "null", "undefined", "symbol"
    ]
}

/// Where completion is being asked, decided from the tree around the caret.
enum TypeScriptSite {
    case none
    case member(SyntaxNode)
    case type
    case importExports(specifier: String)
    case value

    static func classify(byte: Int, tree: JavaSyntaxTree, isMemberAccess: Bool) -> TypeScriptSite {
        let clamped = min(max(0, byte), tree.rootNode.endByte)
        let here = tree.node(atByteOffset: clamped)
        if inCommentOrString(here) { return .none }
        if let name = TypeScriptNames.name(atByte: byte, in: tree), isDeclarationName(name) {
            return .none
        }
        let member = memberExpression(containing: here)
            ?? (byte > 0 ? memberExpression(containing: tree.node(atByteOffset: byte - 1)) : nil)
        if isMemberAccess || isMemberProperty(here) || member != nil && isMemberAccess {
            return .member(member ?? here)
        }
        if isMemberProperty(here), let member {
            return .member(member)
        }
        if let specifier = importSpecifier(around: here) {
            return .importExports(specifier: specifier)
        }
        if inTypePosition(here) { return .type }
        return .value
    }

    static func inCommentOrString(_ node: SyntaxNode) -> Bool {
        var insideSubstitution = false
        var current: SyntaxNode? = node
        while let node = current {
            if node.type == "template_substitution" { insideSubstitution = true }
            if node.type == "comment" || node.type == "string" || node.type == "string_fragment" { return true }
            if node.type == "template_string" && !insideSubstitution { return true }
            current = node.parent
        }
        return false
    }

    static func inTypePosition(_ node: SyntaxNode) -> Bool {
        var current: SyntaxNode? = node
        while let next = current {
            switch next.type {
            case "type_annotation", "type_arguments", "implements_clause", "extends_type_clause",
                 "extends_clause", "constraint":
                return true
            case "object_type", "interface_body":
                return false
            case "type_alias_declaration":
                if let value = next.child(byFieldName: "value"),
                   value.startByte <= node.startByte && node.startByte < value.endByte {
                    return true
                }
                return false
            default:
                break
            }
            current = next.parent
        }
        return false
    }
}

private enum TypeScriptExportMode {
    case none
    case named
    case `default`
}

private struct TypeScriptFrame {
    var blockStart: Int
    var blockEnd: Int
    var functionStart: Int
    var functionEnd: Int
    var recordsDeclarations: Bool
    var moduleLevel: Bool
    var exportMode: TypeScriptExportMode
    var inTypePosition: Bool
    var depth: Int
}

private final class TypeScriptWalker {
    typealias Model = TypeScriptFileModel
    let text: TypeScriptText
    private var stack: [[Model.Declaration]] = [[]]
    private var imports: [Model.Import] = []
    private var reexports: [Model.Reexport] = []
    private var localExports: [Model.LocalExport] = []
    private var bindings: [Model.Binding] = []
    private var uses: [Model.Use] = []
    private var errors: [Model.SyntaxError] = []

    init(text: TypeScriptText) {
        self.text = text
    }

    func build(_ root: SyntaxNode) -> TypeScriptFileModel {
        let end = root.endByte
        let frame = TypeScriptFrame(
            blockStart: 0, blockEnd: end, functionStart: 0, functionEnd: end,
            recordsDeclarations: true, moduleLevel: true, exportMode: .none,
            inTypePosition: false, depth: 0
        )
        _ = collectErrors(root)
        walk(root, frame)
        var declarations = stack.first ?? []
        for export in localExports {
            if let index = declarations.firstIndex(where: { $0.isTopLevel && $0.name == export.localName }) {
                if !declarations[index].exportNames.contains(export.exportedName) {
                    declarations[index].exportNames.append(export.exportedName)
                }
            }
        }
        resolveUses()
        return TypeScriptFileModel(
            declarations: declarations,
            imports: imports,
            reexports: reexports,
            bindings: bindings,
            uses: uses,
            errors: errors,
            identifiers: identifierSet(declarations)
        )
    }

    private func walk(_ node: SyntaxNode, _ frame: TypeScriptFrame) {
        guard frame.depth < 400 else { return }
        var frame = frame
        frame.depth += 1
        switch node.type {
        case "export_statement":
            walkExport(node, frame)
        case "import_statement":
            walkImport(node, frame)
        case "lexical_declaration", "variable_declaration":
            walkVariables(node, frame)
        case "function_declaration", "generator_function_declaration", "function_signature":
            walkFunction(node, frame, kind: .function, hoisted: true)
        case "function", "generator_function", "arrow_function":
            walkFunction(node, frame, kind: .function, hoisted: false)
        case "class_declaration", "abstract_class_declaration":
            walkClass(node, frame)
        case "interface_declaration":
            walkInterface(node, frame)
        case "type_alias_declaration":
            walkTypeAlias(node, frame)
        case "enum_declaration":
            walkEnum(node, frame)
        case "internal_module", "module":
            guard node.isNamed else { walkChildren(node, frame); return }
            walkNamespace(node, frame)
        case "ambient_declaration":
            walkChildren(node, frame)
        case "statement_block":
            var inner = frame
            inner.blockStart = node.startByte
            inner.blockEnd = node.endByte
            walkChildren(node, inner)
        case "for_statement", "for_in_statement":
            var inner = frame
            inner.blockStart = node.startByte
            inner.blockEnd = node.endByte
            walkChildren(node, inner)
        case "catch_clause":
            walkCatch(node, frame)
        case "call_expression":
            walkCall(node, frame)
        case "object_type", "interface_body":
            walkObjectType(node, frame)
        case "comment", "string":
            return
        case "template_string":
            for child in node.namedChildren where child.type == "template_substitution" {
                walk(child, frame)
            }
        default:
            if TypeScriptNames.isName(node.type) {
                recordUse(node, frame)
            } else {
                walkChildren(node, frame)
            }
        }
    }

    private func walkChildren(_ node: SyntaxNode, _ frame: TypeScriptFrame) {
        for child in node.namedChildren {
            walk(child, frame)
        }
    }

    private func walkExport(_ node: SyntaxNode, _ frame: TypeScriptFrame) {
        if let clause = node.namedChildren.first(where: { $0.type == "export_clause" }) {
            walkExportClause(clause, source: specifier(in: node), frame)
            return
        }
        var inner = frame
        inner.exportMode = node.children.contains(where: { $0.type == "default" }) ? .default : .named
        for child in node.namedChildren {
            walk(child, inner)
        }
    }

    private func walkExportClause(_ clause: SyntaxNode, source: String?, _ frame: TypeScriptFrame) {
        for child in clause.namedChildren {
            guard child.type == "import_specifier" || child.type == "export_specifier" else { continue }
            guard let nameNode = child.child(byFieldName: "name") ?? child.namedChildren.first(where: { TypeScriptNames.isName($0.type) }) else { continue }
            let alias = child.child(byFieldName: "alias")
            let exported = alias?.text ?? nameNode.text
            if let source {
                reexports.append(Model.Reexport(
                    exportedName: exported, specifier: source, importedName: nameNode.text, nameBytes: nameNode.byteRange
                ))
            } else {
                localExports.append(Model.LocalExport(
                    localName: nameNode.text, exportedName: exported, nameBytes: nameNode.byteRange
                ))
                recordUse(nameNode, frame)
            }
        }
    }

    private func walkImport(_ node: SyntaxNode, _ frame: TypeScriptFrame) {
        walkImportChildren(
            node, source: specifier(in: node) ?? "", statementTypeOnly: hasTypeKeyword(node), frame: frame
        )
    }

    /// `import { A } from "./a"` wraps the clause in `import_clause`. The module specifier stays on the statement.
    private func walkImportChildren(
        _ node: SyntaxNode, source: String, statementTypeOnly: Bool, frame: TypeScriptFrame
    ) {
        for child in node.namedChildren {
            switch child.type {
            case "import_clause":
                walkImportChildren(
                    child, source: source,
                    statementTypeOnly: statementTypeOnly || hasTypeKeyword(child), frame: frame
                )
            case "namespace_import":
                if let alias = child.child(byFieldName: "alias") ?? child.namedChildren.first(where: { TypeScriptNames.isName($0.type) }) {
                    addImport(
                        local: alias.text, imported: "*", localBytes: alias.byteRange, importedBytes: nil,
                        specifier: source, namespace: true, typeOnly: statementTypeOnly, frame: frame
                    )
                }
            case "named_imports":
                for specifier in child.namedChildren where specifier.type == "import_specifier" || specifier.type == "export_specifier" {
                    guard let nameNode = specifier.child(byFieldName: "name") ?? specifier.namedChildren.first(where: { TypeScriptNames.isName($0.type) }) else { continue }
                    let alias = specifier.child(byFieldName: "alias")
                    let localNode = alias ?? nameNode
                    addImport(
                        local: localNode.text, imported: nameNode.text, localBytes: localNode.byteRange,
                        importedBytes: alias == nil ? nil : nameNode.byteRange, specifier: source,
                        namespace: false, typeOnly: statementTypeOnly || hasTypeKeyword(specifier), frame: frame
                    )
                }
            case "identifier":
                addImport(
                    local: child.text, imported: "default", localBytes: child.byteRange, importedBytes: nil,
                    specifier: source, namespace: false, typeOnly: statementTypeOnly, frame: frame
                )
            default:
                break
            }
        }
    }

    private func addImport(
        local: String, imported: String, localBytes: Range<Int>, importedBytes: Range<Int>?,
        specifier: String, namespace: Bool, typeOnly: Bool, frame: TypeScriptFrame
    ) {
        imports.append(Model.Import(
            localName: local, importedName: imported, localBytes: localBytes, importedNameBytes: importedBytes,
            specifier: specifier, isNamespace: namespace, isTypeOnly: typeOnly
        ))
        bindings.append(Model.Binding(
            name: local, nameBytes: localBytes, scopeStart: frame.blockStart, scopeEnd: frame.blockEnd,
            symbolKind: typeOnly ? .typeAlias : (namespace ? .namespace : .local),
            isValue: !typeOnly, isType: true, isTypeOnly: typeOnly,
            typeName: nil, signature: "import \(local) from \"\(specifier)\"",
            specifier: specifier, importedName: imported, isNamespaceImport: namespace, isImport: true
        ))
    }

    private func walkVariables(_ node: SyntaxNode, _ frame: TypeScriptFrame) {
        let isVar = node.type == "variable_declaration"
        for child in node.namedChildren where child.type == "variable_declarator" {
            let pattern = child.child(byFieldName: "name") ?? child.namedChildren.first { isPattern($0.type) }
            let typeName = syntacticType(of: child)
            if let pattern {
                for (name, range) in bindingNames(in: pattern) {
                    let scopeStart = isVar ? frame.functionStart : child.startByte
                    let scopeEnd = isVar ? frame.functionEnd : frame.blockEnd
                    addBinding(
                        name: name, bytes: range, scopeStart: scopeStart, scopeEnd: scopeEnd,
                        symbolKind: .local, isValue: true, isType: false, typeName: typeName,
                        signature: typeName.map { "\(name): \($0)" } ?? name
                    )
                    if frame.recordsDeclarations && frame.moduleLevel {
                        addDeclaration(Model.Declaration(
                            name: name, nameBytes: range, bodyBytes: child.byteRange, kind: .variable,
                            exportNames: exportNames(for: name, frame: frame), heritage: [], members: [],
                            signature: collapsed(child), docComment: docComment(before: node),
                            isPrivate: false, typeName: typeName, isTopLevel: true
                        ))
                    }
                }
            }
            if let type = child.child(byFieldName: "type") {
                var inner = frame
                inner.inTypePosition = true
                walk(type, inner)
            }
            if let value = child.child(byFieldName: "value") {
                walk(value, frame)
            }
        }
    }

    private func walkFunction(_ node: SyntaxNode, _ frame: TypeScriptFrame, kind: Model.Kind, hoisted: Bool) {
        let nameNode = node.child(byFieldName: "name").flatMap { TypeScriptNames.isName($0.type) ? $0 : nil }
        if let nameNode, hoisted || node.type == "function" || node.type == "generator_function" {
            let scopeStart = hoisted ? frame.blockStart : node.startByte
            let scopeEnd = hoisted ? frame.blockEnd : node.endByte
            if hoisted || nameNode.parent?.type == node.type {
                addBinding(
                    name: nameNode.text, bytes: nameNode.byteRange, scopeStart: scopeStart, scopeEnd: scopeEnd,
                    symbolKind: .function, isValue: true, isType: false, typeName: nil,
                    signature: collapsed(node)
                )
            }
        }
        if hoisted, let nameNode, frame.recordsDeclarations {
            addDeclaration(Model.Declaration(
                name: nameNode.text, nameBytes: nameNode.byteRange, bodyBytes: node.byteRange, kind: kind,
                exportNames: exportNames(for: nameNode.text, frame: frame), heritage: [], members: [],
                signature: collapsed(node), docComment: docComment(before: node),
                isPrivate: false, typeName: nil, isTopLevel: frame.moduleLevel
            ))
        }
        walkTypeParameters(node, frame)
        bindParameters(node, scopeEnd: node.endByte, frame)
        if let type = node.child(byFieldName: "return_type") ?? node.child(byFieldName: "type") {
            var inner = frame
            inner.inTypePosition = true
            walk(type, inner)
        }
        if let body = node.child(byFieldName: "body") {
            var inner = frame
            inner.recordsDeclarations = false
            inner.moduleLevel = false
            inner.exportMode = .none
            inner.blockStart = body.startByte
            inner.blockEnd = body.endByte
            inner.functionStart = node.startByte
            inner.functionEnd = node.endByte
            walk(body, inner)
        }
    }

    private func walkClass(_ node: SyntaxNode, _ frame: TypeScriptFrame) {
        guard let nameNode = declarationName(node) else {
            walkChildren(node, frame)
            return
        }
        addBinding(
            name: nameNode.text, bytes: nameNode.byteRange, scopeStart: frame.blockStart, scopeEnd: frame.blockEnd,
            symbolKind: .class, isValue: true, isType: true, typeName: nil, signature: collapsed(node)
        )
        walkTypeParameters(node, frame)
        let heritage = heritageNames(in: node, ownName: nameNode.text)
        walkHeritageTypes(in: node, frame)
        let members = node.child(byFieldName: "body").map { collectMembers($0, frame) } ?? []
        if frame.recordsDeclarations {
            addDeclaration(Model.Declaration(
                name: nameNode.text, nameBytes: nameNode.byteRange, bodyBytes: node.byteRange, kind: .class,
                exportNames: exportNames(for: nameNode.text, frame: frame), heritage: heritage, members: members,
                signature: collapsed(node), docComment: docComment(before: node),
                isPrivate: false, typeName: nil, isTopLevel: frame.moduleLevel
            ))
        }
    }

    private func walkInterface(_ node: SyntaxNode, _ frame: TypeScriptFrame) {
        guard let nameNode = declarationName(node) else {
            walkChildren(node, frame)
            return
        }
        addBinding(
            name: nameNode.text, bytes: nameNode.byteRange, scopeStart: frame.blockStart, scopeEnd: frame.blockEnd,
            symbolKind: .interface, isValue: false, isType: true, typeName: nil, signature: collapsed(node)
        )
        walkTypeParameters(node, frame)
        let heritage = heritageNames(in: node, ownName: nameNode.text)
        walkHeritageTypes(in: node, frame)
        let body = node.child(byFieldName: "body") ?? node.namedChildren.first { $0.type == "object_type" || $0.type == "interface_body" }
        let members = body.map { collectMembers($0, frame) } ?? []
        if frame.recordsDeclarations {
            addDeclaration(Model.Declaration(
                name: nameNode.text, nameBytes: nameNode.byteRange, bodyBytes: node.byteRange, kind: .interface,
                exportNames: exportNames(for: nameNode.text, frame: frame), heritage: heritage, members: members,
                signature: collapsed(node), docComment: docComment(before: node),
                isPrivate: false, typeName: nil, isTopLevel: frame.moduleLevel
            ))
        }
    }

    private func walkTypeAlias(_ node: SyntaxNode, _ frame: TypeScriptFrame) {
        guard let nameNode = declarationName(node) else { return }
        addBinding(
            name: nameNode.text, bytes: nameNode.byteRange, scopeStart: frame.blockStart, scopeEnd: frame.blockEnd,
            symbolKind: .typeAlias, isValue: false, isType: true, typeName: nil, signature: collapsed(node)
        )
        walkTypeParameters(node, frame)
        var heritage: [String] = []
        var members: [Model.Declaration] = []
        if let value = node.child(byFieldName: "value") {
            if value.type == "object_type" || value.type == "interface_body" {
                members = collectMembers(value, frame)
            } else if let name = simpleTypeName(value) {
                heritage = [name]
            }
            var inner = frame
            inner.inTypePosition = true
            if value.type != "object_type" && value.type != "interface_body" {
                walk(value, inner)
            }
        }
        if frame.recordsDeclarations {
            addDeclaration(Model.Declaration(
                name: nameNode.text, nameBytes: nameNode.byteRange, bodyBytes: node.byteRange, kind: .typeAlias,
                exportNames: exportNames(for: nameNode.text, frame: frame), heritage: heritage, members: members,
                signature: collapsed(node), docComment: docComment(before: node),
                isPrivate: false, typeName: nil, isTopLevel: frame.moduleLevel
            ))
        }
    }

    private func walkEnum(_ node: SyntaxNode, _ frame: TypeScriptFrame) {
        guard let nameNode = declarationName(node) else { return }
        addBinding(
            name: nameNode.text, bytes: nameNode.byteRange, scopeStart: frame.blockStart, scopeEnd: frame.blockEnd,
            symbolKind: .enum, isValue: true, isType: true, typeName: nil, signature: collapsed(node)
        )
        let body = node.child(byFieldName: "body") ?? node.namedChildren.first { $0.type == "enum_body" }
        let members = body.map { collectMembers($0, frame) } ?? []
        if frame.recordsDeclarations {
            addDeclaration(Model.Declaration(
                name: nameNode.text, nameBytes: nameNode.byteRange, bodyBytes: node.byteRange, kind: .enum,
                exportNames: exportNames(for: nameNode.text, frame: frame), heritage: [], members: members,
                signature: collapsed(node), docComment: docComment(before: node),
                isPrivate: false, typeName: nil, isTopLevel: frame.moduleLevel
            ))
        }
    }

    private func walkNamespace(_ node: SyntaxNode, _ frame: TypeScriptFrame) {
        guard let nameNode = declarationName(node) else {
            walkChildren(node, frame)
            return
        }
        addBinding(
            name: nameNode.text, bytes: nameNode.byteRange, scopeStart: frame.blockStart, scopeEnd: frame.blockEnd,
            symbolKind: .namespace, isValue: true, isType: true, typeName: nil, signature: collapsed(node)
        )
        let body = node.child(byFieldName: "body") ?? node.namedChildren.last
        let members: [Model.Declaration]
        if let body {
            members = withChildDeclarations {
                var inner = frame
                inner.moduleLevel = false
                inner.recordsDeclarations = true
                inner.exportMode = .none
                inner.blockStart = body.startByte
                inner.blockEnd = body.endByte
                inner.functionStart = body.startByte
                inner.functionEnd = body.endByte
                walk(body, inner)
            }
        } else {
            members = []
        }
        if frame.recordsDeclarations {
            addDeclaration(Model.Declaration(
                name: nameNode.text, nameBytes: nameNode.byteRange, bodyBytes: node.byteRange, kind: .namespace,
                exportNames: exportNames(for: nameNode.text, frame: frame), heritage: [], members: members,
                signature: collapsed(node), docComment: docComment(before: node),
                isPrivate: false, typeName: nil, isTopLevel: frame.moduleLevel
            ))
        }
    }

    private func walkCatch(_ node: SyntaxNode, _ frame: TypeScriptFrame) {
        if let name = node.namedChildren.first(where: { TypeScriptNames.isName($0.type) || isPattern($0.type) }) {
            for (bound, range) in bindingNames(in: name) {
                addBinding(
                    name: bound, bytes: range, scopeStart: range.lowerBound, scopeEnd: node.endByte,
                    symbolKind: .parameter, isValue: true, isType: false, typeName: nil, signature: bound
                )
            }
        }
        if let body = node.child(byFieldName: "body") ?? node.namedChildren.first(where: { $0.type == "statement_block" }) {
            walk(body, frame)
        }
    }

    private func walkCall(_ node: SyntaxNode, _ frame: TypeScriptFrame) {
        if let function = node.child(byFieldName: "function") {
            walk(function, frame)
        } else if let first = node.namedChildren.first {
            walk(first, frame)
        }
        if let arguments = node.child(byFieldName: "arguments") {
            walk(arguments, frame)
        } else {
            for child in node.namedChildren.dropFirst() {
                walk(child, frame)
            }
        }
    }

    private func walkObjectType(_ node: SyntaxNode, _ frame: TypeScriptFrame) {
        for child in node.namedChildren {
            switch child.type {
            case "property_signature", "method_signature", "call_signature", "construct_signature", "index_signature":
                if let type = child.child(byFieldName: "type") ?? child.child(byFieldName: "return_type") {
                    var inner = frame
                    inner.inTypePosition = true
                    walk(type, inner)
                }
            default:
                var inner = frame
                inner.inTypePosition = false
                walk(child, inner)
            }
        }
    }

    private func collectMembers(_ body: SyntaxNode, _ frame: TypeScriptFrame) -> [Model.Declaration] {
        var members: [Model.Declaration] = []
        for child in body.namedChildren {
            switch child.type {
            case "method_definition", "method_signature", "abstract_method_signature":
                if let member = methodMember(child, frame) { members.append(member) }
            case "public_field_definition", "property_signature":
                if let member = fieldMember(child, frame) { members.append(member) }
            case "enum_assignment":
                if let member = enumMember(child, frame) { members.append(member) }
            case "property_identifier", "identifier":
                members.append(Model.Declaration(
                    name: child.text, nameBytes: child.byteRange, bodyBytes: child.byteRange, kind: .enumMember,
                    exportNames: [], heritage: [], members: [], signature: child.text, docComment: nil,
                    isPrivate: false, typeName: nil, isTopLevel: false
                ))
            case "class_declaration", "abstract_class_declaration", "interface_declaration",
                 "enum_declaration", "type_alias_declaration", "internal_module", "module":
                let nested = withChildDeclarations {
                    var inner = frame
                    inner.recordsDeclarations = true
                    inner.moduleLevel = false
                    inner.exportMode = .none
                    walk(child, inner)
                }
                members.append(contentsOf: nested)
            default:
                walk(child, frame)
            }
        }
        return members
    }

    private func methodMember(_ node: SyntaxNode, _ frame: TypeScriptFrame) -> Model.Declaration? {
        guard let nameNode = declarationName(node) else {
            if let body = node.child(byFieldName: "body") { walk(body, frame) }
            return nil
        }
        walkTypeParameters(node, frame)
        bindParameters(node, scopeEnd: node.endByte, frame)
        if let type = node.child(byFieldName: "return_type") ?? node.child(byFieldName: "type") {
            var inner = frame
            inner.inTypePosition = true
            walk(type, inner)
        }
        if let body = node.child(byFieldName: "body") {
            var inner = frame
            inner.recordsDeclarations = false
            inner.moduleLevel = false
            inner.exportMode = .none
            inner.blockStart = body.startByte
            inner.blockEnd = body.endByte
            inner.functionStart = node.startByte
            inner.functionEnd = node.endByte
            walk(body, inner)
        }
        return Model.Declaration(
            name: nameNode.text, nameBytes: nameNode.byteRange, bodyBytes: node.byteRange, kind: .method,
            exportNames: [], heritage: [], members: [], signature: collapsed(node),
            docComment: docComment(before: node), isPrivate: isRestricted(node), typeName: nil, isTopLevel: false
        )
    }

    private func fieldMember(_ node: SyntaxNode, _ frame: TypeScriptFrame) -> Model.Declaration? {
        guard let nameNode = declarationName(node) else { return nil }
        let typeName = node.child(byFieldName: "type").flatMap(simpleTypeName)
        if let type = node.child(byFieldName: "type") {
            var inner = frame
            inner.inTypePosition = true
            walk(type, inner)
        }
        if let value = node.child(byFieldName: "value") {
            walk(value, frame)
        }
        return Model.Declaration(
            name: nameNode.text, nameBytes: nameNode.byteRange, bodyBytes: node.byteRange, kind: .field,
            exportNames: [], heritage: [], members: [], signature: typeName.map { "\(nameNode.text): \($0)" } ?? nameNode.text,
            docComment: docComment(before: node), isPrivate: isRestricted(node) || nameNode.text.hasPrefix("#"),
            typeName: typeName, isTopLevel: false
        )
    }

    private func enumMember(_ node: SyntaxNode, _ frame: TypeScriptFrame) -> Model.Declaration? {
        guard let nameNode = declarationName(node) ?? node.namedChildren.first(where: { TypeScriptNames.isName($0.type) }) else { return nil }
        if let value = node.child(byFieldName: "value") {
            walk(value, frame)
        }
        return Model.Declaration(
            name: nameNode.text, nameBytes: nameNode.byteRange, bodyBytes: node.byteRange, kind: .enumMember,
            exportNames: [], heritage: [], members: [], signature: nameNode.text, docComment: nil,
            isPrivate: false, typeName: nil, isTopLevel: false
        )
    }

    private func bindParameters(_ node: SyntaxNode, scopeEnd: Int, _ frame: TypeScriptFrame) {
        let list = node.child(byFieldName: "parameters") ?? node.child(byFieldName: "parameter")
        guard let list else {
            if node.type == "arrow_function" {
                for child in node.namedChildren where isPattern(child.type) && child.type != "statement_block" && node.child(byFieldName: "body")?.startByte != child.startByte {
                    bindPattern(child, scopeEnd: scopeEnd, typeName: nil, frame)
                }
            }
            return
        }
        let parameters = list.type == "identifier" || isPattern(list.type) ? [list] : list.namedChildren
        for parameter in parameters {
            let pattern = parameter.child(byFieldName: "pattern") ?? parameter.namedChildren.first { isPattern($0.type) } ?? (isPattern(parameter.type) ? parameter : nil)
            let typeName = parameter.child(byFieldName: "type").flatMap(simpleTypeName)
            if let pattern {
                bindPattern(pattern, scopeEnd: scopeEnd, typeName: typeName, frame)
            }
            if let type = parameter.child(byFieldName: "type") {
                var inner = frame
                inner.inTypePosition = true
                walk(type, inner)
            }
            if let value = parameter.child(byFieldName: "value") {
                walk(value, frame)
            }
        }
    }

    private func bindPattern(_ pattern: SyntaxNode, scopeEnd: Int, typeName: String?, _ frame: TypeScriptFrame) {
        for (name, range) in bindingNames(in: pattern) {
            addBinding(
                name: name, bytes: range, scopeStart: range.lowerBound, scopeEnd: scopeEnd,
                symbolKind: .parameter, isValue: true, isType: false, typeName: typeName,
                signature: typeName.map { "\(name): \($0)" } ?? name
            )
        }
    }

    private func walkTypeParameters(_ node: SyntaxNode, _ frame: TypeScriptFrame) {
        guard let list = node.child(byFieldName: "type_parameters") else { return }
        for child in list.namedChildren {
            guard let nameNode = declarationName(child) ?? (TypeScriptNames.isName(child.type) ? child : nil) else { continue }
            addBinding(
                name: nameNode.text, bytes: nameNode.byteRange, scopeStart: node.startByte, scopeEnd: node.endByte,
                symbolKind: .typeAlias, isValue: false, isType: true, typeName: nil, signature: nameNode.text
            )
            if let constraint = child.child(byFieldName: "constraint") {
                var inner = frame
                inner.inTypePosition = true
                walk(constraint, inner)
            }
        }
    }

    private func walkHeritageTypes(in node: SyntaxNode, _ frame: TypeScriptFrame) {
        for child in node.namedChildren {
            switch child.type {
            case "class_heritage":
                walkHeritageTypes(in: child, frame)
            case "extends_clause", "implements_clause", "extends_type_clause":
                var inner = frame
                inner.inTypePosition = true
                walkChildren(child, inner)
            default:
                break
            }
        }
    }

    private func addBinding(
        name: String, bytes: Range<Int>, scopeStart: Int, scopeEnd: Int,
        symbolKind: Model.SymbolKind, isValue: Bool, isType: Bool, typeName: String?, signature: String,
        specifier: String? = nil, importedName: String? = nil, isNamespaceImport: Bool = false, isImport: Bool = false,
        isTypeOnly: Bool = false
    ) {
        bindings.append(Model.Binding(
            name: name, nameBytes: bytes, scopeStart: scopeStart, scopeEnd: max(scopeStart, scopeEnd),
            symbolKind: symbolKind, isValue: isValue, isType: isType, isTypeOnly: isTypeOnly,
            typeName: typeName, signature: signature, specifier: specifier, importedName: importedName,
            isNamespaceImport: isNamespaceImport, isImport: isImport
        ))
    }

    private func addDeclaration(_ declaration: Model.Declaration) {
        stack[stack.count - 1].append(declaration)
    }

    private func withChildDeclarations(_ body: () -> Void) -> [Model.Declaration] {
        stack.append([])
        body()
        return stack.removeLast()
    }

    private func recordUse(_ node: SyntaxNode, _ frame: TypeScriptFrame) {
        let parent = node.parent
        let isMember = parent?.type == "member_expression" && parent?.child(byFieldName: "property")?.startByte == node.startByte
        uses.append(Model.Use(
            name: node.text, bytes: node.byteRange, bindingStart: nil, inTypePosition: frame.inTypePosition,
            isMemberProperty: isMember, isCall: isDirectCall(node)
        ))
    }

    private func resolveUses() {
        for index in uses.indices {
            if uses[index].isMemberProperty { continue }
            let byte = uses[index].bytes.lowerBound
            let name = uses[index].name
            let matches = bindings.filter { $0.name == name && $0.scopeStart <= byte && byte < $0.scopeEnd }
            uses[index].bindingStart = Model.innermost(matches, at: byte)?.nameBytes.lowerBound
        }
    }

    private func exportNames(for name: String, frame: TypeScriptFrame) -> [String] {
        switch frame.exportMode {
        case .none: return []
        case .named: return [name]
        case .default: return ["default"]
        }
    }

    private func identifierSet(_ declarations: [Model.Declaration]) -> Set<String> {
        var names = Set<String>()
        func walk(_ declaration: Model.Declaration) {
            names.insert(declaration.name)
            names.formUnion(declaration.exportNames)
            declaration.members.forEach(walk)
        }
        declarations.forEach(walk)
        for item in imports {
            names.insert(item.localName)
            names.insert(item.importedName)
        }
        for item in reexports {
            names.insert(item.exportedName)
            names.insert(item.importedName)
        }
        for binding in bindings { names.insert(binding.name) }
        for use in uses { names.insert(use.name) }
        names.remove("*")
        return names
    }

    private func collectErrors(_ node: SyntaxNode) -> Bool {
        var reported = false
        for child in node.children where collectErrors(child) {
            reported = true
        }
        let isError = node.type == "ERROR" || node.isMissing
        if !reported && (isError || node.hasError) {
            errors.append(Model.SyntaxError(bytes: node.byteRange))
            return true
        }
        return reported || isError
    }

    private func declarationName(_ node: SyntaxNode) -> SyntaxNode? {
        if let name = node.child(byFieldName: "name"), TypeScriptNames.isName(name.type) || name.type == "private_property_identifier" {
            return name
        }
        return node.namedChildren.first { TypeScriptNames.isName($0.type) }
    }

    private func bindingNames(in node: SyntaxNode) -> [(String, Range<Int>)] {
        switch node.type {
        case "identifier", "shorthand_property_identifier_pattern", "private_property_identifier":
            return [(node.text, node.byteRange)]
        case "rest_pattern":
            return node.namedChildren.flatMap { bindingNames(in: $0) }
        case "object_pattern", "array_pattern":
            return node.namedChildren.flatMap { bindingNames(in: $0) }
        case "assignment_pattern":
            if let left = node.child(byFieldName: "left") ?? node.namedChildren.first {
                return bindingNames(in: left)
            }
            return []
        case "pair_pattern", "pair":
            if let value = node.child(byFieldName: "value") ?? node.namedChildren.last {
                return bindingNames(in: value)
            }
            return []
        default:
            return []
        }
    }

    private func isPattern(_ type: String) -> Bool {
        switch type {
        case "identifier", "object_pattern", "array_pattern", "rest_pattern", "assignment_pattern",
             "pair_pattern", "shorthand_property_identifier_pattern":
            return true
        default:
            return false
        }
    }

    private func syntacticType(of declarator: SyntaxNode) -> String? {
        if let annotation = declarator.child(byFieldName: "type"), let name = simpleTypeName(annotation) {
            return name
        }
        if let value = declarator.child(byFieldName: "value") {
            return syntacticType(ofValue: value)
        }
        return nil
    }

    private func syntacticType(ofValue node: SyntaxNode) -> String? {
        let node = unwrap(node)
        switch node.type {
        case "new_expression":
            let constructor = node.child(byFieldName: "constructor") ?? node.namedChildren.first
            return constructor.flatMap { simpleTypeName(unwrap($0)) }
        case "as_expression", "type_assertion":
            if let type = node.child(byFieldName: "type") { return simpleTypeName(type) }
            return node.namedChildren.last.flatMap(simpleTypeName)
        default:
            return nil
        }
    }

    private func simpleTypeName(_ node: SyntaxNode) -> String? {
        switch node.type {
        case "identifier", "type_identifier":
            return node.text
        case "generic_type", "type_annotation", "parenthesized_type":
            if let name = node.child(byFieldName: "name") { return simpleTypeName(name) }
            return node.namedChildren.first.flatMap(simpleTypeName)
        default:
            return nil
        }
    }

    private func unwrap(_ node: SyntaxNode) -> SyntaxNode {
        var node = node
        for _ in 0..<8 {
            if node.type == "parenthesized_expression" || node.type == "non_null_expression",
               let inner = node.namedChildren.first {
                node = inner
                continue
            }
            return node
        }
        return node
    }

    private func heritageNames(in node: SyntaxNode, ownName: String) -> [String] {
        var names: [String] = []
        func visit(_ node: SyntaxNode) {
            switch node.type {
            case "class_heritage":
                node.namedChildren.forEach(visit)
            case "extends_clause", "implements_clause", "extends_type_clause":
                for child in node.namedChildren {
                    if let name = simpleTypeName(child), name != ownName {
                        names.append(name)
                    }
                }
            default:
                break
            }
        }
        visit(node)
        node.namedChildren.forEach(visit)
        return names
    }

    private func specifier(in node: SyntaxNode) -> String? {
        guard let source = node.child(byFieldName: "source") else { return nil }
        if let fragment = source.namedChildren.first(where: { $0.type == "string_fragment" }) {
            let text = fragment.text
            return text.isEmpty ? nil : text
        }
        var text = source.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, let first = text.first, let last = text.last, first == last, first == "\"" || first == "'" {
            text = String(text.dropFirst().dropLast())
        }
        return text.isEmpty ? nil : text
    }

    private func hasTypeKeyword(_ node: SyntaxNode) -> Bool {
        node.children.contains { $0.type == "type" }
    }

    private func isRestricted(_ node: SyntaxNode) -> Bool {
        if node.children.contains(where: { $0.type == "private" || $0.type == "protected" || $0.text == "private" || $0.text == "protected" }) {
            return true
        }
        if let name = declarationName(node), name.text.hasPrefix("#") || name.type == "private_property_identifier" {
            return true
        }
        return false
    }

    private func isDirectCall(_ node: SyntaxNode) -> Bool {
        guard let parent = node.parent else { return false }
        if parent.type == "call_expression", parent.child(byFieldName: "function")?.startByte == node.startByte {
            return true
        }
        if parent.type == "member_expression",
           parent.child(byFieldName: "property")?.startByte == node.startByte,
           let grand = parent.parent, grand.type == "call_expression",
           grand.child(byFieldName: "function")?.startByte == parent.startByte {
            return true
        }
        return false
    }

    private func collapsed(_ node: SyntaxNode) -> String {
        let end = node.child(byFieldName: "body")?.startByte ?? node.endByte
        let raw = text.text(bytes: node.startByte..<end)
        var joined = raw.split { $0.isWhitespace }.joined(separator: " ")
        if joined.count > 300 {
            joined = String(joined.prefix(300)) + "…"
        }
        return joined
    }

    private func docComment(before node: SyntaxNode) -> String? {
        let host = node.parent?.type == "export_statement" ? node.parent! : node
        guard let parent = host.parent else { return nil }
        let prior = parent.children.filter { $0.endByte <= host.startByte && $0.type != ";" }
        guard let comment = prior.last, comment.type == "comment", comment.text.contains("/**") else { return nil }
        return comment.text
    }
}

private func isDeclarationName(_ node: SyntaxNode) -> Bool {
    guard let parent = node.parent else { return false }
    switch parent.type {
    case "function_declaration", "generator_function_declaration", "function_signature",
         "class_declaration", "abstract_class_declaration", "interface_declaration",
         "type_alias_declaration", "enum_declaration", "method_definition", "method_signature",
         "abstract_method_signature", "public_field_definition", "property_signature",
         "variable_declarator", "internal_module", "module", "enum_assignment", "type_parameter":
        return parent.child(byFieldName: "name")?.startByte == node.startByte
            || parent.namedChildren.first?.startByte == node.startByte
    default:
        return false
    }
}

private func isMemberProperty(_ node: SyntaxNode) -> Bool {
    guard let parent = node.parent, parent.type == "member_expression" else { return false }
    return parent.child(byFieldName: "property")?.startByte == node.startByte
}

private func memberExpression(containing node: SyntaxNode) -> SyntaxNode? {
    var current: SyntaxNode? = node
    var depth = 0
    while let next = current, depth < 12 {
        if next.type == "member_expression" { return next }
        if next.type == "program" || next.type == "statement_block" { return nil }
        current = next.parent
        depth += 1
    }
    return nil
}

private func importSpecifier(around node: SyntaxNode) -> String? {
    var current: SyntaxNode? = node
    var inClause = false
    while let next = current {
        if next.type == "named_imports" || next.type == "import_specifier" {
            inClause = true
        }
        if next.type == "import_statement" || (next.type == "export_statement" && inClause) {
            guard inClause else { return nil }
            if let source = next.child(byFieldName: "source") {
                if let fragment = source.namedChildren.first(where: { $0.type == "string_fragment" }) {
                    return fragment.text
                }
                var text = source.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.count >= 2, let first = text.first, let last = text.last, first == last, first == "\"" || first == "'" {
                    text = String(text.dropFirst().dropLast())
                }
                return text.isEmpty ? nil : text
            }
            return nil
        }
        current = next.parent
    }
    return nil
}
