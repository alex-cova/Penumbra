import EditorIntelligence
import Foundation
import LanguageSyntax
@_spi(Benchmarks) import Penumbra
import XCTest
@testable import Umbra

/// Edits hammered while background work is in flight (F-20c).
///
/// The cost suites type in bursts and then wait for quiet before asserting counts; nothing drives
/// edits *through* in-flight parses, rebuilds and index passes. This types back-to-back (no
/// pause, so settle generations pile up and cancel each other) with the Structure tab showing —
/// every consumer of the shared tree and text is running at once — and then asserts the only
/// timing-independent facts: every keystroke landed exactly once, the outline rebuilt, and undo
/// restores the fixture. Under TSan (`swift test --package-path Umbra --sanitize=thread
/// --build-path Umbra/.build-tsan --filter IDEConcurrentEditStressTests`) a data race aborts the
/// run, which is the assertion; the XCTest assertions below hold with and without the sanitizer.
@MainActor
final class IDEConcurrentEditStressTests: XCTestCase {
    private var directory: URL!
    private var workspace: IDEWorkspace!
    private var textView: TextView!
    private var fixture = ""

    private static let methodCount = 10
    private static let keystrokes = 120

    override func setUp() async throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("editstress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fixture = Self.makeJavaSource(methods: Self.methodCount)
        let url = directory.appendingPathComponent("Big.java")
        try fixture.write(to: url, atomically: true, encoding: .utf8)
        workspace = IDEWorkspace()
        workspace.bootstrap()
        await workspace.openDocument(from: url)
        textView = workspace.host(for: workspace.workbench.activePaneID).textView
        workspace.showSidebarTab(.structure)
        await settle()
        // The rebuild is scheduled, not started: quiet does not imply it fired yet (under TSan,
        // the scheduled rebuild lands after the quiet window). Wait for the tree itself, with a
        // cap far beyond a sanitized small-file build; it returns the moment the tree lands.
        await waitForCondition("the outline builds before the storm", timeout: 60) {
            workspace.structureStore.root != nil
        }
    }

    override func tearDown() async throws {
        textView = nil
        workspace?.windowWillClose()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: directory)
    }

    /// 120 keystrokes with no pause between them, then a caret storm, all while the Structure
    /// tab, the indexer, run availability and markers chase the buffer. Background generations
    /// overlap and cancel; the foreground assertions are exact either way.
    func testTypingThroughInflightBackgroundWork() async throws {
        placeCaretInsideMethod(5)
        let inserted = String(repeating: "x", count: Self.keystrokes)
        for character in inserted {
            textView.insertText(String(character))
        }
        // A caret storm across methods while the rebuilds from the burst are still running.
        let start = (fixture as NSString).range(of: "method5(").location
        for step in 0..<60 {
            textView.selectedRange = NSRange(location: start + step * 7, length: 0)
            workspace.textViewDidChangeSelection(textView)
        }

        await settle()

        XCTAssertEqual(textView.text.count, fixture.count + Self.keystrokes, "every keystroke lands exactly once")
        XCTAssertTrue(textView.text.contains(inserted))
        XCTAssertNotNil(workspace.structureStore.root, "the outline rebuilds after the storm")

        // The undo stack survived the same storm: unwinding restores the fixture byte for byte.
        var undos = 0
        while textView.undoManager?.canUndo == true, undos < 500 {
            textView.undoManager?.undo()
            undos += 1
        }
        await settle()
        XCTAssertEqual(textView.text, fixture, "undo restores the fixture after concurrent-style edits")
    }

    // MARK: - Driving

    /// Waits until the window has been quiet for 1.5 s: no parse started, no text exported and no
    /// background hop started or running. At most 30 s (a sanitized build is several times
    /// slower and the storm leaves more work behind than a burst).
    private func settle() async {
        func activity() -> [Int] {
            let detached = DetachedWorkStatistics.counts
            return [SyntaxParseStatistics.counts.total, DocumentTextExport.materializedExportCount,
                    detached.started, detached.inFlight]
        }
        var last = activity()
        var quietSince = ContinuousClock.now
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let now = activity()
            if now != last {
                last = now
                quietSince = ContinuousClock.now
            } else if ContinuousClock.now - quietSince > .milliseconds(1_500) {
                return
            }
        }
    }

    /// The caret just after `int total = a + b;` in method `index`, which is inside its body.
    /// Guards the anchors: a missing one is a fixture bug, and an out-of-bounds caret aborts.
    private func placeCaretInsideMethod(_ index: Int) {
        let nsFixture = fixture as NSString
        let method = nsFixture.range(of: "method\(index)(")
        guard method.location != NSNotFound, method.location + 400 <= nsFixture.length else {
            return XCTFail("fixture has no method\(index)")
        }
        let statement = nsFixture.range(
            of: "int total = a + b;", range: NSRange(location: method.location, length: 400))
        guard statement.location != NSNotFound else {
            return XCTFail("fixture method\(index) has no anchor statement")
        }
        textView.selectedRange = NSRange(location: statement.upperBound, length: 0)
    }

    /// About 9 lines per method. The overlap this test stresses comes from the back-to-back
    /// keystrokes (no pause, so settle generations pile up and cancel each other), not from file
    /// size — a small file keeps the sanitized first build inside any reasonable wait while the
    /// burst still outruns the settle delay by orders of magnitude.
    private static func makeJavaSource(methods: Int) -> String {
        var source = "package bench;\n\nimport java.util.List;\n\npublic class Big {\n"
        source.reserveCapacity(methods * 220)
        for index in 0..<methods {
            source += """
                public int method\(index)(int a, int b) {
                    int total = a + b;
                    for (int k = 0; k < 3; k++) {
                        total += k * \(index);
                    }
                    return total;
                }


            """
        }
        source += "}\n"
        return source
    }
}
