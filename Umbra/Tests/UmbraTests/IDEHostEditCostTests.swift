import EditorIntelligence
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

    /// Whether the thread sanitizer's runtime is loaded. A sanitized build runs the typing scenarios
    /// five times slower, so the burst lasts longer, the adapter's one-second maximum wait flushes
    /// more often, and the counts of incremental parses, exports and background hops grow with it.
    /// A sanitizer run is there to find races, so under it only what does not depend on timing is
    /// held to a bound: full parses (the costly kind), main-thread buffer copies, and that a caret
    /// move parses nothing. The other counts are still printed.
    private static let isThreadSanitized = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__tsan_init") != nil

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
        if !Self.isThreadSanitized { XCTAssertLessThanOrEqual(cost.parses.total, Bounds.parsesPerTypingBurst, "\(cost)") }
        XCTAssertLessThanOrEqual(cost.parses.full, Bounds.fullParsesPerTypingBurst, "\(cost)")
        XCTAssertLessThanOrEqual(cost.mainBufferCopies, Bounds.mainCopiesPerTypingBurst, "\(cost)")
        if !Self.isThreadSanitized { XCTAssertLessThanOrEqual(cost.exportedTexts, Bounds.exportsPerTypingBurst, "\(cost)") }
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
        if !Self.isThreadSanitized {
            XCTAssertLessThanOrEqual(
                cost.parses.total, Bounds.parsesPerTypingBurst + Bounds.parsesForAShowingStructureTab, "\(cost)")
        }
        XCTAssertLessThanOrEqual(
            cost.parses.full, Bounds.fullParsesPerTypingBurst + Bounds.parsesForAShowingStructureTab, "\(cost)")
        XCTAssertLessThanOrEqual(cost.mainBufferCopies, Bounds.mainCopiesPerTypingBurst, "\(cost)")
        if !Self.isThreadSanitized { XCTAssertLessThanOrEqual(cost.exportedTexts, Bounds.exportsPerTypingBurst, "\(cost)") }
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
        if !Self.isThreadSanitized { XCTAssertLessThanOrEqual(cost.exportedTexts, Bounds.exportsPerCaretBurst, "\(cost)") }
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
        if !Self.isThreadSanitized { XCTAssertLessThanOrEqual(cost.exportedTexts, Bounds.exportsPerCaretBurst, "\(cost)") }
    }

    // MARK: - Bounds

    /// Measured on this fixture (Debug build), then given a little room. Raise one only for a change
    /// that is meant to cost more, and say why in the commit.
    ///
    /// Typing 120 characters: the sources before the F-01 fix measured 130 full parses (one of the
    /// whole file per keystroke, shown or not). The settle is now one pause (`DocumentSettleCoordinator`)
    /// and one shared Java tree (`JavaParseMemo`, including Structure), so a burst measures 4 parses,
    /// 2 full, with the Structure tab hidden and 3 parses, 1 full, with it showing. What is still
    /// full: completion (it parses the text with a dummy identifier at the caret, so it is a
    /// different text) and the first request of each distinct text. Full parses are bounded
    /// separately because they are the costly kind (about 3 ms per 1,000 lines in a release build).
    /// Whole-buffer copies on the main actor stay at none: the text is built off the main actor,
    /// once per buffer generation (`TextView.materializedText`), and a caret move changes no text.
    ///
    /// Exports of that text: 2 per typing burst (the mid-burst adapter flush and the final settle),
    /// none per caret move.
    private enum Bounds {
        static let parsesPerTypingBurst = 6
        static let fullParsesPerTypingBurst = 3
        static let parsesForAShowingStructureTab = 1
        static let mainCopiesPerTypingBurst = 1
        /// Text that did not change is never parsed again: exact, not measured.
        static let parsesPerCaretBurst = 0
        static let mainCopiesPerCaretBurst = 0
        static let exportsPerTypingBurst = 4
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

    /// Waits until the window has been quiet for 1.5 s: no parse started, no text exported and no
    /// background hop started or running. Parses alone are not enough: on a slow build (the thread
    /// sanitizer's) the work that follows opening a file, such as semantic colours and markers,
    /// lands well after its parse and would be counted against the scenario that follows. At most 20 s.
    private func settle() async {
        func activity() -> [Int] {
            let detached = DetachedWorkStatistics.counts
            return [SyntaxParseStatistics.counts.total, DocumentTextExport.materializedExportCount,
                    detached.started, detached.inFlight]
        }
        var last = activity()
        var quietSince = ContinuousClock.now
        let deadline = ContinuousClock.now + .seconds(20)
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
