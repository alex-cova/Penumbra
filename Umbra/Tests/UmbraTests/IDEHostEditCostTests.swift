import Foundation
import LanguageSyntax
@_spi(Benchmarks) import Penumbra
import XCTest
@testable import Umbra

/// What the window does around an edit, counted (F-04).
///
/// `PerfHarness` measures the text engine and `IDERootViewInvalidationTests` counts SwiftUI body
/// evaluations; neither sees the work `IDEWorkspace`'s delegate callbacks start after a keystroke
/// or a caret move: structure rebuilds, semantic passes, name-index overlays, Java auto-import,
/// run availability. This drives a real window against a 20,000-line Java file the way a person
/// does (a burst of characters, then arrow keys, then a pause) and holds the work it caused to a
/// number of parses and whole-buffer copies. Counts, not milliseconds: they do not move with the
/// machine or a Debug build, so the bounds can be tight and the test can run everywhere.
///
/// Every run prints one `HOSTCOST` line per scenario (the milliseconds are for reading only).
/// A bound that fails says which of the counted costs grew; the fix belongs to whatever started
/// that work, not to the bound.
@MainActor
final class IDEHostEditCostTests: XCTestCase {
    private var directory: URL!
    private var workspace: IDEWorkspace!
    private var textView: TextView!
    private var fixture = ""

    private static let methodCount = 2_200

