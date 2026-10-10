import EditorIntelligence
import Foundation

func lspClient(
    _ connections: any LSPConnectionProviding,
    feature: LanguageFeature,
    languages: Set<String>,
    documentLanguage: String?
) -> (any LSPClient)? {
    guard languages.contains(documentLanguage ?? ""), let client = connections.current else { return nil }
    if let supported = connections.supportedFeatures, !supported.contains(feature) { return nil }
    return client
}

struct LSPReadySignatureHelp: SignatureHelpProviding {
    let languages: Set<String>
    let connections: any LSPConnectionProviding

    func signatureHelp(for document: Document, at position: TextPosition) async -> ParameterHintsModel? {
        guard let client = lspClient(connections, feature: .signatureHelp, languages: languages, documentLanguage: document.languageIdentifier) else {
            return nil
        }
        return await LSPSignatureHelpProvider(client: client).signatureHelp(for: document, at: position)
    }
}

struct LSPReadyCodeActions: CodeActionProviding {
    let languages: Set<String>
    let connections: any LSPConnectionProviding

    func codeActions(for document: Document, at position: TextPosition, diagnostics: [Diagnostic]) async -> [CodeAction] {
        guard let client = lspClient(connections, feature: .codeActions, languages: languages, documentLanguage: document.languageIdentifier) else {
            return []
        }
        return await LSPCodeActionProvider(client: client).codeActions(for: document, at: position, diagnostics: diagnostics)
    }
}

struct LSPReadyRename: RenameProviding {
    let languages: Set<String>
    let connections: any LSPConnectionProviding

    func prepareRename(_ context: NavigationContext) async -> RenameTarget? {
        guard lspClient(connections, feature: .rename, languages: languages, documentLanguage: context.document.languageIdentifier) != nil,
              let hit = identifier(in: context.document, at: context.cursor.position) else { return nil }
        return RenameTarget(range: hit.range, currentName: hit.name)
    }

    func rename(_ context: NavigationContext, to newName: String) async throws -> RenamePlan {
        guard let client = lspClient(connections, feature: .rename, languages: languages, documentLanguage: context.document.languageIdentifier) else {
            return RenamePlan(blockingError: "Rename is not available.", title: "Rename")
        }
        guard let edit = try await client.requestRename(for: context.document, at: context.cursor.position, to: newName) else {
            return RenamePlan(blockingError: "Nothing to rename.", title: "Rename")
        }
        var entries: [WorkspaceEditPlanEntry] = []
        for (uri, changes) in edit.changes {
            guard let url = URL(string: uri) else { continue }
            for change in changes {
                entries.append(WorkspaceEditPlanEntry(
                    url: url, range: textRange(from: change.range), oldText: "", newText: change.newText,
                    lineText: change.newText, description: "rename"
                ))
            }
        }
        return RenamePlan(entries: entries, title: "Rename")
    }
}

struct LSPReadySemanticTokens: SemanticTokenProviding {
    let languages: Set<String>
    let connections: any LSPConnectionProviding

    func semanticHighlights(forSource source: String) async -> [SemanticHighlight]? {
        let language = languages.sorted().first
        guard let client = lspClient(connections, feature: .semanticTokens, languages: languages, documentLanguage: language) else {
            return nil
        }
        let document = lspDocument(source: source, url: nil, language: language, utf16Offset: 0)
        guard let tokens = try? await client.requestSemanticTokens(for: document) else { return nil }
        return LSPSemanticTokenDecoder.decode(tokens.data).compactMap { token in
            guard let start = utf16Offset(line: token.line, character: token.character, in: source) else { return nil }
            let end = start + token.length
            return SemanticHighlight(range: start..<end, highlightName: lspHighlightName(typeIndex: token.typeIndex))
        }
    }
}

struct LSPReadyInlayHints: InlayHintProviding {
    let languages: Set<String>
    let connections: any LSPConnectionProviding

    func inlayHints(for document: Document, in range: EditorIntelligence.TextRange) async -> [InlayHint] {
        guard let client = lspClient(connections, feature: .inlayHints, languages: languages, documentLanguage: document.languageIdentifier) as? LanguageServerClient else {
            return []
        }
        let hints = (try? await client.requestInlayHints(for: document, in: range)) ?? []
        let source = documentText(document)
        return hints.compactMap { hint in
            guard let offset = utf16Offset(line: hint.line, character: hint.character, in: source),
                  offset >= range.start.utf16Offset, offset <= range.end.utf16Offset else { return nil }
            let kind: InlayHint.Kind = hint.kind == "type" ? .type : (hint.kind == "parameter" ? .parameter : .other)
            return InlayHint(utf16Offset: offset, label: hint.label, kind: kind)
        }
    }
}

