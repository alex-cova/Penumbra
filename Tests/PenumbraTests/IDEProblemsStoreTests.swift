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
