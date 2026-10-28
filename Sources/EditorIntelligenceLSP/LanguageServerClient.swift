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
    /// Server work that reports progress, such as background indexing.
    private var workProgress = LSPWorkProgressTracker()
    /// The edits a command sent back through `workspace/applyEdit`, while one is being run; nil otherwise.
    private var applyEditSink: [LanguageServerProtocol.WorkspaceEdit]?
    /// What the server holds of each document this client opened: the version last sent and its UTF-16
    /// length. The client owns the version numbers, so the events that sync a document and the requests
    /// that find it stale cannot send the same one twice.
    private var sent: [DocumentID: SentDocument] = [:]

    private struct SentDocument {
        var version: Int
        var utf16Length: Int
    }
    private let onProgress: (@Sendable ([LSPWorkProgress]) -> Void)?

    /// `onProgress` receives the work running now each time it changes, from this client's event
    /// loop. It is called with an empty list when the last piece ends.
    public init(
        server: InitializingServer,
        documentURI: @escaping @Sendable (Document) -> String,
        onProgress: (@Sendable ([LSPWorkProgress]) -> Void)? = nil
    ) {
        self.server = server
        self.documentURI = documentURI
        self.onProgress = onProgress
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
        initializationOptions: Data? = nil,
        onProgress: (@Sendable ([LSPWorkProgress]) -> Void)? = nil
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
                    // `applyEdit`: SourceKit-LSP hands a refactoring over as a command and sends its edit back as a
                    // `workspace/applyEdit` request while the command runs (see `editsOfRefactoring`).
                    workspace: ClientCapabilities.Workspace(
                        applyEdit: true, workspaceEdit: nil, didChangeConfiguration: nil, didChangeWatchedFiles: nil,
                        symbol: nil, executeCommand: nil, workspaceFolders: nil, configuration: nil, semanticTokens: nil
                    ),
                    // Without literal support SourceKit-LSP answers every `textDocument/codeAction` with an
                    // empty list (it advertises `codeActionProvider: true` all the same), so no fix-it or
                    // refactoring ever reached the editor. Only the kinds the mapping below can apply.
                    textDocument: TextDocumentClientCapabilities(
                        codeAction: CodeActionClientCapabilities(
                            dynamicRegistration: false,
                            codeActionLiteralSupport: .init(codeActionKind: ValueSet(valueSet: [
                                CodeActionKind.Quickfix, CodeActionKind.Refactor, CodeActionKind.RefactorExtract,
                                CodeActionKind.RefactorInline, CodeActionKind.RefactorRewrite,
                            ])),
                            isPreferredSupport: true
                        )
                    ),
                    // Advertised because `consumeServerEvents` answers `window/workDoneProgress/create`;
                    // a server that asked and got no answer would wait for it.
                    window: WindowClientCapabilities(workDoneProgress: true, showMessage: nil, showDocument: nil),
                    general: nil, experimental: nil
                ),
                trace: nil,
                workspaceFolders: folders
            )
        }
        return LanguageServerClient(server: server, documentURI: documentURI, onProgress: onProgress)
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
        await ensureSynced(document)
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
        try await requestCompletionList(for: document, at: position).items
    }

    /// The server's answer with its `isIncomplete` flag. SourceKit-LSP stops at a page of 200 items and
    /// marks the list incomplete: the rest comes from asking again once more has been typed, which the
    /// editor does on each keystroke of an identifier, so a caller that wants a name that is not on the
    /// first page narrows the request by typing its first characters.
    public func requestCompletionList(for document: Document, at position: TextPosition) async throws -> LSPCompletionList {
        guard await allows(.completion) else { return LSPCompletionList(items: [], isIncomplete: false) }
        await ensureSynced(document)
        let params = CompletionParams(
            textDocument: textDocument(for: document),
            position: lspPosition(from: position),
            context: CompletionContext(triggerKind: .invoked, triggerCharacter: nil)
        )
        guard let result = try await server.completion(params) else {
            return LSPCompletionList(items: [], isIncomplete: false)
        }
        switch result {
        case .optionA(let items):
            return LSPCompletionList(items: items.map(eipCompletionItem(from:)), isIncomplete: false)
        case .optionB(let list):
            return LSPCompletionList(items: list.items.map(eipCompletionItem(from:)), isIncomplete: list.isIncomplete)
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
        await ensureSynced(document)
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
        await ensureSynced(document)
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
        await ensureSynced(document)
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
        await ensureSynced(document)
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
        await ensureSynced(document)
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
        await ensureSynced(document)
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
        await ensureSynced(document)
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
        await ensureSynced(document)
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
        await ensureSynced(document)
        // The context is what the server published, not what the editor made of it: SourceKit-LSP finds a
        // fix-it by the diagnostic's range, message, severity and `source` together, and the editor's own
        // copy carries its provider name as the source. A server that publishes nothing here (or pulls
        // diagnostics instead) gets the caller's list.
        let spot: LanguageServerProtocol.Position = lspPosition(from: position)
        let published = publishedDiagnostics.diagnostics(for: documentURI(document)).filter { contains($0.range, spot) }
        // A selection that holds the caret is the range of the request: the server offers its extract refactorings
        // (method, variable) only for a range, never for a point.
        let selection = document.selection.range
        let selectionHoldsCaret = !selection.isEmpty
            && (selection.start.line, selection.start.column) <= (position.line, position.column)
            && (position.line, position.column) <= (selection.end.line, selection.end.column)
        let params = CodeActionParams(
            textDocument: textDocument(for: document),
            range: selectionHoldsCaret
                ? LSPRange(start: lspPosition(from: selection.start), end: lspPosition(from: selection.end))
                : LSPRange(start: spot, end: spot),
            context: CodeActionContext(
                diagnostics: (published.isEmpty ? diagnostics : published).map(lspDiagnostic(from:)),
                only: nil,
                triggerKind: CodeActionTriggerKind.invoked
            )
        )
        guard let response = try await server.codeAction(params) else {
            return []
        }
        let uri = documentURI(document)
        var actions: [EditorIntelligence.LSPCodeAction] = []
        var commandsRun = 0
        for item in response {
            if let action = eipCodeAction(from: item, documentURI: uri) {
                actions.append(action)
            } else if commandsRun < Self.maximumRefactoringCommands, let action = await refactoring(from: item, documentURI: uri) {
                commandsRun += 1
                actions.append(action)
            }
        }
        return actions
    }

    /// How many command-only refactorings one request resolves. Each is a round trip to the server.
    static let maximumRefactoringCommands = 8

    /// A refactoring the server offers as a command (`Extract Method`, `Extract Expression`, …) with its edit, which
    /// the server only produces by running the command: it sends the edit back as `workspace/applyEdit`, and the
    /// client keeps it instead of applying it, so choosing the action in the editor is an ordinary edit. Only
    /// `refactor.*` actions that touch just this document are resolved; anything else could do more than edit.
    private func refactoring(
        from item: TwoTypeOption<Command, LanguageServerProtocol.CodeAction>, documentURI: String
    ) async -> EditorIntelligence.LSPCodeAction? {
        guard case .optionB(let action) = item, action.edit == nil, let command = action.command,
              (action.kind ?? "").hasPrefix("refactor"), applyEditSink == nil else { return nil }
        applyEditSink = []
        defer { applyEditSink = nil }
        do {
            _ = try await server.executeCommand(ExecuteCommandParams(command: command.command, arguments: command.arguments))
        } catch {
            return nil
        }
        var changes: [String: [EditorIntelligence.LSPTextEdit]] = [:]
        for edit in applyEditSink ?? [] {
            for (uri, edits) in LSPWorkspaceEditMapping.changes(from: edit) { changes[uri, default: []] += edits }
        }
        guard !changes.isEmpty, changes.keys.allSatisfy({ sameDocument($0, documentURI) }) else { return nil }
        let edits = changes.values.flatMap { $0 }
        guard !edits.isEmpty else { return nil }
        return EditorIntelligence.LSPCodeAction(title: action.title, kind: action.kind, edits: edits, isPreferred: action.isPreferred ?? false)
    }

    public func requestSignatureHelp(for document: Document, at position: TextPosition) async throws -> EditorIntelligence.LSPSignatureHelp? {
        guard await allows(.signatureHelp) else { return nil }
        await ensureSynced(document)
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
        await ensureSynced(document)
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
        await ensureSynced(document)
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
        sent[document.id] = SentDocument(version: version, utf16Length: snapshot.utf16Length)
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
            // Whoever sends increments keeps the server in step itself; a length kept here would go stale.
            sent[documentID] = nil
            let params = LSPDocumentSyncMapper.incrementalParams(uri: uri, changes: batch)
            try? await server.textDocumentDidChange(params)
        }
    }

    public func notifyFullChange(_ document: Document, version: Int) async {
        let uri = uris[document.id] ?? documentURI(document)
        uris[document.id] = uri
        let snapshot = document.contentSnapshot
        sent[document.id] = SentDocument(version: version, utf16Length: snapshot.utf16Length)
        let text = snapshot.substring(utf16Offset: 0, length: snapshot.utf16Length)
        let params = LSPDocumentSyncMapper.fullChangeParams(uri: uri, version: version, text: text)
        try? await server.textDocumentDidChange(params)
    }

    /// Sends `document`'s whole text as the next version when the server may not have it. Only for a
    /// document this client opened. Without `force` it sends only when the length differs from what
    /// the server holds, which is how a re-announcement of an unchanged document costs nothing and how
    /// a request made before the editor's debounce fired finds the text it is about to ask about.
    /// Returns whether it sent.
    @discardableResult
    public func syncFullText(of document: Document, force: Bool = false) async -> Bool {
        guard let state = sent[document.id] else { return false }
        guard force || document.contentSnapshot.utf16Length != state.utf16Length else { return false }
        await notifyFullChange(document, version: state.version + 1)
        return true
    }

    /// Called before a request about `document`, so the server answers about the text on screen.
    private func ensureSynced(_ document: Document) async {
        await syncFullText(of: document)
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
        await ensureSynced(document)
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
        await ensureSynced(document)
        let hints = try await server.inlayHint(InlayHintParams(
            textDocument: textDocument(for: document),
            range: lspRange(from: range)
        )) ?? []
        return hints.map(LSPRenderedInlayHint.init)
    }

    public func notifyClosed(documentID: DocumentID) async {
        sent[documentID] = nil
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
            switch event {
            case .notification(.textDocumentPublishDiagnostics(let params)):
                publishedDiagnostics.apply(params)
            case .notification(.protocolProgress(let params)):
                if workProgress.apply(params) { onProgress?(workProgress.active) }
            case .request(_, .windowWorkDoneProgressCreate(_, let respond)):
                await respond(nil)
            case .request(_, .workspaceApplyEdit(let params, let respond)):
                // Kept for `refactoring(from:)`; applied by the editor, so the server is told it was taken.
                let wanted = applyEditSink != nil
                if wanted { applyEditSink?.append(params.edit) }
                await respond(.success(ApplyWorkspaceEditResult(applied: wanted)))
            default:
                break
            }
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

/// Whether `position` is in `range`, both ends included (a zero-width range holds its own position).
private func contains(_ range: EditorIntelligence.LSPRange, _ position: LanguageServerProtocol.Position) -> Bool {
    let spot = (position.line, position.character)
    return (range.start.line, range.start.character) <= spot && spot <= (range.end.line, range.end.character)
}

/// An action the editor can apply to `documentURI`: its edits are all in that document. A command
/// (`workspace/executeCommand`, answered by the server's own `workspace/applyEdit`) and an edit that
/// reaches other files are dropped: chosen, they would do nothing, or change the wrong text.
func eipCodeAction(
    from action: TwoTypeOption<Command, LanguageServerProtocol.CodeAction>, documentURI: String
) -> EditorIntelligence.LSPCodeAction? {
    guard case .optionB(let codeAction) = action, let edit = codeAction.edit else { return nil }
    let changes = LSPWorkspaceEditMapping.changes(from: edit)
    guard !changes.isEmpty, changes.keys.allSatisfy({ sameDocument($0, documentURI) }) else { return nil }
    let edits = changes.values.flatMap { $0 }
    guard !edits.isEmpty else { return nil }
    return EditorIntelligence.LSPCodeAction(
        title: codeAction.title,
        kind: codeAction.kind,
        edits: edits,
        isPreferred: codeAction.isPreferred ?? false
    )
}

/// Two spellings of one file URI: the server echoes what it was sent, but a `file:///private/…` and a
/// `file:///…` of the same path are the same document.
private func sameDocument(_ lhs: String, _ rhs: String) -> Bool {
    if lhs == rhs { return true }
    guard let left = URL(string: lhs), let right = URL(string: rhs), left.isFileURL, right.isFileURL else { return false }
    return left.standardizedFileURL.path == right.standardizedFileURL.path
}

/// A completion answer: the items, and whether the server cut the list short.
public struct LSPCompletionList: Sendable, Equatable {
    public var items: [EditorIntelligence.LSPCompletionItem]
    /// True when asking again with more of the word typed would return items this list leaves out.
    public var isIncomplete: Bool

    public init(items: [EditorIntelligence.LSPCompletionItem], isIncomplete: Bool) {
        self.items = items
        self.isIncomplete = isIncomplete
    }
}
