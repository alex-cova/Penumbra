import AppKit
import Foundation
import Penumbra
import XCTest
@testable import Umbra

/// The pure side of Actions on Save: which rows changed, which spaces go, where a line break is added.
final class IDESaveActionsTests: XCTestCase {
    private func apply(_ replacements: [IDESaveActions.Replacement], to text: String) -> String {
        var result = text as NSString
        for replacement in replacements.sorted(by: { $0.range.location > $1.range.location }) {
            result = result.replacingCharacters(in: replacement.range, with: replacement.text) as NSString
        }
        return result as String
    }

    // MARK: Changed rows

    func testAChangedLineIsTheOnlyChangedRow() {
        let rows = IDESaveActions.changedRows(base: "a\nb\nc\n", current: "a\nB\nc\n")
        XCTAssertEqual(rows, [1])
    }

    func testInsertedLinesAreChangedAndAFollowingLineIsNot() {
        let rows = IDESaveActions.changedRows(base: "a\nc\n", current: "a\nx\ny\nc\n")
        XCTAssertEqual(rows, [1, 2])
    }

    func testADeletedLineChangesNoRowOfTheNewText() {
        XCTAssertEqual(IDESaveActions.changedRows(base: "a\nb\nc\n", current: "a\nc\n"), [])
    }

    func testAnUnchangedFileHasNoChangedRows() {
        XCTAssertTrue(IDESaveActions.changedRows(base: "same\n", current: "same\n").isEmpty)
    }

    func testANewFileChangesEveryRow() {
        XCTAssertEqual(IDESaveActions.changedRows(base: nil, current: "a\nb\n"), [0, 1, 2])
    }

    func testRowsAreMergedIntoRangesOfTheirContent() {
        let text = "aa\nbb\ncc\ndd\nee\n"
        let ranges = IDESaveActions.ranges(ofRows: [0, 1, 3], in: text)
        XCTAssertEqual(ranges, [NSRange(location: 0, length: 5), NSRange(location: 9, length: 2)])
        XCTAssertEqual((text as NSString).substring(with: ranges[0]), "aa\nbb")
    }

    func testTheRowOfAnOffsetIncludesTheEndOfItsLine() {
        let lines = IDEDiffText("ab\ncd\n").lines
        XCTAssertEqual(IDESaveActions.row(containing: 0, in: lines), 0)
        XCTAssertEqual(IDESaveActions.row(containing: 2, in: lines), 0, "the end of a line belongs to it")
        XCTAssertEqual(IDESaveActions.row(containing: 3, in: lines), 1)
        XCTAssertEqual(IDESaveActions.row(containing: 6, in: lines), 2, "after the last line break is the empty last row")
    }

    // MARK: Trailing whitespace

    func testAllRowsLoseTheirTrailingSpacesAndTabs() {
        let text = "a  \nb\t\n  c  \n"
        let result = apply(IDESaveActions.trailingWhitespaceReplacements(in: text, rows: nil), to: text)
        XCTAssertEqual(result, "a\nb\n  c\n", "leading spaces stay")
    }

    func testOnlyTheGivenRowsAreStripped() {
        let text = "a  \nb  \nc  \n"
        let result = apply(IDESaveActions.trailingWhitespaceReplacements(in: text, rows: [1]), to: text)
        XCTAssertEqual(result, "a  \nb\nc  \n")
    }

    func testTheKeptRowKeepsItsSpaces() {
        let text = "a  \nb  \n"
        let result = apply(IDESaveActions.trailingWhitespaceReplacements(in: text, rows: nil, keepingRows: [1]), to: text)
        XCTAssertEqual(result, "a\nb  \n")
    }

    func testACarriageReturnIsALineBreakNotWhitespace() {
        let text = "a  \r\nb\r\n"
        let result = apply(IDESaveActions.trailingWhitespaceReplacements(in: text, rows: nil), to: text)
        XCTAssertEqual(result, "a\r\nb\r\n")
    }

    func testTheLastLineWithoutABreakIsStripped() {
        let text = "a\nb   "
        let result = apply(IDESaveActions.trailingWhitespaceReplacements(in: text, rows: nil), to: text)
        XCTAssertEqual(result, "a\nb")
    }

    func testAWhitespaceOnlyLineBecomesEmpty() {
        let text = "a\n    \nb\n"
        let result = apply(IDESaveActions.trailingWhitespaceReplacements(in: text, rows: nil), to: text)
        XCTAssertEqual(result, "a\n\nb\n")
    }

    func testNothingToStripIsNoReplacement() {
        XCTAssertTrue(IDESaveActions.trailingWhitespaceReplacements(in: "a\nb\n", rows: nil).isEmpty)
    }

    // MARK: Final newline

    func testAMissingFinalNewlineIsAdded() throws {
        let replacement = try XCTUnwrap(IDESaveActions.finalNewlineReplacement(in: "a\nb"))
        XCTAssertEqual(apply([replacement], to: "a\nb"), "a\nb\n")
    }

