import EditorIntelligence
import Foundation
import JSONRPC
import LanguageClient
import LanguageServerProtocol

/// Concrete LSP client backed by ChimeHQ's `LanguageClient`.
public actor LanguageServerClient: LSPClient {
    private let server: InitializingServer
    private let documentURI: @Sendable (Document) -> String
    private var uris: [DocumentID: String] = [:]
    /// Diagnostics the server pushed with `textDocument/publishDiagnostics`. An empty push clears the file.
    private var publishedDiagnostics = LSPPublishedDiagnostics()
    private var cachedCapabilities: ServerCapabilities?

    public init(server: InitializingServer, documentURI: @escaping @Sendable (Document) -> String) {
        self.server = server
        self.documentURI = documentURI
        Task { await self.consumeServerEvents() }
    }

    /// A client speaking JSON-RPC over `write` and `read`. The host owns the process; this only
    /// frames messages. `initialize` asks for the workspace folder and leaves position encoding at
    /// the UTF-16 offsets EditorIntelligence already uses.
    public static func make(
        write: @escaping @Sendable (Data) async throws -> Void,
        read: AsyncStream<Data>,
        documentURI: @escaping @Sendable (Document) -> String,
        workspaceRoot: URL? = nil,
        initializationOptions: Data? = nil
    ) -> LanguageServerClient {
        let channel = DataChannel(writeHandler: write, dataSequence: read)
        let connection = JSONRPCServerConnection(dataChannel: channel)
        let server = InitializingServer(server: connection) {
            let folders = workspaceRoot.map {
                [WorkspaceFolder(uri: $0.absoluteString, name: $0.lastPathComponent)]
            }
            return InitializeParams(
                processId: Int(ProcessInfo.processInfo.processIdentifier),
                clientInfo: InitializeParams.ClientInfo(name: "Umbra"),
                locale: nil,
                rootPath: workspaceRoot?.path,
                rootUri: workspaceRoot?.absoluteString,
                initializationOptions: initializationOptions.flatMap { try? JSONDecoder().decode(LSPAny.self, from: $0) },
                capabilities: ClientCapabilities(
                    workspace: nil, textDocument: nil, window: nil, general: nil, experimental: nil
                ),
                trace: nil,
                workspaceFolders: folders
            )
        }
        return LanguageServerClient(server: server, documentURI: documentURI)
    }

    /// Features the server advertised. Runs `initialize` if it has not happened yet.
    public func advertisedFeatures() async -> Set<LanguageFeature> {
        guard let capabilities = await capabilities() else { return [] }
        return LSPServerCapabilities.features(in: capabilities)
    }

    public func requestDiagnostics(for document: Document) async throws -> [EditorIntelligence.LSPDiagnostic] {
        publishedDiagnostics.diagnostics(for: documentURI(document))
    }

    /// The version the server attached to the last push for this document, when it sent one.
    public func publishedDiagnosticsVersion(for document: Document) -> Int? {
        publishedDiagnostics.version(for: documentURI(document))
    }

    public func requestHover(for document: Document, at position: TextPosition) async throws -> EditorIntelligence.LSPHover? {
        guard await allows(.hover) else { return nil }
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
        guard await allows(.completion) else { return [] }
        let params = CompletionParams(
            textDocument: textDocument(for: document),
            position: lspPosition(from: position),
            context: CompletionContext(triggerKind: .invoked, triggerCharacter: nil)
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

    /// `completionItem/resolve`. Returns `item` unchanged when the server did not advertise resolve,
    /// or when the item has no payload to send back.
    public func resolveCompletion(
        _ item: EditorIntelligence.LSPCompletionItem
    ) async throws -> EditorIntelligence.LSPCompletionItem {
        guard let payload = item.resolvePayload,
              let capabilities = await capabilities(),
              LSPServerCapabilities.resolvesCompletionItems(capabilities),
              let original = try? JSONDecoder().decode(LanguageServerProtocol.CompletionItem.self, from: payload)
        else { return item }
        let resolved = try await server.completeItemResolve(original)
        return eipCompletionItem(from: resolved)
    }

    public func requestPrepareCallHierarchy(
        for document: Document, at position: TextPosition
    ) async throws -> [LSPHierarchySymbol] {
        guard await allows(.callHierarchy) else { return [] }
        let params = CallHierarchyPrepareParams(textDocument: textDocument(for: document), position: lspPosition(from: position))
        let items = try await server.prepareCallHierarchy(params) ?? []
        return items.compactMap(LSPHierarchySymbol.init(call:))
    }

    public func requestIncomingCalls(for symbol: LSPHierarchySymbol) async throws -> [LSPHierarchySymbol] {
        guard await allows(.callHierarchy), let item = symbol.callItem else { return [] }
        let calls = try await server.callHierarchyIncomingCalls(CallHierarchyIncomingCallsParams(item: item)) ?? []
        return calls.compactMap { LSPHierarchySymbol(call: $0.from) }
    }

    public func requestOutgoingCalls(for symbol: LSPHierarchySymbol) async throws -> [LSPHierarchySymbol] {
        guard await allows(.callHierarchy), let item = symbol.callItem else { return [] }
        let calls = try await server.callHierarchyOutgoingCalls(CallHierarchyOutgoingCallsParams(item: item)) ?? []
        return calls.compactMap { LSPHierarchySymbol(call: $0.to) }
    }

    public func requestPrepareTypeHierarchy(
        for document: Document, at position: TextPosition
    ) async throws -> [LSPHierarchySymbol] {
        guard await allows(.typeHierarchy) else { return [] }
        let params = TypeHierarchyPrepareParams(textDocument: textDocument(for: document), position: lspPosition(from: position))
        let items = try await server.prepareTypeHeirarchy(params) ?? []
        return items.compactMap(LSPHierarchySymbol.init(type:))
    }

    public func requestSupertypes(of symbol: LSPHierarchySymbol) async throws -> [LSPHierarchySymbol] {
        guard await allows(.typeHierarchy), let item = symbol.typeItem else { return [] }
        let items = try await server.typeHierarchySupertypes(TypeHierarchySupertypesParams(item: item)) ?? []
        return items.compactMap(LSPHierarchySymbol.init(type:))
    }

    public func requestSubtypes(of symbol: LSPHierarchySymbol) async throws -> [LSPHierarchySymbol] {
        guard await allows(.typeHierarchy), let item = symbol.typeItem else { return [] }
        let items = try await server.typeHierarchySubtypes(TypeHierarchySubtypesParams(item: item)) ?? []
        return items.compactMap(LSPHierarchySymbol.init(type:))
    }

    public func requestDefinition(for document: Document, at position: TextPosition) async throws -> [EditorIntelligence.LSPLocation] {
        guard await allows(.definition) else { return [] }
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
        guard await allows(.references) else { return [] }
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
        guard await allows(.implementation) else { return [] }
        let params = TextDocumentPositionParams(
            textDocument: textDocument(for: document),
            position: lspPosition(from: position)
        )
        guard let result = try await server.implementation(params) else {
            return []
        }
        return eipLocations(from: result)
    }

    public func requestTypeDefinition(for document: Document, at position: TextPosition) async throws -> [EditorIntelligence.LSPLocation] {
        guard await allows(.typeDefinition) else { return [] }
        let params = TextDocumentPositionParams(
            textDocument: textDocument(for: document),
            position: lspPosition(from: position)
        )
        guard let result = try await server.typeDefinition(params) else {
            return []
        }
        return eipLocations(from: result)
    }

    public func requestRename(for document: Document, at position: TextPosition, to newName: String) async throws -> EditorIntelligence.LSPWorkspaceEdit? {
        guard await allows(.rename) else { return nil }
        let params = RenameParams(
            textDocument: textDocument(for: document),
            position: lspPosition(from: position),
            newName: newName
        )
        guard let edit = try await server.rename(params) else {
            return nil
        }
        return EditorIntelligence.LSPWorkspaceEdit(changes: LSPWorkspaceEditMapping.changes(from: edit))
    }

    public func requestFormatting(for document: Document, in range: EditorIntelligence.TextRange?) async throws -> [EditorIntelligence.LSPTextEdit] {
        guard await allows(.formatting) else { return [] }
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
        guard await allows(.codeActions) else { return [] }
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
        guard await allows(.signatureHelp) else { return nil }
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
        guard await allows(.semanticTokens) else {
            return EditorIntelligence.LSPSemanticTokens(resultId: nil, data: [])
        }
        let params = SemanticTokensParams(textDocument: textDocument(for: document))
        guard let tokens = try await server.semanticTokensFull(params) else {
            return EditorIntelligence.LSPSemanticTokens(resultId: nil, data: [])
        }
        return EditorIntelligence.LSPSemanticTokens(resultId: tokens.resultId, data: tokens.data)
    }

    public func requestSemanticTokensDelta(for document: Document, previousResultId: String) async throws -> EditorIntelligence.LSPSemanticTokensDelta {
        guard await allows(.semanticTokens) else {
            return EditorIntelligence.LSPSemanticTokensDelta(resultId: nil, data: [])
        }
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

    public func notifySaved(_ document: Document, text: String?) async {
        let uri = uris[document.id] ?? documentURI(document)
        try? await server.textDocumentDidSave(DidSaveTextDocumentParams(uri: uri, text: text))
    }

    public func notifyWatchedFilesChanged(_ events: [(uri: String, kind: LSPWatchedFileChange)]) async {
        let changes = events.map { FileEvent(uri: $0.uri, type: $0.kind.lsp) }
        try? await server.workspaceDidChangeWatchedFiles(DidChangeWatchedFilesParams(changes: changes))
    }

    public func cancelRequest(id: String) async {
        try? await server.sendNotification(.protocolCancelRequest(CancelParams(id: id)))
    }

    public func requestDocumentSymbols(for document: Document) async throws -> [LSPOutlineSymbol] {
        guard await allows(.structure) else { return [] }
        guard let response = try await server.documentSymbol(DocumentSymbolParams(textDocument: textDocument(for: document))) else {
            return []
        }
        switch response {
        case .optionA(let symbols):
            return symbols.map(LSPOutlineSymbol.init)
        case .optionB(let symbols):
            return symbols.map(LSPOutlineSymbol.init)
        }
    }

    public func requestWorkspaceSymbols(matching query: String) async throws -> [LSPOutlineSymbol] {
        guard let capabilities = await capabilities(), LSPServerCapabilities.supportsWorkspaceSymbols(capabilities) else { return [] }
        guard let response = try await server.workspaceSymbol(WorkspaceSymbolParams(query: query)) else {
            return []
        }
        switch response {
        case .optionA(let symbols):
            return symbols.map(LSPOutlineSymbol.init)
        case .optionB(let symbols):
            return symbols.map { LSPOutlineSymbol(workspace: $0) }
        }
    }

    public func requestInlayHints(for document: Document, in range: EditorIntelligence.TextRange) async throws -> [LSPRenderedInlayHint] {
        guard await allows(.inlayHints) else { return [] }
        let hints = try await server.inlayHint(InlayHintParams(
            textDocument: textDocument(for: document),
            range: lspRange(from: range)
        )) ?? []
        return hints.map(LSPRenderedInlayHint.init)
    }

    public func notifyClosed(documentID: DocumentID) async {
        guard let uri = uris.removeValue(forKey: documentID) else {
            return
        }
        try? await server.textDocumentDidClose(LSPDocumentSyncMapper.closeParams(uri: uri))
    }

    private func capabilities() async -> ServerCapabilities? {
        if let cachedCapabilities { return cachedCapabilities }
        guard let response = try? await server.initializeIfNeeded() else { return nil }
        cachedCapabilities = response.capabilities
        return response.capabilities
    }

    private func allows(_ feature: LanguageFeature) async -> Bool {
        guard let capabilities = await capabilities() else { return false }
        return LSPServerCapabilities.supports(feature, capabilities)
    }

    private func textDocument(for document: Document) -> TextDocumentIdentifier {
        TextDocumentIdentifier(uri: DocumentUri(stringLiteral: documentURI(document)))
    }

    private func consumeServerEvents() async {
        for await event in server.eventSequence {
            guard case .notification(.textDocumentPublishDiagnostics(let params)) = event else { continue }
            publishedDiagnostics.apply(params)
        }
    }
}

/// Turns an LSP workspace edit into URI-keyed text edits. `documentChanges` wins when the server
/// sends it (the spec's preferred form, including SourceKit-LSP); otherwise `changes` is used.
public enum LSPWorkspaceEditMapping {
    public static func changes(from edit: LanguageServerProtocol.WorkspaceEdit) -> [String: [EditorIntelligence.LSPTextEdit]] {
        if let documentChanges = edit.documentChanges, !documentChanges.isEmpty {
            var changes: [String: [EditorIntelligence.LSPTextEdit]] = [:]
            for change in documentChanges {
                guard case .textDocumentEdit(let documentEdit) = change else { continue }
                let mapped = documentEdit.edits.map {
                    EditorIntelligence.LSPTextEdit(range: eipRange(from: $0.range), newText: $0.newText)
                }
                changes[documentEdit.textDocument.uri, default: []].append(contentsOf: mapped)
            }
            return changes
        }
        var changes: [String: [EditorIntelligence.LSPTextEdit]] = [:]
        for (uri, edits) in edit.changes ?? [:] {
            changes[uri] = edits.map {
                EditorIntelligence.LSPTextEdit(range: eipRange(from: $0.range), newText: $0.newText)
            }
        }
        return changes
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

func eipRange(from range: LanguageServerProtocol.LSPRange) -> EditorIntelligence.LSPRange {
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
        sortText: item.sortText,
        resolvePayload: try? JSONEncoder().encode(item)
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
        let edits = codeAction.edit.map { LSPWorkspaceEditMapping.changes(from: $0).values.flatMap { $0 } } ?? []
        return EditorIntelligence.LSPCodeAction(
            title: codeAction.title,
            kind: codeAction.kind,
            edits: edits,
            isPreferred: codeAction.isPreferred ?? false
        )
    }
}
