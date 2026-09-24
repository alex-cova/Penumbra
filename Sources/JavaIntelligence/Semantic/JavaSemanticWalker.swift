import Foundation

/// One pass over a Java syntax tree that classifies identifiers with a scope chain. See
/// ``JavaSemanticTokenProvider`` for what it does and does not resolve.
final class JavaSemanticWalker {
    private enum Binding {
        /// A local or parameter carries the byte range of its declaring name.
        case local(Range<Int>)
        case parameter(Range<Int>)
        case field(isStatic: Bool, isFinal: Bool)
        case enumConstant
        case typeParameter
    }

    private struct Pending {
        var token: JavaSemanticToken
        /// A type name the file does not declare; its kind comes from the index.
        var externalName: String?
    }

    /// Receives every declaration and use of a local or parameter as `(declaration name range,
    /// identifier range, isDeclaration)`. Set by ``JavaLocalUsages``; nil for token output.
    var localSink: ((Range<Int>, Range<Int>, Bool) -> Void)?

    private let tree: JavaSyntaxTree
    var syntaxTree: JavaSyntaxTree { tree }
    private let importList: JavaImportList
    private var utf16Offsets: [Int32]?
    private var scopes: [[String: Binding]] = []
    private var pending: [Pending] = []
    private var declaredTypes: [String: JavaSemanticTokenKind] = [:]
    private var staticMethodNames: Set<String> = []
    private var staticImportedMembers: Set<String> = []
    private var visited = 0

    private static let typeDeclarations: [String: JavaSemanticTokenKind] = [
        "class_declaration": .classType, "interface_declaration": .interfaceType, "enum_declaration": .enumType,
        "record_declaration": .recordType, "annotation_type_declaration": .annotationType
    ]

    init(tree: JavaSyntaxTree, source: String) {
        self.tree = tree
        self.importList = JavaImportList(tree: tree)
        if source.utf8.count != source.utf16.count {
            var table = [Int32](repeating: 0, count: tree.sourceBytes.count + 1)
            var units: Int32 = 0
            for (index, byte) in tree.sourceBytes.enumerated() {
                table[index] = units
                // Continuation bytes add nothing; a 4-byte sequence is two UTF-16 units.
                if byte & 0xC0 != 0x80 { units += byte >= 0xF0 ? 2 : 1 }
            }
            table[tree.sourceBytes.count] = units
            utf16Offsets = table
        }
    }

    /// Type names used but not declared in the file.
    var undeclaredTypeNames: Set<String> {
        Set(pending.compactMap(\.externalName))
    }

    /// Where a simple type name may live: an import naming it, its own package, then `java.lang`.
    func candidateQualifiedNames(for name: String) -> [String] {
        var result = importList.entries
            .filter { !$0.isStatic && !$0.isOnDemand && $0.qualifiedName.hasSuffix("." + name) }
            .map(\.qualifiedName)
        result += importList.entries.filter { !$0.isStatic && $0.isOnDemand }.map { "\($0.qualifiedName).\(name)" }
        result.append(importList.packageName.isEmpty ? name : "\(importList.packageName).\(name)")
        result.append("java.lang.\(name)")
        return result
    }

    /// Runs the pass. `false` when the task was cancelled part way.
    func run() -> Bool {
        let root = tree.rootNode
        collectDeclarations(root)
        for entry in importList.entries where entry.isStatic && !entry.isOnDemand {
            if let last = entry.qualifiedName.split(separator: ".").last { staticImportedMembers.insert(String(last)) }
        }
        scopes = [[:]]
        return walk(root)
    }

    func finish(externalKinds: [String: JavaTypeKind]) -> [JavaSemanticToken] {
        var tokens = pending.map { entry -> JavaSemanticToken in
            guard let name = entry.externalName, let kind = externalKinds[name] else { return entry.token }
            let mapped: JavaSemanticTokenKind
            switch kind {
            case .classKind: mapped = .classType
            case .interfaceKind: mapped = .interfaceType
            case .enumKind: mapped = .enumType
            case .recordKind: mapped = .recordType
            case .annotationKind: mapped = .annotationType
            }
            return JavaSemanticToken(range: entry.token.range, kind: mapped, isDeclaration: entry.token.isDeclaration)
        }
        tokens.sort { $0.range.lowerBound < $1.range.lowerBound }
        return tokens
    }

    // MARK: - Declarations

    private func collectDeclarations(_ root: SyntaxNode) {
        var stack = [root]
        while let node = stack.popLast() {
            if let kind = Self.typeDeclarations[node.type], let name = node.child(byFieldName: "name") {
                declaredTypes[name.text] = kind
            }
            if node.type == "method_declaration", let name = node.child(byFieldName: "name"),
               node.children.contains(where: { $0.type == "modifiers" && $0.text.contains("static") }) {
                staticMethodNames.insert(name.text)
            }
            stack.append(contentsOf: node.children)
        }
    }