struct LSPReadyCallHierarchy: CallHierarchyProviding {
    let languages: Set<String>
    let connections: any LSPConnectionProviding

    func rootItem(source: String, fileURL: URL?, utf16Offset: Int) async -> HierarchyItem? {
        guard let client = server(sourceLanguage: languages.sorted().first, feature: .callHierarchy) else { return nil }
        let document = lspDocument(source: source, url: fileURL, language: languages.sorted().first, utf16Offset: utf16Offset)
        let symbols = (try? await client.requestPrepareCallHierarchy(for: document, at: document.cursor.position)) ?? []
        return symbols.first.map { hierarchyItem(from: $0, parentID: "call") }
    }

    func callers(of item: HierarchyItem, file: URL?) async -> [HierarchyItem] {
        guard let client = server(sourceLanguage: languages.sorted().first, feature: .callHierarchy),
              let symbol = item.payload as? LSPHierarchySymbol else { return [] }
        let calls = (try? await client.requestIncomingCalls(for: symbol)) ?? []
        return calls.map { hierarchyItem(from: $0, parentID: item.id) }
    }

    func callees(of item: HierarchyItem, file: URL?) async -> [HierarchyItem] {
        guard let client = server(sourceLanguage: languages.sorted().first, feature: .callHierarchy),
              let symbol = item.payload as? LSPHierarchySymbol else { return [] }
        let calls = (try? await client.requestOutgoingCalls(for: symbol)) ?? []
        return calls.map { hierarchyItem(from: $0, parentID: item.id) }
    }

    func location(of item: HierarchyItem, file: URL?) async -> HierarchyLocation? {
        hierarchyLocation(of: item, file: file)
    }

    private func server(sourceLanguage: String?, feature: LanguageFeature) -> LanguageServerClient? {
        lspClient(connections, feature: feature, languages: languages, documentLanguage: sourceLanguage) as? LanguageServerClient
    }
}

struct LSPReadyTypeHierarchy: TypeHierarchyProviding {
    let languages: Set<String>
    let connections: any LSPConnectionProviding

    func rootItem(source: String, fileURL: URL?, utf16Offset: Int) async -> HierarchyItem? {
        guard let client = server(feature: .typeHierarchy) else { return nil }
        let document = lspDocument(source: source, url: fileURL, language: languages.sorted().first, utf16Offset: utf16Offset)
        let symbols = (try? await client.requestPrepareTypeHierarchy(for: document, at: document.cursor.position)) ?? []
        return symbols.first.map { hierarchyItem(from: $0, parentID: "type") }
    }

    func supertypes(of item: HierarchyItem, file: URL?) async -> [HierarchyItem] {
        guard let client = server(feature: .typeHierarchy), let symbol = item.payload as? LSPHierarchySymbol else { return [] }
        let items = (try? await client.requestSupertypes(of: symbol)) ?? []
        return items.map { hierarchyItem(from: $0, parentID: item.id) }
    }

    func subtypes(of item: HierarchyItem, file: URL?) async -> [HierarchyItem] {
        guard let client = server(feature: .typeHierarchy), let symbol = item.payload as? LSPHierarchySymbol else { return [] }
        let items = (try? await client.requestSubtypes(of: symbol)) ?? []
        return items.map { hierarchyItem(from: $0, parentID: item.id) }
    }

    func location(of item: HierarchyItem, file: URL?) async -> HierarchyLocation? {
        hierarchyLocation(of: item, file: file)
    }

    private func server(feature: LanguageFeature) -> LanguageServerClient? {
        lspClient(connections, feature: feature, languages: languages, documentLanguage: languages.sorted().first) as? LanguageServerClient
    }
}

private func hierarchyItem(from symbol: LSPHierarchySymbol, parentID: String) -> HierarchyItem {
    let kind: HierarchyItemKind = symbol.kind == .call ? .method : hierarchyKind(symbol.symbolKind)
    return HierarchyItem(
        id: parentID + "/" + symbol.uri + "/" + symbol.name,
        name: symbol.name,
        detail: symbol.detail ?? "",
        kind: kind,
        origin: .project,
        payload: symbol
    )
}

private func hierarchyKind(_ symbolKind: Int) -> HierarchyItemKind {
    switch symbolKind {
    case 11: return .interfaceType
    case 10: return .enumType
    case 6, 9, 12: return .method
    default: return .classType
    }
}

