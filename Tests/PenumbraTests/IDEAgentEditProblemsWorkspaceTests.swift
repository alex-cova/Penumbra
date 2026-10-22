import AgentKit
import AppKit
import EditorIntelligence
import Foundation
import XCTest
@testable import Umbra

/// The window's side of "problems after an edit": the agent changes an open file, the editor's next
/// report arrives, and the note names the errors in it.
@MainActor
final class IDEAgentEditProblemsWorkspaceTests: XCTestCase {
    private var directory: URL!
    private var workspace: IDEWorkspace!

    override func setUp() async throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("editproblems-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        workspace = IDEWorkspace()
        workspace.bootstrap()
        workspace.openProjectFolder(directory)
    }

    override func tearDown() async throws {
        workspace?.teardown()
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: directory)
    }

    private func diagnostic(_ message: String, line: Int) -> Diagnostic {
        let position = TextPosition(line: line, column: 0, utf16Offset: 0)
        return Diagnostic(severity: .error, message: message, range: TextRange(start: position, end: position), source: "java")
    }

    private func openFile(_ name: String, _ text: String) async throws -> URL {
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        await workspace.openDocument(from: url)
        let deadline = Date().addingTimeInterval(5)
        while workspace.agentOpenFilePaths().isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        return url.standardizedFileURL
    }

    /// Opening a file starts the editor's own analysis; let it land so it cannot answer in the middle of a test.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(400))
    }

    func testTheNoteWaitsForTheEditorsReportOnTheNewTextThenNamesTheErrors() async throws {
        let url = try await openFile("A.txt", "one\n")
        try await settle()
        workspace.problems.setEditorDiagnostics([], for: url)   // the editor has analysed this file before
        workspace.problems.noteAgentEdit(of: url)               // what the agent's write does first

        // The editor answers a moment later.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            self.workspace.problems.setEditorDiagnostics([self.diagnostic("cannot find symbol", line: 0)], for: url)
        }
        let started = Date()
        let note = await workspace.agentProblemsAfterEdit(relativePaths: ["A.txt"], timeout: 3)
        XCTAssertEqual(note?.contains("A.txt:1: cannot find symbol"), true, note ?? "nil")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.2, "it waited for the new report")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testAnOldReportIsNotPassedOffAsTheNewTextsAndATimeoutSaysNothing() async throws {
        let url = try await openFile("B.txt", "one\n")
        try await settle()
        workspace.problems.setEditorDiagnostics([diagnostic("error from before the edit", line: 0)], for: url)
        workspace.problems.noteAgentEdit(of: url)

        let started = Date()
        let note = await workspace.agentProblemsAfterEdit(relativePaths: ["B.txt"], timeout: 0.3)
        XCTAssertNil(note, "the only report describes the text before the edit")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.25, "it did wait")
    }

    func testTheAgentsWritesRecordWhatTheEditorHadReportedSoFar() async throws {
        let url = try await openFile("D.txt", "one\n")
        try await settle()
        workspace.problems.setEditorDiagnostics([], for: url)
        XCTAssertTrue(workspace.problems.hasEditorReportSinceAgentEdit(for: url))

        try await workspace.agentReplaceText(
            relativePath: "D.txt", expecting: "one\n", edits: [AgentTextEdit(location: 0, length: 3, replacement: "two")])
        // The write marked the file; the editor's own analysis of the new text then brings the answer.
        let deadline = Date().addingTimeInterval(5)
        while !workspace.problems.hasEditorReportSinceAgentEdit(for: url), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(workspace.problems.hasEditorReportSinceAgentEdit(for: url), "the editor reported on the new text")

        let created = directory.appendingPathComponent("New.txt").standardizedFileURL
        try await workspace.agentCreateFile(relativePath: "New.txt", contents: "x")
        XCTAssertFalse(workspace.problems.hasEditorReportSinceAgentEdit(for: created) && workspace.problems.hasEditorReport(for: created) == false,
                       "a created file is marked too")
    }

    func testAFileTheEditorNeverAnalysedDoesNotMakeTheRunWait() async throws {
        _ = try await openFile("C.txt", "one\n")
        try await settle()
        let started = Date()
        let note = await workspace.agentProblemsAfterEdit(relativePaths: ["C.txt"], timeout: 3)
        XCTAssertNil(note)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    func testAClosedFileHasNothingToReport() async {
        let note = await workspace.agentProblemsAfterEdit(relativePaths: ["Nowhere.txt"], timeout: 1)
        XCTAssertNil(note)
    }
}
