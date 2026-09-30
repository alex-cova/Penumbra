import Foundation
import XCTest
@testable import Umbra

final class JavaBreakpointStoreTests: XCTestCase {
    private var directory: URL!
    private let root = URL(fileURLWithPath: "/work/alpha", isDirectory: true)
    private let source = URL(fileURLWithPath: "/work/alpha/src/A.java")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JavaBreakpointStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var storeURL: URL { directory.appendingPathComponent("breakpoints.json") }

    func testAFileWrittenBeforePropertiesExistedStillLoads() throws {
        let id = UUID()
        let old = """
        {"\(root.path)": {"breakpoints": [{"id": "\(id.uuidString)", "filePath": "\(source.path)", "line": 7, "isEnabled": false}]}}
        """
        try Data(old.utf8).write(to: storeURL)
        let store = JavaBreakpointStore(storeURL: storeURL)
        let breakpoint = try XCTUnwrap(store.breakpoints(forProject: root).first)
        XCTAssertEqual(breakpoint.id, id)
        XCTAssertEqual(breakpoint.line, 7)
        XCTAssertFalse(breakpoint.isEnabled)
        XCTAssertEqual(breakpoint.kind, .line)
        XCTAssertEqual(breakpoint.suspendPolicy, .all)
        XCTAssertNil(breakpoint.condition)
        XCTAssertFalse(store.isMuted(project: root))
    }

    func testPropertiesAndMuteRoundTrip() throws {
        let store = JavaBreakpointStore(storeURL: storeURL)
        var breakpoint = try XCTUnwrap(store.toggle(atLine: 3, file: source, project: root))
        breakpoint.condition = "i == 3"
        breakpoint.suspendPolicy = .thread
        breakpoint.logExpression = "\"i=\" + i"
        breakpoint.passCount = 4
        store.update(breakpoint, project: root)
        store.add(JavaBreakpoint(filePath: "", line: 0, kind: .exception(className: "java.lang.IllegalStateException", caught: true, uncaught: false)),
                  project: root)
        store.setMuted(true, project: root)

        let fresh = JavaBreakpointStore(storeURL: storeURL)
        XCTAssertEqual(fresh.breakpoints(forProject: root).first, breakpoint)
        XCTAssertEqual(fresh.breakpoints(forProject: root).count, 2)
        XCTAssertEqual(fresh.breakpoints(forFile: source, project: root).count, 1, "only line breakpoints belong to a file")
        XCTAssertTrue(fresh.isMuted(project: root))
    }

    func testMovingLinesAfterAnEditAndDroppingADeletedLine() throws {
        let store = JavaBreakpointStore(storeURL: storeURL)
        let a = try XCTUnwrap(store.toggle(atLine: 3, file: source, project: root))
        let b = try XCTUnwrap(store.toggle(atLine: 9, file: source, project: root))
        let other = URL(fileURLWithPath: "/work/alpha/src/B.java")
        let c = try XCTUnwrap(store.toggle(atLine: 9, file: other, project: root))

        XCTAssertTrue(store.moveLines(in: source, to: [a.id: 4, b.id: 10], removing: [], project: root))
        XCTAssertEqual(store.breakpoints(forFile: source, project: root).map(\.line), [4, 10])
        XCTAssertFalse(store.moveLines(in: source, to: [a.id: 4, b.id: 10], removing: [], project: root), "nothing changed")

        XCTAssertTrue(store.moveLines(in: source, to: [b.id: 9], removing: [a.id], project: root))
        XCTAssertEqual(store.breakpoints(forProject: root).map(\.id), [b.id, c.id], "another file's breakpoint stays")
    }

    func testAdapterRequestCarriesEveryProperty() {
        let breakpoint = JavaBreakpoint(filePath: source.path, line: 5, condition: " x > 1 ", suspendPolicy: .none,
                                        logMessage: true, logExpression: "x", removeOnceHit: true, passCount: 2)
        let request = breakpoint.adapterRequest(imports: ["import java.util.List"])
        XCTAssertEqual(request["breakpointId"] as? String, breakpoint.id.uuidString)
        XCTAssertEqual(request["kind"] as? String, "line")
        XCTAssertEqual(request["line"] as? Int, 5)
        XCTAssertEqual(request["condition"] as? String, "x > 1")
        XCTAssertEqual(request["suspendPolicy"] as? String, "none")
        XCTAssertEqual(request["logMessage"] as? Bool, true)
        XCTAssertEqual(request["logExpression"] as? String, "x")
        XCTAssertEqual(request["removeOnceHit"] as? Bool, true)
        XCTAssertEqual(request["passCount"] as? Int, 2)
        XCTAssertEqual(request["imports"] as? [String], ["import java.util.List"])

        let method = JavaBreakpoint(filePath: "", line: 0, kind: .method(className: "a.B", methodName: "run")).adapterRequest(imports: [])
        XCTAssertEqual(method["kind"] as? String, "method")
        XCTAssertEqual(method["methodName"] as? String, "run")
        XCTAssertNil(method["condition"])
    }

    func testOnlyLinesWithCodeTakeABreakpoint() {
        XCTAssertTrue(IDEWorkspace.canHoldBreakpoint("        int x = 1;"))
        XCTAssertTrue(IDEWorkspace.canHoldBreakpoint("}"))
        XCTAssertFalse(IDEWorkspace.canHoldBreakpoint("   "))
        XCTAssertFalse(IDEWorkspace.canHoldBreakpoint("    // a comment"))
        XCTAssertFalse(IDEWorkspace.canHoldBreakpoint(" * Javadoc"))
        XCTAssertFalse(IDEWorkspace.canHoldBreakpoint("import java.util.List;"))
        XCTAssertFalse(IDEWorkspace.canHoldBreakpoint("    @Override"))
    }

    func testImportsAreReadUpToTheFirstType() {
        let source = """
        package demo;

        import java.util.List;
        import static java.util.Map.entry;

        public class A {
            import notAnImport;
        }
        """
        XCTAssertEqual(JavaDebugSession.imports(inSource: source), ["import java.util.List", "import static java.util.Map.entry"])
    }
}

final class IDEInlineDebugValueTests: XCTestCase {
    func testValuesGoAtTheEndOfTheLineThatLastSetThem() {
        let text = """
        class A {
            int field = 1;

            void run(int count) {
                int total = 0;
                for (int i = 0; i < count; i++) {
                    total += i;
                }
                String name = "x"; // STOP
            }
        }
        """
        let hints = IDEWorkspace.inlineValueHints(
            [("count", "3"), ("total", "3"), ("i", "2"), ("name", "\"x\""), ("field", "1")],
            stopLine: 9, text: text
        )
        let lines = text.components(separatedBy: "\n")
        func lineEnd(_ line: Int) -> Int {
            lines.prefix(line - 1).reduce(0) { $0 + ($1 as NSString).length + 1 } + (lines[line - 1] as NSString).length
        }
        let byOffset = Dictionary(uniqueKeysWithValues: hints.map { ($0.utf16Offset, $0.label) })
        // Each local goes on the last line at or above the stop that mentions it.
        XCTAssertEqual(byOffset[lineEnd(6)], "count = 3")
        XCTAssertEqual(byOffset[lineEnd(7)], "total = 3, i = 2")
        XCTAssertEqual(byOffset[lineEnd(9)], "name = \"x\"")
        XCTAssertEqual(hints.count, 3, "a field outside the method is not shown")
        // Stopped on the signature line, only the parameter is there.
        XCTAssertEqual(IDEWorkspace.inlineValueHints([("count", "3")], stopLine: 4, text: text).map(\.label), ["count = 3"])
    }
}
