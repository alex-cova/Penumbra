import EditorIntelligence
import EditorIntelligenceLSP
import LanguageServerProtocol
import XCTest

/// A scripted language server over pipes. No Xcode and no Node: the peer speaks Content-Length
/// JSON-RPC and answers the requests the client is supposed to gate, resolve and forward.
final class LSPFakeServerTests: XCTestCase {
    func testCapabilitiesGateRequestsAndResolveAndHierarchiesRoundTrip() async throws {
        let toServer = Pipe()
        let fromServer = Pipe()
        let peer = ScriptedLSPPeer()
        let server = Task.detached {
            peer.serve(reading: toServer.fileHandleForReading, writing: fromServer.fileHandleForWriting)
        }
        let clientWrite = HandleWriter(toServer.fileHandleForWriting)
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let reader = Task.detached {
            let handle = fromServer.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty {
                    continuation.finish()
                    return
                }
                continuation.yield(data)
            }
        }
        defer {
            clientWrite.close()
            try? fromServer.fileHandleForWriting.close()
            server.cancel()
            reader.cancel()
        }

        let client = LanguageServerClient.make(
            write: { try clientWrite.write($0) },
            read: stream,
            documentURI: { _ in "file:///tmp/A.swift" },
            workspaceRoot: URL(fileURLWithPath: "/tmp")
        )
        let document = Self.document()
        let position = document.cursor.position

        let hover = try await client.requestHover(for: document, at: position)
        XCTAssertNil(hover)
        let definition = try await client.requestDefinition(for: document, at: position)
        XCTAssertTrue(definition.isEmpty)

        let items = try await client.requestCompletions(for: document, at: position)
        XCTAssertEqual(items.map(\.label), ["Box"])
        XCTAssertTrue(items[0].additionalTextEdits.isEmpty)
        let resolved = try await client.resolveCompletion(items[0])
        XCTAssertEqual(resolved.additionalTextEdits.map(\.newText), ["import Box\n"])

        let calls = try await client.requestPrepareCallHierarchy(for: document, at: position)
        XCTAssertEqual(calls.map(\.name), ["moved"])
        let types = try await client.requestPrepareTypeHierarchy(for: document, at: position)
        XCTAssertEqual(types.map(\.name), ["Box"])

        let methods = peer.methods
        XCTAssertTrue(methods.contains("initialize"))
        XCTAssertTrue(methods.contains("textDocument/completion"))
        XCTAssertTrue(methods.contains("completionItem/resolve"))
        XCTAssertTrue(methods.contains("textDocument/prepareCallHierarchy"))
        XCTAssertTrue(methods.contains("textDocument/prepareTypeHierarchy"))
        XCTAssertFalse(methods.contains("textDocument/hover"))
        XCTAssertFalse(methods.contains("textDocument/definition"))

        let advertised = await client.advertisedFeatures()
        XCTAssertTrue(advertised.contains(.completion))
        XCTAssertTrue(advertised.contains(.callHierarchy))
        XCTAssertTrue(advertised.contains(.typeHierarchy))
        XCTAssertFalse(advertised.contains(.hover))
        XCTAssertFalse(advertised.contains(.definition))

        let box = LSPConnectionBox(client: client)
        box.setSupportedFeatures(advertised)
        let service = LSPLanguageService(
            configuration: LSPLanguageConfiguration(
                name: "sourcekit-lsp", languageIdentifiers: ["swift"],
                enabledFeatures: [.rename, .callHierarchy, .completion],
                diagnosticSource: .sourceKitLSP
            ),
            connections: box
        )
        let renameContext = NavigationContext(
            document: document, cursor: document.cursor, selection: document.selection, kind: .definition
        )
        let target = await service.providers.rename?.prepareRename(renameContext)
        XCTAssertEqual(target?.currentName, "Box")
        let plan = try await service.providers.rename?.rename(renameContext, to: "Crate")
        XCTAssertEqual(plan?.entries.map { $0.newText }, ["Crate"])