    // MARK: - Walk

    private func walk(_ node: SyntaxNode) -> Bool {
        visited += 1
        if visited % 512 == 0, Task.isCancelled { return false }
        switch node.type {
        case "class_declaration", "interface_declaration", "enum_declaration", "record_declaration", "annotation_type_declaration":
            return walkTypeDeclaration(node)
        case "method_declaration", "constructor_declaration", "compact_constructor_declaration":
            return walkMethod(node)
        case "lambda_expression":
            return inScope(node) {
                // `x -> ...`: a bare identifier parameter. Only bound when collecting local usages,
                // so semantic-token output stays as it was.
                if localSink != nil, let single = node.child(byFieldName: "parameters"), single.type == "identifier" {
                    bindLocal(single, .parameter(single.byteRange))
                    for child in node.children where child.isNamed && child.byteRange != single.byteRange {
                        if !walk(child) { return false }
                    }
                    return true
                }
                return walkChildren(node)
            }
        case "block", "constructor_body", "switch_block", "for_statement", "enhanced_for_statement", "catch_clause",
             "try_with_resources_statement":
            return inScope(node) { walkChildren(node) }
        case "local_variable_declaration":
            return walkLocalDeclaration(node)
        case "field_declaration":
            return walkFieldDeclaration(node)
        case "formal_parameter", "spread_parameter", "catch_formal_parameter", "inferred_parameters":
            return walkParameter(node)
        case "resource":
            return walkParameter(node)
        case "type_pattern", "record_pattern":
            return walkParameter(node)
        case "method_invocation":
            return walkInvocation(node)
        case "object_creation_expression":
            return walkCreation(node)
        case "field_access":
            return walkFieldAccess(node)
        case "marker_annotation", "annotation":
            return walkAnnotation(node)
        case "type_identifier":
            classify(typeName: node)
            return true
        case "identifier":
            classify(expressionName: node)
            return true
        default:
            return walkChildren(node)
        }
    }

    private func walkChildren(_ node: SyntaxNode) -> Bool {
        for child in node.children where child.isNamed {
            if !walk(child) { return false }
        }
        return true
    }

    private func inScope(_ node: SyntaxNode, _ body: () -> Bool) -> Bool {
        scopes.append([:])
        defer { scopes.removeLast() }
        return body()
    }

    private func walkTypeDeclaration(_ node: SyntaxNode) -> Bool {
        guard let kind = Self.typeDeclarations[node.type], let name = node.child(byFieldName: "name") else { return walkChildren(node) }
        emit(name, kind, isDeclaration: true)
        scopes.append([:])
        defer { scopes.removeLast() }
        // Type parameters, then record components (they are fields), then the members.
        if let parameters = node.child(byFieldName: "type_parameters") {
            for parameter in parameters.namedChildren(ofType: "type_parameter") {
                if let id = parameter.namedChild(at: 0) {
                    bind(id.text, .typeParameter)
                    emit(id, .typeParameter, isDeclaration: true)
                }
                for child in parameter.namedChildren.dropFirst() where !walk(child) { return false }
            }
        }
        if node.type == "record_declaration", let components = node.child(byFieldName: "parameters") {
            for component in components.namedChildren(ofType: "formal_parameter") {
                if let id = component.child(byFieldName: "name") {
                    bind(id.text, .field(isStatic: false, isFinal: true))
                    emit(id, .field, isFinal: true, isDeclaration: true)
                }
                if let type = component.child(byFieldName: "type"), !walk(type) { return false }
            }
        }
        let body = node.child(byFieldName: "body")
        if let body { bindMembers(of: body) }
        for child in node.children where child.isNamed {
            let isBody = body.map { $0.byteRange == child.byteRange } ?? false
            let isName = child.byteRange == name.byteRange
            let isHeader = child.type == "type_parameters" || (node.type == "record_declaration" && child.type == "formal_parameters")
            if isBody || (!isName && !isHeader && child.type != "modifiers") {
                if !walk(child) { return false }
            } else if child.type == "modifiers", !walk(child) {
                return false
            }
        }
        return true
    }

