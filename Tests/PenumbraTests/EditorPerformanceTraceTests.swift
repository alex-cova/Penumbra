import XCTest
import EditorIntelligence

final class EditorPerformanceTraceTests: XCTestCase {
    func testReducerReportsMedianP95P99AndWorst() {
        let distribution = LatencyDistributionReducer.reduce([5, 1, 4, 2, 3])
        XCTAssertEqual(distribution.count, 5)
        XCTAssertEqual(distribution.median, 3)
        XCTAssertEqual(distribution.p95, 5)
        XCTAssertEqual(distribution.p99, 5)
        XCTAssertEqual(distribution.worst, 5)
    }

    func testReducerIgnoresEmptyInput() {
        let distribution = LatencyDistributionReducer.reduce([])
        XCTAssertEqual(distribution, LatencyDistribution(count: 0, median: 0, p95: 0, p99: 0, worst: 0))
    }

    func testTraceRecordsOnlyWhileEnabled() {
        let trace = EditorPerformanceTrace()
        XCTAssertFalse(trace.isEnabled)
        trace.measure(.textMutation) { _ = 1 + 1 }
        XCTAssertTrue(trace.samples(for: .textMutation).isEmpty)

        trace.isEnabled = true
        trace.measure(.textMutation) {
            _ = (0..<20).reduce(0, +)
        }
        let samples = trace.samples(for: .textMutation)
        XCTAssertEqual(samples.count, 1)
        XCTAssertGreaterThanOrEqual(samples[0], 0)

        trace.isEnabled = false
        trace.record(.textMutation, seconds: 1)
        XCTAssertEqual(trace.samples(for: .textMutation).count, 1)
    }

    func testGrossFreezeThreshold() {
        XCTAssertFalse(EditorPerformanceGuard.isGrossFreeze(0.2))
        XCTAssertTrue(EditorPerformanceGuard.isGrossFreeze(1))
        XCTAssertTrue(EditorPerformanceGuard.isGrossFreeze(1.5))
        XCTAssertEqual(
            EditorPerformanceGuard.grossFreezes(["insert_large": 1.2, "insert_small": 0.001]),
            ["insert_large"]
        )
    }

    func testDashboardSwitchAndLabels() throws {
        XCTAssertFalse(EditorPerformanceDashboard.isEnabled(environment: [:]))
        XCTAssertTrue(EditorPerformanceDashboard.isEnabled(environment: [
            EditorPerformanceDashboard.switchEnvironmentVariable: "1"
        ]))
        XCTAssertFalse(EditorPerformanceDashboard.performsNetworkAccess)

        let text = EditorPerformanceDashboard.render(
            frameSeconds: 0.0071,
            textMutationSeconds: 0.00018,
            incrementalParseSeconds: 0.0014,
            completionSeconds: 0.017,
            diagnosticsSeconds: 0.028,
            indexQuerySeconds: 0.003,
            mainThreadSeconds: 0.0041,
            droppedFrames: 0,
            memoryBytes: 620 * 1_048_576
        )
        for label in [
            "Frame:", "Text Mutation:", "Incremental Parse:", "Completion:",
            "Diagnostics:", "Index Query:", "Main Thread:", "Dropped Frames:", "Memory:"
        ] {
            XCTAssertTrue(text.contains(label), text)
        }
        XCTAssertTrue(text.contains("7.100 ms"))
        XCTAssertTrue(text.contains("0.180 ms"))
        XCTAssertTrue(text.contains("620.0 MB"))
        XCTAssertFalse(text.contains("http"))

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/EditorIntelligence/Performance/EditorPerformanceDashboard.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertFalse(source.contains("URLSession"))
        XCTAssertFalse(source.contains("NWConnection"))
    }
}
