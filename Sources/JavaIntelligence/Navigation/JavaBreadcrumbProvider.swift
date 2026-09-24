import EditorIntelligence
import Foundation

/// Breadcrumbs for Java: the enclosing types and method at the caret, labeled the way a reader
/// would say them (`Box<T>`, `put(String, int)`) rather than by bare name.
///
/// The outline of a file is computed once per distinct text, so moving the caret through an
/// unchanged file only scans a cached list.
public actor JavaBreadcrumbProvider: BreadcrumbProviding {
    private struct Entry {
        let bytes: Range<Int>
        let title: String
        let nameBytes: Range<Int>
    }

    private var cachedText: String?
    private var cachedEntries: [Entry] = []

    public init() {}

    public func breadcrumbs(for document: Document) async -> [BreadcrumbSegment]? {
        guard document.languageIdentifier == "java" else { return nil }
        let text = JavaNavigationText.fullText(of: document)
        guard let entries = outline(of: text) else { return nil }
        let byteOffset = JavaNavigationText.utf8ByteOffset(forUTF16Offset: document.cursor.position.utf16Offset, in: text)
        return entries
            .filter { $0.bytes.contains(byteOffset) || $0.bytes.upperBound == byteOffset }
            .map { BreadcrumbSegment(title: $0.title, range: JavaNavigationText.textRange(for: $0.nameBytes, in: text)) }
    }

    // MARK: - Outline

    private func outline(of text: String) -> [Entry]? {
        if cachedText == text { return cachedEntries }
        guard let tree = JavaSyntaxParser().parse(text) else { return nil }
        var entries: [Entry] = []
        collect(tree.rootNode, into: &entries)
        cachedText = text
        cachedEntries = entries
        return entries
    }

    private static let typeDeclarations: Set<String> = [
        "class_declaration", "interface_declaration", "enum_declaration",
        "record_declaration", "annotation_type_declaration"
    ]

    /// Depth-first, so an enclosing declaration always precedes what it contains.
    private func collect(_ node: SyntaxNode, into entries: inout [Entry]) {
        if let entry = entry(for: node) { entries.append(entry) }
        for child in node.namedChildren { collect(child, into: &entries) }
    }

    private func entry(for node: SyntaxNode) -> Entry? {
        guard let name = node.child(byFieldName: "name") else { return nil }
        if Self.typeDeclarations.contains(node.type) {
            return Entry(bytes: node.byteRange, title: name.text + typeParameters(of: node), nameBytes: name.byteRange)
        }
        if node.type == "method_declaration" || node.type == "constructor_declaration" {
            return Entry(bytes: node.byteRange, title: "\(name.text)(\(parameterTypes(of: node)))", nameBytes: name.byteRange)
        }
        return nil
    }

    /// `<T, U>` from a declaration's type parameters, or `""`.
    private func typeParameters(of node: SyntaxNode) -> String {
        guard let parameters = node.child(byFieldName: "type_parameters") else { return "" }
        let names = parameters.namedChildren(ofType: "type_parameter").compactMap { $0.namedChild(at: 0)?.text }
        return names.isEmpty ? "" : "<\(names.joined(separator: ", "))>"
    }

    /// `String, int, List<String>...` from a method's formal parameters.
    private func parameterTypes(of node: SyntaxNode) -> String {
        guard let parameters = node.child(byFieldName: "parameters") else { return "" }
        return parameters.namedChildren.compactMap { parameter -> String? in
            switch parameter.type {
            case "formal_parameter":
                return typeNode(of: parameter).map { Self.simpleTypeText($0.text) }
            case "spread_parameter":
                return typeNode(of: parameter).map { Self.simpleTypeText($0.text) + "..." }
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

    /// `java.util.List<java.lang.String>` -> `List<String>`, with whitespace collapsed.
    static func simpleTypeText(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.replacingOccurrences(of: #"\b(?:[a-z_][A-Za-z0-9_]*\.)+(?=[A-Z])"#, with: "", options: .regularExpression)
    }
}
