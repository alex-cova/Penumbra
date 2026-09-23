import Foundation
import LanguageClient
import LanguageServerProtocol
import EditorIntelligence

/// Concrete LSP client backed by ChimeHQ's `LanguageClient`.
public actor LanguageServerClient: LSPClient {
    private let server: InitializingServer
    private let documentURI: @Sendable (Document) -> String
    private var uris: [DocumentID: String] = [:]

    public init(server: InitializingServer, documentURI: @escaping @Sendable (Document) -> String) {
        self.server = server
        self.documentURI = documentURI
    }

    public func requestDiagnostics(for document: Document) async throws -> [EditorIntelligence.LSPDiagnostic] {
        // Pull diagnostics are optional in LSP; most servers publish via `textDocument/publishDiagnostics`.
        _ = document
        return []
    }

    public func requestHover(for document: Document, at position: TextPosition) async throws -> EditorIntelligence.LSPHover? {
        let params = TextDocumentPositionParams(
            textDocument: textDocument(for: document),
            position: lspPosition(from: position)
        )
        guard let hover = try await server.hover(params) else {
            return nil
        }
        return EditorIntelligence.LSPHover(
            contents: hoverText(from: hover.contents),
            range: hover.range.map(eipRange(from:))
        )
    }

    public func requestCompletions(for document: Document, at position: TextPosition) async throws -> [EditorIntelligence.LSPCompletionItem] {
        let params = CompletionParams(
            textDocument: textDocument(for: document),
            position: lspPosition(from: position),
            context: nil
        )
        guard let result = try await server.completion(params) else {
            return []
        }
        switch result {
        case .optionA(let items):
            return items.map(eipCompletionItem(from:))
        case .optionB(let list):
            return list.items.map(eipCompletionItem(from:))
        }
    }

    public func requestDefinition(for document: Document, at position: TextPosition) async throws -> [EditorIntelligence.LSPLocation] {
        let params = TextDocumentPositionParams(
            textDocument: textDocument(for: document),
            position: lspPosition(from: position)
        )
        guard let result = try await server.definition(params) else {
            return []
        }
        return eipLocations(from: result)
    }

    public func requestReferences(for document: Document, at position: TextPosition) async throws -> [EditorIntelligence.LSPLocation] {
        let params = ReferenceParams(
            textDocument: textDocument(for: document),
            position: lspPosition(from: position),
            context: ReferenceContext(includeDeclaration: true)
        )
        guard let result = try await server.references(params) else {
            return []
        }
        return result.map { EditorIntelligence.LSPLocation(uri: $0.uri, range: eipRange(from: $0.range)) }
    }

    public func requestImplementation(for document: Document, at position: TextPosition) async throws -> [EditorIntelligence.LSPLocation] {
        let params = TextDocumentPositionParams(
            textDocument: textDocument(for: document),
            position: lspPosition(from: position)
        )
        guard let result = try await server.implementation(params) else {
            return []
        }
        return eipLocations(from: result)
    }

    public func requestRename(for document: Document, at position: TextPosition, to newName: String) async throws -> EditorIntelligence.LSPWorkspaceEdit? {
        let params = RenameParams(
            textDocument: textDocument(for: document),
            position: lspPosition(from: position),
            newName: newName
        )
        guard let edit = try await server.rename(params) else {
            return nil
        }
        var changes: [String: [EditorIntelligence.LSPTextEdit]] = [:]
        if let documentChanges = edit.changes {
            for (uri, edits) in documentChanges {
                changes[uri] = edits.map {
                    EditorIntelligence.LSPTextEdit(range: eipRange(from: $0.range), newText: $0.newText)
                }
            }
        }
        return EditorIntelligence.LSPWorkspaceEdit(changes: changes)
    }

    public func requestFormatting(for document: Document, in range: EditorIntelligence.TextRange?) async throws -> [EditorIntelligence.LSPTextEdit] {
        let options = FormattingOptions(tabSize: 4, insertSpaces: true)
        if let range {
            let params = DocumentRangeFormattingParams(
                textDocument: textDocument(for: document),
                range: lspRange(from: range),
                options: options
            )
            guard let edits = try await server.rangeFormatting(params) else {
                return []
            }
            return edits.map { EditorIntelligence.LSPTextEdit(range: eipRange(from: $0.range), newText: $0.newText) }
        }
        let params = DocumentFormattingParams(
            textDocument: textDocument(for: document),
            options: options
        )
        guard let edits = try await server.formatting(params) else {
            return []
        }
        return edits.map { EditorIntelligence.LSPTextEdit(range: eipRange(from: $0.range), newText: $0.newText) }
    }

    public func requestCodeActions(
        for document: Document,
        at position: TextPosition,
        diagnostics: [EditorIntelligence.LSPDiagnostic]
    ) async throws -> [EditorIntelligence.LSPCodeAction] {
        let params = CodeActionParams(
            textDocument: textDocument(for: document),
            range: LSPRange(
                start: lspPosition(from: position),
                end: lspPosition(from: position)
            ),
            context: CodeActionContext(
                diagnostics: diagnostics.map(lspDiagnostic(from:)),
                only: nil,
                triggerKind: CodeActionTriggerKind.invoked
            )
        )
        guard let response = try await server.codeAction(params) else {
            return []
        }
        return response.compactMap(eipCodeAction(from:))
    }

    public func requestSignatureHelp(for document: Document, at position: TextPosition) async throws -> EditorIntelligence.LSPSignatureHelp? {
        let params = TextDocumentPositionParams(
            textDocument: textDocument(for: document),
            position: lspPosition(from: position)
        )
        guard let help = try await server.signatureHelp(params) else {
            return nil
        }
        return EditorIntelligence.LSPSignatureHelp(
            signatures: help.signatures.map { $0.label },
            activeSignature: help.activeSignature ?? 0,
            activeParameter: help.activeParameter ?? 0
        )
    }

    public func requestSemanticTokens(for document: Document) async throws -> EditorIntelligence.LSPSemanticTokens {
        let params = SemanticTokensParams(textDocument: textDocument(for: document))
        guard let tokens = try await server.semanticTokensFull(params) else {
            return EditorIntelligence.LSPSemanticTokens(resultId: nil, data: [])
        }
        return EditorIntelligence.LSPSemanticTokens(resultId: tokens.resultId, data: tokens.data)
    }

    public func requestSemanticTokensDelta(for document: Document, previousResultId: String) async throws -> EditorIntelligence.LSPSemanticTokensDelta {
        let params = SemanticTokensDeltaParams(
            textDocument: textDocument(for: document),
            previousResultId: previousResultId
        )
        guard let response = try await server.semanticTokensFullDelta(params) else {
            return EditorIntelligence.LSPSemanticTokensDelta(resultId: nil, data: [])
        }
        switch response {
        case .optionA(let tokens):
            return EditorIntelligence.LSPSemanticTokensDelta(resultId: tokens.resultId, data: tokens.data)
        case .optionB(let delta):
            let edits = delta.edits.map { edit in
                EditorIntelligence.LSPSemanticTokensEdit(
                    start: Int(edit.start),
                    deleteCount: Int(edit.deleteCount),
                    data: edit.data ?? []
                )
            }
            return EditorIntelligence.LSPSemanticTokensDelta(resultId: delta.resultId, data: [], edits: edits)
        }
    }

    // MARK: - Document sync

    /// Handlers that send `textDocument/didOpen` / `didChange` / `didClose` for this client.
    public func syncHandlers() -> LSPDocumentSyncHandlers {
        LSPDocumentSyncHandlers(
            onIncrementalChanges: { changes in
                await self.notifyIncrementalChanges(changes)
            },
            onOpen: { document, languageID, version in
                await self.notifyOpened(document, languageID: languageID, version: version)
            },
            onFullChange: { document, version in
                await self.notifyFullChange(document, version: version)
            },
            onClose: { documentID in
                await self.notifyClosed(documentID: documentID)
            }
        )
    }

    public func notifyOpened(_ document: Document, languageID: String, version: Int) async {
        let uri = documentURI(document)
        uris[document.id] = uri
        let snapshot = document.contentSnapshot
        let text = snapshot.substring(utf16Offset: 0, length: snapshot.utf16Length)
        let params = LSPDocumentSyncMapper.openParams(
            uri: uri,
            languageID: languageID,
            version: version,
            text: text
        )
        try? await server.textDocumentDidOpen(params)
    }

    public func notifyIncrementalChanges(_ changes: [LSPDocumentSyncService.DocumentChange]) async {
        let grouped = Dictionary(grouping: changes, by: \.documentID)
        for (documentID, batch) in grouped {
            guard let uri = uris[documentID] else {
                continue
            }
            let params = LSPDocumentSyncMapper.incrementalParams(uri: uri, changes: batch)
            try? await server.textDocumentDidChange(params)
        }
    }

    public func notifyFullChange(_ document: Document, version: Int) async {
        let uri = uris[document.id] ?? documentURI(document)
        uris[document.id] = uri
        let snapshot = document.contentSnapshot
        let text = snapshot.substring(utf16Offset: 0, length: snapshot.utf16Length)
        let params = LSPDocumentSyncMapper.fullChangeParams(uri: uri, version: version, text: text)
        try? await server.textDocumentDidChange(params)
    }

    public func notifyClosed(documentID: DocumentID) async {
        guard let uri = uris.removeValue(forKey: documentID) else {
            return
        }
        try? await server.textDocumentDidClose(LSPDocumentSyncMapper.closeParams(uri: uri))
    }

    private func textDocument(for document: Document) -> TextDocumentIdentifier {
        TextDocumentIdentifier(uri: DocumentUri(stringLiteral: documentURI(document)))
    }
}

