import Foundation
import TreeSitter
import EditorIntelligence

/// Syntax tree produced by the Tree-sitter language parser.
struct TreeSitterSyntaxTree: EditorIntelligence.SyntaxTree {
    let symbols: [EditorIntelligence.Symbol]
    let words: [String]
    let imports: [String]

    init(
        tree: TreeSitterTree?,
        documentID: EditorIntelligence.DocumentID,
        text: String,
        languageConfiguration: LanguageConfiguration? = nil
    ) {
        self.symbols = Self.extractSymbols(
            tree: tree,
            documentID: documentID,
            text: text,
            languageConfiguration: languageConfiguration
        )
        self.words = Self.extractWords(from: text)
        self.imports = Self.extractImports(tree: tree, text: text)
    }

    // MARK: - Symbol extraction

    private static func extractSymbols(
        tree: TreeSitterTree?,
        documentID: EditorIntelligence.DocumentID,
        text: String,
        languageConfiguration: LanguageConfiguration?
    ) -> [EditorIntelligence.Symbol] {
        guard let root = tree?.rootNode else { return [] }
        var symbols: [EditorIntelligence.Symbol] = []
        // Bare identifier / reference symbols (go-to-definition, find-references, completion) and,
        // when no language configuration is available, the legacy hardcoded declaration cases.
        walk(
            node: root,
            into: &symbols,
            documentID: documentID,
            text: text,
            emitLegacyDeclarations: languageConfiguration == nil
        )
        // Rich declaration symbols carrying a `containerRange` (breadcrumbs, outline).
        if let languageConfiguration {
            appendDeclarationSymbols(
                root: root,
                configuration: languageConfiguration,
                documentID: documentID,
                text: text,
                into: &symbols
            )
        }
        return symbols
    }

    private static func walk(
        node: TreeSitterNode,
        into symbols: inout [EditorIntelligence.Symbol],
        documentID: EditorIntelligence.DocumentID,
        text: String,
        emitLegacyDeclarations: Bool
    ) {
        if let type = node.type {
            switch type {
            case "identifier":
                let name = textForNode(node, in: text)
                let range = makeRange(node)
                symbols.append(EditorIntelligence.Symbol(name: name, kind: .variable, documentID: documentID, range: range))
            case "property_identifier":
                let name = textForNode(node, in: text)
                let range = makeRange(node)
                symbols.append(EditorIntelligence.Symbol(name: name, kind: .property, documentID: documentID, range: range))
            case "type_identifier":
                let name = textForNode(node, in: text)
                let range = makeRange(node)
                symbols.append(EditorIntelligence.Symbol(name: name, kind: .type, documentID: documentID, range: range))
            case "function_declaration", "method_definition":
                if emitLegacyDeclarations, let nameNode = findChildIdentifier(in: node) {
                    let name = textForNode(nameNode, in: text)
                    let range = makeRange(nameNode)
                    symbols.append(EditorIntelligence.Symbol(name: name, kind: .function, documentID: documentID, range: range))
                }
            case "class_declaration":
                if emitLegacyDeclarations, let nameNode = findChildIdentifier(in: node) {
                    let name = textForNode(nameNode, in: text)
                    let range = makeRange(nameNode)
                    symbols.append(EditorIntelligence.Symbol(name: name, kind: .type, documentID: documentID, range: range))
                }
            default:
                break
            }
        }
        for index in 0 ..< node.childCount {
            if let child = node.child(at: index) {
                walk(
                    node: child,
                    into: &symbols,
                    documentID: documentID,
                    text: text,
                    emitLegacyDeclarations: emitLegacyDeclarations
                )
            }
        }
    }

    private static func appendDeclarationSymbols(
        root: TreeSitterNode,
        configuration: LanguageConfiguration,
        documentID: EditorIntelligence.DocumentID,
        text: String,
        into symbols: inout [EditorIntelligence.Symbol]
    ) {
        let declarations = DeclarationScanner.scan(
            root: root,
            configuration: configuration,
            text: text as NSString
        )
        for declaration in declarations {
            let containerRange = makeRange(declaration.container)
            let nameRange = declaration.name.isEmpty ? containerRange : makeRange(declaration.name_span)
            let displayName = declaration.name.isEmpty ? "\(declaration.kind)" : declaration.name
            symbols.append(EditorIntelligence.Symbol(
                name: displayName,
                kind: symbolKind(for: declaration.kind),
                documentID: documentID,
                range: nameRange,
                containerRange: containerRange
            ))
        }
    }

    private static func symbolKind(for kind: DeclarationKind) -> EditorIntelligence.SymbolKind {
        switch kind {
        case .type, .namespace:
            return .type
        case .function:
            return .function
        case .property:
            return .property
        }
    }

    private static func findChildIdentifier(in node: TreeSitterNode) -> TreeSitterNode? {
        for index in 0 ..< node.childCount {
            if let child = node.child(at: index), let type = child.type, type == "identifier" {
                return child
            }
        }
        return nil
    }

    private static func textForNode(_ node: TreeSitterNode, in text: String) -> String {
        let start = node.startByte.utf16Length
        let end = node.endByte.utf16Length
        let range = NSRange(location: start, length: end - start)
        return (text as NSString).substring(with: range)
    }

    private static func makeRange(_ node: TreeSitterNode) -> EditorIntelligence.TextRange {
        let start = EditorIntelligence.TextPosition(
            line: Int(node.startPoint.row),
            column: Int(node.startPoint.column) / 2,
            utf16Offset: node.startByte.utf16Length
        )
        let end = EditorIntelligence.TextPosition(
            line: Int(node.endPoint.row),
            column: Int(node.endPoint.column) / 2,
            utf16Offset: node.endByte.utf16Length
        )
        return EditorIntelligence.TextRange(start: start, end: end)
    }

    private static func makeRange(_ span: DeclarationSpan) -> EditorIntelligence.TextRange {
        let start = EditorIntelligence.TextPosition(
            line: span.startRow,
            column: span.startColumn,
            utf16Offset: span.startUTF16
        )
        let end = EditorIntelligence.TextPosition(
            line: span.endRow,
            column: span.endColumn,
            utf16Offset: span.endUTF16
        )
        return EditorIntelligence.TextRange(start: start, end: end)
    }

    // MARK: - Word extraction

    private static func extractWords(from text: String) -> [String] {
        let separators = CharacterSet.alphanumerics.inverted
        return Set(text.components(separatedBy: separators).filter { !$0.isEmpty }).sorted()
    }

    // MARK: - Import extraction

    private static func extractImports(tree: TreeSitterTree?, text: String) -> [String] {
        guard let root = tree?.rootNode else { return [] }
        var imports: [String] = []
        walkImports(node: root, into: &imports, text: text)
        return imports
    }

    private static func walkImports(node: TreeSitterNode, into imports: inout [String], text: String) {
        if let type = node.type, type == "import_statement" {
            for index in 0 ..< node.childCount {
                if let child = node.child(at: index), let childType = child.type, childType == "string" {
                    var source = textForNode(child, in: text)
                    if source.count >= 2 {
                        source = String(source.dropFirst().dropLast())
                    }
                    imports.append(source)
                }
            }
        }
        for index in 0 ..< node.childCount {
            if let child = node.child(at: index) {
                walkImports(node: child, into: &imports, text: text)
            }
        }
    }
}
