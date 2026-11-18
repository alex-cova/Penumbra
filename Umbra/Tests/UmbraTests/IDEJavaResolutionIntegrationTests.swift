import AppKit
import EditorIntelligence
import Foundation
@testable import JavaIntelligence
import XCTest
@testable import Umbra

/// The real window: `IDEWorkspace` opens a folder, `IDEJavaSupport` indexes the installed JDK and
/// the folder, publishes the sources, and the inspection results reach the Problems store through
/// `onInspectionDiagnostics`. Every inspection publication is recorded, so a transient false
/// "Cannot resolve type 'String'" during indexing fails the test even if it is later replaced.
///
/// Needs an installed JDK (skipped otherwise). Waits poll for the condition the app must reach;
/// they are not part of what is being tested.
@MainActor
final class IDEJavaResolutionIntegrationTests: XCTestCase {
    private var directory: URL!
    private var workspaces: [IDEWorkspace] = []

    override func setUp() async throws {
        try XCTSkipIf(JDKLocator().select() == nil, "needs an installed JDK")
        IDEWorkspace.isSessionPersistenceEnabled = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("java-int-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("src/app"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for workspace in workspaces { workspace.teardown() }
        workspaces = []
        IDEWorkspace.isSessionPersistenceEnabled = true
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - Helpers

    /// Every inspection publication, per file name, in arrival order.
    private final class Recorder {
        var publications: [String: [[String]]] = [:]
        func record(_ url: URL, _ diagnostics: [Diagnostic]) {
            publications[url.lastPathComponent, default: []].append(
                diagnostics.filter { $0.code?.hasPrefix("unresolved-") == true }.map(\.message).sorted()
            )
        }
        func everything(for name: String) -> [String] { (publications[name] ?? []).flatMap { $0 } }
    }

    private func write(_ relative: String, _ text: String, in root: URL? = nil) throws -> URL {
        let url = (root ?? directory).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeWorkspace(_ recorder: Recorder) -> IDEWorkspace {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        let original = workspace.javaSupport.onInspectionDiagnostics
        workspace.javaSupport.onInspectionDiagnostics = { url, diagnostics in
            recorder.record(url, diagnostics)
            original?(url, diagnostics)
        }
        workspaces.append(workspace)
        return workspace
    }

    private func quiet(_ workspace: IDEWorkspace) async -> [String] {
        var all: [String] = []
        for document in workspace.openJavaDocuments() {
            guard let url = document.url else { continue }
            all += await workspace.javaSupport.inspectionService.quietFindings(for: url).map(\.message)
        }
        return all
    }

    private func pendingFlags(_ workspace: IDEWorkspace) async -> [Bool] {
        var flags: [Bool] = []
        for document in workspace.openJavaDocuments() {
            guard let url = document.url else { continue }
            flags.append(await workspace.javaSupport.inspectionService.isResolutionPending(for: url))
        }
        return flags
    }

    /// What the window's Java state is, for a wait that gave up.
    private func dump(_ workspace: IDEWorkspace, _ recorder: Recorder) async -> String {
        let index = workspace.javaSupport.javaIndex
        let service = workspace.javaSupport.inspectionService
        return "platform=\(await index.hasPlatformClasses) complete=\(await index.classpathComplete) "
            + "sourcesVersion=\(await index.sourcesVersion) canProve=\(await index.canProveAbsence) "
            + "passes=\(await service.completedPasses) cancelled=\(await service.cancelledPasses) straddled=\(await service.straddledPasses) "
            + "openJava=\(workspace.openJavaDocuments().map { $0.url?.lastPathComponent ?? "?" }) "
            + "pending=\(await pendingFlags(workspace)) "
            + "profileDisabled=\(await service.currentProfile.disabled.filter { $0.hasPrefix("unresolved") }) "
            + "severities=\(await service.currentProfile.severities.filter { $0.key.hasPrefix("unresolved") }) "
            + "quiet=\(await quiet(workspace)) jdkMissing=\(await index.classes(simpleName: "Missing").map(\.qualifiedName)) "
            + "jdkGizmoPkg=\(await index.hasPackage("com.fake")) "
            + "published=\(recorder.publications) rows=\(workspace.problems.inspectionDiagnostics.mapValues { $0.map(\.message) })"
    }

    private func rows(_ workspace: IDEWorkspace, _ name: String) -> [String] {
        // Only the missing-class findings: the other rules (unused fields, …) are not under test.
        workspace.problems.inspectionDiagnostics.first { $0.key.lastPathComponent == name }?.value
            .filter { $0.code?.hasPrefix("unresolved-") == true }.map(\.message).sorted() ?? []
    }

    private func eventually(_ message: String, seconds: Double = 40, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(condition(), message)
    }

    private static let main = """
    package app;

    import java.util.List;
    import java.util.Map;
    import com.fake.Gizmo;

    public class Main {
        private String name;
        private List<String> names;
        private Map<String, Object> values;
        private Helper helper;
        private Missing missing;
    }
    """

    private static let expectedMain = [
        "Cannot resolve import 'com.fake.Gizmo'",
        "Cannot resolve type 'Missing'",
    ]

    /// Valid JDK and project types must never be reported missing, at any point.
    private func assertNoFalsePositives(_ recorder: Recorder, file: StaticString = #filePath, line: UInt = #line) {
        let all = recorder.everything(for: "Main.java")
        for valid in ["'String'", "'List'", "'Map'", "'Object'", "'Helper'", "'java.util.List'", "'java.util.Map'"] {
            XCTAssertFalse(all.contains { $0.contains(valid) }, "published a false \(valid): \(all)", file: file, line: line)
        }
    }

    // MARK: - Project opening, indexing, publication

    func testOpeningAProjectReportsOnlyGenuineMisses() async throws {
        let main = try write("src/app/Main.java", Self.main)
        _ = try write("src/app/Helper.java", "package app;\npublic class Helper { }\n")
        let recorder = Recorder()
        let workspace = makeWorkspace(recorder)
        workspace.openProjectFolder(directory)
        await workspace.openDocument(from: main)

        await eventually("Main.java never got its genuine findings") { rows(workspace, "Main.java") == Self.expectedMain }
        if rows(workspace, "Main.java") != Self.expectedMain {
            print("STATE \(await dump(workspace, recorder))")
            var options = JavaBatchInspector.Options(profile: .standard())
            options.onlyRules = [.unresolvedType, .unresolvedImport]
            let source = Self.main
            let batch = await JavaBatchInspector(index: workspace.javaSupport.javaIndex).inspect(url: main, options: options) { _ in source }
            print("BATCH \(batch.map(\.message))")
            let doc = try XCTUnwrap(workspace.openJavaDocuments().first)
            print("DOCTEXT elided=\(doc.contentSnapshot.isElided) length=\(doc.text.count) full=\(JavaNavigationText.fullText(of: doc).count) lang=\(doc.languageIdentifier) dep=\(doc.isDependencySource)")
        }
        assertNoFalsePositives(recorder)
        let pending = await workspace.javaSupport.inspectionService.isResolutionPending(for: main.standardizedFileURL)
        XCTAssertFalse(pending, "the index is authoritative once the JDK and the folder are in")
    }

    // MARK: - Unsaved edits and tab switching

    func testUnsavedEditsAndTabSwitchesKeepFindingsCurrent() async throws {
        let main = try write("src/app/Main.java", Self.main)
        let helper = try write("src/app/Helper.java", "package app;\npublic class Helper { }\n")
        let recorder = Recorder()
        let workspace = makeWorkspace(recorder)
        workspace.openProjectFolder(directory)
        await workspace.openDocument(from: main)
        await eventually("Main.java never settled") { rows(workspace, "Main.java") == Self.expectedMain }

        // Unsaved: a new genuine miss appears, an existing valid type stays valid.
        let host = workspace.host(for: workspace.workbench.activePaneID)
        let text = host.textView.text as NSString
        let insertAt = text.range(of: "    private Missing missing;").location
        host.textView.selectedRange = NSRange(location: insertAt, length: 0)
        host.textView.insertText("    private AlsoMissing other;\n")
        await eventually("the unsaved edit was not re-inspected") {
            rows(workspace, "Main.java") == (Self.expectedMain + ["Cannot resolve type 'AlsoMissing'"]).sorted()
        }

        // Another tab, then back: Main's findings stay those of its current (unsaved) text.
        await workspace.openDocument(from: helper)
        await eventually("Helper.java should be clean") { rows(workspace, "Helper.java").isEmpty && recorder.publications["Helper.java"] != nil }
        await workspace.openDocument(from: main)
        await eventually("Main.java did not return to current findings after switching tabs") {
            rows(workspace, "Main.java") == (Self.expectedMain + ["Cannot resolve type 'AlsoMissing'"]).sorted()
                && !workspace.problems.staleSources(for: main).contains(IDEProblemsStore.inspectionSource)
        }
        assertNoFalsePositives(recorder)
    }

    // MARK: - Index publication re-checks open files once

    /// A publish that moves the sources re-checks each open file through the coalescing schedule;
    /// an identical republish re-checks nothing.
    func testIndexPublicationRechecksOpenFilesWithoutRepeats() async throws {
        let main = try write("src/app/Main.java", Self.main)
        _ = try write("src/app/Helper.java", "package app;\npublic class Helper { }\n")
        let recorder = Recorder()
        let workspace = makeWorkspace(recorder)
        workspace.openProjectFolder(directory)
        await workspace.openDocument(from: main)
        await eventually("Main.java never settled") { rows(workspace, "Main.java") == Self.expectedMain }
        let service = workspace.javaSupport.inspectionService
        await service.settle()

        // Same sources again (what a model removal or a folder re-open with nothing new publishes).
        let before = await service.completedPasses
        let version = await workspace.javaSupport.javaIndex.sourcesVersion
        workspace.javaSupport.reanalyzeInspectionsAfterIndexChange(workspace.openJavaDocuments())
        try await Task.sleep(for: .milliseconds(300))
        await service.settle()
        let afterNoop = await service.completedPasses
        let versionAfter = await workspace.javaSupport.javaIndex.sourcesVersion
        XCTAssertEqual(version, versionAfter)
        XCTAssertEqual(afterNoop, before, "a re-check with nothing changed must not run a pass")
        print("REINSPECT idle_recheck passes=\(afterNoop - before)")
    }

    // MARK: - Workspace isolation

    /// Two windows, two folders: each window's findings and index are its own, and one window's
    /// project classes never resolve in the other.
    func testTwoWindowsStayIsolated() async throws {
        let main = try write("src/app/Main.java", Self.main)
        _ = try write("src/app/Helper.java", "package app;\npublic class Helper { }\n")
        let other = directory.appendingPathComponent("other", isDirectory: true)
        let otherMain = try write("src/app/Main.java", "package app;\npublic class Main { private Helper helper; private String s; }\n", in: other)

        let recorderA = Recorder()
        let recorderB = Recorder()
        let a = makeWorkspace(recorderA)
        let b = makeWorkspace(recorderB)
        a.openProjectFolder(directory)
        b.openProjectFolder(other)
        await a.openDocument(from: main)
        await b.openDocument(from: otherMain)

        await eventually("window A never settled") { rows(a, "Main.java") == Self.expectedMain }
        await eventually("window B never settled") { rows(b, "Main.java") == ["Cannot resolve type 'Helper'"] }
        assertNoFalsePositives(recorderA)
        XCTAssertFalse(recorderB.everything(for: "Main.java").contains { $0.contains("'String'") })
    }

    // MARK: - Closing and switching projects

    func testSwitchingProjectsDoesNotCarryFindingsOrClasses() async throws {
        let main = try write("src/app/Main.java", Self.main)
        _ = try write("src/app/Helper.java", "package app;\npublic class Helper { }\n")
        let second = directory.appendingPathComponent("second", isDirectory: true)
        let secondMain = try write("src/app/Uses.java", "package app;\npublic class Uses { private Helper helper; private String s; }\n", in: second)

        let recorder = Recorder()
        let workspace = makeWorkspace(recorder)
        workspace.openProjectFolder(directory)
        await workspace.openDocument(from: main)
        await eventually("first project never settled") { rows(workspace, "Main.java") == Self.expectedMain }

        workspace.closeFolder()
        workspace.openProjectFolder(second)
        await workspace.openDocument(from: secondMain)
        // `Helper` was the first project's class: in the second project it is genuinely missing.
        await eventually("the second project kept the first project's classes") {
            rows(workspace, "Uses.java") == ["Cannot resolve type 'Helper'"]
        }
        XCTAssertFalse(recorder.everything(for: "Uses.java").contains { $0.contains("'String'") })
    }

    // MARK: - Problems panel state

    /// Once the index is authoritative the panel's note goes away (no permanent pending state).
    func testProblemsPanelResolutionStatusSettlesToComplete() async throws {
        let main = try write("src/app/Main.java", Self.main)
        _ = try write("src/app/Helper.java", "package app;\npublic class Helper { }\n")
        let workspace = makeWorkspace(Recorder())
        workspace.openProjectFolder(directory)
        await workspace.openDocument(from: main)
        await eventually("Main.java never settled") { rows(workspace, "Main.java") == Self.expectedMain }
        await eventually("the panel still says the checks are pending") { workspace.problems.resolutionSummary == .complete }
    }

    // MARK: - Unsaved declarations in another tab

    /// `Widget` is typed into another open tab and never saved: Main.java stops reporting it.
    func testAnUnsavedDeclarationInAnotherTabResolves() async throws {
        let main = try write("src/app/Main.java", "package app;\npublic class Main { private Widget widget; private String s; }\n")
        let widget = try write("src/app/Widget.java", "package app;\n")
        let recorder = Recorder()
        let workspace = makeWorkspace(recorder)
        workspace.autosave.settings = { IDEAutosaveController.Settings(isEnabled: false) }
        workspace.openProjectFolder(directory)
        await workspace.openDocument(from: main)
        await eventually("Main.java never reported the missing Widget") { rows(workspace, "Main.java") == ["Cannot resolve type 'Widget'"] }

        await workspace.openDocument(from: widget)
        let host = workspace.host(for: workspace.workbench.activePaneID)
        host.textView.selectedRange = NSRange(location: (host.textView.text as NSString).length, length: 0)
        host.textView.insertText("public class Widget { }\n")
        // The overlay indexes the unsaved buffer (it is elided in the bridge, like every file).
        await eventually("the unsaved declaration never reached the overlay", seconds: 10) {
            workspace.workbench.activePane.selectedDocument?.isDirty == true
        }
        await eventually("an unsaved declaration in another tab did not reach Main.java", seconds: 10) { rows(workspace, "Main.java").isEmpty }
        let overlay = await workspace.javaSupport.javaIndex.classStub(qualifiedName: "app.Widget")
        XCTAssertNotNil(overlay)
        let onDisk = try String(contentsOf: widget, encoding: .utf8)
        XCTAssertFalse(onDisk.contains("class Widget"), "the declaration must reach Main.java without being saved")
        XCTAssertFalse(recorder.everything(for: "Main.java").contains { $0.contains("'String'") })
    }
}
