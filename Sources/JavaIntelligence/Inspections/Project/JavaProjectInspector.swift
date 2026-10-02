import Foundation

/// Inspections that need usages from the whole project. They run on save (and when the index
/// changes), never per keystroke: each declaration of the file costs one usage search through
/// ``JavaFindUsagesProvider``, so the number of declarations looked at is capped.
enum JavaProjectInspector {
    static let maxDeclarations = 150

    private enum Access: Int, Comparable {
        case `private`, packagePrivate, protected, `public`
        static func < (lhs: Access, rhs: Access) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private struct Declaration {
        enum Kind { case type, field, method }
        let kind: Kind
        let node: SyntaxNode
        let name: SyntaxNode
        let access: Access
        let enclosingType: SyntaxNode?
    }

    /// Annotations that do not mark a framework entry point.
    private static let harmlessAnnotations: Set<String> = ["Deprecated", "SuppressWarnings", "SafeVarargs", "FunctionalInterface", "SuppressFBWarnings"]
    private static let typeNodes: Set<String> = ["class_declaration", "interface_declaration", "enum_declaration", "record_declaration", "annotation_type_declaration"]
    private static let literalTypes: Set<String> = [
        "string_literal", "decimal_integer_literal", "true", "false", "null_literal", "character_literal",
        "decimal_floating_point_literal", "hex_integer_literal", "text_block",
    ]

    static func inspect(
        source: String, url: URL, tree: JavaSyntaxTree, provider: JavaFindUsagesProvider,
        enabled: Set<JavaInspectionRule>, options: JavaProjectInspectionOptions
    ) async -> [JavaInspection] {
        let rules = enabled.intersection(JavaInspectionRegistry.projectRules)
        guard !rules.isEmpty, !tree.rootNode.hasError else { return [] }
        var results: [JavaInspection] = []
        var parsed: [URL: (text: String, tree: JavaSyntaxTree)] = [:]
        var looked = 0
        for declaration in declarations(in: tree) {
            if Task.isCancelled { return [] }
            guard isCandidate(declaration, options: options) else { continue }
            looked += 1
            if looked > maxDeclarations { break }
            let offset = JavaInspectionSupport.position(forByte: declaration.name.startByte, in: tree).utf16Offset
            guard let found = await provider.declarationUsages(source: source, url: url, utf16Offset: offset) else { continue }
            let standardized = url.standardizedFileURL
            let outside = found.usages.filter { usage in
                !(usage.url.standardizedFileURL == standardized && declaration.node.byteRange.contains(usage.byteRange.lowerBound))
            }
            if rules.contains(.unusedDeclaration), outside.isEmpty, isReportableAsUnused(declaration) {
                results.append(JavaInspectionSupport.inspection(
                    .unusedDeclaration, message: "\(label(of: declaration)) '\(declaration.name.text)' is never used", node: declaration.name
                ))
                continue
            }
            guard !outside.isEmpty else { continue }
            if rules.contains(.declarationAccessCanBeWeaker), canBePrivate(declaration, usages: outside, in: url, tree: tree) {
                results.append(JavaInspectionSupport.inspection(
                    .declarationAccessCanBeWeaker, message: "\(label(of: declaration)) '\(declaration.name.text)' can be private", node: declaration.name
                ))
            }
            guard declaration.kind == .method, found.familyCount <= 1, found.usages.allSatisfy({ $0.confidence == .exact }) else { continue }
            if rules.contains(.methodCanBeVoid) || rules.contains(.parameterAlwaysSameValue) {
                let calls = await callSites(of: found.usages, provider: provider, cache: &parsed)
                guard let calls else { continue }
                if rules.contains(.methodCanBeVoid), returnsValue(declaration.node), !returnsThis(declaration.node),
                   calls.allSatisfy({ $0.call.parent?.type == "expression_statement" }) {
                    results.append(JavaInspectionSupport.inspection(
                        .methodCanBeVoid, message: "Return value of '\(declaration.name.text)' is never used", node: declaration.name
                    ))
                }
                if rules.contains(.parameterAlwaysSameValue), calls.count >= 2 {
                    results.append(contentsOf: constantParameters(of: declaration, calls: calls.map(\.call)))
                }
            }
        }
        return results
    }

