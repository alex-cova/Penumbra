import EditorIntelligence
import Foundation

public enum JavaStructureKind: String, Sendable {
    case type
    case field
    case method
    case constructor
    case enumConstant
    case recordComponent
}

/// One row in the Structure tool window: a type, field, method, or similar declaration with the
/// byte ranges needed to jump the editor and highlight the caret's enclosing member.
public struct JavaStructureNode: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let kind: JavaStructureKind
    public let nameByteRange: Range<Int>
    public let bodyByteRange: Range<Int>
    public let children: [JavaStructureNode]

    public init(
        id: String,
        title: String,
        kind: JavaStructureKind,
        nameByteRange: Range<Int>,
        bodyByteRange: Range<Int>,
        children: [JavaStructureNode] = []
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.nameByteRange = nameByteRange
        self.bodyByteRange = bodyByteRange
        self.children = children
    }

    /// UTF-16 range of the declaration name, for jumping the editor caret.
    public func nameTextRange(in text: String) -> EditorIntelligence.TextRange {
        JavaNavigationText.textRange(for: nameByteRange, in: text)
    }
}

/// Builds a hierarchical view of the Java type at the caret for the Structure tool window.
public actor JavaStructureProvider {
    private var cachedText: String?
    private var cachedRoots: [JavaStructureNode] = []

    public init() {}

    /// The innermost type declaration at `caretUTF16Offset`, with its members as `children`.
    /// Falls back to the first top-level type when the caret is outside every type body.
    public func structure(for text: String, atUTF16Offset caretUTF16Offset: Int) -> JavaStructureNode? {
        guard let roots = roots(of: text), !roots.isEmpty else { return nil }
        let byteOffset = JavaNavigationText.utf8ByteOffset(forUTF16Offset: caretUTF16Offset, in: text)
        return innermostType(at: byteOffset, in: roots) ?? roots.first
    }

    /// The deepest node whose body contains the caret within `root`.
    public func selectedNode(in root: JavaStructureNode, text: String, atUTF16Offset caretUTF16Offset: Int) -> JavaStructureNode? {
        let byteOffset = JavaNavigationText.utf8ByteOffset(forUTF16Offset: caretUTF16Offset, in: text)
        var best: JavaStructureNode?
        func visit(_ node: JavaStructureNode) {
            guard node.bodyByteRange.contains(byteOffset) || node.bodyByteRange.upperBound == byteOffset else { return }
            best = node
            for child in node.children { visit(child) }
        }
        visit(root)
        return best ?? root
    }

    // MARK: - Parse cache

    private func roots(of text: String) -> [JavaStructureNode]? {
        if cachedText == text { return cachedRoots }
        guard let tree = JavaSyntaxParser().parse(text) else { return nil }
        var roots: [JavaStructureNode] = []
        for node in tree.rootNode.namedChildren where Self.typeDeclarations.contains(node.type) {
            if let built = buildTypeNode(node) {
                roots.append(built)
            }
        }
        cachedText = text
        cachedRoots = roots
        return roots
    }

    private func innermostType(at byteOffset: Int, in roots: [JavaStructureNode]) -> JavaStructureNode? {
        var best: JavaStructureNode?
        func visit(_ node: JavaStructureNode) {
            guard node.kind == .type else { return }
            guard node.bodyByteRange.contains(byteOffset) || node.bodyByteRange.upperBound == byteOffset else { return }
            best = node
            for child in node.children where child.kind == .type {
                visit(child)
            }
        }
        for root in roots { visit(root) }
        return best
    }

    // MARK: - Tree building

    private static let typeDeclarations: Set<String> = [
        "class_declaration", "interface_declaration", "enum_declaration",
        "record_declaration", "annotation_type_declaration"
    ]

    private func buildTypeNode(_ node: SyntaxNode) -> JavaStructureNode? {
        guard let name = node.child(byFieldName: "name") else { return nil }
        let body = node.child(byFieldName: "body")
        var children: [JavaStructureNode] = []

        if node.type == "record_declaration", let parameters = node.child(byFieldName: "parameters") {
            children.append(contentsOf: recordComponents(in: parameters))
        }

        if node.type == "annotation_type_declaration", let body {
            for element in body.namedChildren where element.type == "annotation_type_element_declaration" {
                if let built = buildAnnotationElement(element) {
                    children.append(built)
                }
            }
        }

        if let body {
            for child in body.namedChildren {
                switch child.type {
                case "field_declaration":
                    children.append(contentsOf: fieldNodes(in: child))
                case "method_declaration":
                    if let built = methodNode(in: child, isConstructor: false) { children.append(built) }
                case "constructor_declaration":
                    if let built = methodNode(in: child, isConstructor: true) { children.append(built) }
                case "enum_constant":
                    if let built = enumConstantNode(in: child) { children.append(built) }
                case "enum_body_declarations":
                    children.append(contentsOf: collectBodyMembers(child.namedChildren))
                default:
                    if Self.typeDeclarations.contains(child.type), let built = buildTypeNode(child) {
                        children.append(built)
                    }
                }
            }
        }

        return JavaStructureNode(
            id: nodeID(kind: .type, nameBytes: name.byteRange),
            title: name.text + typeParameters(of: node),
            kind: .type,
            nameByteRange: name.byteRange,
            bodyByteRange: node.byteRange,
            children: children
        )
    }

    private func collectBodyMembers(_ members: [SyntaxNode]) -> [JavaStructureNode] {
        var children: [JavaStructureNode] = []
        for member in members {
            switch member.type {
            case "field_declaration":
                children.append(contentsOf: fieldNodes(in: member))
            case "method_declaration":
                if let built = methodNode(in: member, isConstructor: false) { children.append(built) }
            case "constructor_declaration":
                if let built = methodNode(in: member, isConstructor: true) { children.append(built) }
            default:
                if Self.typeDeclarations.contains(member.type), let built = buildTypeNode(member) {
                    children.append(built)
                }
            }
        }
        return children
    }

    private func recordComponents(in parameters: SyntaxNode) -> [JavaStructureNode] {
        parameters.namedChildren.compactMap { parameter -> JavaStructureNode? in
            guard parameter.type == "formal_parameter",
                  let typeNode = parameter.child(byFieldName: "type"),
                  let nameNode = parameter.child(byFieldName: "name") else { return nil }
            let typeText = JavaBreadcrumbProvider.simpleTypeText(typeNode.text)
            return JavaStructureNode(
                id: nodeID(kind: .recordComponent, nameBytes: nameNode.byteRange),
                title: "\(nameNode.text): \(typeText)",
                kind: .recordComponent,
                nameByteRange: nameNode.byteRange,
                bodyByteRange: parameter.byteRange
            )
        }
    }

    private func fieldNodes(in node: SyntaxNode) -> [JavaStructureNode] {
        guard let typeNode = node.child(byFieldName: "type") else { return [] }
        let typeText = JavaBreadcrumbProvider.simpleTypeText(typeNode.text)
        return node.namedChildren(ofType: "variable_declarator").compactMap { declarator in
            guard let nameNode = declarator.child(byFieldName: "name") else { return nil }
            return JavaStructureNode(
                id: nodeID(kind: .field, nameBytes: nameNode.byteRange),
                title: "\(nameNode.text): \(typeText)",
                kind: .field,
                nameByteRange: nameNode.byteRange,
                bodyByteRange: declarator.byteRange
            )
        }
    }

    private func methodNode(in node: SyntaxNode, isConstructor: Bool) -> JavaStructureNode? {
        guard let name = node.child(byFieldName: "name") else { return nil }
        let kind: JavaStructureKind = isConstructor ? .constructor : .method
        let title = "\(name.text)(\(parameterTypes(of: node)))"
        return JavaStructureNode(
            id: nodeID(kind: kind, nameBytes: name.byteRange),
            title: title,
            kind: kind,
            nameByteRange: name.byteRange,
            bodyByteRange: node.byteRange
        )
    }

    private func enumConstantNode(in node: SyntaxNode) -> JavaStructureNode? {
        guard let name = node.child(byFieldName: "name") else { return nil }
        return JavaStructureNode(
            id: nodeID(kind: .enumConstant, nameBytes: name.byteRange),
            title: name.text,
            kind: .enumConstant,
            nameByteRange: name.byteRange,
            bodyByteRange: node.byteRange
        )
    }

    private func buildAnnotationElement(_ node: SyntaxNode) -> JavaStructureNode? {
        guard let typeNode = node.child(byFieldName: "type"),
              let name = node.child(byFieldName: "name") else { return nil }
        let typeText = JavaBreadcrumbProvider.simpleTypeText(typeNode.text)
        return JavaStructureNode(
            id: nodeID(kind: .method, nameBytes: name.byteRange),
            title: "\(name.text)(): \(typeText)",
            kind: .method,
            nameByteRange: name.byteRange,
            bodyByteRange: node.byteRange
        )
    }

    private func nodeID(kind: JavaStructureKind, nameBytes: Range<Int>) -> String {
        "\(kind.rawValue)-\(nameBytes.lowerBound)"
    }

    private func typeParameters(of node: SyntaxNode) -> String {
        guard let parameters = node.child(byFieldName: "type_parameters") else { return "" }
        let names = parameters.namedChildren(ofType: "type_parameter").compactMap { $0.namedChild(at: 0)?.text }
        return names.isEmpty ? "" : "<\(names.joined(separator: ", "))>"
    }

    private func parameterTypes(of node: SyntaxNode) -> String {
        guard let parameters = node.child(byFieldName: "parameters") else { return "" }
        return parameters.namedChildren.compactMap { parameter -> String? in
            switch parameter.type {
            case "formal_parameter":
                return typeNode(of: parameter).map { JavaBreadcrumbProvider.simpleTypeText($0.text) }
            case "spread_parameter":
                return typeNode(of: parameter).map { JavaBreadcrumbProvider.simpleTypeText($0.text) + "..." }
            default:
                return nil
            }
        }.joined(separator: ", ")
    }

    private func typeNode(of parameter: SyntaxNode) -> SyntaxNode? {
        if let typed = parameter.child(byFieldName: "type") { return typed }
        return parameter.namedChildren.first { child in
            child.type != "modifiers" && child.type != "variable_declarator" && child.type != "identifier"
        }
    }
}
