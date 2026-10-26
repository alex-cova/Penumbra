import AppKit
import Foundation
import JavaIntelligence
import Penumbra
import XCTest
@testable import Umbra

private func fixture(_ folder: String, _ name: String) -> URL {
    InstrumentationFixtures.url(folder, name)
}

@MainActor
private func waitUntil(_ condition: () -> Bool, seconds: Double = 15, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(condition(), "timed out", file: file, line: line)
}

// MARK: - Coverage controller

@MainActor
final class IDECoverageControllerTests: XCTestCase {
    private let source = URL(fileURLWithPath: "/project/src/main/java/app/Calc.java")

    private func snapshot() throws -> IDECoverageSnapshot {
        let report = try JaCoCoXMLReportParser.parse(
            contentsOf: fixture("JavaCoverage", "calc-report.xml")
        ) { _ in self.source }
        return IDECoverageSnapshot(
            report: report, runID: "r1", label: "Calc", date: Date(), tasks: [],
            runDirectory: URL(fileURLWithPath: "/tmp/r1"), executionFiles: [], classDirectories: [], sourceDirectories: [],
            java: URL(fileURLWithPath: "/jdk/bin/java"), cliJar: URL(fileURLWithPath: "/res/jacococli.jar")
        )
    }

    func testBandsComeFromTheSnapshotAndGoOnTheFirstEdit() throws {
        let controller = IDECoverageController()
        XCTAssertTrue(controller.bands(forFile: source).isEmpty)
        try controller.publish(snapshot())
        XCTAssertEqual(controller.bands(forFile: source).count, 8)
        XCTAssertTrue(controller.hasLiveCoverage(forFile: source))
        XCTAssertTrue(controller.bands(forFile: URL(fileURLWithPath: "/elsewhere/Other.java")).isEmpty)

        let before = controller.generation
        XCTAssertTrue(controller.noteEdit(file: source), "the first edit takes the bands away")
        XCTAssertGreaterThan(controller.generation, before)
        XCTAssertFalse(controller.noteEdit(file: source), "later keystrokes cost nothing and change nothing")
        XCTAssertTrue(controller.bands(forFile: source).isEmpty)
        XCTAssertFalse(controller.hasLiveCoverage(forFile: source))
        // The numbers stay.
        XCTAssertEqual(controller.snapshot?.report.totals.lines.percent, 70)
    }

    func testAFileThatWasAlreadyDirtyStartsWithoutBands() throws {
        let controller = IDECoverageController()
        try controller.publish(snapshot(), staleFiles: [source.standardizedFileURL.path])
        XCTAssertTrue(controller.bands(forFile: source).isEmpty)
    }

    func testClearAndFailure() throws {
        let controller = IDECoverageController()
        controller.beginReport(message: "Building…")
        XCTAssertTrue(controller.isBuilding)
        XCTAssertTrue(controller.hasContent)
        controller.fail("no data")
        XCTAssertFalse(controller.isBuilding)
        XCTAssertEqual(controller.failureMessage, "no data")
        try controller.publish(snapshot())
        XCTAssertNil(controller.failureMessage)
        controller.clear()
        XCTAssertNil(controller.snapshot)
        XCTAssertFalse(controller.hasContent)
    }

    func testRowsAreFilteredAndWorstFirst() throws {
        let controller = IDECoverageController()
        try controller.publish(snapshot())
        let rows = controller.packageRows
        XCTAssertEqual(rows.map(\.name), ["app"])
        XCTAssertEqual(rows.first?.classes.first?.displayName, "Calc")
        XCTAssertEqual(rows.first?.classes.first?.linePercent, 70)
        XCTAssertEqual(rows.first?.classes.first?.firstMissedLine, 2)
        controller.maximumPercent = 50
        XCTAssertTrue(controller.packageRows.isEmpty, "70% is above the 50% limit")
        controller.maximumPercent = nil
        controller.filterText = "nomatch"
        XCTAssertTrue(controller.packageRows.isEmpty)
        controller.filterText = "calc"
        XCTAssertEqual(controller.packageRows.count, 1)
        XCTAssertEqual(controller.summary, "70% lines · 66% branches · 50% methods · 1 classes")
    }

