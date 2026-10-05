import AppKit
import XCTest
@testable import Penumbra
@testable import Umbra

@MainActor
final class IDEChangeMarkerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "umbra.change-markers.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func changes(head: String?, buffer: String, maximumMiddle: Int = IDEChangeMarkerPresentation.maximumMiddleLineCount) -> [GutterChange] {
        IDEChangeMarkerPresentation.changes(head: head.map { Data($0.utf8) }, buffer: buffer, maximumMiddle: maximumMiddle)
    }

    func testAddedModifiedAndDeletedLines() {
        XCTAssertEqual(changes(head: "a\nb\nc", buffer: "a\nX\nb\nc"), [GutterChange(line: 2, lineCount: 1, kind: .added)])
        XCTAssertEqual(changes(head: "a\nb\nc", buffer: "a\nB\nc"), [GutterChange(line: 2, lineCount: 1, kind: .modified)])
        XCTAssertEqual(
            changes(head: "a\nb\nc", buffer: "a\nc"),
            [GutterChange(line: 2, lineCount: 0, kind: .deleted, deletedLineCount: 1)]
        )
        XCTAssertEqual(changes(head: "a\nb\nc\n", buffer: "a\nB\nc\nd\n"), [
            GutterChange(line: 2, lineCount: 1, kind: .modified),
            GutterChange(line: 4, lineCount: 1, kind: .added),
        ])
    }

    func testIdenticalTextsAndAMissingHead() {
        XCTAssertTrue(changes(head: "a\nb", buffer: "a\nb").isEmpty)
        XCTAssertTrue(IDEChangeMarkerPresentation.changes(head: Data(), buffer: "").isEmpty)
        XCTAssertEqual(changes(head: nil, buffer: "a\nb"), [GutterChange(line: 1, lineCount: 2, kind: .added)])
        XCTAssertEqual(
            IDEChangeMarkerPresentation.changes(head: Data(), buffer: "a"),
            [GutterChange(line: 1, lineCount: 1, kind: .modified)]
        )
    }

    func testADeletionAtTheEndOfTheFileAndBeforeASharedTrailingLine() {
        XCTAssertEqual(
            changes(head: "a\nb\nc", buffer: "a\nb"),
            [GutterChange(line: 3, lineCount: 0, kind: .deleted, deletedLineCount: 1)]
        )
        XCTAssertEqual(
            changes(head: "a\nb\nc\n", buffer: "a\nb\n"),
            [GutterChange(line: 3, lineCount: 0, kind: .deleted, deletedLineCount: 1)]
        )
    }

    func testALongDifferingMiddleIsOneSpanAndABinaryFileDrawsNothing() {
        let head = (["a"] + (0 ..< 5).map { "L\($0)" } + ["z"]).joined(separator: "\n")
        let buffer = (["a"] + (0 ..< 5).map { "R\($0)" } + ["z"]).joined(separator: "\n")
        XCTAssertEqual(
            changes(head: head, buffer: buffer, maximumMiddle: 2),
            [GutterChange(line: 2, lineCount: 5, kind: .modified)]
        )
        XCTAssertTrue(changes(head: "a", buffer: "a\u{0}b").isEmpty)
        XCTAssertTrue(IDEChangeMarkerPresentation.changes(head: Data([0x61, 0x00]), buffer: "ab").isEmpty)
    }

    func testTheStripeIsOnUntilTurnedOffAndHiddenOutsideARepository() {
        let controller = IDEChangeMarkerController(defaults: defaults)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertNil(defaults.object(forKey: IDEChangeMarkerController.defaultsKey))

        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        textView.showsGutterChangeStripe = true
        textView.setGutterChanges([GutterChange(line: 1, lineCount: 2, kind: .added)])
        controller.refresh(
            textView: textView,
            url: URL(fileURLWithPath: "/tmp/File.java"),
            git: IDEGitStatusModel(),
            force: true,
            delay: .zero
        )
        XCTAssertFalse(textView.showsGutterChangeStripe)
        XCTAssertTrue(textView.gutterChanges.isEmpty)

        controller.toggle()
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(defaults.bool(forKey: IDEChangeMarkerController.defaultsKey), false)
        let restored = IDEChangeMarkerController(defaults: defaults)
        XCTAssertFalse(restored.isEnabled)

        textView.showsGutterChangeStripe = true
        restored.refresh(textView: textView, url: URL(fileURLWithPath: "/tmp/File.java"), git: IDEGitStatusModel(), force: true, delay: .zero)
        XCTAssertFalse(textView.showsGutterChangeStripe)
    }
}