// MARK: - Conversions

private func lspPosition(from position: TextPosition) -> LanguageServerProtocol.Position {
    LanguageServerProtocol.Position(line: position.line, character: position.column)
}

private func lspRange(from range: EditorIntelligence.TextRange) -> LanguageServerProtocol.LSPRange {
    LanguageServerProtocol.LSPRange(
        start: lspPosition(from: range.start),
        end: lspPosition(from: range.end)
    )
}

private func eipRange(from range: LanguageServerProtocol.LSPRange) -> EditorIntelligence.LSPRange {
    EditorIntelligence.LSPRange(
        start: EditorIntelligence.LSPPosition(line: range.start.line, character: range.start.character),
        end: EditorIntelligence.LSPPosition(line: range.end.line, character: range.end.character)
    )
}

private func eipDiagnostic(from diagnostic: LanguageServerProtocol.Diagnostic) -> EditorIntelligence.LSPDiagnostic {
    EditorIntelligence.LSPDiagnostic(
        range: eipRange(from: diagnostic.range),
        severity: diagnostic.severity?.rawValue,
        message: diagnostic.message,
        code: diagnosticCodeString(diagnostic.code),
        source: diagnostic.source
    )
}

private func eipCompletionItem(from item: LanguageServerProtocol.CompletionItem) -> EditorIntelligence.LSPCompletionItem {
    EditorIntelligence.LSPCompletionItem(
        label: item.label,
        insertText: item.insertText,
        kind: item.kind?.rawValue,
        documentation: completionDocumentation(item.documentation),
        detail: item.detail,
        isSnippet: item.insertTextFormat == .snippet,
        deprecated: item.deprecated ?? false,
        additionalTextEdits: (item.additionalTextEdits ?? []).map {
            EditorIntelligence.LSPTextEdit(range: eipRange(from: $0.range), newText: $0.newText)
        },
        filterText: item.filterText,
        sortText: item.sortText
    )
}

