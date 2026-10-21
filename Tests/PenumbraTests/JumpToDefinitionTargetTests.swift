import AppKit
import XCTest
import EditorIntelligence
@testable import Penumbra

/// A folder or package location has no text to select, so ⌘-click hands it to the host and leaves
/// the caret alone; a source location still moves the selection.
@MainActor
final class JumpToDefinitionTargetTests: XCTestCase {
    private struct FixedProvider: NavigationProvider {
        let name = "Fixed"
        let location: Location

        func provide(context: NavigationContext) async -> NavigationResult? { .single(location) }
        func isPrimary(for context: NavigationContext) -> Bool { true }
    }

    private func makeLocation(target: Location.Target, utf16Offset: Int = 4) -> Location {
        let start = TextPosition(line: 0, column: utf16Offset, utf16Offset: utf16Offset)
        let end = TextPosition(line: 0, column: utf16Offset + 3, utf16Offset: utf16Offset + 3)
        return Location(
            documentID: DocumentID(), url: URL(fileURLWithPath: "/tmp/model"),
            range: TextRange(start: start, end: end), displayName: "model", target: target
        )
    }

    private func jump(to location: Location) async throws -> (selection: NSRange, opened: [Location]) {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.text = "import com.acme.model.Dog;"
        let adapter = PenumbraEditorAdapter(textView: textView, context: EditorContext())
        try await Task.sleep(nanoseconds: 100_000_000)
        textView.selectedRange = NSRange(location: 1, length: 0)
        let controller = JumpToDefinitionController(
            textView: textView, adapter: adapter, navigationEngine: NavigationEngine(providers: [FixedProvider(location: location)])
        )
        var opened: [Location] = []
        controller.onOpenInOtherDocument = { opened.append($0); return true }
        controller.jumpToDefinition(at: TextPosition(line: 0, column: 12, utf16Offset: 12))
        try await Task.sleep(nanoseconds: 300_000_000)
        return (textView.selectedRange, opened)
    }

    func testDirectoryTargetGoesToTheHostAndKeepsTheCaret() async throws {
        let location = makeLocation(target: .directory)
        let result = try await jump(to: location)
        XCTAssertEqual(result.selection, NSRange(location: 1, length: 0))
        XCTAssertEqual(result.opened.map(\.id), [location.id])
    }

    func testPackageTargetGoesToTheHostAndKeepsTheCaret() async throws {
        let location = makeLocation(target: .package("java.util"))
        let result = try await jump(to: location)
        XCTAssertEqual(result.selection, NSRange(location: 1, length: 0))
        XCTAssertEqual(result.opened.first?.target, .package("java.util"))
    }

    func testSourceTargetStillSelectsItsRange() async throws {
        // The same document: no `url` difference to hand to the host, so the range is selected.
        var location = makeLocation(target: .source, utf16Offset: 7)
        location = Location(
            documentID: location.documentID, url: nil, range: location.range, displayName: "acme", target: .source
        )
        let result = try await jump(to: location)
        XCTAssertEqual(result.selection, NSRange(location: 7, length: 3))
        XCTAssertTrue(result.opened.isEmpty)
    }

    // MARK: - Reusing the hover

    private final class CountingProvider: NavigationProvider, @unchecked Sendable {
        let name = "Counting"
        private let lock = NSLock()
        private var count = 0
        let location: Location
        init(location: Location) { self.location = location }
        var calls: Int { lock.withLock { count } }
        func provide(context: NavigationContext) async -> NavigationResult? {
            lock.withLock { count += 1 }
            return .single(location)
        }
        func isPrimary(for context: NavigationContext) -> Bool { true }
    }

    func testAHoverResultIsServedToAClickOnTheSameWordUntilTheTextChanges() async throws {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.text = "import com.acme.model.Dog;"
        let adapter = PenumbraEditorAdapter(textView: textView, context: EditorContext())
        try await Task.sleep(nanoseconds: 100_000_000)
        let provider = CountingProvider(location: makeLocation(target: .source))
        let controller = JumpToDefinitionController(
            textView: textView, adapter: adapter, navigationEngine: NavigationEngine(providers: [provider])
        )
        let word = NSRange(location: 22, length: 3)

        XCTAssertNil(controller.cachedHoverResult(for: word), "nothing was hovered yet")
        await controller.resolveHover(at: TextPosition(line: 0, column: 22, utf16Offset: 22), identifier: word)
        XCTAssertEqual(provider.calls, 1)
        XCTAssertNotNil(controller.cachedHoverResult(for: word))
        XCTAssertNil(controller.cachedHoverResult(for: NSRange(location: 15, length: 5)), "another word was not hovered")

        textView.selectedRange = NSRange(location: 22, length: 0)
        textView.insertText("X")
        XCTAssertNil(controller.cachedHoverResult(for: word), "an edit makes the answer stale")
    }

