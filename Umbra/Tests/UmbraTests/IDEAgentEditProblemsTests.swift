import EditorIntelligence
import Foundation
import XCTest
@testable import Umbra

@MainActor
final class IDEAgentEditProblemsTests: XCTestCase {
    private let file = URL(fileURLWithPath: "/tmp/project/src/Main.java")

    private func diagnostic(_ message: String, line: Int = 0, severity: DiagnosticSeverity = .error, source: String = "java") -> Diagnostic {
        let position = TextPosition(line: line, column: 0, utf16Offset: 0)
        return Diagnostic(severity: severity, message: message, range: TextRange(start: position, end: position), source: source)
    }

    // MARK: - Store

    func testAReportAfterTheAgentsEditIsTheOneThatCounts() {
        let store = IDEProblemsStore()
        store.setEditorDiagnostics([], for: file)
        XCTAssertTrue(store.hasEditorReportSinceAgentEdit(for: file), "a file the agent never changed is reported")

        store.noteAgentEdit(of: file)
        XCTAssertFalse(store.hasEditorReportSinceAgentEdit(for: file), "the last report describes the text before the edit")
        store.setEditorDiagnostics([diagnostic("broken")], for: file)
        XCTAssertTrue(store.hasEditorReportSinceAgentEdit(for: file))

        store.noteAgentEdit(of: file)
        XCTAssertFalse(store.hasEditorReportSinceAgentEdit(for: file), "a second edit starts waiting again")
    }

    func testOnlyCurrentErrorsAreListedInLineOrder() {
        let store = IDEProblemsStore()
        store.setEditorDiagnostics([
            diagnostic("late", line: 9), diagnostic("early", line: 2), diagnostic("just a warning", severity: .warning),
        ], for: file)
        store.setInspectionDiagnostics([diagnostic("inspection error", line: 5, source: "java-inspection")], for: file)
        store.setBuildDiagnostics([file: [diagnostic("old build error", source: "gradle")]], source: IDEProblemsStore.gradleBuildSource)

        XCTAssertEqual(store.currentErrors(for: file).map(\.message), ["early", "inspection error", "late"])
    }

    func testRowsFromASourceWithOnlyOlderTextAreLeftOut() {
        let store = IDEProblemsStore()
        store.setEditorDiagnostics([diagnostic("from the old text", source: "javac"), diagnostic("syntax", line: 1, source: "java")], for: file)
        store.setStaleSources(["javac"], for: file)
        XCTAssertEqual(store.currentErrors(for: file).map(\.message), ["syntax"])
    }

    // MARK: - Note

    func testTheNoteListsAFewErrorsAndCountsTheRest() throws {
        let rows = (1...8).map { IDEAgentEditProblems.Row(path: "src/A.java", line: $0, message: "error \($0)") }
        let note = try XCTUnwrap(IDEAgentEditProblems.note(errors: rows, analysed: true))
        XCTAssertTrue(note.hasPrefix("[Editor] 8 errors in the files you just changed"))
        XCTAssertTrue(note.contains("src/A.java:1: error 1"))
        XCTAssertTrue(note.contains("src/A.java:5: error 5"))
        XCTAssertFalse(note.contains("error 6"))
        XCTAssertTrue(note.hasSuffix("… and 3 more."))
    }

    func testOneErrorIsSingularAndALongMessageIsCut() throws {
        let long = String(repeating: "x", count: 400)
        let note = try XCTUnwrap(IDEAgentEditProblems.note(errors: [.init(path: "a", line: 1, message: long + "\nsecond line")], analysed: true))
        XCTAssertTrue(note.contains("1 error in"))
        XCTAssertFalse(note.contains("second line"))
        XCTAssertTrue(note.contains(String(repeating: "x", count: 200) + "…"))
    }

    func testNothingIsSaidWithoutErrorsOrBeforeTheEditorHasAnalysedTheNewText() {
        XCTAssertNil(IDEAgentEditProblems.note(errors: [], analysed: true))
        XCTAssertNil(IDEAgentEditProblems.note(errors: [.init(path: "a", line: 1, message: "old")], analysed: false))
    }

    // MARK: - Waiting

    func testWaitReturnsAsSoonAsTheConditionHolds() async {
        var checks = 0
        let started = Date()
        let held = await IDEAgentEditProblems.wait(timeout: 5, interval: .milliseconds(10)) {
            checks += 1
            return checks >= 3
        }
        XCTAssertTrue(held)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testWaitGivesUpAtTheTimeout() async {
        let started = Date()
        let held = await IDEAgentEditProblems.wait(timeout: 0.15, interval: .milliseconds(10)) { false }
        XCTAssertFalse(held)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.14)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }
}
