import Foundation
import JavaIntelligence
import XCTest
@testable import Umbra

@MainActor
final class JavaDebugSessionAdapterFailureTests: XCTestCase {
    func testSilentAdapterFailsTheLaunchWithinTheRequestDeadline() async throws {
        let session = makeSession(script: "read -r request; read -r disconnect", timeout: .milliseconds(200))
        defer { session.stop() }
        await launch(session)
        guard case .failed(let message) = session.state else { return XCTFail("Expected launch to fail") }
        XCTAssertTrue(message.contains("did not reply to"), message)
        XCTAssertTrue(message.contains("launch"), message)
    }

    func testAdapterEOFUnblocksAnOutstandingLaunch() async throws {
        let session = makeSession(script: "read -r request; exec 1>&-; read -r disconnect", timeout: .seconds(2))
        defer { session.stop() }
        await launch(session)
        guard case .failed(let message) = session.state else { return XCTFail("Expected launch to fail") }
        XCTAssertEqual(message, JavaDebugProcessError.disconnected.localizedDescription)
    }

    private func makeSession(script: String, timeout: Duration) -> JavaDebugSession {
        JavaDebugSession(requestTimeout: timeout) { _ in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            process.standardInput = Pipe()
            process.standardOutput = Pipe()
            try process.run()
            return process
        }
    }

    private func launch(_ session: JavaDebugSession) async {
        await session.start(
            launch: JavaManagedLaunch(
                javaExecutable: URL(fileURLWithPath: "/unused/bin/java"),
                vmArguments: [],
                classpath: [],
                mainClass: "Fixture",
                programArguments: [],
                environment: [:],
                jdwpPort: 0,
                suspendOnStart: true
            ),
            breakpoints: []
        )
    }
}