    /// Fields and enum constants are visible throughout a type body, whatever their order.
    private func bindMembers(of body: SyntaxNode) {
        for member in body.namedChildren {
            switch member.type {
            case "field_declaration":
                let modifiers = member.children.first { $0.type == "modifiers" }?.text ?? ""
                let isInterface = body.parent?.type == "interface_declaration" || body.parent?.type == "annotation_type_declaration"
                let isStatic = modifiers.contains("static") || isInterface
                let isFinal = modifiers.contains("final") || isInterface
                for declarator in member.namedChildren(ofType: "variable_declarator") {
                    if let id = declarator.child(byFieldName: "name") { bind(id.text, .field(isStatic: isStatic, isFinal: isFinal)) }
                }
            case "enum_constant":
                if let id = member.child(byFieldName: "name") { bind(id.text, .enumConstant) }
            case "enum_body_declarations":
                bindMembers(of: member)
            default:
                break
            }
        }
        for constant in body.namedChildren(ofType: "enum_constant") {
            if let id = constant.child(byFieldName: "name") { bind(id.text, .enumConstant) }
        }
    }

    private func walkMethod(_ node: SyntaxNode) -> Bool {
        scopes.append([:])
        defer { scopes.removeLast() }
        let isConstructor = node.type != "method_declaration"
        if let name = node.child(byFieldName: "name") { emit(name, isConstructor ? .constructor : .methodDeclaration, isStatic: isStatic(node), isDeclaration: true) }
        if let parameters = node.child(byFieldName: "type_parameters") {
            for parameter in parameters.namedChildren(ofType: "type_parameter") {
                if let id = parameter.namedChild(at: 0) {
                    bind(id.text, .typeParameter)
                    emit(id, .typeParameter, isDeclaration: true)
                }
            }
        }
        let name = node.child(byFieldName: "name")
        for child in node.children where child.isNamed {
            if child.byteRange == name?.byteRange || child.type == "type_parameters" { continue }
            if !walk(child) { return false }
        }
        return true
    }

    private func isStatic(_ node: SyntaxNode) -> Bool {
        node.children.contains { $0.type == "modifiers" && $0.text.contains("static") }
    }

    private func walkLocalDeclaration(_ node: SyntaxNode) -> Bool {
        for child in node.children where child.isNamed {
            if child.type == "variable_declarator" {
                if let id = child.child(byFieldName: "name") {
                    bindLocal(id, .local(id.byteRange))
                    emit(id, .localVariable, isDeclaration: true)
                }
                for part in child.namedChildren where part.byteRange != child.child(byFieldName: "name")?.byteRange {
                    if !walk(part) { return false }
                }
            } else if !walk(child) {
                return false
            }
        }
        return true
    }

    private func walkFieldDeclaration(_ node: SyntaxNode) -> Bool {
        for child in node.children where child.isNamed {
            guard child.type == "variable_declarator", let id = child.child(byFieldName: "name") else {
                if !walk(child) { return false }
                continue
            }
            if case .field(let isStatic, let isFinal)? = lookup(id.text) {
                emit(id, .field, isStatic: isStatic, isFinal: isFinal, isDeclaration: true)
            }
            for part in child.namedChildren where part.byteRange != id.byteRange {
                if !walk(part) { return false }
            }
        }
        return true
    }

    /// A parameter-like declaration: its name is declared here; everything else is walked.
    private func walkParameter(_ node: SyntaxNode) -> Bool {
        if node.type == "inferred_parameters" {
            for id in node.namedChildren(ofType: "identifier") {
                bindLocal(id, .parameter(id.byteRange))
                emit(id, .parameter, isDeclaration: true)
            }
            return true
        }
        let nameNode = node.child(byFieldName: "name") ?? node.namedChildren(ofType: "variable_declarator").first?.child(byFieldName: "name")
            ?? (node.type == "type_pattern" || node.type == "catch_formal_parameter" ? node.namedChildren(ofType: "identifier").last : nil)
        let isLocal = node.type == "resource" || node.type == "type_pattern"
        if let nameNode {
            bindLocal(nameNode, isLocal ? .local(nameNode.byteRange) : .parameter(nameNode.byteRange))
            emit(nameNode, isLocal ? .localVariable : .parameter, isDeclaration: true)
        }
        for child in node.namedChildren where child.byteRange != nameNode?.byteRange {
            if child.type == "variable_declarator" {
                for part in child.namedChildren where part.byteRange != nameNode?.byteRange {
                    if !walk(part) { return false }
                }
            } else if !walk(child) {
                return false
            }
        }
        return true
    }

    // MARK: - Uses

    private func walkInvocation(_ node: SyntaxNode) -> Bool {
        let name = node.child(byFieldName: "name")
        let object = node.child(byFieldName: "object")
        var isStaticCall = false
        if let object {
            if object.type == "identifier", lookup(object.text) == nil, isTypeLike(object.text) { isStaticCall = true }
        } else if let name {
            isStaticCall = staticMethodNames.contains(name.text) || staticImportedMembers.contains(name.text)
        }
        if let name { emit(name, .methodCall, isStatic: isStaticCall) }
        for child in node.children where child.isNamed {
            if child.byteRange == name?.byteRange { continue }
            if child.byteRange == object?.byteRange, isStaticCall, child.type == "identifier" {
                emitType(child)
                continue
            }
            if !walk(child) { return false }
        }
        return true
    }