        let root = await service.providers.callHierarchy?.rootItem(
            source: "func moved() {}", fileURL: URL(fileURLWithPath: "/tmp/A.swift"), utf16Offset: 5
        )
        let item = try XCTUnwrap(root)
        XCTAssertEqual(item.name, "moved")
        let callers = await service.providers.callHierarchy?.callers(of: item, file: nil)
        XCTAssertEqual(callers?.map(\.name), ["caller"])
    }

    func testWorkDoneProgressIsAdvertisedAnsweredAndReported() async throws {
        let toServer = Pipe()
        let fromServer = Pipe()
        let peer = ScriptedLSPPeer()
        peer.scriptsProgress = true
        let server = Task.detached {
            peer.serve(reading: toServer.fileHandleForReading, writing: fromServer.fileHandleForWriting)
        }
        let clientWrite = HandleWriter(toServer.fileHandleForWriting)
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let reader = Task.detached {
            let handle = fromServer.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty {
                    continuation.finish()
                    return
                }
                continuation.yield(data)
            }
        }
        defer {
            clientWrite.close()
            try? fromServer.fileHandleForWriting.close()
            server.cancel()
            reader.cancel()
        }

        let updates = ProgressLog()
        let client = LanguageServerClient.make(
            write: { try clientWrite.write($0) },
            read: stream,
            documentURI: { _ in "file:///tmp/A.swift" },
            workspaceRoot: URL(fileURLWithPath: "/tmp"),
            onProgress: { updates.append($0.map(\.summary)) }
        )
        _ = await client.advertisedFeatures()

        let deadline = Date().addingTimeInterval(5)
        while updates.snapshot.count < 3, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(updates.snapshot, [["Indexing (0%)"], ["Indexing: 3/10 (30%)"], []])

        let answered = Date().addingTimeInterval(5)
        while !peer.methods.contains("response:900"), Date() < answered {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(peer.methods.contains("response:900"), "the server waits for an answer to create; got \(peer.methods)")
    }

    func testCodeActionsAreRequestedWithLiteralSupportAndOnlyApplicableOnesSurvive() async throws {
        let toServer = Pipe()
        let fromServer = Pipe()
        let peer = ScriptedLSPPeer()
        let server = Task.detached {
            peer.serve(reading: toServer.fileHandleForReading, writing: fromServer.fileHandleForWriting)
        }
        let clientWrite = HandleWriter(toServer.fileHandleForWriting)
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let reader = Task.detached {
            let handle = fromServer.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty {
                    continuation.finish()
                    return
                }
                continuation.yield(data)
            }
        }
        defer {
            clientWrite.close()
            try? fromServer.fileHandleForWriting.close()
            server.cancel()
            reader.cancel()
        }

        let client = LanguageServerClient.make(
            write: { try clientWrite.write($0) },
            read: stream,
            documentURI: { _ in "file:///tmp/A.swift" },
            workspaceRoot: URL(fileURLWithPath: "/tmp")
        )
        let document = Self.document()
        let actions = try await client.requestCodeActions(for: document, at: document.cursor.position, diagnostics: [])

        // SourceKit-LSP answers a client without code-action literal support with an empty list.
        let textDocument = peer.clientCapabilities["textDocument"] as? [String: Any]
        let codeAction = textDocument?["codeAction"] as? [String: Any]
        let kinds = ((codeAction?["codeActionLiteralSupport"] as? [String: Any])?["codeActionKind"] as? [String: Any])?["valueSet"] as? [String]
        XCTAssertEqual(kinds?.contains("quickfix"), true, "the client must advertise code-action literal support")

        XCTAssertEqual(actions.map(\.title), ["Replace var with let"],
                       "a command, an edit elsewhere, a mixed edit and an empty edit cannot be applied to this document")
        XCTAssertEqual(actions.first?.kind, "quickfix")
        XCTAssertEqual(actions.first?.isPreferred, true)
        XCTAssertEqual(actions.first?.edits.map(\.newText), ["let"])
    }

    func testCodeActionContextIsTheServersOwnDiagnosticAtThePosition() async throws {
        let toServer = Pipe()
        let fromServer = Pipe()
        let peer = ScriptedLSPPeer()
        peer.publishesDiagnostic = true
        let server = Task.detached {
            peer.serve(reading: toServer.fileHandleForReading, writing: fromServer.fileHandleForWriting)
        }
        let clientWrite = HandleWriter(toServer.fileHandleForWriting)
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let reader = Task.detached {
            let handle = fromServer.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty {
                    continuation.finish()
                    return
                }
                continuation.yield(data)
            }
        }
        defer {
            clientWrite.close()
            try? fromServer.fileHandleForWriting.close()
            server.cancel()
            reader.cancel()
        }

        let client = LanguageServerClient.make(
            write: { try clientWrite.write($0) },
            read: stream,
            documentURI: { _ in "file:///tmp/A.swift" },
            workspaceRoot: URL(fileURLWithPath: "/tmp")
        )
        let document = Self.document()
        _ = await client.advertisedFeatures() // runs `initialize`, as the host does; the peer publishes after `initialized`
        var published: [LSPDiagnostic] = []
        let deadline = Date().addingTimeInterval(5)
        while published.isEmpty, Date() < deadline {
            published = try await client.requestDiagnostics(for: document)
            if published.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        XCTAssertEqual(published.count, 1)

        // What the editor holds: the same problem under its own provider's name.
        let editorCopy = LSPDiagnostic(
            range: LSPRange(start: LSPPosition(line: 0, character: 4), end: LSPPosition(line: 0, character: 7)),
            severity: 2, message: "never mutated", source: "sourcekit-lsp"
        )
        let inside = TextPosition(line: 0, column: 5, utf16Offset: 5)
        let outside = TextPosition(line: 4, column: 0, utf16Offset: 40)
        _ = try await client.requestCodeActions(for: document, at: inside, diagnostics: [editorCopy])
        _ = try await client.requestCodeActions(for: document, at: outside, diagnostics: [editorCopy])

        let contexts = peer.contextsOfCodeActionRequests
        XCTAssertEqual(contexts.count, 2)
        XCTAssertEqual(contexts.first?.compactMap { $0["source"] as? String }, ["SourceKit"],
                       "at the diagnostic, the server's own copy is the context, not the editor's")
        XCTAssertEqual(contexts.last?.compactMap { $0["source"] as? String }, ["sourcekit-lsp"],
                       "where the server published nothing, the caller's diagnostics are sent")
    }

    func testDocumentSyncSendsTheServersLanguageAndOnlyRealChanges() async throws {
        let toServer = Pipe()
        let fromServer = Pipe()
        let peer = ScriptedLSPPeer()
        let server = Task.detached {
            peer.serve(reading: toServer.fileHandleForReading, writing: fromServer.fileHandleForWriting)
        }
        let clientWrite = HandleWriter(toServer.fileHandleForWriting)
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let reader = Task.detached {
            let handle = fromServer.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty {
                    continuation.finish()
                    return
                }
                continuation.yield(data)
            }
        }
        defer {
            clientWrite.close()
            try? fromServer.fileHandleForWriting.close()
            server.cancel()
            reader.cancel()
        }

        let client = LanguageServerClient.make(
            write: { try clientWrite.write($0) },
            read: stream,
            documentURI: { $0.url?.absoluteString ?? "untitled:\($0.id)" },
            workspaceRoot: URL(fileURLWithPath: "/tmp")
        )
        func document(_ id: DocumentID, _ path: String?, _ text: String, language: String) -> Document {
            let origin = TextPosition(line: 0, column: 0, utf16Offset: 0)
            return Document(
                id: id, url: path.map { URL(fileURLWithPath: $0) }, displayName: path ?? "Untitled",
                contentSnapshot: TextSnapshot(version: 0, text: text),
                selection: Selection(range: EditorIntelligence.TextRange(start: origin, end: origin)),
                cursor: Cursor(position: origin), viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
                languageIdentifier: language
            )
        }
        func waitForNotifications(_ count: Int) async throws {
            let deadline = Date().addingTimeInterval(5)
            while peer.documentSyncNotifications.count < count, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        let swiftID = DocumentID()
        let workspace = Workspace()
        // Open before the sync starts, as a tab opened before the server was ready.
        await workspace.openDocument(document(swiftID, "/tmp/A.swift", "let a = 1", language: "swift"))
        await workspace.openDocument(document(DocumentID(), "/tmp/B.java", "class B {}", language: "java"))
        await workspace.openDocument(document(DocumentID(), nil, "let untitled = 1", language: "swift"))

        let sync = LSPWorkspaceDocumentSync(client: client, languages: ["swift"])
        await sync.start(workspace: workspace)
        try await waitForNotifications(1)
        var notes = peer.documentSyncNotifications
        XCTAssertEqual(notes.map(\.method), ["textDocument/didOpen"], "only the saved Swift file is sent")
        let item = notes.first?.params["textDocument"] as? [String: Any]
        XCTAssertEqual(item?["uri"] as? String, "file:///tmp/A.swift")
        XCTAssertEqual(item?["languageId"] as? String, "swift")
        XCTAssertEqual(item?["text"] as? String, "let a = 1")
        XCTAssertEqual(item?["version"] as? Int, 1)

        // A refresh that announces the same document again sends nothing; a longer text is a change.
        await workspace.updateDocument(document(swiftID, "/tmp/A.swift", "let a = 1", language: "swift"))
        await workspace.updateDocument(document(swiftID, "/tmp/A.swift", "let a = 12", language: "swift"))
        try await waitForNotifications(2)
        notes = peer.documentSyncNotifications
        XCTAssertEqual(notes.map(\.method), ["textDocument/didOpen", "textDocument/didChange"])
        let change = notes.last?.params
        XCTAssertEqual((change?["textDocument"] as? [String: Any])?["version"] as? Int, 2)
        XCTAssertEqual((change?["contentChanges"] as? [[String: Any]])?.first?["text"] as? String, "let a = 12")

        // An edit event is always sent, even when the length did not change.
        await workspace.handleEditorEvent(.documentEdited(
            swiftID, [], newSnapshot: TextSnapshot(version: 0, text: "let b = 12")
        ))
        try await waitForNotifications(3)
        notes = peer.documentSyncNotifications
        XCTAssertEqual(notes.count, 3)
        XCTAssertEqual((notes.last?.params["textDocument"] as? [String: Any])?["version"] as? Int, 3)
        XCTAssertEqual((notes.last?.params["contentChanges"] as? [[String: Any]])?.first?["text"] as? String, "let b = 12")

        await workspace.closeDocument(swiftID)
        try await waitForNotifications(4)
        notes = peer.documentSyncNotifications
        XCTAssertEqual(notes.map(\.method), ["textDocument/didOpen", "textDocument/didChange", "textDocument/didChange", "textDocument/didClose"])
        let syncedCount = await sync.syncedDocumentCount
        XCTAssertEqual(syncedCount, 0)
        await sync.stop()
    }

    func testAReadOnlyGeneratedInterfaceGetsTheHigherLimitAndAnEditableFileDoesNot() async throws {
        let toServer = Pipe()
        let fromServer = Pipe()
        let peer = ScriptedLSPPeer()
        let server = Task.detached {
            peer.serve(reading: toServer.fileHandleForReading, writing: fromServer.fileHandleForWriting)
        }
        let clientWrite = HandleWriter(toServer.fileHandleForWriting)
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let reader = Task.detached {
            let handle = fromServer.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty {
                    continuation.finish()
                    return
                }
                continuation.yield(data)
            }
        }
        defer {
            clientWrite.close()
            try? fromServer.fileHandleForWriting.close()
            server.cancel()
            reader.cancel()
        }
        let client = LanguageServerClient.make(
            write: { try clientWrite.write($0) },
            read: stream,
            documentURI: { $0.url?.absoluteString ?? "untitled:\($0.id)" },
            workspaceRoot: URL(fileURLWithPath: "/tmp")
        )
        func document(_ path: String, characters: Int) -> Document {
            let origin = TextPosition(line: 0, column: 0, utf16Offset: 0)
            return Document(
                url: URL(fileURLWithPath: path), displayName: "D",
                contentSnapshot: TextSnapshot(version: 0, text: String(repeating: "x", count: characters)),
                selection: Selection(range: EditorIntelligence.TextRange(start: origin, end: origin)),
                cursor: Cursor(position: origin), viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
                languageIdentifier: "swift"
            )
        }
        let workspace = Workspace()
        // The same size: Foundation's generated interface is 2.3 MB; an ordinary source file that big is not sent.
        await workspace.openDocument(document("/proj/Sources/Big.swift", characters: 3_000))
        await workspace.openDocument(document("/var/T/sourcekit-lsp/GeneratedInterfaces/1/Foundation.swiftinterface", characters: 3_000))
        let sync = LSPWorkspaceDocumentSync(
            client: client, languages: ["swift"], maximumUTF16Length: 1_000, maximumGeneratedInterfaceUTF16Length: 10_000
        )
        await sync.start(workspace: workspace)
        let deadline = Date().addingTimeInterval(5)
        while peer.documentSyncNotifications.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        let uris = peer.documentSyncNotifications.compactMap { ($0.params["textDocument"] as? [String: Any])?["uri"] as? String }
        XCTAssertEqual(uris, ["file:///var/T/sourcekit-lsp/GeneratedInterfaces/1/Foundation.swiftinterface"])
        await sync.stop()
    }

    func testAFileOverTheSizeLimitIsNotSentAndOneThatGrowsPastItIsClosed() async throws {
        let toServer = Pipe()
        let fromServer = Pipe()
        let peer = ScriptedLSPPeer()
        let server = Task.detached {
            peer.serve(reading: toServer.fileHandleForReading, writing: fromServer.fileHandleForWriting)
        }
        let clientWrite = HandleWriter(toServer.fileHandleForWriting)
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let reader = Task.detached {
            let handle = fromServer.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty {
                    continuation.finish()
                    return
                }
                continuation.yield(data)
            }
        }
        defer {
            clientWrite.close()
            try? fromServer.fileHandleForWriting.close()
            server.cancel()
            reader.cancel()
        }
        let client = LanguageServerClient.make(
            write: { try clientWrite.write($0) },
            read: stream,
            documentURI: { $0.url?.absoluteString ?? "untitled:\($0.id)" },
            workspaceRoot: URL(fileURLWithPath: "/tmp")
        )
        func document(_ id: DocumentID, _ text: String) -> Document {
            let origin = TextPosition(line: 0, column: 0, utf16Offset: 0)
            return Document(
                id: id, url: URL(fileURLWithPath: "/tmp/Big.swift"), displayName: "Big.swift",
                contentSnapshot: TextSnapshot(version: 0, text: text),
                selection: Selection(range: EditorIntelligence.TextRange(start: origin, end: origin)),
                cursor: Cursor(position: origin), viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
                languageIdentifier: "swift"
            )
        }
        let id = DocumentID()
        let workspace = Workspace()
        await workspace.openDocument(document(id, String(repeating: "x", count: 50)))
        let sync = LSPWorkspaceDocumentSync(client: client, languages: ["swift"], maximumUTF16Length: 40)
        await sync.start(workspace: workspace)
        // A small file after it proves the big one was skipped and not merely slow.
        let small = DocumentID()
        let origin = TextPosition(line: 0, column: 0, utf16Offset: 0)
        await workspace.openDocument(Document(
            id: small, url: URL(fileURLWithPath: "/tmp/Small.swift"), displayName: "Small.swift",
            contentSnapshot: TextSnapshot(version: 0, text: "let a = 1"),
            selection: Selection(range: EditorIntelligence.TextRange(start: origin, end: origin)),
            cursor: Cursor(position: origin), viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "swift"
        ))
        let deadline = Date().addingTimeInterval(5)
        while peer.documentSyncNotifications.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        let uris = peer.documentSyncNotifications.compactMap { ($0.params["textDocument"] as? [String: Any])?["uri"] as? String }
        XCTAssertEqual(uris, ["file:///tmp/Small.swift"], "the 50-character file is over the 40-character limit")

        // Growing past the limit closes a file the server had.
        await workspace.updateDocument(document(small, String(repeating: "y", count: 60)))
        let closeDeadline = Date().addingTimeInterval(5)
        while !peer.documentSyncNotifications.contains(where: { $0.method == "textDocument/didClose" }), Date() < closeDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(peer.documentSyncNotifications.contains { $0.method == "textDocument/didClose" })
        await sync.stop()
    }

    func testARequestFirstSendsTheTextTheEditorHasAndAskingTwiceSendsItOnce() async throws {
        let toServer = Pipe()
        let fromServer = Pipe()
        let peer = ScriptedLSPPeer()
        let server = Task.detached {
            peer.serve(reading: toServer.fileHandleForReading, writing: fromServer.fileHandleForWriting)
        }
        let clientWrite = HandleWriter(toServer.fileHandleForWriting)
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let reader = Task.detached {
            let handle = fromServer.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty {
                    continuation.finish()
                    return
                }
                continuation.yield(data)
            }
        }
        defer {
            clientWrite.close()
            try? fromServer.fileHandleForWriting.close()
            server.cancel()
            reader.cancel()
        }

        let client = LanguageServerClient.make(
            write: { try clientWrite.write($0) },
            read: stream,
            documentURI: { $0.url?.absoluteString ?? "untitled:\($0.id)" },
            workspaceRoot: URL(fileURLWithPath: "/tmp")
        )
        let origin = TextPosition(line: 0, column: 0, utf16Offset: 0)
        func document(_ id: DocumentID, _ text: String) -> Document {
            Document(
                id: id, url: URL(fileURLWithPath: "/tmp/A.swift"), displayName: "A.swift",
                contentSnapshot: TextSnapshot(version: 0, text: text),
                selection: Selection(range: EditorIntelligence.TextRange(start: origin, end: origin)),
                cursor: Cursor(position: origin), viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
                languageIdentifier: "swift"
            )
        }
        let id = DocumentID()
        await client.notifyOpened(document(id, "let b = Box()"), languageID: "swift", version: 1)

        // The editor's debounce has not sent the keystroke yet; the request does.
        let typed = document(id, "let b = Box().w")
        _ = try await client.requestCompletions(for: typed, at: typed.cursor.position)
        _ = try await client.requestCompletions(for: typed, at: typed.cursor.position)
        _ = try await client.requestHover(for: typed, at: typed.cursor.position)

        let methods = peer.methods
        let change = try XCTUnwrap(methods.firstIndex(of: "textDocument/didChange"), "no didChange in \(methods)")
        let firstCompletion = try XCTUnwrap(methods.firstIndex(of: "textDocument/completion"))
        XCTAssertLessThan(change, firstCompletion, "the text goes before the request that depends on it")
        XCTAssertEqual(methods.filter { $0 == "textDocument/didChange" }.count, 1, "the same text is not sent again")
        let notification = try XCTUnwrap(peer.documentSyncNotifications.last { $0.method == "textDocument/didChange" })
        XCTAssertEqual((notification.params["textDocument"] as? [String: Any])?["version"] as? Int, 2)
        XCTAssertEqual((notification.params["contentChanges"] as? [[String: Any]])?.first?["text"] as? String, "let b = Box().w")

        // A document this client never opened is not the client's to send.
        let stranger = document(DocumentID(), "let other = 1")
        _ = try await client.requestCompletions(for: stranger, at: origin)
        XCTAssertEqual(peer.methods.filter { $0 == "textDocument/didChange" }.count, 1)
    }

    func testTheCompletionListSaysWhetherTheServerCutItShort() async throws {
        let toServer = Pipe()
        let fromServer = Pipe()
        let peer = ScriptedLSPPeer()
        let server = Task.detached {
            peer.serve(reading: toServer.fileHandleForReading, writing: fromServer.fileHandleForWriting)
        }
        let clientWrite = HandleWriter(toServer.fileHandleForWriting)
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let reader = Task.detached {
            let handle = fromServer.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty {
                    continuation.finish()
                    return
                }
                continuation.yield(data)
            }
        }
        defer {
            clientWrite.close()
            try? fromServer.fileHandleForWriting.close()
            server.cancel()
            reader.cancel()
        }
        let client = LanguageServerClient.make(
            write: { try clientWrite.write($0) },
            read: stream,
            documentURI: { _ in "file:///tmp/A.swift" },
            workspaceRoot: URL(fileURLWithPath: "/tmp")
        )
        let document = Self.document()
        let position = document.cursor.position

        let complete = try await client.requestCompletionList(for: document, at: position)
        XCTAssertEqual(complete.items.map(\.label), ["Box"])
        XCTAssertFalse(complete.isIncomplete, "a plain array is the whole answer")

        peer.incompleteCompletion = true
        let cut = try await client.requestCompletionList(for: document, at: position)
        XCTAssertEqual(cut.items.map(\.label), ["Box"])
        XCTAssertTrue(cut.isIncomplete)
        let items = try await client.requestCompletions(for: document, at: position)
        XCTAssertEqual(items.map(\.label), ["Box"], "the plain call still returns just the items")
    }

    func testInitializationOptionsReachTheServer() async throws {
        let toServer = Pipe()
        let fromServer = Pipe()
        let peer = ScriptedLSPPeer()
        let server = Task.detached {
            peer.serve(reading: toServer.fileHandleForReading, writing: fromServer.fileHandleForWriting)
        }
        let clientWrite = HandleWriter(toServer.fileHandleForWriting)
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let reader = Task.detached {
            let handle = fromServer.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty {
                    continuation.finish()
                    return
                }
                continuation.yield(data)
            }
        }
        defer {
            clientWrite.close()
            try? fromServer.fileHandleForWriting.close()
            server.cancel()
            reader.cancel()
        }
        let client = LanguageServerClient.make(
            write: { try clientWrite.write($0) },
            read: stream,
            documentURI: { _ in "file:///tmp/A.swift" },
            workspaceRoot: URL(fileURLWithPath: "/tmp"),
            initializationOptions: Data(#"{"compilationDatabase":{"searchPaths":["../../cache"]}}"#.utf8)
        )
        _ = await client.advertisedFeatures()
        let options = try XCTUnwrap(peer.clientInitializationOptions as? [String: Any], "initializationOptions missing from initialize")
        let search = ((options["compilationDatabase"] as? [String: Any])?["searchPaths"]) as? [String]
        XCTAssertEqual(search, ["../../cache"])
    }

    func testAFalseHoverCapabilityIsOffAndResolveIsRecorded() {
        var capabilities = ServerCapabilities()
        capabilities.hoverProvider = .optionA(false)
        capabilities.definitionProvider = .optionA(false)
        capabilities.completionProvider = CompletionOptions(
            workDoneProgress: false, triggerCharacters: ["."], allCommitCharacters: nil,
            resolveProvider: true, completionItem: nil
        )
        capabilities.callHierarchyProvider = .optionB(WorkDoneProgressOptions())
        let features = LSPServerCapabilities.features(in: capabilities)
        XCTAssertTrue(features.contains(.completion))
        XCTAssertTrue(features.contains(.callHierarchy))
        XCTAssertFalse(features.contains(.hover))
        XCTAssertFalse(features.contains(.definition))
        XCTAssertTrue(LSPServerCapabilities.resolvesCompletionItems(capabilities))
    }

    private static func document() -> Document {
        let position = TextPosition(line: 1, column: 4, utf16Offset: 8)
        return Document(
            url: URL(fileURLWithPath: "/tmp/A.swift"), displayName: "A.swift",
            contentSnapshot: TextSnapshot(version: 1, text: "let b = Box()"),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "swift"
        )
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [[String]] = []
    func append(_ entry: [String]) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }
    var snapshot: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

