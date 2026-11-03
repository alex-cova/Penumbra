import XCTest
@testable import JavaIntelligence

/// F17: usage search narrows a project to candidate files before verifying them. The persistent
/// name index must give the same usages as the text scan it replaces (the scan is slower, never
/// wrong), and must see an unsaved buffer.
final class JavaUsageCandidateParityTests: XCTestCase {
    private enum Symbol: CaseIterable {
        case type, method, field

        /// Where the `€` caret goes in `p/Widget.java`.
        var widgetSource: String {
            switch self {
            case .type:
                return "package p; public class €Widget { public int size; public void spin(int turns) {} public void spin() {} }"
            case .method:
                return "package p; public class Widget { public int size; public void €spin(int turns) {} public void spin() {} }"
            case .field:
                return "package p; public class Widget { public int €size; public void spin(int turns) {} public void spin() {} }"
            }
        }
    }

    private func makeFixture(_ symbol: Symbol, fillers: Int = 25) throws -> JavaReferenceFixture {
        let fixture = try JavaReferenceFixture()
        try fixture.add("p/Widget.java", symbol.widgetSource)
        try fixture.add("p/A.java", "package p; class A { Widget w = new Widget(); void go() { w.spin(1); w.spin(); w.size = 2; int n = w.size; } }")
        try fixture.add("p/B.java", "package p; class B { java.util.List<Widget> all; void go(Widget w) { w.spin(2); Runnable r = w::spin; } }")
        // The word is there, the symbol is not: a comment, a string, an unrelated class of the same name.
        try fixture.add("p/C.java", "package p; class C { String s = \"Widget spin size\"; /* Widget.spin */ int size; }")
        try fixture.add("q/Widget.java", "package q; public class Widget { public int size; public void spin(int turns) {} }")
        try fixture.add("q/D.java", "package q; class D { Widget w = new Widget(); void go() { w.spin(3); w.size++; } }")
        for number in 0..<fillers {
            try fixture.add("f/F\(number).java", "package f; class F\(number) { int value\(number); void run() { value\(number)++; } }")
        }
        return fixture
    }

    private func signature(_ usages: [JavaUsage]) -> [String] {
        usages.map { "\($0.url.lastPathComponent):\($0.byteRange.lowerBound)-\($0.byteRange.upperBound):\($0.kind)" }.sorted()
    }

    func testIndexedCandidatesGiveTheSameUsagesAsTheTextScan() async throws {
        for symbol in Symbol.allCases {
            let fixture = try makeFixture(symbol)
            let id = try await fixture.requireID()
            let environment = try await fixture.build()
            let scanned = await JavaUsageSearch.collect(
                id, candidates: JavaTextScanCandidateSource(), roots: [fixture.root], environment: environment
            )

            let names = JavaNameIndex(paths: JavaIndexPaths(root: fixture.root.appendingPathComponent("names")))
            for await _ in await names.build(roots: [fixture.root]) {}
            let indexed = await JavaUsageSearch.collect(
                id, candidates: JavaIndexedOrScanningCandidates(nameIndex: names), roots: [fixture.root], environment: environment
            )

            XCTAssertFalse(scanned.isEmpty, "\(symbol): the fixture should have usages")
            XCTAssertEqual(signature(indexed), signature(scanned), "\(symbol)")
            // The decoys really are decoys: neither source returns the unrelated package's Widget.
            XCTAssertFalse(scanned.contains { $0.url.path.contains("/q/") }, "\(symbol)")
        }
    }

    /// The index holds the saved text; a buffer with unsaved edits must still count.
    func testUnsavedBufferIsSeenThroughTheNameIndex() async throws {
        let fixture = try makeFixture(.type)
        let id = try await fixture.requireID()
        let environment = try await fixture.build()
        let names = JavaNameIndex(paths: JavaIndexPaths(root: fixture.root.appendingPathComponent("names")))
        for await _ in await names.build(roots: [fixture.root]) {}

        let unsavedFile = fixture.url("f/F0.java")
        let unsavedText = "package f; class F0 { p.Widget w; }"
        await names.setOverlay(unsavedFile, text: unsavedText)
        var withBuffer = environment
        withBuffer.openBuffer = { url in
            url.standardizedFileURL.path == unsavedFile.standardizedFileURL.path ? unsavedText : nil
        }
        let usages = await JavaUsageSearch.collect(
            id, candidates: JavaIndexedOrScanningCandidates(nameIndex: names), roots: [fixture.root], environment: withBuffer
        )
        XCTAssertTrue(usages.contains { $0.url.lastPathComponent == "F0.java" }, "the unsaved reference must be found")
    }
}
