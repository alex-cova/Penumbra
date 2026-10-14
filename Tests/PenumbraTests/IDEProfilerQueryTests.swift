import AppKit
import JavaIntelligence
import XCTest
@testable import Umbra

/// The profiler tab's query chain: a thread, recursion collapsing and "what if"s on one shown tree.
@MainActor
final class IDEProfilerQueryTests: XCTestCase {
    private func makeProfile() -> JavaProfile {
        let symbols = JavaProfileSymbols()
        func frame(_ className: String, _ name: String, line: Int32 = 1) -> Int32 {
            symbols.internFrame(method: symbols.internMethod(className: className, name: name, parameters: ""), line: line)
        }
        var profile = JavaProfile(symbols: symbols)
        let main = frame("app.Main", "main"), a = frame("app.A", "a"), c = frame("app.C", "c"), fib = frame("app.Fib", "fib")
        func sample(_ stack: [Int32], thread: String, times: Int = 1) {
            for _ in 0..<times {
                profile.ingest(JFRTextEvent(type: "jdk.ExecutionSample", thread: thread, frames: stack.reversed()))
            }
        }
        sample([main, a, c], thread: "main", times: 4)
        sample([main, c], thread: "worker", times: 2)
        sample([main, fib, fib, fib], thread: "main", times: 3)
        return profile
    }

    private func makeSession() -> IDEProfilerSession {
        let session = IDEProfilerSession(recordings: [], title: "t")
        session.setProfileForTesting(makeProfile())
        return session
    }

    func testThreadFilterAppliesToEveryKindAndRefreshesTheTree() {
        let session = makeSession()
        XCTAssertEqual(session.tree?.totalSamples, 9)
        let revision = session.treeRevision
        session.thread = "worker"
        XCTAssertEqual(session.tree?.totalSamples, 2)
        XCTAssertGreaterThan(session.treeRevision, revision, "a view that caches by node count must relayout")
        XCTAssertEqual(session.threadNames, ["main", "worker"])
    }

    func testFocusAndExcludeChainAndRemoval() throws {
        let session = makeSession()
        let tree = try XCTUnwrap(session.tree)
        let symbols = try XCTUnwrap(session.symbols)
        let mainNode = try XCTUnwrap(tree.children(of: JavaProfileTree.root).first)
        let aNode = try XCTUnwrap(tree.children(of: mainNode).first { symbols.method(ofFrame: tree.frame(of: $0)).name == "a" })

        session.focusOnSubtree(node: aNode)
        XCTAssertEqual(session.transforms.count, 1)
        XCTAssertEqual(session.tree?.totalSamples, 4)
        XCTAssertEqual(session.percent(4), 100, "percentages follow the shown tree")

        // Node numbers now belong to the focused tree; excluding its root call empties it.
        let focusedRoot = try XCTUnwrap(session.tree?.children(of: JavaProfileTree.root).first)
        session.excludeSubtree(node: focusedRoot)
        XCTAssertEqual(session.tree?.totalSamples, 0)

        let last = try XCTUnwrap(session.transforms.last)
        session.removeTransform(last)
        XCTAssertEqual(session.tree?.totalSamples, 4)
        session.transforms = []
        XCTAssertEqual(session.tree?.totalSamples, 9)
    }

    func testCollapsingRecursionClearsTransformsAndMergesFrames() throws {
        let session = makeSession()
        let tree = try XCTUnwrap(session.tree)
        let mainNode = try XCTUnwrap(tree.children(of: JavaProfileTree.root).first)
        session.focusOnSubtree(node: mainNode)
        XCTAssertFalse(session.transforms.isEmpty)

        session.collapsesRecursion = true
        XCTAssertTrue(session.transforms.isEmpty, "their nodes were made on the other shape")
        let folded = try XCTUnwrap(session.tree).foldedStacks(symbols: try XCTUnwrap(session.symbols))
        XCTAssertTrue(folded.contains("app.Main.main;app.Fib.fib 3"), "\(folded)")
    }