private func eipLocations(from result: DefinitionResponse) -> [EditorIntelligence.LSPLocation] {
    guard let result else {
        return []
    }
    switch result {
    case .optionA(let location):
        return [EditorIntelligence.LSPLocation(uri: location.uri, range: eipRange(from: location.range))]
    case .optionB(let locations):
        return locations.map { EditorIntelligence.LSPLocation(uri: $0.uri, range: eipRange(from: $0.range)) }
    case .optionC(let links):
        return links.map { EditorIntelligence.LSPLocation(uri: $0.targetUri, range: eipRange(from: $0.targetRange)) }
    }
}

private func hoverText(from contents: ThreeTypeOption<MarkedString, [MarkedString], MarkupContent>) -> String {
    switch contents {
    case .optionA(let marked):
        return marked.value
    case .optionB(let strings):
        return strings.map(\.value).joined(separator: "\n")
    case .optionC(let markup):
        return markup.value
    }
}

private func markedStringText(_ marked: MarkedString) -> String {
    marked.value
}

private func completionDocumentation(_ documentation: TwoTypeOption<String, MarkupContent>?) -> String? {
    guard let documentation else {
        return nil
    }
    switch documentation {
    case .optionA(let string):
        return string
    case .optionB(let content):
        return content.value
    }
}

private func diagnosticCodeString(_ code: DiagnosticCode?) -> String? {
    guard let code else {
        return nil
    }
    switch code {
    case .optionA(let intValue):
        return String(intValue)
    case .optionB(let stringValue):
        return stringValue
    }
}

private func lspDiagnostic(from diagnostic: EditorIntelligence.LSPDiagnostic) -> LanguageServerProtocol.Diagnostic {
    LanguageServerProtocol.Diagnostic(
        range: LanguageServerProtocol.LSPRange(
            start: LanguageServerProtocol.Position(line: diagnostic.range.start.line, character: diagnostic.range.start.character),
            end: LanguageServerProtocol.Position(line: diagnostic.range.end.line, character: diagnostic.range.end.character)
        ),
        severity: diagnostic.severity.map { LanguageServerProtocol.DiagnosticSeverity(rawValue: $0) ?? .hint },
        code: diagnostic.code.map { .optionB($0) },
        source: diagnostic.source,
        message: diagnostic.message
    )
}

private func eipCodeAction(from action: TwoTypeOption<Command, LanguageServerProtocol.CodeAction>) -> EditorIntelligence.LSPCodeAction? {
    switch action {
    case .optionA(let command):
        return EditorIntelligence.LSPCodeAction(
            title: command.title,
            kind: command.command,
            edits: [],
            isPreferred: false
        )
    case .optionB(let codeAction):
        let edits: [EditorIntelligence.LSPTextEdit]
        if let workspaceEdit = codeAction.edit, let changes = workspaceEdit.changes {
            edits = changes.values.flatMap { $0 }.map {
                EditorIntelligence.LSPTextEdit(range: eipRange(from: $0.range), newText: $0.newText)
            }
        } else {
            edits = []
        }
        return EditorIntelligence.LSPCodeAction(
            title: codeAction.title,
            kind: codeAction.kind,
            edits: edits,
            isPreferred: codeAction.isPreferred ?? false
        )
    }
}