    private func walkCreation(_ node: SyntaxNode) -> Bool {
        // `new Foo(...)`: the type is a type; it is the constructor being called.
        for child in node.children where child.isNamed {
            if child.byteRange == node.child(byFieldName: "type")?.byteRange, child.type == "type_identifier" {
                emitConstructorOrType(child)
                continue
            }
            if !walk(child) { return false }
        }
        return true
    }

    private func walkFieldAccess(_ node: SyntaxNode) -> Bool {
        let object = node.child(byFieldName: "object")
        let field = node.child(byFieldName: "field")
        var isStaticAccess = false
        if let object {
            if object.type == "identifier", lookup(object.text) == nil, isTypeLike(object.text) {
                isStaticAccess = true
                emitType(object)
            } else if !walk(object) {
                return false
            }
        }
        if let field {
            let isConstantName = field.text.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" } && field.text.contains { $0.isUppercase }
            emit(field, .field, isStatic: isStaticAccess, isFinal: isConstantName)
        }
        return true
    }

    private func walkAnnotation(_ node: SyntaxNode) -> Bool {
        for child in node.children where child.isNamed {
            if child.byteRange == node.child(byFieldName: "name")?.byteRange {
                if child.type == "identifier" { emitType(child, forcedKind: .annotationType) }
                else { _ = walk(child) }
                continue
            }
            if !walk(child) { return false }
        }
        return true
    }

    private func classify(typeName node: SyntaxNode) {
        let name = node.text
        if case .typeParameter? = lookup(name) {
            emit(node, .typeParameter)
        } else {
            emitType(node)
        }
    }

    private func classify(expressionName node: SyntaxNode) {
        let name = node.text
        if let binding = lookup(name) {
            switch binding {
            case .local(let declaration):
                localSink?(declaration, node.byteRange, false)
                emit(node, .localVariable)
            case .parameter(let declaration):
                localSink?(declaration, node.byteRange, false)
                emit(node, .parameter)
            case .field(let isStatic, let isFinal): emit(node, .field, isStatic: isStatic, isFinal: isFinal)
            case .enumConstant: emit(node, .enumConstant)
            case .typeParameter: emit(node, .typeParameter)
            }
        } else if declaredTypes[name] != nil {
            emitType(node)
        } else if staticImportedMembers.contains(name) {
            let isConstantName = name.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" }
            emit(node, .field, isStatic: true, isFinal: isConstantName)
        }
    }

    // MARK: - Emitting

    private func isTypeLike(_ name: String) -> Bool {
        declaredTypes[name] != nil || (name.first?.isUppercase ?? false)
    }

    /// Binds a local or parameter name and reports its declaration to ``localSink``.
    private func bindLocal(_ node: SyntaxNode, _ binding: Binding) {
        bind(node.text, binding)
        localSink?(node.byteRange, node.byteRange, true)
    }

    private func bind(_ name: String, _ binding: Binding) {
        guard !scopes.isEmpty else { return }
        scopes[scopes.count - 1][name] = binding
    }

    private func lookup(_ name: String) -> Binding? {
        for scope in scopes.reversed() {
            if let binding = scope[name] { return binding }
        }
        return nil
    }

    private func emitConstructorOrType(_ node: SyntaxNode) {
        // A constructor call is coloured as the type it creates, as editors usually do; the
        // dedicated `constructor` kind is for the declaration.
        emitType(node)
    }

    private func emitType(_ node: SyntaxNode, forcedKind: JavaSemanticTokenKind? = nil) {
        let name = node.text
        if let forcedKind {
            emit(node, forcedKind)
        } else if let kind = declaredTypes[name] {
            emit(node, kind)
        } else {
            append(node, JavaSemanticToken(range: utf16Range(of: node), kind: .classType), externalName: name)
        }
    }

    private func emit(_ node: SyntaxNode, _ kind: JavaSemanticTokenKind, isStatic: Bool = false, isFinal: Bool = false, isDeclaration: Bool = false) {
        append(node, JavaSemanticToken(range: utf16Range(of: node), kind: kind, isStatic: isStatic, isFinal: isFinal, isDeclaration: isDeclaration), externalName: nil)
    }

    private func append(_ node: SyntaxNode, _ token: JavaSemanticToken, externalName: String?) {
        guard token.range.upperBound > token.range.lowerBound else { return }
        pending.append(Pending(token: token, externalName: externalName))
    }

    private func utf16Range(of node: SyntaxNode) -> Range<Int> {
        guard let table = utf16Offsets else { return node.startByte..<node.endByte }
        return Int(table[node.startByte])..<Int(table[node.endByte])
    }
}
