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

    // MARK: - Rollback

    func testRollbackPutsAModifiedBlockBack() throws {
        let head = Data("a\nb\nc\n".utf8)
        let edit = try XCTUnwrap(IDEChangeMarkerPresentation.rollback(head: head, buffer: "a\nB\nc\n", caretLine: 1))
        XCTAssertEqual(edit.replacement, "b\n")
        XCTAssertEqual(edit.currentText, "B\n")
        var text = "a\nB\nc\n" as NSString
        text = text.replacingCharacters(in: edit.range, with: edit.replacement) as NSString
        XCTAssertEqual(text as String, "a\nb\nc\n")
    }

    func testRollbackRemovesAnAddedBlockAndRestoresADeletedOne() throws {
        let added = try XCTUnwrap(IDEChangeMarkerPresentation.rollback(
            head: Data("a\nc\n".utf8), buffer: "a\nnew\nc\n", caretLine: 1))
        XCTAssertEqual(added.replacement, "")
        XCTAssertEqual(added.currentText, "new\n")

        let deleted = try XCTUnwrap(IDEChangeMarkerPresentation.rollback(
            head: Data("a\nb\nc\n".utf8), buffer: "a\nc\n", caretLine: 1))
        XCTAssertEqual(deleted.range.length, 0)
        XCTAssertEqual(deleted.replacement, "b\n")
    }

    func testRollbackNeedsTheCaretInAChangeAndACommittedVersion() {
        let head = Data("a\nb\nc\n".utf8)
        XCTAssertNil(IDEChangeMarkerPresentation.rollback(head: head, buffer: "a\nB\nc\n", caretLine: 0))
        XCTAssertNil(IDEChangeMarkerPresentation.rollback(head: nil, buffer: "a\n", caretLine: 0), "a new file has nothing to go back to")
        XCTAssertNil(IDEChangeMarkerPresentation.rollback(head: Data([0, 1, 2]), buffer: "x", caretLine: 0))
    }

    func testRollbackAfterALastLineWithoutABreakAddsOne() throws {
        let edit = try XCTUnwrap(IDEChangeMarkerPresentation.rollback(
            head: Data("a\nb\n".utf8), buffer: "a", caretLine: 1))
        var text = "a" as NSString
        text = text.replacingCharacters(in: edit.range, with: edit.replacement) as NSString
        XCTAssertEqual(text as String, "a\nb\n")
    }

    // MARK: - HEAD blob cache bounds

    func testHeadCacheStaysWithinTheEntryCap() {
        let controller = IDEChangeMarkerController(defaults: defaults)
        for i in 0 ..< IDEChangeMarkerController.maxHeadCacheEntries + 20 {
            controller.cacheHead(relativePath: "src/File\(i).java", data: Data("x".utf8))
        }
        XCTAssertEqual(controller.headCacheEntryCount, IDEChangeMarkerController.maxHeadCacheEntries)
        XCTAssertNil(controller.cachedHeadData(for: "src/File0.java"), "oldest entries go first")
        XCTAssertNotNil(controller.cachedHeadData(for: "src/File\(IDEChangeMarkerController.maxHeadCacheEntries + 19).java"))
    }

    func testHeadCacheStaysWithinTheByteCap() {
        let controller = IDEChangeMarkerController(defaults: defaults)
        let blob = Data(repeating: 0x61, count: 1024 * 1024)
        let inserted = IDEChangeMarkerController.maxHeadCacheBytes / blob.count + 4
        for i in 0 ..< inserted {
            controller.cacheHead(relativePath: "src/Big\(i).java", data: blob)
        }
        XCTAssertLessThanOrEqual(controller.headCacheByteCount, IDEChangeMarkerController.maxHeadCacheBytes)
        XCTAssertLessThanOrEqual(controller.headCacheEntryCount, IDEChangeMarkerController.maxHeadCacheEntries)
        XCTAssertNil(controller.cachedHeadData(for: "src/Big0.java"), "byte pressure evicts the oldest first")
    }

    func testHeadCacheReplacesAnEntryWithoutDoubleCounting() {
        let controller = IDEChangeMarkerController(defaults: defaults)
        controller.cacheHead(relativePath: "src/A.java", data: Data("aaa".utf8))
        controller.cacheHead(relativePath: "src/A.java", data: Data("bb".utf8))
        XCTAssertEqual(controller.headCacheEntryCount, 1)
        XCTAssertEqual(controller.headCacheByteCount, 2)
        XCTAssertEqual(controller.cachedHeadData(for: "src/A.java"), .some(Data("bb".utf8)))
    }

    func testInvalidateHeadCacheResetsByteAccounting() {
        let controller = IDEChangeMarkerController(defaults: defaults)
        controller.cacheHead(relativePath: "src/A.java", data: Data("aaa".utf8))
        controller.invalidateHeadCache()
        XCTAssertEqual(controller.headCacheEntryCount, 0)
        XCTAssertEqual(controller.headCacheByteCount, 0)
        controller.cacheHead(relativePath: "src/B.java", data: Data("bb".utf8))
        XCTAssertEqual(controller.headCacheByteCount, 2)
    }

    func testAnOverCapSingleBlobStaysCached() {
        let controller = IDEChangeMarkerController(defaults: defaults)
        let blob = Data(repeating: 0x61, count: IDEChangeMarkerController.maxHeadCacheBytes + 1)
        controller.cacheHead(relativePath: "src/Huge.java", data: blob)
        XCTAssertNotNil(
            controller.cachedHeadData(for: "src/Huge.java"),
            "evicting the just-stored blob would re-read it from git on every refresh"
        )
        XCTAssertEqual(controller.headCacheEntryCount, 1)
    }

    func testMissingHeadEntriesDoNotConsumeTheByteBudget() {
        let controller = IDEChangeMarkerController(defaults: defaults)
        for i in 0 ..< 10 {
            controller.cacheHead(relativePath: "src/New\(i).java", data: nil)
        }
        XCTAssertEqual(controller.headCacheEntryCount, 10)
        XCTAssertEqual(controller.headCacheByteCount, 0)
    }
}

