import Foundation
import XCTest
@testable import Umbra

@MainActor
final class JavaDebugSessionBridgeTests: XCTestCase {
    func testIdleSessionMapsToIdle() {
        let bridge = JavaDebugSessionBridge(JavaDebugSession())
        XCTAssertEqual(bridge.state, .idle)
        XCTAssertFalse(bridge.isActive)
        XCTAssertFalse(bridge.isStopped)
        XCTAssertTrue(bridge.threads.isEmpty)
        XCTAssertTrue(bridge.frames.isEmpty)
        XCTAssertTrue(bridge.variables.isEmpty)
    }

    func testStoppedStateKeepsTheFileLineAndReason() {
        let file = URL(fileURLWithPath: "/tmp/Main.java")
        let mapped = IDEDebugSessionMapping.state(.stopped(file: file, line: 12, reason: "breakpoint"))
        XCTAssertEqual(mapped, .stopped(file: file, line: 12, reason: "breakpoint"))
    }

    func testFrameAndVariableUseTheJavaValues() {
        let frame = JavaDebugStackFrame(
            index: 2, name: "main", className: "demo.Main", filePath: "/tmp/Main.java", line: 8
        )
        let mapped = IDEDebugSessionMapping.frame(frame)
        XCTAssertEqual(mapped.id, 2)
        XCTAssertEqual(mapped.name, "main")
        XCTAssertEqual(mapped.line, 8)
        XCTAssertEqual(mapped.file?.path, "/tmp/Main.java")

        let library = JavaDebugStackFrame(index: 3, name: "start", className: "java.lang.Thread", filePath: "", line: 0)
        XCTAssertNil(IDEDebugSessionMapping.frame(library).file)

        let value = JavaDebugValue(name: "count", type: "int", value: "3", expression: "count")
        let variable = IDEDebugSessionMapping.variable(value)
        XCTAssertEqual(variable.name, "count")
        XCTAssertEqual(variable.value, "3")
        XCTAssertEqual(variable.variablesReference, 0)
    }
}