    func testLineBackgroundsMergeLikeBands() {
        let bands = [
            JavaCoverageBand(lines: 4...6, status: .covered),
            JavaCoverageBand(lines: 9...9, status: .missed)
        ]
        let backgrounds = IDECoverageController.lineBackgrounds(for: bands, darkTheme: true)
        XCTAssertEqual(backgrounds.map(\.line), [4, 9])
        XCTAssertEqual(backgrounds.map(\.lineCount), [3, 1])
        XCTAssertNotEqual(backgrounds[0].color, backgrounds[1].color)
        XCTAssertTrue(IDECoverageController.lineBackgrounds(for: [], darkTheme: false).isEmpty)
    }

    func testWorkspacePaintsCoverageAndExecutionLineTogetherAndDropsItOnEdit() async throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        defer { IDEWorkspace.isSessionPersistenceEnabled = true }
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        defer { workspace.teardown() }
        let textView = workspace.host(for: workspace.workbench.activePaneID).textView
        try workspace.coverage.publish(snapshot())

        workspace.applyExecutionLineBackground(to: textView, shownFile: source)
        XCTAssertEqual(textView.lineBackgrounds.count, 8)
        // Settings can turn the colours off without clearing the report.
        let defaults = UserDefaults.standard
        let key = "com.umbra.editor.javaCoverageShowsInEditor"
        let previous = defaults.object(forKey: key)
        IDEPreferences.shared.javaCoverageShowsInEditor = false
        workspace.applyExecutionLineBackground(to: textView, shownFile: source)
        XCTAssertTrue(textView.lineBackgrounds.isEmpty)
        IDEPreferences.shared.javaCoverageShowsInEditor = true
        if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }

        workspace.applyExecutionLineBackground(to: textView, shownFile: source)
        XCTAssertEqual(textView.lineBackgrounds.count, 8)
        XCTAssertTrue(workspace.coverage.noteEdit(file: source))
        workspace.applyExecutionLineBackground(to: textView, shownFile: source)
        XCTAssertTrue(textView.lineBackgrounds.isEmpty)
    }
}

// MARK: - Profiler session

@MainActor
final class IDEProfilerSessionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("profiler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A JDK home whose `bin/jfr` is a shell script: `summary` prints a table, `print` prints the
    /// sample fixture after `delay` seconds.
    private func fakeJDK(name: String, delay: Double = 0, failing: Bool = false) throws -> JDKInstallation {
        let home = directory.appendingPathComponent(name, isDirectory: true)
        let bin = home.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "JAVA_VERSION=\"21.0.1\"\n".write(to: home.appendingPathComponent("release"), atomically: true, encoding: .utf8)
        let print = fixture("JavaProfiling", "spin-print.txt").path
        let summary = fixture("JavaProfiling", "spin-summary.txt").path
        let script: String
        if failing {
            script = "#!/bin/sh\necho 'Unsupported chunk version 99' >&2\nexit 1\n"
        } else {
            script = """
            #!/bin/sh
            if [ "$1" = "summary" ]; then cat "\(summary)"; exit 0; fi
            sleep \(delay)
            cat "\(print)"
            """
        }
        let jfr = bin.appendingPathComponent("jfr")
        try script.write(to: jfr, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: jfr.path)
        return try XCTUnwrap(JDKInstallation(home: home, featureVersion: 21, versionString: "21.0.1", vendor: nil)) as JDKInstallation
    }

    private func recording() throws -> URL {
        let url = directory.appendingPathComponent("rec.jfr")
        try Data([0x46, 0x4C, 0x52, 0x00, 0, 2]).write(to: url)
        return url
    }

    func testReadsARecordingThroughTheJFRTool() async throws {
        let jdk = try fakeJDK(name: "jdk21")
        let session = IDEProfilerSession(recordings: [try recording()], title: "rec.jfr")
        session.jfrCandidates = { [jdk] in [jdk] }
        session.load()
        try await waitUntil { session.phase == .ready }
        XCTAssertEqual(session.profile?.cpuSamples, 12)
        XCTAssertEqual(session.summary?.executionSamples, 255)
        XCTAssertEqual(session.threadNames.sorted(), ["main", "worker-1"])
        XCTAssertEqual(session.hotMethods.first.flatMap { session.symbols?.qualifiedName(ofMethod: $0.method) }, "app.Spin.fib")
        session.thread = "main"
        XCTAssertLessThan(session.tree?.totalSamples ?? 0, 12)
        XCTAssertTrue(session.totalDescription.contains("samples"))
    }

    func testASupersededImportIsDropped() async throws {
        let slow = try fakeJDK(name: "slow", delay: 2)
        let fast = try fakeJDK(name: "fast")
        let session = IDEProfilerSession(recordings: [try recording()], title: "rec.jfr")
        session.jfrCandidates = { [slow] in [slow] }
        session.load()
        try await Task.sleep(nanoseconds: 200_000_000)
        session.jfrCandidates = { [fast] in [fast] }
        session.load()
        try await waitUntil { session.phase == .ready }
        let loadedAt = session.loadedAt
        // Wait past the slow tool's end: its result must not replace the newer one.
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.loadedAt, loadedAt)
    }

    func testNoJFRToolSaysSoAndFailuresFallThroughToTheNextJDK() async throws {
        let session = IDEProfilerSession(recordings: [try recording()], title: "rec.jfr")
        session.jfrCandidates = { [] }
        session.load()
        try await waitUntil { session.phase == .needsJDK }

        let broken = try fakeJDK(name: "broken", failing: true)
        let good = try fakeJDK(name: "good")
        let retry = IDEProfilerSession(recordings: [try recording()], title: "rec.jfr")
        retry.jfrCandidates = { [broken, good] in [broken, good] }
        retry.load()
        try await waitUntil { retry.phase == .ready }
        XCTAssertEqual(retry.profile?.cpuSamples, 12)

        let hopeless = IDEProfilerSession(recordings: [try recording()], title: "rec.jfr")
        hopeless.jfrCandidates = { [broken] in [broken] }
        hopeless.load()
        try await waitUntil { if case .failed = hopeless.phase { return true } else { return false } }
        guard case .failed(let message) = hopeless.phase else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("Unsupported chunk version"), message)
    }

    func testABigRecordingAsksFirst() async throws {
        let jdk = try fakeJDK(name: "jdk")
        let session = IDEProfilerSession(recordings: [try recording()], title: "rec.jfr")
        session.jfrCandidates = { [jdk] in [jdk] }
        session.confirmThresholdBytes = 3
        session.load()
        try await waitUntil { if case .needsConfirmation = session.phase { return true } else { return false } }
        session.load(confirmed: true)
        try await waitUntil { session.phase == .ready }
    }

    func testZoomStackAndNavigationReset() {
        let session = IDEProfilerSession(recordings: [], title: "x")
        session.zoom(into: 4)
        session.zoom(into: 9)
        XCTAssertEqual(session.zoomStack, [4, 9])
        session.zoomOut()
        XCTAssertEqual(session.zoomStack, [4])
        session.selectedMethod = 3
        session.kind = .allocations
        XCTAssertTrue(session.zoomStack.isEmpty)
        XCTAssertNil(session.selectedMethod)
    }
}