    func testSearchStepsThroughMatchesAndWraps() throws {
        let session = makeSession()
        session.searchText = "app.c"
        XCTAssertEqual(session.searchMatches.count, 2, "app.C.c under main → a, and directly under main")
        let first = session.focusedMatch
        session.nextMatch()
        XCTAssertNotEqual(session.focusedMatch, first)
        session.nextMatch()
        XCTAssertEqual(session.focusedMatch, first, "wraps")
        session.previousMatch()
        XCTAssertNotEqual(session.focusedMatch, first)
        session.searchText = "no-such-method"
        XCTAssertNil(session.focusedMatch)
    }

    func testFrameOriginsFollowTheClassifier() {
        let session = makeSession()
        session.classifyClass = { $0.hasPrefix("app.") ? .project : .library }
        let symbols = session.symbols!
        let main = symbols.methods.firstIndex { $0.name == "main" }!
        XCTAssertEqual(session.origin(ofMethod: Int32(main)), .project)
        let jdk = symbols.internMethod(className: "java.util.HashMap", name: "put", parameters: "")
        XCTAssertEqual(session.origin(ofMethod: jdk), .jdk)
        let marker = symbols.internMethod(className: "", name: "sleeping", parameters: "")
        XCTAssertEqual(session.origin(ofMethod: marker), .marker)
        XCTAssertNotEqual(IDEFlameGraphNSView.color(for: .project), IDEFlameGraphNSView.color(for: .jdk))
    }

    func testFlameGraphRelayoutsForATreeOfTheSameSize() throws {
        let session = makeSession()
        let symbols = try XCTUnwrap(session.symbols)
        let graph = IDEFlameGraphNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let full = try XCTUnwrap(session.tree)
        graph.update(tree: full, symbols: symbols, rootNode: JavaProfileTree.root, highlighted: [], selected: nil, revision: session.treeRevision)
        graph.layout()
        let before = graph.boxCountForTesting
        session.thread = "worker"
        let worker = try XCTUnwrap(session.tree)
        XCTAssertEqual(worker.nodeCount, full.nodeCount, "same structure, other counts")
        graph.update(tree: worker, symbols: symbols, rootNode: JavaProfileTree.root, highlighted: [], selected: nil, revision: session.treeRevision)
        graph.layout()
        XCTAssertLessThan(graph.boxCountForTesting, before, "the worker thread has fewer branches")
    }

    // MARK: - Time range and the timeline

    private func mixedSession() throws -> IDEProfilerSession {
        let text = try String(contentsOf: InstrumentationFixtures.url("JavaProfiling", "mixed-print.txt"), encoding: .utf8)
        var parser = JFRTextParser()
        var profile = JavaProfile(symbols: parser.symbols)
        parser.parse(text) { profile.ingest($0) }
        let session = IDEProfilerSession(recordings: [], title: "mixed")
        session.setProfileForTesting(profile)
        return session
    }

    func testTimeRangeLimitsTheShownTreeAndTheCollections() throws {
        let session = try mixedSession()
        let span = try XCTUnwrap(session.timeline?.span)
        let all = try XCTUnwrap(session.tree?.totalSamples)
        XCTAssertGreaterThan(all, 0)
        XCTAssertEqual(session.visibleGCPauses.count, 2)

        // The first quarter of the recording holds fewer CPU samples than the whole.
        let quarter = span.lowerBound...(span.lowerBound + (span.upperBound - span.lowerBound) / 4)
        session.timeRange = quarter
        let part = try XCTUnwrap(session.tree?.totalSamples)
        XCTAssertLessThan(part, all)
        session.timeRange = (span.upperBound + 1_000)...(span.upperBound + 2_000)
        XCTAssertEqual(session.tree?.totalSamples, 0)
        XCTAssertEqual(session.visibleGCPauses.count, 0)
        session.timeRange = nil
        XCTAssertEqual(session.tree?.totalSamples, all)
    }