    func testTheFilesOwnLineBreakStyleIsUsed() throws {
        let replacement = try XCTUnwrap(IDESaveActions.finalNewlineReplacement(in: "a\r\nb"))
        XCTAssertEqual(apply([replacement], to: "a\r\nb"), "a\r\nb\r\n")
    }

    func testAFileThatEndsWithABreakIsLeftAlone() {
        XCTAssertNil(IDESaveActions.finalNewlineReplacement(in: "a\n"))
        XCTAssertNil(IDESaveActions.finalNewlineReplacement(in: "a\r\n"))
        XCTAssertNil(IDESaveActions.finalNewlineReplacement(in: "a\r"))
    }

    func testAnEmptyFileStaysEmpty() {
        XCTAssertNil(IDESaveActions.finalNewlineReplacement(in: ""))
    }

    func testTheEndingSpacesAndTheMissingBreakAreFixedTogether() throws {
        let text = "a\nb   "
        var replacements = IDESaveActions.trailingWhitespaceReplacements(in: text, rows: nil)
        replacements.append(try XCTUnwrap(IDESaveActions.finalNewlineReplacement(in: text)))
        XCTAssertEqual(apply(replacements, to: text), "a\nb\n")
    }
}

/// The pipeline in a real workspace: the order, the scope, the languages and reasons it skips.
@MainActor
final class IDESaveActionsWorkspaceTests: XCTestCase {
    private var directory: URL!
    private var workspace: IDEWorkspace!
    private var saved: [(String, Any)] = []

    override func setUp() async throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        let p = IDEPreferences.shared
        saved = [
            ("reformatOnSave", p.reformatOnSave), ("whole", p.reformatsWholeFileOnSave), ("cleanup", p.codeCleanupOnSave),
            ("strip", p.stripTrailingWhitespaceOnSave), ("caret", p.keepsTrailingWhitespaceOnCaretLine),
            ("newline", p.ensureNewlineAtEndOfFile), ("imports", p.javaOptimizeImportsOnSave)
        ]
        p.reformatOnSave = false
        p.reformatsWholeFileOnSave = false
        p.codeCleanupOnSave = false
        p.stripTrailingWhitespaceOnSave = .off
        p.keepsTrailingWhitespaceOnCaretLine = true
        p.ensureNewlineAtEndOfFile = false
        p.javaOptimizeImportsOnSave = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("saveactions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        workspace = IDEWorkspace()
        workspace.bootstrap()
    }

    override func tearDown() async throws {
        workspace?.teardown()
        let p = IDEPreferences.shared
        for (key, value) in saved {
            switch key {
            case "reformatOnSave": p.reformatOnSave = value as! Bool
            case "whole": p.reformatsWholeFileOnSave = value as! Bool
            case "cleanup": p.codeCleanupOnSave = value as! Bool
            case "strip": p.stripTrailingWhitespaceOnSave = value as! IDEStripWhitespaceScope
            case "caret": p.keepsTrailingWhitespaceOnCaretLine = value as! Bool
            case "newline": p.ensureNewlineAtEndOfFile = value as! Bool
            default: p.javaOptimizeImportsOnSave = value as! Bool
            }
        }
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ name: String, _ text: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func open(_ url: URL) async throws -> (WorkbenchDocument, IDEEditorPaneHost) {
        await workspace.openDocument(from: url)
        let document = try XCTUnwrap(workspace.workbench.activePane.selectedDocument)
        let host = workspace.host(for: workspace.workbench.activePaneID)
        let deadline = Date().addingTimeInterval(5)
        while host.textView.text != (try? String(contentsOf: url, encoding: .utf8)), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(200))
        return (document, host)
    }

    private func edit(_ document: WorkbenchDocument, in host: IDEEditorPaneHost, to text: String) {
        host.textView.text = text
        document.isDirty = true
    }

    func testEveryLineIsStrippedAndTheFinalBreakAddedOnASave() async throws {
        IDEPreferences.shared.stripTrailingWhitespaceOnSave = .allLines
        IDEPreferences.shared.keepsTrailingWhitespaceOnCaretLine = false
        IDEPreferences.shared.ensureNewlineAtEndOfFile = true
        let url = try write("a.txt", "x\n")
        let (document, host) = try await open(url)
        edit(document, in: host, to: "one  \ntwo\t\nthree  ")
        host.textView.selectedRange = NSRange(location: 0, length: 0)

        let saved = await workspace.saveActiveDocument()

        XCTAssertTrue(saved)
        XCTAssertEqual(try read(url), "one\ntwo\nthree\n")
        XCTAssertEqual(host.textView.text, "one\ntwo\nthree\n", "the buffer shows what was written")
        XCTAssertFalse(document.isDirty)
        XCTAssertTrue(host.textView.undoManager?.canUndo ?? false, "the cleanup is an undo step")
    }

