import Foundation
import XCTest
@testable import Umbra

/// js-debug through `DAPDebugSession`: breakpoint, variables, step and evaluate.
/// Gated on `UMBRA_JS_DEBUG=1`. `UMBRA_JS_DEBUG_PATH` is `dapDebugServer.js`. Skipped when it is absent.
@MainActor
final class JSDebugSessionTests: XCTestCase {
    func testBreakpointStopVariablesStepAndEvaluate() async throws {
        guard ProcessInfo.processInfo.environment["UMBRA_JS_DEBUG"] == "1" else {
            throw XCTSkip("Set UMBRA_JS_DEBUG=1 to run the js-debug session")
        }
        guard let script = JSDebugDiscovery.serverScript(userPath: ProcessInfo.processInfo.environment["UMBRA_JS_DEBUG_PATH"]),
              let node = JSDebugDiscovery.node() else {
            throw XCTSkip("js-debug or node was not found")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-js-debug-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("main.js")
        try Data("let value = 21;\nlet answer = value + 21;\nconsole.log(answer);\n".utf8).write(to: source)

        let session = DAPDebugSession()
        await session.launchJavaScript(
            node: node, serverScript: URL(fileURLWithPath: script), program: source, workingDirectory: root,
            lineBreakpoints: [source.path: [2]]
        )
        defer { session.stop() }
        try await waitUntil(session, isAtLine: 2)
        let value = session.variables.first { $0.name == "value" }?.value
        XCTAssertTrue(value?.contains("21") == true, session.failureSummary)
        session.stepOver()
        try await waitUntil(session, isAtLine: 3)
        let evaluated = await session.evaluate("answer")
        XCTAssertTrue(evaluated?.contains("42") == true, session.failureSummary)
        session.stop()
    }

    private func waitUntil(_ session: DAPDebugSession, isAtLine line: Int) async throws {
        for _ in 0..<80 {
            if session.isStopped, session.frames.contains(where: { $0.line == line && $0.file?.lastPathComponent == "main.js" }) {
                return
            }
            if case .failed(let message) = session.state {
                XCTFail(message)
                throw JSDebugWaitEnded()
            }
            if case .terminated = session.state {
                XCTFail("the session ended before line \(line). \(session.failureSummary)")
                throw JSDebugWaitEnded()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("timed out waiting for line \(line). \(session.failureSummary)")
        throw JSDebugWaitEnded()
    }
}

private struct JSDebugWaitEnded: Error {}
