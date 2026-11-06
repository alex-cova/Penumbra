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

    func testARefactoringTheServerOffersAsACommandIsRunAndItsEditComesBackAsTheAction() async throws {
        let toServer = Pipe()
        let fromServer = Pipe()
        let peer = ScriptedLSPPeer()
        peer.appliesEditOnCommand = true
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

        let workspace = peer.clientCapabilities["workspace"] as? [String: Any]
        XCTAssertEqual(workspace?["applyEdit"] as? Bool, true, "the client must say it takes workspace/applyEdit")
        XCTAssertTrue(peer.methods.contains("workspace/executeCommand"), "\(peer.methods)")
        XCTAssertTrue(peer.methods.contains("response:9001"), "the client answered the server's applyEdit: \(peer.methods)")

        // The refactoring is an ordinary edit now; the one that is neither a refactoring nor an edit here is still dropped.
        XCTAssertEqual(actions.map(\.title), ["Replace var with let", "Extract Method"])
        let extract = try XCTUnwrap(actions.last)
        XCTAssertEqual(extract.kind, "refactor.extract")
        XCTAssertEqual(extract.edits.map(\.newText), ["func extracted() {}\n"])
    }

    func testACommandIsNotRunWhenNoOneIsCollectingItsEdit() async throws {
        // Without a refactoring in flight a stray `workspace/applyEdit` is refused (applied: false), so the server
        // does not believe an edit landed that the editor never saw. Covered by the response above; here the plain
        // path: a server that does not send applyEdit gives no action for its command.
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
        XCTAssertEqual(actions.map(\.title), ["Replace var with let"])
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

    // MARK: - Incremental document sync (P1)

    func testIncrementalDidChangeSendsOneRangedChange() async throws {
        let fixture = await makeIncrementalFixture(syncKind: 2)
        defer { fixture.stop() }
        let id = DocumentID()
        await fixture.workspace.openDocument(incrementalDocument(id, "let a = 1"))
        try await waitForSyncCount(fixture.peer, 1)

        let edit = appendTextEdit("2", to: "let a = 1")
        await fixture.workspace.handleEditorEvent(.documentEdited(
            id, [edit], newSnapshot: TextSnapshot(version: 1, text: "let a = 12")
        ))
        try await waitForSyncCount(fixture.peer, 2)

        let notes = fixture.peer.documentSyncNotifications
        XCTAssertEqual(notes.map(\.method), ["textDocument/didOpen", "textDocument/didChange"])
        let change = try XCTUnwrap(notes.last?.params)
        XCTAssertEqual((change["textDocument"] as? [String: Any])?["version"] as? Int, 2)
        let changes = try XCTUnwrap(change["contentChanges"] as? [[String: Any]])
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0]["text"] as? String, "2")
        let range = try XCTUnwrap(changes[0]["range"] as? [String: Any])
        XCTAssertEqual((range["start"] as? [String: Any])?["line"] as? Int, 0)
        XCTAssertEqual((range["start"] as? [String: Any])?["character"] as? Int, 9)
        XCTAssertEqual((range["end"] as? [String: Any])?["character"] as? Int, 9)
        XCTAssertEqual(fixture.peer.mirroredText(for: "file:///tmp/A.swift"), "let a = 12")
    }

    func testFullSyncServerStillReceivesWholeText() async throws {
        let fixture = await makeIncrementalFixture(syncKind: 1)
        defer { fixture.stop() }
        let id = DocumentID()
        await fixture.workspace.openDocument(incrementalDocument(id, "let a = 1"))
        try await waitForSyncCount(fixture.peer, 1)

        let edit = appendTextEdit("2", to: "let a = 1")
        await fixture.workspace.handleEditorEvent(.documentEdited(
            id, [edit], newSnapshot: TextSnapshot(version: 1, text: "let a = 12")
        ))
        try await waitForSyncCount(fixture.peer, 2)

        let notes = fixture.peer.documentSyncNotifications
        XCTAssertEqual(notes.map(\.method), ["textDocument/didOpen", "textDocument/didChange"])
        let change = try XCTUnwrap(notes.last?.params)
        XCTAssertEqual((change["textDocument"] as? [String: Any])?["version"] as? Int, 2)
        let changes = try XCTUnwrap(change["contentChanges"] as? [[String: Any]])
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0]["text"] as? String, "let a = 12")
        XCTAssertNil(changes[0]["range"] as? [String: Any])
        XCTAssertEqual(fixture.peer.mirroredText(for: "file:///tmp/A.swift"), "let a = 12")
    }

    func testRequestDrivenResendFallsBackToFullTextThenRecovers() async throws {
        let fixture = await makeIncrementalFixture(syncKind: 2)
        defer { fixture.stop() }
        let id = DocumentID()
        await fixture.workspace.openDocument(incrementalDocument(id, "let a = 1"))
        try await waitForSyncCount(fixture.peer, 1)

        // A request made before the debounce fires resends the whole text off the event stream.
        let origin = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let typed = incrementalDocument(id, "let a = 12", version: 1)
        _ = try await fixture.client.requestCompletions(for: typed, at: origin)
        try await waitForSyncCount(fixture.peer, 2)

        // The debounced event carries pre-resend positions: ranges would apply twice, so full text.
        await fixture.workspace.handleEditorEvent(.documentEdited(
            id, [appendTextEdit("2", to: "let a = 1")],
            newSnapshot: TextSnapshot(version: 2, text: "let a = 12")
        ))
        try await waitForSyncCount(fixture.peer, 3)

        // The next edit starts from what the server holds again: incremental.
        await fixture.workspace.handleEditorEvent(.documentEdited(
            id, [appendTextEdit("3", to: "let a = 12")],
            newSnapshot: TextSnapshot(version: 3, text: "let a = 123")
        ))
        try await waitForSyncCount(fixture.peer, 4)

        let notes = fixture.peer.documentSyncNotifications
        XCTAssertEqual(notes.map(\.method), [
            "textDocument/didOpen", "textDocument/didChange",
            "textDocument/didChange", "textDocument/didChange",
        ])
        XCTAssertEqual(
            (notes[1].params["textDocument"] as? [String: Any])?["version"] as? Int, 2,
            "the request resends the whole text"
        )
        let resent = try XCTUnwrap(notes[2].params["contentChanges"] as? [[String: Any]])
        XCTAssertEqual(resent.count, 1)
        XCTAssertEqual(resent[0]["text"] as? String, "let a = 12")
        XCTAssertNil(resent[0]["range"] as? [String: Any], "pre-resend positions must not go as ranges")
        let ranged = try XCTUnwrap(notes[3].params["contentChanges"] as? [[String: Any]])
        XCTAssertEqual(ranged.count, 1)
        XCTAssertEqual(ranged[0]["text"] as? String, "3")
        let range = try XCTUnwrap(ranged[0]["range"] as? [String: Any])
        XCTAssertEqual((range["start"] as? [String: Any])?["character"] as? Int, 10)
        XCTAssertEqual(fixture.peer.mirroredText(for: "file:///tmp/A.swift"), "let a = 123")
    }

    func testIncrementalRangeCharacterIsUTF16() async throws {
        let fixture = await makeIncrementalFixture(syncKind: 2)
        defer { fixture.stop() }
        let id = DocumentID()
        // "let a = 😀" is 10 UTF-16 units (the emoji is a surrogate pair) but 9 scalars.
        await fixture.workspace.openDocument(incrementalDocument(id, "let a = 😀"))
        try await waitForSyncCount(fixture.peer, 1)

        let at = TextPosition(line: 0, column: 10, utf16Offset: 10)
        await fixture.workspace.handleEditorEvent(.documentEdited(
            id, [EditorIntelligence.TextEdit(range: TextRange(start: at, end: at), replacement: "!")],
            newSnapshot: TextSnapshot(version: 1, text: "let a = 😀!")
        ))
        try await waitForSyncCount(fixture.peer, 2)

        let change = try XCTUnwrap(fixture.peer.documentSyncNotifications.last?.params)
        let changes = try XCTUnwrap(change["contentChanges"] as? [[String: Any]])
        XCTAssertEqual(changes.count, 1)
        let range = try XCTUnwrap(changes[0]["range"] as? [String: Any])
        XCTAssertEqual((range["start"] as? [String: Any])?["character"] as? Int, 10)
        XCTAssertEqual(fixture.peer.mirroredText(for: "file:///tmp/A.swift"), "let a = 😀!")
    }

    func testIncrementalMirrorHoldsAcrossRandomEditsAndRequests() async throws {
        let fixture = await makeIncrementalFixture(syncKind: 2)
        defer { fixture.stop() }
        let id = DocumentID()
        let uri = "file:///tmp/A.swift"
        var text = "func f() {\n    let x = 1\n    return x\n}\n"
        await fixture.workspace.openDocument(incrementalDocument(id, text))
        try await waitForSyncCount(fixture.peer, 1)

        let origin = TextPosition(line: 0, column: 0, utf16Offset: 0)
        var rng = SeededEdits(state: 0x5EED)
        var version = 0
        for step in 0..<200 {
            var current = text
            var edits: [EditorIntelligence.TextEdit] = []
            for _ in 0..<(1 + Int(rng.next() % 2)) {
                let (edit, next) = randomTextEdit(in: current, rng: &rng)
                edits.append(edit)
                current = next
            }
            text = current
            version += 1
            await fixture.workspace.handleEditorEvent(.documentEdited(
                id, edits, newSnapshot: TextSnapshot(version: version, text: text)
            ))
            if step % 10 == 9 {
                let fresh = incrementalDocument(id, text, version: version)
                _ = try await fixture.client.requestCompletions(for: fresh, at: origin)
            }
            let deadline = Date().addingTimeInterval(5)
            while fixture.peer.mirroredText(for: uri) != text, Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(fixture.peer.mirroredText(for: uri), text, "mirror drifts at step \(step)")
        }
    }

    func testIncrementalPathNeverReadsTheWholeSnapshot() async throws {
        let fixture = await makeIncrementalFixture(syncKind: 2)
        defer { fixture.stop() }
        let id = DocumentID()
        let counter = FullReadCounter()
        let fullLength = ("let a = 1" as NSString).length
        let reader = TextRangeReader(utf16Length: fullLength) { [counter] offset, length in
            counter.record(offset: offset, length: length, fullLength: fullLength)
            let ns = "let a = 1" as NSString
            return ns.substring(with: NSRange(location: offset, length: min(length, fullLength - offset)))
        }
        let origin = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let document = Document(
            id: id, url: URL(fileURLWithPath: "/tmp/A.swift"), displayName: "A.swift",
            contentSnapshot: TextSnapshot(version: 0, utf16Length: fullLength, text: nil, rangeReader: reader),
            selection: Selection(range: TextRange(start: origin, end: origin)),
            cursor: Cursor(position: origin), viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "swift"
        )
        await fixture.workspace.openDocument(document)
        try await waitForSyncCount(fixture.peer, 1)

        await fixture.workspace.handleEditorEvent(.documentEdited(
            id, [appendTextEdit("2", to: "let a = 1")],
            newSnapshot: TextSnapshot(version: 1, text: "let a = 12")
        ))
        try await waitForSyncCount(fixture.peer, 2)

        // One full read for didOpen; the ranged didChange reads nothing.
        XCTAssertEqual(counter.fullReads, 1)
        let change = try XCTUnwrap(fixture.peer.documentSyncNotifications.last?.params)
        let changes = try XCTUnwrap(change["contentChanges"] as? [[String: Any]])
        XCTAssertEqual(changes.first?["text"] as? String, "2")
        XCTAssertEqual(fixture.peer.mirroredText(for: "file:///tmp/A.swift"), "let a = 12")
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

    // MARK: - Incremental sync fixtures

    private struct IncrementalFixture {
        let peer: ScriptedLSPPeer
        let client: LanguageServerClient
        let workspace: Workspace
        let sync: LSPWorkspaceDocumentSync
        let stop: () -> Void
    }

    private func makeIncrementalFixture(syncKind: Int) async -> IncrementalFixture {
        let toServer = Pipe()
        let fromServer = Pipe()
        let peer = ScriptedLSPPeer()
        peer.syncKind = syncKind
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
        let client = LanguageServerClient.make(
            write: { try clientWrite.write($0) },
            read: stream,
            documentURI: { $0.url?.absoluteString ?? "untitled:\($0.id)" },
            workspaceRoot: URL(fileURLWithPath: "/tmp")
        )
        let workspace = Workspace()
        let sync = LSPWorkspaceDocumentSync(client: client, languages: ["swift"])
        _ = await client.advertisedFeatures() // runs `initialize`, as the host does
        await sync.start(workspace: workspace)
        return IncrementalFixture(peer: peer, client: client, workspace: workspace, sync: sync, stop: {
            clientWrite.close()
            try? fromServer.fileHandleForWriting.close()
            server.cancel()
            reader.cancel()
        })
    }

    private func incrementalDocument(_ id: DocumentID, _ text: String, version: Int = 0) -> Document {
        let origin = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Document(
            id: id, url: URL(fileURLWithPath: "/tmp/A.swift"), displayName: "A.swift",
            contentSnapshot: TextSnapshot(version: version, text: text),
            selection: Selection(range: TextRange(start: origin, end: origin)),
            cursor: Cursor(position: origin), viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "swift"
        )
    }

    private func waitForSyncCount(_ peer: ScriptedLSPPeer, _ count: Int) async throws {
        let deadline = Date().addingTimeInterval(5)
        while peer.documentSyncNotifications.count < count, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// An insertion at the end of `text`, with line/column measured in UTF-16 units.
    private func appendTextEdit(_ insertion: String, to text: String) -> EditorIntelligence.TextEdit {
        let offset = (text as NSString).length
        let (line, column) = lineColumn(of: offset, in: text)
        let at = TextPosition(line: line, column: column, utf16Offset: offset)
        return EditorIntelligence.TextEdit(range: TextRange(start: at, end: at), replacement: insertion)
    }

    private func lineColumn(of utf16Offset: Int, in text: String) -> (line: Int, column: Int) {
        let ns = text as NSString
        var line = 0
        var start = 0
        for index in 0..<min(utf16Offset, ns.length) where ns.character(at: index) == 0x0A {
            line += 1
            start = index + 1
        }
        return (line, utf16Offset - start)
    }

    /// One random single-character insert, delete or replace at a character boundary.
    private func randomTextEdit(in text: String, rng: inout SeededEdits) -> (EditorIntelligence.TextEdit, String) {
        let insertions = ["x", "yz", " ", "\n", "😀", "let ", ";"]
        let ns = text as NSString
        let characters = Array(text)
        let index = characters.isEmpty ? 0 : Int(rng.next() % UInt64(characters.count + 1))
        var offset = 0
        for character in characters.prefix(index) {
            offset += (String(character) as NSString).length
        }
        let operation = rng.next() % 3
        var deleteLength = 0
        var insertion = ""
        if operation == 0 || index >= characters.count {
            insertion = insertions[Int(rng.next() % UInt64(insertions.count))]
        } else {
            deleteLength = (String(characters[index]) as NSString).length
            if operation == 2 {
                insertion = insertions[Int(rng.next() % UInt64(insertions.count))]
            }
        }
        let (line, column) = lineColumn(of: offset, in: text)
        let (endLine, endColumn) = lineColumn(of: offset + deleteLength, in: text)
        let edit = EditorIntelligence.TextEdit(
            range: TextRange(
                start: TextPosition(line: line, column: column, utf16Offset: offset),
                end: TextPosition(line: endLine, column: endColumn, utf16Offset: offset + deleteLength)
            ),
            replacement: insertion
        )
        let next = ns.replacingCharacters(
            in: NSRange(location: offset, length: deleteLength), with: insertion
        )
        return (edit, next)
    }
}

/// Deterministic RNG for the sync mirror fuzz test: the same seed replays the same edits.
private struct SeededEdits {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var x = state
        x ^= x >> 29
        x = x &* 0xBF58476D1CE4E5B9
        x ^= x >> 27
        x = x &* 0x94D049BB133111EB
        x ^= x >> 31
        return x
    }
}