private final class HandleWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    init(_ handle: FileHandle) { self.handle = handle }
    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        try handle.write(contentsOf: data)
    }
    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle.close()
    }
}

private final class ScriptedLSPPeer: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    var methods: [String] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    /// After `initialized`, ask the client to create a progress token and report on it.
    var scriptsProgress = false
    /// After `initialized`, push one diagnostic (source `SourceKit`, 0:4-0:7) for `file:///tmp/A.swift`.
    var publishesDiagnostic = false
    private var incomplete = false
    private var initializeParams: [String: Any] = [:]
    private var codeActionContexts: [[[String: Any]]] = []
    private var syncNotifications: [(method: String, params: [String: Any])] = []

    /// Each `textDocument/didOpen`, `didChange` and `didClose` the client sent, in order.
    var documentSyncNotifications: [(method: String, params: [String: Any])] {
        lock.lock()
        defer { lock.unlock() }
        return syncNotifications
    }

    /// The `context.diagnostics` of each `textDocument/codeAction` request, in order.
    var contextsOfCodeActionRequests: [[[String: Any]]] {
        lock.lock()
        defer { lock.unlock() }
        return codeActionContexts
    }

    /// Answer `textDocument/completion` as a list the server cut short (`isIncomplete: true`) instead of an array.
    var incompleteCompletion: Bool {
        get { lock.lock(); defer { lock.unlock() }; return incomplete }
        set { lock.lock(); defer { lock.unlock() }; incomplete = newValue }
    }

    /// The `initializationOptions` the client sent with `initialize`.
    var clientInitializationOptions: Any? {
        lock.lock()
        defer { lock.unlock() }
        return initializeParams["initializationOptions"]
    }

    /// The `capabilities` the client sent with `initialize`.
    var clientCapabilities: [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return initializeParams["capabilities"] as? [String: Any] ?? [:]
    }

    func serve(reading input: FileHandle, writing output: FileHandle) {
        var buffer = Data()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let message = Self.takeMessage(from: &buffer) {
                self.reply(to: message, on: output)
            }
        }
    }

    private func reply(to message: Data, on output: FileHandle) {
        guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any] else { return }
        guard let method = object["method"] as? String else {
            // The client answering a request this peer sent.
            if let id = object["id"], !(id is NSNull) {
                lock.lock()
                seen.append("response:\(id)")
                lock.unlock()
            }
            return
        }
        lock.lock()
        seen.append(method)
        if method == "initialize" { initializeParams = object["params"] as? [String: Any] ?? [:] }
        if ["textDocument/didOpen", "textDocument/didChange", "textDocument/didClose"].contains(method) {
            syncNotifications.append((method, object["params"] as? [String: Any] ?? [:]))
        }
        if method == "textDocument/codeAction" {
            let context = (object["params"] as? [String: Any])?["context"] as? [String: Any]
            codeActionContexts.append(context?["diagnostics"] as? [[String: Any]] ?? [])
        }
        lock.unlock()
        if method == "initialized", scriptsProgress { Self.sendProgress(on: output) }
        if method == "initialized", publishesDiagnostic { Self.sendDiagnostic(on: output) }
        guard let id = object["id"], !(id is NSNull) else { return }
        let body = Self.response(id: id, method: method, incompleteCompletion: incompleteCompletion)
        var framed = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        framed.append(body)
        try? output.write(contentsOf: framed)
    }

    private static func response(id: Any, method: String, incompleteCompletion: Bool = false) -> Data {
        let result: Any
        switch method {
        case "initialize":
            result = [
                "capabilities": [
                    "completionProvider": ["resolveProvider": true, "triggerCharacters": ["."]],
                    "definitionProvider": false,
                    "renameProvider": true,
                    "codeActionProvider": true,
                    "callHierarchyProvider": true,
                    "typeHierarchyProvider": true
                ]
            ] as [String: Any]
        case "textDocument/completion":
            let items = [["label": "Box", "insertText": "Box"]]
            result = incompleteCompletion ? ["isIncomplete": true, "items": items] as [String: Any] : items as Any
        case "completionItem/resolve":
            result = [
                "label": "Box",
                "additionalTextEdits": [[
                    "range": [
                        "start": ["line": 0, "character": 0],
                        "end": ["line": 0, "character": 0]
                    ],
                    "newText": "import Box\n"
                ]]
            ] as [String: Any]
        case "textDocument/codeAction":
            func edit(_ uri: String) -> [String: Any] {
                ["changes": [uri: [["range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 3]], "newText": "let"]]]]
            }
            result = [
                ["title": "Replace var with let", "kind": "quickfix", "isPreferred": true, "edit": edit("file:///tmp/A.swift")],
                // Chosen, a command would do nothing here: the server finishes it with workspace/applyEdit.
                ["title": "Extract Method", "kind": "refactor.extract", "command": ["title": "Extract Method", "command": "refactor"]],
                ["title": "Rename in another file", "kind": "refactor", "edit": edit("file:///tmp/Other.swift")],
                ["title": "Both files", "kind": "quickfix", "edit": [
                    "changes": [
                        "file:///tmp/A.swift": [["range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 1]], "newText": "x"]],
                        "file:///tmp/Other.swift": [["range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 1]], "newText": "y"]],
                    ],
                ]],
                ["title": "Empty edit", "kind": "quickfix", "edit": ["changes": [String: Any]()]],
            ] as [Any]
        case "textDocument/prepareCallHierarchy":
            result = [symbol(name: "moved", kind: 6)]
        case "textDocument/prepareTypeHierarchy":
            result = [symbol(name: "Box", kind: 5)]
        case "textDocument/rename":
            result = [
                "changes": [
                    "file:///tmp/A.swift": [[
                        "range": [
                            "start": ["line": 0, "character": 8],
                            "end": ["line": 0, "character": 11]
                        ],
                        "newText": "Crate"
                    ]]
                ]
            ] as [String: Any]
        case "callHierarchy/incomingCalls":
            result = [["from": symbol(name: "caller", kind: 6), "fromRanges": [[
                "start": ["line": 2, "character": 0],
                "end": ["line": 2, "character": 6]
            ]]]]
        default:
            result = NSNull()
        }
        let object: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private static func sendDiagnostic(on output: FileHandle) {
        let diagnostic: [String: Any] = [
            "range": ["start": ["line": 0, "character": 4], "end": ["line": 0, "character": 7]],
            "severity": 2, "source": "SourceKit", "message": "never mutated",
        ]
        let message: [String: Any] = [
            "jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
            "params": ["uri": "file:///tmp/A.swift", "diagnostics": [diagnostic]],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: message) else { return }
        var framed = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        framed.append(body)
        try? output.write(contentsOf: framed)
    }

    /// `window/workDoneProgress/create` (a request, id 900) and then begin, report and end on that token.
    private static func sendProgress(on output: FileHandle) {
        func send(_ object: [String: Any]) {
            guard let body = try? JSONSerialization.data(withJSONObject: object) else { return }
            var framed = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
            framed.append(body)
            try? output.write(contentsOf: framed)
        }
        func progress(_ value: [String: Any]) -> [String: Any] {
            ["jsonrpc": "2.0", "method": "$/progress", "params": ["token": "index", "value": value]]
        }
        send(["jsonrpc": "2.0", "id": 900, "method": "window/workDoneProgress/create", "params": ["token": "index"]])
        send(progress(["kind": "begin", "title": "Indexing", "percentage": 0]))
        send(progress(["kind": "report", "message": "3/10", "percentage": 30]))
        send(progress(["kind": "end"]))
    }

    private static func symbol(name: String, kind: Int) -> [String: Any] {
        let range: [String: Any] = [
            "start": ["line": 1, "character": 4],
            "end": ["line": 1, "character": 7]
        ]
        return ["name": name, "kind": kind, "uri": "file:///tmp/A.swift", "range": range, "selectionRange": range]
    }

    private static func takeMessage(from buffer: inout Data) -> Data? {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let header = String(decoding: buffer[..<separator.lowerBound], as: UTF8.self)
        guard let line = header.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
              let length = Int(line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "")
        else { return nil }
        let bodyStart = separator.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
        let body = Data(buffer[bodyStart..<bodyEnd])
        buffer.removeSubrange(..<bodyEnd)
        return body
    }
}
