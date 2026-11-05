import EditorIntelligence
import Penumbra
import XCTest
@testable import Umbra

/// The text view delegate does not name a language. A pause asks that language's service (F-10).
@MainActor
final class IDELanguageSettleTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        var requests: [BufferSettleRequest] = []
        private let lock = NSLock()
        func add(_ request: BufferSettleRequest) {
            lock.lock()
            requests.append(request)
            lock.unlock()
        }
        func snapshot() -> [BufferSettleRequest] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }
    }

    private struct RecordingService: LanguageService {
        let name = "recording"
        let languageIdentifiers: Set<String> = ["toy"]
        let providers = LanguageProviders()
        let box: Box
        func bufferDidSettle(_ request: BufferSettleRequest) async -> [TextEdit] {
            box.add(request)
            return []
        }
    }

    private func waitFor(_ message: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), message)
    }

    func testAPauseAsksOnlyTheLanguageThatClaimsTheBuffer() async {
        let box = Box()
        let languages = LanguageServiceRegistry(services: [RecordingService(box: box)])
        let settle = DocumentSettleCoordinator()
        let languageSettle = IDELanguageSettle()
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        textView.languageIdentifier = "toy"
        textView.text = "alpha"
        textView.selectedRange = NSRange(location: 5, length: 0)
        let here = TextLocation(lineNumber: 0, column: 0)
        languageSettle.noteContentChange(TextContentChange(
            range: NSRange(location: 0, length: 0), replacementText: "nope", start: here, oldEnd: here
        ))

        languageSettle.schedule(for: textView, delay: .milliseconds(20), settle: settle, languages: languages)
        await waitFor("the service was not asked") { !box.snapshot().isEmpty }
        let request = box.snapshot()[0]
        XCTAssertEqual(request.text, "alpha")
        XCTAssertEqual(request.caretUTF16, 5)
        XCTAssertNil(request.pastedText, "a replacement that is not the pasteboard is not a paste")
        XCTAssertFalse(request.suppressEdits)

        let other = TextView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        other.languageIdentifier = "plain"
        other.text = "beta"
        languageSettle.schedule(for: other, delay: .milliseconds(20), settle: settle, languages: languages)
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(box.snapshot().count, 1, "a language nobody claimed was still asked")
    }

    func testOpeningAFileDoesNotProposeEdits() async {
        let box = Box()
        let languages = LanguageServiceRegistry(services: [RecordingService(box: box)])
        let settle = DocumentSettleCoordinator()
        let languageSettle = IDELanguageSettle()
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        textView.languageIdentifier = "toy"
        textView.text = "opened"
        languageSettle.schedule(
            for: textView, delay: .zero, settle: settle, languages: languages, proposesEdits: false
        )
        await waitFor("the service was not asked") { !box.snapshot().isEmpty }
        XCTAssertTrue(box.snapshot()[0].suppressEdits)
        XCTAssertEqual(box.snapshot()[0].text, "opened")
    }
}