/// Counts full-snapshot reads through a `TextRangeReader`, for the elided-text sync test.
private final class FullReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    func record(offset: Int, length: Int, fullLength: Int) {
        lock.lock()
        defer { lock.unlock() }
        if offset == 0 && length == fullLength {
            reads += 1
        }
    }
    var fullReads: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
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
    /// While running `workspace/executeCommand`, send the client a `workspace/applyEdit` (id 9001) first, as
    /// SourceKit-LSP does for a refactoring.
    var appliesEditOnCommand = false
    /// The id of an `executeCommand` held back until the client has answered the `workspace/applyEdit`, as the real
    /// server does.
    private var deferredCommandID: Any?
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

    /// Advertised in the `initialize` result as `textDocumentSync` (1 = full, 2 = incremental).
    /// Nil (the default) advertises nothing, like a server that never declares sync.
    private var advertisedSyncKind: Int?
    var syncKind: Int? {
        get { lock.lock(); defer { lock.unlock() }; return advertisedSyncKind }
        set { lock.lock(); defer { lock.unlock() }; advertisedSyncKind = newValue }
    }
    /// What the server holds per URI after applying every `didOpen`/`didChange` in order.
    private var mirrored: [String: String] = [:]

    /// The text the server holds for `uri`, or nil when it never saw the document.
    func mirroredText(for uri: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return mirrored[uri]
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
                let deferred = (id as? Int) == 9001 ? deferredCommandID : nil
                if deferred != nil { deferredCommandID = nil }
                lock.unlock()
                if let deferred {
                    let body = Self.response(id: deferred, method: "workspace/executeCommand")
                    var framed = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
                    framed.append(body)
                    try? output.write(contentsOf: framed)
                }
            }
            return
        }
        lock.lock()
        seen.append(method)
        if method == "initialize" { initializeParams = object["params"] as? [String: Any] ?? [:] }
        if ["textDocument/didOpen", "textDocument/didChange", "textDocument/didClose"].contains(method) {
            let params = object["params"] as? [String: Any] ?? [:]
            syncNotifications.append((method, params))
            Self.applyMirror(method: method, params: params, mirrored: &mirrored)
        }
        if method == "textDocument/codeAction" {
            let context = (object["params"] as? [String: Any])?["context"] as? [String: Any]
            codeActionContexts.append(context?["diagnostics"] as? [[String: Any]] ?? [])
        }
        lock.unlock()
        if method == "initialized", scriptsProgress { Self.sendProgress(on: output) }
        if method == "initialized", publishesDiagnostic { Self.sendDiagnostic(on: output) }
        guard let id = object["id"], !(id is NSNull) else { return }
        if method == "workspace/executeCommand", appliesEditOnCommand {
            lock.lock()
            deferredCommandID = id
            lock.unlock()
            Self.sendApplyEdit(on: output)
            return
        }
        let body = Self.response(
            id: id, method: method, incompleteCompletion: incompleteCompletion, syncKind: syncKind
        )
        var framed = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        framed.append(body)
        try? output.write(contentsOf: framed)
    }

    /// Applies `didOpen`/`didChange` to the mirror, the way a language server would: a change
    /// without a range replaces the whole text, ranged changes apply in order at UTF-16 offsets.
    private static func applyMirror(method: String, params: [String: Any], mirrored: inout [String: String]) {
        switch method {
        case "textDocument/didOpen":
            guard let document = params["textDocument"] as? [String: Any],
                  let uri = document["uri"] as? String,
                  let text = document["text"] as? String else { return }
            mirrored[uri] = text
        case "textDocument/didChange":
            guard let document = params["textDocument"] as? [String: Any],
                  let uri = document["uri"] as? String,
                  let changes = params["contentChanges"] as? [[String: Any]] else { return }
            var current = mirrored[uri] ?? ""
            for change in changes {
                guard let text = change["text"] as? String else { continue }
                guard let range = change["range"] as? [String: Any] else {
                    current = text
                    continue
                }
                current = applyRangedMirrorChange(range: range, text: text, to: current)
            }
            mirrored[uri] = current
        case "textDocument/didClose":
            guard let uri = (params["textDocument"] as? [String: Any])?["uri"] as? String else { return }
            mirrored.removeValue(forKey: uri)
        default:
            break
        }
    }

    private static func applyRangedMirrorChange(range: [String: Any], text: String, to current: String) -> String {
        func point(_ value: Any?) -> (line: Int, character: Int)? {
            guard let point = value as? [String: Any],
                  let line = point["line"] as? Int,
                  let character = point["character"] as? Int else { return nil }
            return (line, character)
        }
        guard let start = point(range["start"]), let end = point(range["end"]) else { return current }
        let ns = current as NSString
        var starts = [0]
        for index in 0..<ns.length where ns.character(at: index) == 0x0A {
            starts.append(index + 1)
        }
        func offset(line: Int, character: Int) -> Int {
            guard line < starts.count else { return ns.length }
            let lineStart = starts[line]
            let lineEnd = line + 1 < starts.count ? starts[line + 1] - 1 : ns.length
            return min(lineStart + character, lineEnd)
        }
        let lower = offset(line: start.line, character: start.character)
        let upper = offset(line: end.line, character: end.character)
        guard lower <= upper else { return current }
        return ns.replacingCharacters(in: NSRange(location: lower, length: upper - lower), with: text)
    }

    private static func response(
        id: Any, method: String, incompleteCompletion: Bool = false, syncKind: Int? = nil
    ) -> Data {
        let result: Any
        switch method {
        case "initialize":
            var capabilities: [String: Any] = [
                "completionProvider": ["resolveProvider": true, "triggerCharacters": ["."]],
                "definitionProvider": false,
                "renameProvider": true,
                "codeActionProvider": true,
                "callHierarchyProvider": true,
                "typeHierarchyProvider": true,
            ]
            if let syncKind {
                capabilities["textDocumentSync"] = syncKind
            }
            result = ["capabilities": capabilities] as [String: Any]
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

    private static func sendApplyEdit(on output: FileHandle) {
        let edit: [String: Any] = ["changes": ["file:///tmp/A.swift": [[
            "range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 0]], "newText": "func extracted() {}\n",
        ]]]]
        let message: [String: Any] = ["jsonrpc": "2.0", "id": 9001, "method": "workspace/applyEdit", "params": ["edit": edit]]
        guard let body = try? JSONSerialization.data(withJSONObject: message) else { return }
        var framed = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        framed.append(body)
        try? output.write(contentsOf: framed)
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
