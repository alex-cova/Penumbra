import XCTest
import EditorIntelligence

final class LSPWorkspaceSyncBridgeTests: XCTestCase {
    func testDocumentLifecycleHandlersFire() async {
        let opened = LockedBox<Document>()
        let changed = LockedBox<Document>()
        let closed = LockedBox<DocumentID>()

        let barrier = HandlerBarrier(expected: 3)

        let handlers = LSPDocumentSyncHandlers(
            onOpen: { document, languageID, version in
                XCTAssertEqual(languageID, "swift")
                XCTAssertEqual(version, 1)
                opened.value = document
                await barrier.signal()
            },
            onFullChange: { document, version in
                XCTAssertEqual(version, 2)
                changed.value = document
                await barrier.signal()
            },
            onClose: { documentID in
                closed.value = documentID
                await barrier.signal()
            }
        )

        let bridge = LSPWorkspaceSyncBridge(
            handlers: handlers,
            languageResolver: { _ in "swift" }
        )
        let workspace = Workspace()
        await bridge.connect(to: workspace)

        let document = makeDocument(text: "let a = 1")
        async let handlersComplete = barrier.wait()
        await workspace.openDocument(document)
        await workspace.updateDocument(
            Document(
                id: document.id,
                url: document.url,
                displayName: document.displayName,
                contentSnapshot: TextSnapshot(version: 1, text: "let a = 2"),
                selection: document.selection,
                cursor: document.cursor,
                viewport: document.viewport,
                languageIdentifier: document.languageIdentifier
            )
        )
        await workspace.closeDocument(document.id)
        await handlersComplete

        XCTAssertEqual(opened.value?.contentSnapshot.text, "let a = 1")
        if let changedDocument = changed.value {
            XCTAssertEqual(changedDocument.contentSnapshot.text, "let a = 2")
        } else {
            XCTFail("Expected document change handler")
        }
        XCTAssertEqual(closed.value, document.id)
    }

    func testRangedEditUsesIncrementalSyncInsteadOfFullChange() async {
        let incremental = LockedBox<[LSPDocumentSyncService.DocumentChange]>()
        let fullChanges = LockedBox<Int>(0)
        let barrier = HandlerBarrier(expected: 2)

        let handlers = LSPDocumentSyncHandlers(
            onIncrementalChanges: { changes in
                incremental.value = changes
                await barrier.signal()
            },
            onOpen: { _, _, _ in
                await barrier.signal()
            },
            onFullChange: { _, _ in
                fullChanges.value = (fullChanges.value ?? 0) + 1
            }
        )

        let bridge = LSPWorkspaceSyncBridge(
            handlers: handlers,
            batchInterval: 0.05,
            languageResolver: { _ in "swift" }
        )
        let workspace = Workspace()
        await bridge.connect(to: workspace)

        let document = makeDocument(text: "let a = 1")
        async let handlersComplete = barrier.wait()
        await workspace.openDocument(document)

        let start = TextPosition(line: 0, column: 8, utf16Offset: 8)
        let end = TextPosition(line: 0, column: 9, utf16Offset: 9)
        let edit = TextEdit(range: TextRange(start: start, end: end), replacement: "2")
        await workspace.handleEditorEvent(
            .documentEdited(
                document.id,
                [edit],
                newSnapshot: TextSnapshot(version: 1, text: "let a = 2")
            )
        )
        await handlersComplete

        XCTAssertEqual(fullChanges.value, 0)
        let changes = incremental.value ?? []
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.text, "2")
        XCTAssertEqual(changes.first?.range.start.character, 8)
        XCTAssertEqual(changes.first?.range.end.character, 9)
        XCTAssertEqual(changes.first?.rangeLength, 1)
        XCTAssertEqual(changes.first?.version, 2)
    }

    func testElidedDocumentStillOpens() async {
        let opened = LockedBox<Document>()
        let barrier = HandlerBarrier(expected: 1)
        let handlers = LSPDocumentSyncHandlers(
            onOpen: { document, _, _ in
                opened.value = document
                await barrier.signal()
            }
        )
        let bridge = LSPWorkspaceSyncBridge(handlers: handlers, languageResolver: { _ in "swift" })
        let workspace = Workspace()
        await bridge.connect(to: workspace)

        let text = "elided body"
        let utf16Length = (text as NSString).length
        let reader = TextRangeReader(utf16Length: utf16Length) { offset, length in
            (text as NSString).substring(with: NSRange(location: offset, length: min(length, utf16Length - offset)))
        }
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let range = TextRange(start: position, end: position)
        let document = Document(
            id: DocumentID(),
            url: nil,
            displayName: "big.swift",
            contentSnapshot: TextSnapshot(version: 0, utf16Length: utf16Length, text: nil, rangeReader: reader),
            selection: Selection(range: range),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "swift"
        )
        XCTAssertTrue(document.contentSnapshot.isElided)

        async let handlersComplete = barrier.wait()
        await workspace.openDocument(document)
        await handlersComplete

        XCTAssertEqual(opened.value?.displayName, "big.swift")
        XCTAssertTrue(opened.value?.contentSnapshot.isElided ?? false)
        XCTAssertEqual(opened.value?.substring(utf16Offset: 0, length: 6), "elided")
    }
}

private actor HandlerBarrier {
    private let expected: Int
    private var received = 0
    private var waiter: CheckedContinuation<Void, Never>?

    init(expected: Int) {
        self.expected = expected
    }

    func signal() {
        received += 1
        if received >= expected, let waiter {
            waiter.resume()
            self.waiter = nil
        }
    }

    func wait() async {
        if received >= expected {
            return
        }
        await withCheckedContinuation { continuation in
            if received >= expected {
                continuation.resume()
            } else {
                waiter = continuation
            }
        }
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    var value: T?

    init(_ value: T? = nil) {
        self.value = value
    }
}

private func makeDocument(text: String) -> Document {
    let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
    let range = TextRange(start: position, end: position)
    return Document(
        id: DocumentID(),
        url: nil,
        displayName: "test.swift",
        contentSnapshot: TextSnapshot(version: 0, text: text),
        selection: Selection(range: range),
        cursor: Cursor(position: position),
        viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
        languageIdentifier: "swift"
    )
}
