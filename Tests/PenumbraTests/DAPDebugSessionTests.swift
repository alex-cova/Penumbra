import Foundation
import XCTest
@testable import Umbra

/// The product path of the lldb-dap spike: breakpoint, variables, step and evaluate through
/// `DAPDebugSession`. Gated on `UMBRA_LLDB_DAP=1` and skipped when `lldb-dap` is absent.
@MainActor
final class DAPDebugSessionTests: XCTestCase {
    func testBreakpointStopVariablesStepAndEvaluate() async throws {
        guard ProcessInfo.processInfo.environment["UMBRA_LLDB_DAP"] == "1" else {
            throw XCTSkip("Set UMBRA_LLDB_DAP=1 to run the lldb-dap session")
        }
        let userPath = ProcessInfo.processInfo.environment["UMBRA_LLDB_DAP_PATH"]
        guard let adapter = await LLDBDAPSpike.discover(userPath: userPath) else {
            throw XCTSkip("lldb-dap was not found")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-dap-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("main.swift")
        try Data("let value = 21\nlet answer = value + 21\nprint(answer)\n".utf8).write(to: source)
        let binary = root.appendingPathComponent("spike")
        try await LLDBDAPSpike.compileExecutable(source: source, binary: binary)

        let session = DAPDebugSession()
        await session.launch(
            adapterPath: adapter, program: binary, workingDirectory: root,
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
            if session.isStopped, session.frames.contains(where: { $0.line == line }) { return }
            if case .failed(let message) = session.state {
                XCTFail(message)
                throw WaitEnded()
            }
            if case .terminated = session.state {
                XCTFail("the session ended before line \(line). \(session.failureSummary)")
                throw WaitEnded()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("timed out waiting for line \(line). \(session.failureSummary)")
        throw WaitEnded()
    }
}

private struct WaitEnded: Error {}

@MainActor
extension DAPDebugSession {
    var failureSummary: String {
        let names = variables.map { "\($0.name)=\($0.value)" }.joined(separator: ", ")
        return "state=\(state) frames=\(frames.map { "\($0.name):\($0.line)" }) variables=\(names)"
    }
}