    func testClickingALaneSelectsTheWaitThereAndShowsItsFrames() throws {
        let session = try mixedSession()
        let timeline = try XCTUnwrap(session.timeline)
        let holder = try XCTUnwrap(timeline.lanes.first { $0.name == "lock-holder" })
        let bucket = try XCTUnwrap(holder.waiting.indices.first { holder.waiting[$0] > 0.9 })
        session.selectTimelineEvent(thread: "lock-holder", near: timeline.time(ofBucket: bucket) + 5, toleranceMilliseconds: 30)
        let event = try XCTUnwrap(session.timelineEvent)
        XCTAssertEqual(event.kind, .contention)
        let symbols = try XCTUnwrap(session.symbols)
        let frames = session.timelineEventFrames
        XCTAssertEqual(symbols.method(ofFrame: frames[0]).name, "sleeping", "leaf first")
        XCTAssertTrue(frames.contains { symbols.method(ofFrame: $0).name == "main" || symbols.method(ofFrame: $0).className.hasPrefix("app.Mixed") })

        session.selectTimelineEvent(thread: "no-such-thread", near: 0, toleranceMilliseconds: 10)
        XCTAssertNil(session.timelineEvent)
    }

    func testTimelineIsCachedPerLoad() throws {
        let session = try mixedSession()
        XCTAssertEqual(session.timeline?.lanes.count, session.timeline?.lanes.count)
        XCTAssertTrue(IDEProfilerSession.Mode.allCases.contains(.timeline))
    }

    // MARK: - Baseline

    private func profile(extraWork: Int) -> JavaProfile {
        // A second recording with its own symbol table: more time in `c`, a new `d`.
        let symbols = JavaProfileSymbols()
        func frame(_ className: String, _ name: String, line: Int32) -> Int32 {
            symbols.internFrame(method: symbols.internMethod(className: className, name: name, parameters: ""), line: line)
        }
        var profile = JavaProfile(symbols: symbols)
        func sample(_ stack: [Int32], thread: String, times: Int) {
            for _ in 0..<times {
                profile.ingest(JFRTextEvent(type: "jdk.ExecutionSample", thread: thread, frames: stack.reversed()))
            }
        }
        let main = frame("app.Main", "main", line: 9), a = frame("app.A", "a", line: 20), c = frame("app.C", "c", line: 3)
        let d = frame("app.D", "d", line: 1)
        sample([main, a, c], thread: "main", times: 4 + extraWork)
        sample([main, c], thread: "worker", times: 2)
        if extraWork > 0 { sample([main, d], thread: "main", times: extraWork) }
        return profile
    }

    func testComparingWithAnotherRecordingMatchesFramesByMethod() throws {
        let session = makeSession()
        XCTAssertNil(session.comparison)
        session.setBaseline(IDEProfilerSession.BaselineCandidate(
            id: "x", title: "before", subtitle: "", recordings: [], profile: profile(extraWork: 0)
        ))
        XCTAssertTrue(session.isComparing)
        XCTAssertEqual(session.baselineState, .ready)
        let comparison = try XCTUnwrap(session.comparison)
        XCTAssertEqual(comparison.baselineSamples, 6)
        XCTAssertEqual(comparison.targetSamples, 9)
        // `main` is one frame in the merged tree although its lines differ between the recordings.
        XCTAssertEqual(comparison.tree.children(of: JavaProfileTree.root).count, 1)
        let fib = try XCTUnwrap(comparison.rows.first { $0.method.name == "fib" })
        XCTAssertEqual(fib.baselineSelf, 0)
        XCTAssertEqual(fib.targetSelf, 3)

        // Thread and kind carry over to the baseline; clearing returns to the plain tree.
        session.thread = "worker"
        XCTAssertEqual(session.comparison?.baselineSamples, 2)
        XCTAssertEqual(session.comparison?.targetSamples, 2)
        session.clearBaseline()
        XCTAssertNil(session.comparison)
        XCTAssertNil(session.baselineTitle)
    }

