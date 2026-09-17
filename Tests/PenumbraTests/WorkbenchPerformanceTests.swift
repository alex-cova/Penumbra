import XCTest
@testable import Penumbra

/// Regression guards for workbench tab/split coordination performance characteristics.
final class WorkbenchPerformanceTests: XCTestCase {
    func testAllDocumentsDeduplicatesAcrossPanes() {
        let bench = EditorWorkbench()
        let doc = WorkbenchDocument(displayName: "shared", text: "x")
        bench.openDocument(doc)
        let rightPane = bench.splitActivePane(edge: .trailing)
        bench.openDocument(doc, in: rightPane)
        XCTAssertEqual(bench.allDocuments().count, 1)
    }

    func testRestorationEncodeDecodeIsFast() {
        let bench = EditorWorkbench()
        for index in 0..<8 {
            bench.openDocument(WorkbenchDocument(displayName: "f\(index).txt", text: "line \(index)"))
        }
        bench.splitActivePane(edge: .trailing)
        bench.openDocument(WorkbenchDocument(displayName: "split.txt", text: "split"))

        let start = CFAbsoluteTimeGetCurrent()
        let state = bench.makeRestorationState()
        let data = try! JSONEncoder().encode(state)
        let decoded = try! JSONDecoder().decode(EditorRestorationState.self, from: data)
        let restored = EditorWorkbench()
        restored.restore(from: decoded)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertEqual(restored.panes.count, bench.panes.count)
        XCTAssertLessThan(elapsed, 0.5)
    }
}