    // MARK: Declarations

    private static func declarations(in tree: JavaSyntaxTree) -> [Declaration] {
        var found: [Declaration] = []
        var stack: [(SyntaxNode, SyntaxNode?)] = [(tree.rootNode, nil)]
        while let (node, enclosing) = stack.popLast() {
            var nextEnclosing = enclosing
            if typeNodes.contains(node.type), let name = node.child(byFieldName: "name") {
                found.append(Declaration(kind: .type, node: node, name: name, access: access(of: node, in: enclosing), enclosingType: enclosing))
                nextEnclosing = node
            } else if let enclosing {
                switch node.type {
                case "method_declaration":
                    if let name = node.child(byFieldName: "name") {
                        found.append(Declaration(kind: .method, node: node, name: name, access: access(of: node, in: enclosing), enclosingType: enclosing))
                    }
                case "field_declaration":
                    for declarator in node.namedChildren(ofType: "variable_declarator") {
                        if let name = declarator.child(byFieldName: "name") {
                            found.append(Declaration(kind: .field, node: node, name: name, access: access(of: node, in: enclosing), enclosingType: enclosing))
                        }
                    }
                default:
                    break
                }
            }
            for child in node.namedChildren.reversed() { stack.append((child, nextEnclosing)) }
        }
        return found.sorted { $0.name.startByte < $1.name.startByte }
    }

    /// The access a declaration is reachable with: its own modifier, capped by the types around it.
    private static func access(of node: SyntaxNode, in enclosing: SyntaxNode?) -> Access {
        var own: Access = .packagePrivate
        if node.hasModifier("private") { own = .private }
        else if node.hasModifier("public") { own = .public }
        else if node.hasModifier("protected") { own = .protected }
        else if let enclosing, enclosing.type == "interface_declaration" || enclosing.type == "annotation_type_declaration" { own = .public }
        guard let enclosing else { return own }
        return min(own, access(of: enclosing, in: enclosing.parent.flatMap(enclosingType(of:))))
    }

    private static func enclosingType(of node: SyntaxNode) -> SyntaxNode? {
        var current: SyntaxNode? = node
        while let candidate = current {
            if typeNodes.contains(candidate.type) { return candidate }
            current = candidate.parent
        }
        return nil
    }

    private static func isCandidate(_ declaration: Declaration, options: JavaProjectInspectionOptions) -> Bool {
        if declaration.access == .private { return false }
        if options.treatsPublicApiAsUsed, declaration.access >= .protected { return false }
        let node = declaration.node
        if hasEntryPointAnnotation(node) { return false }
        switch declaration.kind {
        case .method:
            if declaration.name.text == "main" || node.hasModifier("abstract") { return false }
            if node.firstNamedChild(ofType: "modifiers")?.text.contains("@Override") == true { return false }
            if declaration.enclosingType?.type == "annotation_type_declaration" { return false }
        case .field:
            if declaration.name.text == "serialVersionUID" { return false }
        case .type:
            if declaration.name.text == "package-info" { return false }
        }
        return true
    }

    private static func hasEntryPointAnnotation(_ node: SyntaxNode) -> Bool {
        guard let modifiers = node.firstNamedChild(ofType: "modifiers") else { return false }
        for annotation in modifiers.namedChildren where annotation.type == "annotation" || annotation.type == "marker_annotation" {
            let name = annotation.child(byFieldName: "name")?.text.split(separator: ".").last.map(String.init) ?? ""
            if !harmlessAnnotations.contains(name) { return true }
        }
        return false
    }

    private static func isReportableAsUnused(_ declaration: Declaration) -> Bool {
        // A type with `main` is run, not referenced.
        if declaration.kind == .type, let body = declaration.node.child(byFieldName: "body") {
            return !body.namedChildren(ofType: "method_declaration").contains { $0.child(byFieldName: "name")?.text == "main" }
        }
        return true
    }

