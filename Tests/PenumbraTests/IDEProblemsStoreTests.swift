import EditorIntelligence
import Foundation
import XCTest
@testable import Umbra

@MainActor
final class IDEProblemsStoreTests: XCTestCase {
    private let file = URL(fileURLWithPath: "/tmp/project/Sources/App/main.swift")
    private let other = URL(fileURLWithPath: "/tmp/project/src/Main.java")

    private func diagnostic(_ message: String, source: String) -> Diagnostic {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Diagnostic(severity: .error, message: message, range: TextRange(start: position, end: position), source: source)
    }

    func testEachBuildSourceKeepsItsOwnProblems() {
        let store = IDEProblemsStore()
        store.setBuildDiagnostics([other: [diagnostic("gradle error", source: "gradle")]], source: IDEProblemsStore.gradleBuildSource)
        store.setBuildDiagnostics([file: [diagnostic("swift error", source: "swiftpm")]], source: IDEProblemsStore.swiftPMBuildSource)
        XCTAssertEqual(store.buildDiagnostics.keys.count, 2)
        XCTAssertEqual(store.errorCount, 2)

        // A later SwiftPM run replaces only SwiftPM's bucket.
        store.setBuildDiagnostics([:], source: IDEProblemsStore.swiftPMBuildSource)
        XCTAssertEqual(store.buildDiagnostics.keys.map(\.path), [other.standardizedFileURL.path])
        XCTAssertEqual(store.errorCount, 1)
    }

    func testAPublicationReplacesOneSourceForOneFile() {
        let store = IDEProblemsStore()
        store.publish(DiagnosticPublication(source: .javac, url: other, diagnostics: [diagnostic("old", source: "javac")]))
        store.publish(DiagnosticPublication(source: .swiftPM, url: file, diagnostics: [diagnostic("swift", source: "swiftpm")]))
        store.publish(DiagnosticPublication(source: .javac, url: other, diagnostics: [diagnostic("new", source: "javac")]))
        XCTAssertEqual(store.compilerDiagnostics[other.standardizedFileURL]?.map(\.message), ["new"])
        XCTAssertEqual(store.buildDiagnostics[file.standardizedFileURL]?.map(\.message), ["swift"])
        store.publish(DiagnosticPublication(source: .javac, url: other, diagnostics: []))
        XCTAssertNil(store.compilerDiagnostics[other.standardizedFileURL])
        XCTAssertEqual(store.errorCount, 1)
    }

    func testStaleSourcesSuperposeWithoutTouchingRows() {
        let store = IDEProblemsStore()
        store.setEditorDiagnostics([diagnostic("editor problem", source: "editor")], for: other)
        store.publish(DiagnosticPublication(source: .javac, url: other, diagnostics: [diagnostic("old error", source: "javac")]))
        XCTAssertEqual(store.staleSources(for: other), [])

        // A stale javac report flags the source; the rows and the badge counts don't move.
        store.setStaleSources(["javac"], for: other)
        XCTAssertEqual(store.staleSources(for: other), ["javac"])
        XCTAssertEqual(store.compilerDiagnostics[other.standardizedFileURL]?.map(\.message), ["old error"])
        XCTAssertEqual(store.errorCount, 2)

        // Fresh results clear the flag without touching the rows.
        store.setStaleSources([], for: other)
        XCTAssertEqual(store.staleSources(for: other), [])
        XCTAssertEqual(store.compilerDiagnostics[other.standardizedFileURL]?.count, 1)
    }

    func testStaleFlagsSurviveUnrelatedWritesAndClearWithTheFile() {
        let store = IDEProblemsStore()
        store.publish(DiagnosticPublication(source: .javac, url: other, diagnostics: [diagnostic("old error", source: "javac")]))
        store.setStaleSources(["javac"], for: other)

        // An unrelated bucket write leaves the flags alone.
        store.publish(DiagnosticPublication(source: .swiftPM, url: file, diagnostics: [diagnostic("swift", source: "swiftpm")]))
        XCTAssertEqual(store.staleSources(for: other), ["javac"])

        // Closing the file clears its flags; flags alone keep the store non-empty
        // without contributing to the badge counts.
        store.clearEditorDiagnostics(for: other)
        XCTAssertEqual(store.staleSources(for: other), [])

        let pending = IDEProblemsStore()
        pending.setStaleSources(["javac"], for: other)
        XCTAssertFalse(pending.isEmpty)
        XCTAssertEqual(pending.errorCount, 0)
    }

    func testEditorReportTrackingDistinguishesCleanFromNotYetAnalyzed() {
        let store = IDEProblemsStore()
        XCTAssertFalse(store.hasEditorReport(for: other))
        XCTAssertFalse(store.hasEditorReport(for: file))

        // Service publications alone don't count: only the editor refresh says the
        // file's current text has been analysed.
        store.publish(DiagnosticPublication(source: .javac, url: other, diagnostics: [diagnostic("old error", source: "javac")]))
        XCTAssertFalse(store.hasEditorReport(for: other))

        // An empty report still counts: the file was analysed and is clean.
        store.setEditorDiagnostics([], for: other)
        XCTAssertTrue(store.hasEditorReport(for: other))
        XCTAssertFalse(store.hasEditorReport(for: file))

        // Closing the file forgets the report.
        store.clearEditorDiagnostics(for: other)
        XCTAssertFalse(store.hasEditorReport(for: other))
    }

    func testClearingAFileDropsItFromEverySource() {
        let store = IDEProblemsStore()
        store.setBuildDiagnostics([file: [diagnostic("a", source: "gradle")]], source: IDEProblemsStore.gradleBuildSource)
        store.setBuildDiagnostics(
            [file: [diagnostic("b", source: "swiftpm")], other: [diagnostic("c", source: "swiftpm")]],
            source: IDEProblemsStore.swiftPMBuildSource
        )
        XCTAssertEqual(store.buildDiagnostics[file.standardizedFileURL]?.count, 2)
        store.clearBuildDiagnostics(for: file)
        XCTAssertNil(store.buildDiagnostics[file.standardizedFileURL])
        XCTAssertNotNil(store.buildDiagnostics[other.standardizedFileURL])
        store.clearBuildDiagnostics()
        XCTAssertTrue(store.isEmpty)
    }
}
