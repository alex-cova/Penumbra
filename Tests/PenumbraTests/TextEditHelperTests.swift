import XCTest
@testable import Penumbra

final class TextEditHelperTests: XCTestCase {
    private func makeHelper(text: String) -> (TextEditHelper, StringView) {
        let stringView = StringView(string: text)
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        let helper = TextEditHelper(stringView: stringView, lineManager: lineManager, lineEndings: .lf)
        return (helper, stringView)
    }

    private func documentText(_ stringView: StringView) -> String {
        stringView.substring(in: NSRange(location: 0, length: stringView.length)) ?? ""
    }

    func testReplaceTextClampsOutOfBoundsRangeOnEmptyDocument() {
        let (helper, stringView) = makeHelper(text: "")
        _ = helper.replaceText(in: NSRange(location: 0, length: 1), with: "")
        XCTAssertEqual(stringView.length, 0)
    }

    func testApplyProducesTheSameStringAsStringByApplying() {
        let (helper, stringView) = makeHelper(text: "aaa bbb ccc")
        let batch = BatchReplaceSet(replacements: [
            .init(range: NSRange(location: 0, length: 3), text: "X"),
            .init(range: NSRange(location: 8, length: 3), text: "YY")
        ])
        _ = helper.apply(batch)
        XCTAssertEqual(documentText(stringView), "X bbb YY")

        let (stringHelper, _) = makeHelper(text: "aaa bbb ccc")
        XCTAssertEqual(stringHelper.string(byApplying: batch) as String, "X bbb YY")
    }

    /// This is the case that makes computing the inverse non-trivial: two replacements whose
    /// lengths differ from what they replace, so the second replacement's position in the
    /// resulting string has shifted relative to its original range.
    func testInverseReplacementsRestoreTheOriginalStringWhenLengthsDiffer() {
        let original = "aaa bbb ccc"
        let (helper, stringView) = makeHelper(text: original)
        let batch = BatchReplaceSet(replacements: [
            .init(range: NSRange(location: 0, length: 3), text: "X"),   // shrinks by 2
            .init(range: NSRange(location: 8, length: 3), text: "YY")   // shrinks by 1
        ])
        let application = helper.apply(batch)
        let replaced = documentText(stringView)
        XCTAssertEqual(replaced, "X bbb YY")

        // Applying the inverse to a fresh helper seeded with the *new* string should restore the
        // original — exactly what undo does by feeding `inverseReplacements` back through
        // `replaceText(in:)`.
        let (undoHelper, _) = makeHelper(text: replaced)
        let restored = undoHelper.string(byApplying: BatchReplaceSet(replacements: application.inverseReplacements))
        XCTAssertEqual(restored as String, original)
    }

    func testInverseReplacementsRestoreTheOriginalStringWhenReplacementGrows() {
        let original = "a b c"
        let (helper, stringView) = makeHelper(text: original)
        let batch = BatchReplaceSet(replacements: [
            .init(range: NSRange(location: 0, length: 1), text: "AAA"), // grows by 2
            .init(range: NSRange(location: 4, length: 1), text: "C")    // same length
        ])
        let application = helper.apply(batch)
        let replaced = documentText(stringView)
        XCTAssertEqual(replaced, "AAA b C")

        let (undoHelper, _) = makeHelper(text: replaced)
        let restored = undoHelper.string(byApplying: BatchReplaceSet(replacements: application.inverseReplacements))
        XCTAssertEqual(restored as String, original)
    }

    func testInverseReplacementsAreDeltaSizedNotDocumentSized() {
        // A long document with only two small edits — the inverse should carry just the two old
        // fragments, not a copy of the whole document (PERFORMANCE_AUDIT.md Phase 2 #7).
        let original = String(repeating: "x", count: 10_000) + "NEEDLE" + String(repeating: "y", count: 10_000)
        let (helper, _) = makeHelper(text: original)
        let batch = BatchReplaceSet(replacements: [
            .init(range: NSRange(location: 10_000, length: 6), text: "FOUND")
        ])
        let application = helper.apply(batch)
        XCTAssertEqual(application.inverseReplacements.count, 1)
        XCTAssertEqual(application.inverseReplacements.first?.text, "NEEDLE")
        XCTAssertLessThan(application.inverseReplacements.first?.text.utf16.count ?? .max, 100)
    }

    func testOverlappingReplacementsKeepOnlyTheFirstAndItsInverseStillRoundTrips() {
        let original = "abcdef"
        let (helper, stringView) = makeHelper(text: original)
        let batch = BatchReplaceSet(replacements: [
            .init(range: NSRange(location: 0, length: 3), text: "XYZ"),
            .init(range: NSRange(location: 2, length: 3), text: "OVERLAP") // overlaps the first, should be dropped
        ])
        let application = helper.apply(batch)
        let replaced = documentText(stringView)
        XCTAssertEqual(replaced, "XYZdef")

        let (undoHelper, _) = makeHelper(text: replaced)
        let restored = undoHelper.string(byApplying: BatchReplaceSet(replacements: application.inverseReplacements))
        XCTAssertEqual(restored as String, original)
    }

    func testFileBackedApplyDoesNotMaterialize() async throws {
        let original = "aaa bbb ccc"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try original.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        let state = try await TextViewState.load(contentsOf: url)
        XCTAssertTrue(state.stringView.isFileBacked)
        let helper = TextEditHelper(
            stringView: state.stringView,
            lineManager: state.lineManager,
            lineEndings: .lf
        )
        let before = state.stringView.materializeCount
        let batch = BatchReplaceSet(replacements: [
            .init(range: NSRange(location: 0, length: 3), text: "X"),
            .init(range: NSRange(location: 8, length: 3), text: "YY")
        ])
        let application = helper.apply(batch)
        XCTAssertEqual(documentText(state.stringView), "X bbb YY")
        XCTAssertEqual(state.stringView.materializeCount, before)
        XCTAssertEqual(state.stringView.materializeCount, 0)
        XCTAssertEqual(application.inverseReplacements.count, 2)

        let (undoHelper, undoView) = makeHelper(text: documentText(state.stringView))
        _ = undoHelper.apply(BatchReplaceSet(replacements: application.inverseReplacements))
        XCTAssertEqual(documentText(undoView), original)
    }
}