    private static func label(of declaration: Declaration) -> String {
        switch declaration.kind {
        case .type: return declaration.node.type == "interface_declaration" ? "Interface" : "Class"
        case .field: return "Field"
        case .method: return "Method"
        }
    }

    // MARK: Access

    private static func canBePrivate(_ declaration: Declaration, usages: [JavaUsage], in url: URL, tree: JavaSyntaxTree) -> Bool {
        guard declaration.kind != .type || declaration.enclosingType != nil, declaration.access > .private else { return false }
        // Interface members cannot be private in older sources and enum constants are not covered here.
        if declaration.enclosingType?.type == "interface_declaration" || declaration.enclosingType?.type == "annotation_type_declaration" { return false }
        var top = declaration.enclosingType
        while let parent = top?.parent.flatMap(enclosingType(of:)) { top = parent }
        guard let top else { return false }
        let standardized = url.standardizedFileURL
        return usages.allSatisfy { $0.url.standardizedFileURL == standardized && top.byteRange.contains($0.byteRange.lowerBound) }
    }

    // MARK: Calls

    private struct CallSite {
        let call: SyntaxNode
    }

    /// The `method_invocation` for each usage, or nil when a usage is not a plain call (a method reference, say).
    private static func callSites(
        of usages: [JavaUsage], provider: JavaFindUsagesProvider, cache: inout [URL: (text: String, tree: JavaSyntaxTree)]
    ) async -> [CallSite]? {
        var calls: [CallSite] = []
        for usage in usages {
            guard usage.kind == .call else { return nil }
            let file = usage.url.standardizedFileURL
            if cache[file] == nil {
                guard let text = await provider.text(of: file), let tree = JavaSyntaxParser().parse(text) else { return nil }
                cache[file] = (text, tree)
            }
            guard let tree = cache[file]?.tree else { return nil }
            var node: SyntaxNode? = tree.node(inByteRange: usage.byteRange)
            while let current = node, current.type != "method_invocation" {
                if current.byteRange.count > 4096 { return nil }
                node = current.parent
            }
            guard let call = node, call.child(byFieldName: "name")?.startByte == usage.byteRange.lowerBound else { return nil }
            calls.append(CallSite(call: call))
        }
        return calls
    }

    private static func returnsValue(_ method: SyntaxNode) -> Bool {
        guard let type = method.child(byFieldName: "type") else { return false }
        return type.type != "void_type"
    }

    private static func returnsThis(_ method: SyntaxNode) -> Bool {
        var found = false
        method.child(byFieldName: "body")?.forEachDescendant { node in
            if node.type == "return_statement", node.namedChild(at: 0)?.type == "this" { found = true }
        }
        return found
    }

    private static func constantParameters(of declaration: Declaration, calls: [SyntaxNode]) -> [JavaInspection] {
        guard let parameters = declaration.node.child(byFieldName: "parameters") else { return [] }
        let formals = parameters.namedChildren.filter { $0.type == "formal_parameter" || $0.type == "spread_parameter" }
        guard !formals.contains(where: { $0.type == "spread_parameter" }) else { return [] }
        var results: [JavaInspection] = []
        for (index, formal) in formals.enumerated() {
            guard let name = formal.child(byFieldName: "name") else { continue }
            var shared: String?
            var isConstant = true
            for call in calls {
                let arguments = call.child(byFieldName: "arguments")?.namedChildren.filter { !["line_comment", "block_comment"].contains($0.type) } ?? []
                guard arguments.count == formals.count, literalTypes.contains(arguments[index].type) else { isConstant = false; break }
                if let shared, shared != arguments[index].text { isConstant = false; break }
                shared = arguments[index].text
            }
            if isConstant, let shared {
                results.append(JavaInspectionSupport.inspection(
                    .parameterAlwaysSameValue, message: "Parameter '\(name.text)' always receives \(shared)", node: name
                ))
            }
        }
        return results
    }
}
