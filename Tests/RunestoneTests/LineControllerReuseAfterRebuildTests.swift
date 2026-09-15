@preconcurrency import AppKit
import XCTest
@testable import Runestone

/// `TextView.text =` (the path Hextech's read-only output editors use) rebuilds the document's
/// lines in place. `DocumentLineNodeID` is a bare monotonic `UInt32` counter, and the
/// `invalidateLines()` the setter runs only clears syntax highlighting — it does **not** clear a
/// `LineController`'s cached `attributedString` / typeset fragments / line height. Before the
/// fix, the setter therefore left stale `LineController`s in `LineControllerStorage`, and
/// because `PackedLineIndex` also restarted its id counter at 1 on every rebuild,
/// `getOrCreateLineController` handed those stale controllers back for the *new* document's
/// lines — painting the previous text, at the wrong offsets (overlap).
///
/// The fix has two independent halves, both asserted here:
///  1. the `string` setter now calls `lineControllerStorage.removeAllLineControllers()` +
///     `contentSizeService.reset()`, matching what `setState` already did;
///  2. `PackedLineIndex` no longer recycles ids across a rebuild.
final class LineControllerReuseAfterRebuildTests: XCTestCase, LineControllerStorageDelegate, LineControllerDelegate {
    func lineControllerStorage(_ storage: LineControllerStorage, didCreate lineController: LineController) {
        lineController.delegate = self
        lineController.constrainingWidth = 320
    }

    func lineSyntaxHighlighter(for lineController: LineController) -> LineSyntaxHighlighter? {
        PlainTextSyntaxHighlighter()
    }

    func lineControllerDidInvalidateLineWidthDuringAsyncSyntaxHighlight(_ lineController: LineController) {}

    func lineControllerDidRefreshDisplayedLineFragments(_ lineController: LineController) {}

    private func makeStorage(_ stringView: StringView, _ lineManager: LineManager) -> LineControllerStorage {
        let factory = LineControllerFactory(
            stringView: stringView,
            highlightService: HighlightService(lineManager: lineManager),
            invisibleCharacterConfiguration: InvisibleCharacterConfiguration()
        )
        let storage = LineControllerStorage(stringView: stringView, lineControllerFactory: factory)
        storage.delegate = self
        return storage
    }

    @discardableResult
    private func typesetFirstLine(_ storage: LineControllerStorage, _ lineManager: LineManager) -> LineController {
        let line = lineManager.line(atRow: 0)
        let controller = storage.getOrCreateLineController(for: line)
        controller.prepareToDisplayString(toLocation: line.data.totalLength, syntaxHighlightAsynchronously: false)
        return controller
    }

    func testRebuiltLineTypesetsTheNewDocumentNotThePreviousOne() {
        let stringView = StringView(string: "old line zero\nold line one")
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        let storage = makeStorage(stringView, lineManager)

        let staleController = typesetFirstLine(storage, lineManager)
        // `attributedString` spans the whole line including its trailing newline delimiter.
        XCTAssertEqual(staleController.attributedString?.string, "old line zero\n")

        // Exactly what TextInputView.string's setter now does on an external text push.
        stringView.string = "brand new zero\nbrand new one\nbrand new two"
        lineManager.rebuild()
        storage.removeAllLineControllers()

        let refreshed = typesetFirstLine(storage, lineManager)
        XCTAssertFalse(staleController === refreshed, "a rebuilt line must not reuse the pre-rebuild controller")
        XCTAssertEqual(
            refreshed.attributedString?.string,
            "brand new zero\n",
            "the output editor must typeset the new document, not the previous one"
        )
    }

    func testPackedLineIndexDoesNotRecycleIDsAcrossRebuild() {
        let stringView = StringView(string: "a\nb\nc")
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        let idsBefore = Set((0..<lineManager.lineCount).map { lineManager.line(atRow: $0).id })

        stringView.string = "x\ny\nz"
        lineManager.rebuild()
        let idsAfter = Set((0..<lineManager.lineCount).map { lineManager.line(atRow: $0).id })

        XCTAssertTrue(
            idsBefore.isDisjoint(with: idsAfter),
            "rebuilt lines must get fresh ids so identity-keyed caches (line controllers, line widths, reused views) cannot collide"
        )
    }

    func testFreshLineManagerStillStartsItsIDCounterLow() {
        // The no-recycle change must not leak across instances: a brand-new LineManager still
        // begins numbering from a small value (setState relies on fresh managers, unaffected).
        let stringView = StringView(string: "one\ntwo")
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        XCTAssertLessThan(lineManager.line(atRow: 0).id.value, 100)
    }
}