    // MARK: - Not copying the buffer on the main thread

    private final class TextRecordingProvider: NavigationProvider, @unchecked Sendable {
        let name = "Recording"
        private let lock = NSLock()
        private var texts: [String] = []
        let location: Location
        init(location: Location) { self.location = location }
        var seen: [String] { lock.withLock { texts } }
        func provide(context: NavigationContext) async -> NavigationResult? {
            lock.withLock { texts.append(context.document.contentSnapshot.text ?? "<elided>") }
            return .single(location)
        }
        func isPrimary(for context: NavigationContext) -> Bool { true }
    }

    func testHoverAndClickOnALargeBufferDoNotMaterializeItOnTheMainThread() async throws {
        let line = String(repeating: "value ", count: 40) + "\n"
        let text = String(repeating: line, count: 1_200) + "target"
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.text = text
        XCTAssertNotNil(textView.pieceTreeContentSnapshot(), "the test needs a piece-tree buffer")
        let adapter = PenumbraEditorAdapter(textView: textView, context: EditorContext())
        try await Task.sleep(nanoseconds: 100_000_000)
        let target = makeLocation(target: .source, utf16Offset: 7)
        let provider = TextRecordingProvider(location: Location(
            documentID: target.documentID, url: nil, range: target.range, displayName: "target", target: .source
        ))
        let controller = JumpToDefinitionController(
            textView: textView, adapter: adapter, navigationEngine: NavigationEngine(providers: [provider])
        )
        let word = NSRange(location: (text as NSString).length - 6, length: 6)
        let before = textView.pieceTreeMaterializeCount

        await controller.resolveHover(at: TextPosition(line: 1_200, column: 2, utf16Offset: word.location + 2), identifier: word)
        controller.jumpToDefinition(at: TextPosition(line: 1_200, column: 2, utf16Offset: word.location + 2))
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(textView.selectedRange, NSRange(location: 7, length: 3), "the click still jumps")
        XCTAssertEqual(textView.pieceTreeMaterializeCount, before, "the string was built on the main thread")
        XCTAssertEqual(provider.seen.count, 2)
        XCTAssertTrue(provider.seen.allSatisfy { $0 == text }, "providers still get the full text")
        _ = textView.text
        XCTAssertGreaterThan(textView.pieceTreeMaterializeCount, before, "the probe must see a main-thread copy")
    }

    // MARK: - Finding the identifier under the pointer

    func testIdentifierIsFoundFromAWindowAroundThePointer() throws {
        let name = String(repeating: "abc_", count: 150) // 600 units: longer than the first window
        let text = String(repeating: "padding padding\n", count: 400) + "x = \(name) + 12abc;\n" + String(repeating: "tail\n", count: 400)
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.text = text
        let adapter = PenumbraEditorAdapter(textView: textView, context: EditorContext())
        let controller = JumpToDefinitionController(
            textView: textView, adapter: adapter, navigationEngine: NavigationEngine(providers: [])
        )
        let start = (text as NSString).range(of: name).location
        let expected = NSRange(location: start, length: (name as NSString).length)
        for index in [start, start + 1, start + 300, expected.upperBound - 1] {
            XCTAssertEqual(controller.identifierRange(at: index, in: textView), expected, "index \(index)")
        }
        XCTAssertNil(controller.identifierRange(at: expected.upperBound, in: textView), "a space is not an identifier")
        let digits = (text as NSString).range(of: "12abc")
        XCTAssertNil(controller.identifierRange(at: digits.location + 3, in: textView), "a name cannot start with a digit")
        XCTAssertNil(controller.identifierRange(at: -1, in: textView))
        XCTAssertNil(controller.identifierRange(at: (text as NSString).length, in: textView))

        textView.text = "word"
        XCTAssertEqual(controller.identifierRange(at: 0, in: textView), NSRange(location: 0, length: 4))
        XCTAssertEqual(controller.identifierRange(at: 3, in: textView), NSRange(location: 0, length: 4))
    }
}