    func testOnlyTheLinesChangedSinceTheFileWasOnDiskAreStripped() async throws {
        IDEPreferences.shared.stripTrailingWhitespaceOnSave = .modifiedLines
        let url = try write("b.txt", "old  \nkeep\n")
        let (document, host) = try await open(url)
        edit(document, in: host, to: "old  \nkeep  \nnew  \n")
        host.textView.selectedRange = NSRange(location: 0, length: 0)

        _ = await workspace.saveActiveDocument()

        XCTAssertEqual(try read(url), "old  \nkeep\nnew\n", "the line that already had spaces on disk is not a modified line")
    }

    func testTheCaretLineKeepsItsSpaces() async throws {
        IDEPreferences.shared.stripTrailingWhitespaceOnSave = .allLines
        let url = try write("c.txt", "x\n")
        let (document, host) = try await open(url)
        edit(document, in: host, to: "a  \nb  \n")
        host.textView.selectedRange = NSRange(location: 6, length: 0)

        _ = await workspace.saveActiveDocument()

        XCTAssertEqual(try read(url), "a\nb  \n")
    }

    func testMarkdownKeepsItsTrailingSpaces() async throws {
        IDEPreferences.shared.stripTrailingWhitespaceOnSave = .allLines
        let url = try write("d.md", "x\n")
        let (document, host) = try await open(url)
        edit(document, in: host, to: "line  \nnext\n")
        host.textView.selectedRange = NSRange(location: 0, length: 0)

        _ = await workspace.saveActiveDocument()

        XCTAssertEqual(try read(url), "line  \nnext\n")
    }

    func testASaveOnTheWayOutLeavesTheTextAlone() async throws {
        IDEPreferences.shared.stripTrailingWhitespaceOnSave = .allLines
        IDEPreferences.shared.ensureNewlineAtEndOfFile = true
        let url = try write("e.txt", "x\n")
        let (document, host) = try await open(url)
        edit(document, in: host, to: "spaced  ")

        let outcome = await workspace.saveDocument(document, reason: .closingWindow)

        XCTAssertEqual(outcome, .saved)
        XCTAssertEqual(try read(url), "spaced  ")
    }

    func testTheAgentsSaveLeavesItsTextAlone() async throws {
        IDEPreferences.shared.stripTrailingWhitespaceOnSave = .allLines
        let url = try write("f.txt", "x\n")
        let (document, host) = try await open(url)
        edit(document, in: host, to: "agent  \n")

        _ = await workspace.saveDocument(document, reason: .agent)

        XCTAssertEqual(try read(url), "agent  \n")
    }

    func testAnAutosaveRunsTheActionsToo() async throws {
        IDEPreferences.shared.stripTrailingWhitespaceOnSave = .allLines
        IDEPreferences.shared.keepsTrailingWhitespaceOnCaretLine = false
        let url = try write("g.txt", "x\n")
        let (document, host) = try await open(url)
        edit(document, in: host, to: "idle  \nmore  \n")
        host.textView.selectedRange = NSRange(location: 0, length: 0)

        await workspace.autosaveAll(reason: .autosaveIdle)

        XCTAssertEqual(try read(url), "idle\nmore\n")
    }

    func testAJavaFileIsReformattedOnSaveWhenAsked() async throws {
        IDEPreferences.shared.reformatOnSave = true
        IDEPreferences.shared.reformatsWholeFileOnSave = true
        let original = "class A {\nint x;\n}\n"
        let url = try write("A.java", original)
        let (document, host) = try await open(url)
        edit(document, in: host, to: original + "// edited\n")

        _ = await workspace.saveActiveDocument()

        let written = try read(url)
        XCTAssertNotEqual(written, original + "// edited\n", "the formatter never ran")
        XCTAssertTrue(written.contains("\n    int x;") || written.contains("\n\tint x;") || written.contains("\n  int x;"), written)
    }

    func testTheNewSettingsSurviveASnapshotRoundTripAndOlderFilesGetTheDefaults() throws {
        let preferences = IDEPreferences.shared
        let previous = preferences.stripTrailingWhitespaceOnSave
        defer { preferences.stripTrailingWhitespaceOnSave = previous }
        preferences.stripTrailingWhitespaceOnSave = .allLines

        let data = try JSONEncoder().encode(preferences.snapshot())
        let decoded = try JSONDecoder().decode(IDEPreferencesSnapshot.self, from: data)
        XCTAssertEqual(decoded.stripTrailingWhitespaceOnSave, .allLines)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["stripTrailingWhitespaceOnSave", "reformatOnSave", "ensureNewlineAtEndOfFile", "keepsTrailingWhitespaceOnCaretLine"] {
            object.removeValue(forKey: key)
        }
        let older = try JSONDecoder().decode(IDEPreferencesSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(older.stripTrailingWhitespaceOnSave, .modifiedLines)
        XCTAssertFalse(older.reformatOnSave)
        XCTAssertFalse(older.ensureNewlineAtEndOfFile)
        XCTAssertTrue(older.keepsTrailingWhitespaceOnCaretLine)
    }
}
