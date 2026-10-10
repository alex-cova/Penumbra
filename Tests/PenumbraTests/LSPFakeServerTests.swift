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
        guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
              let method = object["method"] as? String else { return }
        lock.lock()
        seen.append(method)
        lock.unlock()
        guard let id = object["id"], !(id is NSNull) else { return }
        let body = Self.response(id: id, method: method)
        var framed = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        framed.append(body)
        try? output.write(contentsOf: framed)
    }

    private static func response(id: Any, method: String) -> Data {
        let result: Any
        switch method {
        case "initialize":
            result = [
                "capabilities": [
                    "completionProvider": ["resolveProvider": true, "triggerCharacters": ["."]],
                    "definitionProvider": false,
                    "renameProvider": true,
                    "callHierarchyProvider": true,
                    "typeHierarchyProvider": true
                ]
            ] as [String: Any]
        case "textDocument/completion":
            result = [["label": "Box", "insertText": "Box"]]
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
