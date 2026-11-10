import AppKit
import XCTest
@_spi(Benchmarks) @testable import Penumbra

/// `TextView.materializedText` turns the buffer into a string once per generation for everything
/// that asks once typing pauses, off the main actor (F-07).
@MainActor
final class MaterializedTextTests: XCTestCase {
    private func makeView(_ text: String) -> TextView {
        let view = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.setState(TextViewState(text: text))
        return view
    }

    /// Past the size where the buffer is a piece tree, so exporting it is a real copy.
    private var large: String {
        String(repeating: "value = compute(items) // padding padding padding\n", count: 6_000)
    }

    func testTheTextAndItsGenerationAreReturned() async throws {
        let view = makeView(large)

        let materialized = await view.materializedText()
        let snapshot = try XCTUnwrap(materialized)

        XCTAssertEqual(snapshot.text, large)
        XCTAssertEqual(snapshot.generation, view.contentGeneration)
    }

    func testConcurrentAndLaterCallersForOneGenerationShareOneBuild() async throws {
        let view = makeView(large)
        let before = DocumentTextExport.materializedExportCount

        let first = Task { @MainActor in await view.materializedText() }
        let second = Task { @MainActor in await view.materializedText() }
        let third = Task { @MainActor in await view.materializedText() }
        let all = await [first.value, second.value, third.value]
        let later = await view.materializedText()

        XCTAssertEqual(DocumentTextExport.materializedExportCount - before, 1, "the buffer was turned into a string more than once")
        XCTAssertTrue(all.allSatisfy { $0?.text == large })
        XCTAssertEqual(later?.text, large)
    }

    func testAnEditMakesTheNextCallBuildAgain() async throws {
        let view = makeView(large)
        _ = await view.materializedText()
        let before = DocumentTextExport.materializedExportCount

        view.replace(NSRange(location: 0, length: 0), withText: "edited ")
        let materialized = await view.materializedText()
        let snapshot = try XCTUnwrap(materialized)

        XCTAssertEqual(DocumentTextExport.materializedExportCount - before, 1)
        XCTAssertTrue(snapshot.text.hasPrefix("edited value"))
        XCTAssertEqual(snapshot.generation, view.contentGeneration)
    }

    /// `setState` can put another file's text in the view, whose generation counts from zero again.
    func testReplacingTheTextWithSetStateNeverAnswersWithTheOldText() async throws {
        let view = makeView(large)
        _ = await view.materializedText()

        view.setState(TextViewState(text: String(repeating: "other file line\n", count: 20_000)))
        let materialized = await view.materializedText()
        let snapshot = try XCTUnwrap(materialized)

        XCTAssertTrue(snapshot.text.hasPrefix("other file line"), "answered with the previous file's text")
    }

    /// The text is built on a background thread from a snapshot while the main thread keeps editing
    /// the same buffer. The snapshot must be unaffected by those edits (and the thread sanitizer
    /// must see no race: the repo's rule after touching shared background data).
    func testMaterializingWhileTheMainThreadKeepsEditing() async throws {
        let view = makeView(large)
        for round in 0..<40 {
            let expected = view.text
            let reader = Task { @MainActor in await view.materializedText() }
            await Task.yield()
            for index in 0..<25 {
                view.replace(NSRange(location: (round + index) % 500, length: 0), withText: "y")
            }
            let materialized = await reader.value
            let snapshot = try XCTUnwrap(materialized)
            XCTAssertEqual(snapshot.text, expected, "round \(round): the text did not match the buffer it was taken from")
        }
    }

    func testASmallBufferAlsoWorks() async throws {
        let view = makeView("small")

        let materialized = await view.materializedText()
        let snapshot = try XCTUnwrap(materialized)

        XCTAssertEqual(snapshot.text, "small")
    }
}