// MARK: - Flame graph layout

@MainActor
final class IDEFlameGraphLayoutTests: XCTestCase {
    func testOnlyBoxesWiderThanAPixelAreLaidOutAndHitTestingFindsThem() {
        let symbols = JavaProfileSymbols()
        func frame(_ name: String) -> Int32 {
            symbols.internFrame(method: symbols.internMethod(className: "app.K", name: name, parameters: ""), line: 1)
        }
        var tree = JavaProfileTree()
        let main = frame("main"), hot = frame("hot"), tiny = frame("tiny")
        tree.add(stack: [main, hot], weight: 100_000)
        tree.add(stack: [main, tiny], weight: 1)
        let graph = IDEFlameGraphNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        graph.update(tree: tree, symbols: symbols, rootNode: JavaProfileTree.root, highlighted: [], selected: nil)
        graph.layout()
        // root + main + hot: `tiny` is 0.004 px wide.
        XCTAssertEqual(graph.boxCountForTesting, 3)
        XCTAssertEqual(graph.rowCountForTesting, 3)
        let hit = graph.node(at: NSPoint(x: 100, y: IDEFlameGraphNSView.rowHeight * 2 + 4))
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit.map { graph.tree.selfCount(of: $0) }, 100_000)
        XCTAssertNil(graph.node(at: NSPoint(x: 100, y: 4 * IDEFlameGraphNSView.rowHeight)))
    }

    func testTheDocumentIsTallEnoughForTheDeepestStack() {
        let symbols = JavaProfileSymbols()
        var tree = JavaProfileTree()
        var stack: [Int32] = []
        for depth in 0 ..< 120 {
            stack.append(symbols.internFrame(
                method: symbols.internMethod(className: "app.K", name: "m\(depth)", parameters: ""), line: 1
            ))
        }
        tree.add(stack: stack, weight: 10)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let graph = IDEFlameGraphNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scroll.documentView = graph
        graph.update(tree: tree, symbols: symbols, rootNode: JavaProfileTree.root, highlighted: [], selected: nil)
        graph.layout()
        XCTAssertEqual(graph.rowCountForTesting, 121)
        XCTAssertGreaterThanOrEqual(graph.frame.height, 121 * IDEFlameGraphNSView.rowHeight)
    }
}