    func testBaselineIsReadByASessionTheWorkspaceMakes() async throws {
        let session = makeSession()
        // A loader with no JDK to read with: its phase ends at "needs a JDK", which the parent reports.
        let loaded = IDEProfilerSession(recordings: [], title: "later")
        session.makeBaselineSession = { _, _ in loaded }
        session.setBaseline(IDEProfilerSession.BaselineCandidate(
            id: "f", title: "later.jfr", subtitle: "file", recordings: [URL(fileURLWithPath: "/nope.jfr")], profile: nil
        ))
        XCTAssertEqual(session.baselineState, .loading)
        for _ in 0..<50 where session.baselineState == .loading {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .failed(let message) = session.baselineState else { return XCTFail("\(String(describing: session.baselineState))") }
        XCTAssertTrue(message.contains("jfr"), message)
        XCTAssertFalse(session.isComparing)
    }

    // MARK: - Hidden classes

    /// `app.Main.main` calling the JDK's `HashMap.get` calling a library's `Codec.read` (both under
    /// `main`), and one sample of main on its own.
    private func layeredProfile() -> JavaProfile {
        let symbols = JavaProfileSymbols()
        func frame(_ className: String, _ name: String) -> Int32 {
            symbols.internFrame(method: symbols.internMethod(className: className, name: name, parameters: ""), line: 1)
        }
        var profile = JavaProfile(symbols: symbols)
        let main = frame("app.Main", "main"), get = frame("java.util.HashMap", "get")
        let read = frame("lib.Codec", "read"), own = frame("app.Work", "work")
        func sample(_ stack: [Int32], times: Int) {
            for _ in 0..<times { profile.ingest(JFRTextEvent(type: "jdk.ExecutionSample", thread: "main", frames: stack.reversed())) }
        }
        sample([main, own, get, read], times: 5)
        sample([main], times: 1)
        return profile
    }

    private func layeredSession() -> IDEProfilerSession {
        let session = IDEProfilerSession(recordings: [], title: "layers")
        session.setProfileForTesting(layeredProfile())
        session.classifyClass = { $0.hasPrefix("lib.") ? .library : .project }
        return session
    }

    private func folded(_ session: IDEProfilerSession) -> [String] {
        guard let tree = session.tree, let symbols = session.symbols else { return [] }
        return tree.foldedStacks(symbols: symbols).sorted()
    }

    func testHidingTheJDKAttachesItsCalleesToTheCaller() {
        let session = layeredSession()
        XCTAssertEqual(folded(session), ["app.Main.main 1", "app.Main.main;app.Work.work;java.util.HashMap.get;lib.Codec.read 5"])
        session.toggleClassFilter(.jdk)
        XCTAssertEqual(folded(session), ["app.Main.main 1", "app.Main.main;app.Work.work;lib.Codec.read 5"])
        XCTAssertEqual(session.tree?.totalSamples, 6, "no sample is lost")
        session.toggleClassFilter(.jdk)
        XCTAssertEqual(folded(session).count, 2)
        XCTAssertTrue(session.classFilters.isEmpty)
    }

    func testHidingLibrariesUsesTheProjectClassifier() {
        let session = layeredSession()
        session.addClassFilter(.libraries)
        XCTAssertEqual(folded(session), ["app.Main.main 1", "app.Main.main;app.Work.work;java.util.HashMap.get 5"])

        // Without a way to tell a library from the project, hiding libraries hides nothing.
        let unclassified = IDEProfilerSession(recordings: [], title: "plain")
        unclassified.setProfileForTesting(layeredProfile())
        unclassified.addClassFilter(.libraries)
        XCTAssertEqual(unclassified.tree?.totalSamples, 6)
        XCTAssertEqual(folded(unclassified).count, 2)
        XCTAssertTrue(folded(unclassified).contains("app.Main.main;app.Work.work;java.util.HashMap.get;lib.Codec.read 5"))
    }

    func testHidingByPatternAndEverythingStillCountsAtTheRoot() throws {
        let session = layeredSession()
        session.addClassFilter(.pattern(try XCTUnwrap(JavaClassPattern("app"))))
        // The lone `main` sample has no frame left: it is the root's own, which has no folded line.
        XCTAssertEqual(folded(session), ["java.util.HashMap.get;lib.Codec.read 5"])
        XCTAssertEqual(session.tree?.totalSamples, 6)
        session.addClassFilter(.pattern(try XCTUnwrap(JavaClassPattern("*.Codec"))))
        session.addClassFilter(.jdk)
        XCTAssertEqual(session.tree?.totalSamples, 6)
        XCTAssertEqual(session.tree?.children(of: JavaProfileTree.root).count, 0, "every frame hidden: the samples are the root's")
    }

    func testChangingClassFiltersClearsTheWhatIfsAndRelayouts() throws {
        let session = layeredSession()
        let tree = try XCTUnwrap(session.tree)
        let main = try XCTUnwrap(tree.children(of: JavaProfileTree.root).first)
        session.focusOnSubtree(node: main)
        XCTAssertEqual(session.transforms.count, 1)
        let revision = session.treeRevision
        session.addClassFilter(.jdk)
        XCTAssertTrue(session.transforms.isEmpty, "their node numbers were made on the other shape")
        XCTAssertGreaterThan(session.treeRevision, revision)
        // Adding the same filter again is not a change.
        let again = session.treeRevision
        session.addClassFilter(.jdk)
        XCTAssertEqual(session.treeRevision, again)
        session.removeClassFilter(.jdk)
        XCTAssertEqual(folded(session).count, 2)
    }

    func testHiddenClassesAreHiddenOnBothSidesOfAComparison() throws {
        let session = layeredSession()
        session.setBaseline(IDEProfilerSession.BaselineCandidate(
            id: "l", title: "layers-before", subtitle: "", recordings: [], profile: layeredProfile()
        ))
        session.addClassFilter(.jdk)
        let comparison = try XCTUnwrap(session.comparison)
        XCTAssertFalse(comparison.rows.contains { $0.method.className.hasPrefix("java.") })
        XCTAssertTrue(comparison.rows.allSatisfy { $0.baselineSelf == $0.targetSelf })
    }

    // MARK: - Compatibility

    private func timedProfile(period: Int, kind: String = "jdk.ExecutionSample", thread: String = "main") -> JavaProfile {
        let symbols = JavaProfileSymbols()
        let frame = symbols.internFrame(method: symbols.internMethod(className: "app.Main", name: "main", parameters: ""), line: 1)
        var profile = JavaProfile(symbols: symbols)
        for index in 0..<40 {
            profile.ingest(JFRTextEvent(
                type: kind, thread: thread, frames: [frame],
                attributes: kind == "jdk.ObjectAllocationSample" ? ["weight": "64 bytes", "objectClass": "byte[]"] : [:],
                timeMillis: 5_000 + Int64(index * period)
            ))
        }
        return profile
    }

    func testABaselineSampledAtAnotherPeriodWarnsButStillCompares() throws {
        let session = IDEProfilerSession(recordings: [], title: "now")
        session.setProfileForTesting(timedProfile(period: 10))
        session.setBaseline(IDEProfilerSession.BaselineCandidate(
            id: "p", title: "20ms.jfr", subtitle: "", recordings: [], profile: timedProfile(period: 20)
        ))
        guard case .warning(let text) = try XCTUnwrap(session.comparisonCompatibility) else { return XCTFail("no warning") }
        XCTAssertTrue(text.contains("20 ms"), text)
        XCTAssertNotNil(session.comparison, "a period difference is a caveat, not a refusal")
    }

    func testABaselineWithoutTheShownKindIsRefusedWithTheReason() throws {
        let session = IDEProfilerSession(recordings: [], title: "now")
        session.setProfileForTesting(timedProfile(period: 10, kind: "jdk.ObjectAllocationSample"))
        session.setBaseline(IDEProfilerSession.BaselineCandidate(
            id: "c", title: "cpu-only.jfr", subtitle: "", recordings: [], profile: timedProfile(period: 10)
        ))
        session.kind = .allocations
        XCTAssertTrue(try XCTUnwrap(session.comparisonCompatibility).isIncompatible)
        XCTAssertNil(session.comparison)
        XCTAssertTrue(session.isComparing, "the baseline stays chosen: another kind may fit")
        session.kind = .cpu
        XCTAssertTrue(try XCTUnwrap(session.comparisonCompatibility).isIncompatible, "this side has no CPU samples now")
    }

    func testAThreadOnlyTheTargetHasRefusesTheComparison() throws {
        let session = IDEProfilerSession(recordings: [], title: "now")
        session.setProfileForTesting(timedProfile(period: 10, thread: "pool-1"))
        session.setBaseline(IDEProfilerSession.BaselineCandidate(
            id: "t", title: "before.jfr", subtitle: "", recordings: [], profile: timedProfile(period: 10, thread: "main")
        ))
        XCTAssertNotNil(session.comparison, "all threads compare")
        session.thread = "pool-1"
        XCTAssertNil(session.comparison)
        XCTAssertTrue(session.comparisonCompatibility?.message?.contains("pool-1") ?? false)
    }
}