    override func setUp() async throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostcost-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fixture = Self.makeJavaSource(methods: Self.methodCount)
        let url = directory.appendingPathComponent("Big.java")
        try fixture.write(to: url, atomically: true, encoding: .utf8)
        workspace = IDEWorkspace()
        workspace.bootstrap()
        await workspace.openDocument(from: url)
        textView = workspace.host(for: workspace.workbench.activePaneID).textView
        await settle()
    }

    override func tearDown() async throws {
        textView = nil
        workspace?.windowWillClose()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Scenarios

    /// 120 characters typed 15 ms apart inside a method body, Structure tab not showing, then a pause.
    func testTypingWithTheStructureTabHidden() async throws {
        workspace.isSidebarVisible = false
        placeCaretInsideMethod(1_100)

        let cost = await measure("typing_structure_hidden") {
            await self.type(characters: 120)
        }

        // Nothing here reads the Structure tree, so nothing may build it.
        XCTAssertNil(workspace.structureStore.root)
        // One settle's worth of semantic / marker / inspection passes, never one per keystroke.
        XCTAssertLessThanOrEqual(cost.parses.total, Bounds.parsesPerTypingBurst, "\(cost)")
        XCTAssertLessThanOrEqual(cost.mainBufferCopies, Bounds.mainCopiesPerTypingBurst, "\(cost)")
        XCTAssertLessThanOrEqual(cost.exportedTexts, Bounds.exportsPerTypingBurst, "\(cost)")
    }

    /// The same burst with the Structure tab showing: one rebuild once typing pauses, not 120.
    func testTypingWithTheStructureTabShowing() async throws {
        workspace.showSidebarTab(.structure)
        await settle()
        placeCaretInsideMethod(1_100)

        let cost = await measure("typing_structure_showing") {
            await self.type(characters: 120)
        }

        XCTAssertNotNil(workspace.structureStore.root)
        XCTAssertLessThanOrEqual(
            cost.parses.total, Bounds.parsesPerTypingBurst + Bounds.parsesForAShowingStructureTab, "\(cost)")
        XCTAssertLessThanOrEqual(cost.mainBufferCopies, Bounds.mainCopiesPerTypingBurst, "\(cost)")
        XCTAssertLessThanOrEqual(cost.exportedTexts, Bounds.exportsPerTypingBurst, "\(cost)")
    }

    /// 200 caret moves (a held arrow key) with the Structure tab showing: the tree is not rebuilt,
    /// and nothing else re-parses text that did not change.
    func testHoldingAnArrowKeyWithTheStructureTabShowing() async throws {
        workspace.showSidebarTab(.structure)
        await settle()
        let start = (fixture as NSString).range(of: "method1100(").location

        let cost = await measure("arrow_structure_showing") {
            for step in 0..<200 {
                self.moveCaret(to: start + step)
                try? await Task.sleep(nanoseconds: 15_000_000)
            }
        }

        XCTAssertLessThanOrEqual(cost.parses.total, Bounds.parsesPerCaretBurst, "\(cost)")
        XCTAssertLessThanOrEqual(cost.mainBufferCopies, Bounds.mainCopiesPerCaretBurst, "\(cost)")
        XCTAssertLessThanOrEqual(cost.exportedTexts, Bounds.exportsPerCaretBurst, "\(cost)")
    }

    /// Caret moves with the Structure tab hidden cost no parse at all.
    func testHoldingAnArrowKeyWithTheStructureTabHidden() async throws {
        workspace.isSidebarVisible = false
        let start = (fixture as NSString).range(of: "method1100(").location

        let cost = await measure("arrow_structure_hidden") {
            for step in 0..<200 {
                self.moveCaret(to: start + step)
                try? await Task.sleep(nanoseconds: 15_000_000)
            }
        }

        XCTAssertLessThanOrEqual(cost.parses.total, Bounds.parsesPerCaretBurst, "\(cost)")
        XCTAssertLessThanOrEqual(cost.mainBufferCopies, Bounds.mainCopiesPerCaretBurst, "\(cost)")
        XCTAssertLessThanOrEqual(cost.exportedTexts, Bounds.exportsPerCaretBurst, "\(cost)")
    }

    // MARK: - Bounds

    /// Measured on this fixture (Debug build), then given a little room. Raise one only for a change
    /// that is meant to cost more, and say why in the commit.
    ///
    /// Typing 120 characters measured 11 parses with the Structure tab hidden and 12 showing, after
    /// the fixes in 81f8f344; the sources before them measured 130 in both (a full parse of the file
    /// per keystroke, whether or not anyone looked at the result). The ten that remain are one
    /// settle's worth of independent features each parsing the same text (F-02, F-03): semantic
    /// tokens, line markers, run locations, name-index and role-index overlays, auto-import,
    /// inspections. Making them share one parse should take this bound down to two or three.
    /// Whole-buffer copies measured 7 to 9 before and after: they are the `textView.text` reads of
    /// run availability and friends (F-07, not yet fixed).
    ///
    /// 200 caret moves measured 200 exported texts before the fixes (the Structure refresh copied
    /// the whole document off the main actor on every move, shown or not, and compared it with the
    /// last one to find it had not changed) and none after. Typing measured 8 to 9 exports, one per
    /// settled feature that wants the text.
    private enum Bounds {
        static let parsesPerTypingBurst = 14
        static let parsesForAShowingStructureTab = 2
        static let mainCopiesPerTypingBurst = 10
        /// Text that did not change is never parsed again: exact, not measured.
        static let parsesPerCaretBurst = 0
        static let mainCopiesPerCaretBurst = 4
        static let exportsPerTypingBurst = 12
        /// A caret move does not change the text, so nothing may ask for it again.
        static let exportsPerCaretBurst = 0
    }

    // MARK: - Driving and counting

    private struct Cost: CustomStringConvertible {
        var parses: SyntaxParseStatistics.Counts
        var mainBufferCopies: Int
        var exportedTexts: Int
        var detachedStarted: Int
        var detachedCancelled: Int
        var detachedPeak: Int
        var keystrokeMedianMilliseconds: Double
        var keystrokeMaxMilliseconds: Double

        var description: String {
            "parses=\(parses.total) (full \(parses.full), incremental \(parses.incremental)) "
                + "mainBufferCopies=\(mainBufferCopies) exportedTexts=\(exportedTexts) detachedStarted=\(detachedStarted) "
                + "detachedCancelled=\(detachedCancelled) detachedPeak=\(detachedPeak) "
                + String(format: "keystrokeMedianMs=%.2f keystrokeMaxMs=%.2f",
                         keystrokeMedianMilliseconds, keystrokeMaxMilliseconds)
        }
    }

    private var keystrokeDurations: [Double] = []

    /// Runs `drive`, waits for the work it caused to finish, and returns what that work cost.
    private func measure(_ name: String, _ drive: () async -> Void) async -> Cost {
        keystrokeDurations = []
        let parsesBefore = SyntaxParseStatistics.counts
        let copiesBefore = textView.pieceTreeMaterializeCountForBenchmarks
        let exportsBefore = DocumentTextExport.materializedExportCount
        let detachedBefore = DetachedWorkStatistics.counts
        DetachedWorkStatistics.resetPeak()

        await drive()
        await settle()

        let detached = DetachedWorkStatistics.counts - detachedBefore
        let sorted = keystrokeDurations.sorted()
        let cost = Cost(
            parses: SyntaxParseStatistics.counts - parsesBefore,
            mainBufferCopies: textView.pieceTreeMaterializeCountForBenchmarks - copiesBefore,
            exportedTexts: DocumentTextExport.materializedExportCount - exportsBefore,
            detachedStarted: detached.started,
            detachedCancelled: detached.cancelled,
            detachedPeak: detached.peakInFlight,
            keystrokeMedianMilliseconds: sorted.isEmpty ? 0 : sorted[sorted.count / 2],
            keystrokeMaxMilliseconds: sorted.last ?? 0
        )
        print("HOSTCOST \(name) \(cost)")
        return cost
    }

    /// A caret move as the window sees one. The text view reports a selection change from
    /// `layoutSubviews` (so a host never writes state during layout), and a view that is not in a
    /// window never lays out, so the report is made here: it is the same call, on the same object.
    private func moveCaret(to location: Int) {
        textView.selectedRange = NSRange(location: location, length: 0)
        workspace.textViewDidChangeSelection(textView)
    }

    private func type(characters count: Int) async {
        for index in 0..<count {
            let began = ContinuousClock.now
            textView.insertText(index % 8 == 7 ? " " : "x")
            let elapsed = ContinuousClock.now - began
            keystrokeDurations.append(Double(elapsed.components.attoseconds) / 1e15
                + Double(elapsed.components.seconds) * 1_000)
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    /// Waits until no parse has started for 1.5 s (the longest debounce in the window is 400 ms
    /// and the autoreparse delay is shorter than that unless the user raised it), at most 15 s.
    private func settle() async {
        var last = SyntaxParseStatistics.counts.total
        var quietSince = ContinuousClock.now
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let now = SyntaxParseStatistics.counts.total
            if now != last {
                last = now
                quietSince = ContinuousClock.now
            } else if ContinuousClock.now - quietSince > .milliseconds(1_500) {
                return
            }
        }
    }

    /// The caret just after `int total = a + b;` in method `index`, which is inside its body.
    private func placeCaretInsideMethod(_ index: Int) {
        let method = (fixture as NSString).range(of: "method\(index)(")
        let statement = (fixture as NSString).range(
            of: "int total = a + b;", range: NSRange(location: method.location, length: 400))
        textView.selectedRange = NSRange(location: statement.upperBound, length: 0)
    }

    /// About 9 lines per method, so 2,200 methods is about 20,000 lines (about 550 KB, past the
    /// size where the buffer is a piece tree and a whole-text read is a real copy).
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