// MARK: - Opening recordings

@MainActor
final class IDEProfileRoutingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("route-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: directory)
    }

    private func profileDocuments(_ workspace: IDEWorkspace) -> [WorkbenchDocument] {
        workspace.workbench.allDocuments().filter { $0.contentKind == .profile }
    }

    private func write(_ name: String, bytes: [UInt8]) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    func testARecordingOpensInTheProfilerAndASecondOpenReusesTheTab() async throws {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        defer { workspace.teardown() }
        let url = try write("run.jfr", bytes: [0x46, 0x4C, 0x52, 0x00, 0x00, 0x02, 0x00, 0x01])

        await workspace.openDocument(from: url)
        XCTAssertEqual(profileDocuments(workspace).count, 1)
        let document = try XCTUnwrap(profileDocuments(workspace).first)
        XCTAssertEqual(document.displayName, "run.jfr")
        XCTAssertNotNil(workspace.profileSessions[document.id])

        await workspace.openDocument(from: url)
        XCTAssertEqual(profileDocuments(workspace).count, 1, "the same recording reuses its tab")

        workspace.closeTab(document.id)
        XCTAssertTrue(profileDocuments(workspace).isEmpty)
        XCTAssertTrue(workspace.profileSessions.isEmpty, "closing frees the session")
    }

    func testARenamedRecordingIsFoundByItsMagicAndATextFileNamedJFRStaysText() async throws {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        defer { workspace.teardown() }
        let renamed = try write("capture.bin", bytes: [0x46, 0x4C, 0x52, 0x00, 0x00, 0x02])
        XCTAssertTrue(IDEWorkspace.isFlightRecording(renamed))
        let notes = directory.appendingPathComponent("notes.jfr")
        try "these are just notes about the flight recorder\n".write(to: notes, atomically: true, encoding: .utf8)
        XCTAssertFalse(IDEWorkspace.isFlightRecording(notes))

        await workspace.openDocument(from: notes)
        XCTAssertTrue(profileDocuments(workspace).isEmpty)
        XCTAssertEqual(workspace.workbench.activePane.selectedDocument?.contentKind, .text)
    }

    func testReopenAsHexBypassesTheProfiler() async throws {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        defer { workspace.teardown() }
        let url = try write("run.jfr", bytes: [0x46, 0x4C, 0x52, 0x00, 0x00, 0x02, 0x00, 0x01])
        let document = try await workspace.loadDocument(from: url, openAsHex: true)
        XCTAssertEqual(document.contentKind, .binary)
    }

    func testAProfileTabWhoseFileIsGoneIsDroppedNotShownEmpty() async throws {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        defer { workspace.teardown() }
        let url = try write("pruned.jfr", bytes: [0x46, 0x4C, 0x52, 0x00, 0x00, 0x02])
        // A restored tab: a profile document with a file and no session.
        let document = WorkbenchDocument(displayName: "pruned.jfr")
        document.contentKind = .profile
        document.url = url
        workspace.workbench.openDocument(document)
        try FileManager.default.removeItem(at: url)
        workspace.refreshPresentation()
        let pane = workspace.workbench.activePane
        workspace.showDocument(in: pane, host: workspace.host(for: pane.id))
        try await waitUntil { self.profileDocuments(workspace).isEmpty }
        XCTAssertTrue(workspace.profileSessions.isEmpty)
    }

    func testRunRecordingsShareTheirFolder() throws {
        let runs = directory.appendingPathComponent("Profiles/abc/run1", isDirectory: true)
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
        try Data(count: 100).write(to: runs.appendingPathComponent("app-test-1.jfr"))
        try Data(count: 500).write(to: runs.appendingPathComponent("app-test-2.jfr"))
        let found = IDEWorkspace.recordings(sharingFolderWith: runs.appendingPathComponent("app-test-1.jfr"))
        XCTAssertEqual(found.map(\.lastPathComponent), ["app-test-2.jfr", "app-test-1.jfr"], "the largest first")
        let loose = try write("x.jfr", bytes: [0x46, 0x4C, 0x52, 0x00])
        XCTAssertEqual(IDEWorkspace.recordings(sharingFolderWith: loose), [loose])
    }
}