private func hierarchyLocation(of item: HierarchyItem, file: URL?) -> HierarchyLocation? {
    guard let symbol = item.payload as? LSPHierarchySymbol else { return nil }
    if let call = symbol.callItem {
        return HierarchyLocation(url: URL(string: call.uri) ?? file, range: textRange(from: eipRange(from: call.range)))
    }
    if let type = symbol.typeItem {
        return HierarchyLocation(url: URL(string: type.uri) ?? file, range: textRange(from: eipRange(from: type.range)))
    }
    let empty = EditorIntelligence.LSPRange(
        start: EditorIntelligence.LSPPosition(line: 0, character: 0),
        end: EditorIntelligence.LSPPosition(line: 0, character: 0)
    )
    return HierarchyLocation(url: URL(string: symbol.uri) ?? file, range: textRange(from: empty))
}

private func identifier(in document: Document, at position: TextPosition) -> (range: EditorIntelligence.TextRange, name: String)? {
    let text = documentText(document) as NSString
    let offset = min(max(0, position.utf16Offset), text.length)
    var start = offset
    if start < text.length, !isIdentifierUnit(text.character(at: start)), start > 0, isIdentifierUnit(text.character(at: start - 1)) {
        start -= 1
    }
    while start > 0, isIdentifierUnit(text.character(at: start - 1)) { start -= 1 }
    var end = start
    while end < text.length, isIdentifierUnit(text.character(at: end)) { end += 1 }
    guard end > start else { return nil }
    let name = text.substring(with: NSRange(location: start, length: end - start))
    let rangeStart = TextPosition(line: position.line, column: 0, utf16Offset: start)
    let rangeEnd = TextPosition(line: position.line, column: 0, utf16Offset: end)
    return (EditorIntelligence.TextRange(start: rangeStart, end: rangeEnd), name)
}

private func isIdentifierUnit(_ unit: unichar) -> Bool {
    guard let scalar = Unicode.Scalar(unit) else { return false }
    return CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "$"
}

private func documentText(_ document: Document) -> String {
    let snapshot = document.contentSnapshot
    return snapshot.substring(utf16Offset: 0, length: snapshot.utf16Length)
}

func lspDocument(source: String, url: URL?, language: String?, utf16Offset: Int) -> Document {
    let position = textPosition(utf16Offset: utf16Offset, in: source)
    return Document(
        url: url, displayName: url?.lastPathComponent ?? "untitled",
        contentSnapshot: TextSnapshot(version: 1, text: source),
        selection: Selection(range: TextRange(start: position, end: position)),
        cursor: Cursor(position: position),
        viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
        languageIdentifier: language
    )
}

private func textPosition(utf16Offset: Int, in source: String) -> TextPosition {
    let text = source as NSString
    let offset = min(max(0, utf16Offset), text.length)
    var line = 0
    var lineStart = 0
    var index = 0
    while index < offset {
        let unit = text.character(at: index)
        index += 1
        if unit == 10 {
            line += 1
            lineStart = index
        } else if unit == 13 {
            if index < text.length, text.character(at: index) == 10 { index += 1 }
            line += 1
            lineStart = index
        }
    }
    return TextPosition(line: line, column: offset - lineStart, utf16Offset: offset)
}

func utf16Offset(line: Int, character: Int, in source: String) -> Int? {
    let text = source as NSString
    var current = 0
    var index = 0
    while current < line && index < text.length {
        let unit = text.character(at: index)
        index += 1
        if unit == 10 { current += 1 }
        else if unit == 13 {
            if index < text.length, text.character(at: index) == 10 { index += 1 }
            current += 1
        }
    }
    guard current == line else { return nil }
    let offset = index + character
    guard offset <= text.length else { return nil }
    return offset
}

private func lspHighlightName(typeIndex: Int) -> String {
    let names = [
        "namespace", "type", "class", "enum", "interface", "struct", "typeParameter",
        "parameter", "variable", "property", "enumMember", "event", "function", "method",
        "macro", "keyword", "modifier", "comment", "string", "number", "regexp", "operator"
    ]
    let raw = names.indices.contains(typeIndex) ? names[typeIndex] : "variable"
    switch raw {
    case "class", "struct", "enum", "interface", "type", "typeParameter": return "type"
    case "function", "method", "macro": return "function"
    case "property", "enumMember": return "property"
    case "keyword", "modifier": return "keyword"
    case "comment": return "comment"
    case "string": return "string"
    case "number": return "number"
    default: return "variable"
    }
}
