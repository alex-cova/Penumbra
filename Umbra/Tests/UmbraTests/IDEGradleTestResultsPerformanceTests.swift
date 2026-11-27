import AppKit
import JavaIntelligence
import Observation
import SwiftUI
import XCTest
@testable import Umbra

@MainActor
final class IDEGradleTestResultsPerformanceTests: XCTestCase {
    func testStreamingRepeatedResultsKeepsTheWindowResponsive() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UMBRA_UI_TESTS"] == "1", "Requires the window server")
        let workspace = IDEWorkspace()
        let store = workspace.testResults.gradle
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 1100, height: 330),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: IDEGradleTestResultsPanel(store: store).environment(workspace))
        window.orderFront(nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            window.close()
            window.contentView = nil
            workspace.teardown()
            try? FileManager.default.removeItem(at: directory)
        }
        let history = GradleTestHistory(directory: directory)
        let summary = try await history.begin(root: directory, tasks: [":test"])
        store.begin(summary)
        let session = GradleTestSession(id: summary.id, directory: history.directory(for: summary.id))
        let clock = ContinuousClock()
        var longestGap = Duration.zero
        let heartbeat = Task {
            var last = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
                let now = clock.now
                longestGap = max(longestGap, last.duration(to: now))
                last = now
            }
        }
        defer { heartbeat.cancel() }
        let batchSize = 30
        let testCount = 1_200
        for start in stride(from: 0, to: testCount, by: batchSize) {
            for index in start..<(start + batchSize) {
                let event = try JSONDecoder().decode(GradleTestEvent.self, from: Data("""
                {"version":1,"sessionID":"\(summary.id)","sequence":\(index),"timestamp":0,
                 "kind":"testFinished","build":"\(directory.path)","module":":","task":":test",
                 "nodeID":"test-\(index)","name":"repeated()[\(index)]","className":"Example",
                 "methodName":"repeated","outcome":"passed","durationMs":1}
                """.utf8))
                await session.ingest(event)
            }
            let update = await session.poll()
            store.ingest(update, for: summary.id)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
            if start == 300 {
                try await Task.sleep(for: .milliseconds(200))
                let scroll = try XCTUnwrap(scrollView(in: window.contentView))
                let contentHeight = try XCTUnwrap(scroll.documentView).bounds.height
                XCTAssertGreaterThan(contentHeight, scroll.documentVisibleRect.height)
                XCTAssertEqual(scroll.documentVisibleRect.maxY, contentHeight, accuracy: 24)
                store.selected = ["test-299"]
            }
        }
        let deadline = clock.now + .seconds(3)
        while store.rows.count < testCount && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.rows.count, testCount + 5)
        print("Gradle results longest main actor heartbeat gap: \(longestGap)")
        XCTAssertLessThan(longestGap, .milliseconds(250))

        let redraw = expectation(description: "Output should not invalidate the test outline")
        redraw.isInverted = true
        withObservationTracking { _ = store.rows } onChange: { redraw.fulfill() }
        let output = try JSONDecoder().decode(GradleTestEvent.self, from: Data("""
        {"version":1,"sessionID":"\(summary.id)","sequence":\(testCount),"timestamp":0,
         "kind":"output","build":"\(directory.path)","task":":test","nodeID":"test-299",
         "output":{"offset":0,"length":5,"stream":"StdOut"}}
        """.utf8))
        await session.ingest(output)
        let update = await session.poll()
        store.ingest(update, for: summary.id)
        XCTAssertEqual(store.selectedNode?.output.count, 1)
        await fulfillment(of: [redraw], timeout: 0.2)
    }

    private func scrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scrollView = view as? NSScrollView,
           let document = scrollView.documentView, document.bounds.height > 1_000 {
            return scrollView
        }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }
}
