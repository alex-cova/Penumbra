import Foundation
import Testing
@testable import SubprocessKit

struct StreamingOutputTests {
    private enum Failure: Error { case diskFull }

    @Test func sinkFailureStopsChildAndPropagatesAfterDrain() async throws {
        var request = SubprocessRequest(executable: "/bin/sh", arguments: ["-c", "printf x; exec /bin/sleep 20"])
        request.timeout = .seconds(3)
        request.terminationGrace = .milliseconds(20)
        let start = ContinuousClock.now
        await #expect(throws: Failure.diskFull) {
            try await SubprocessRunner.runStreaming(request) { _, _ in throw Failure.diskFull }
        }
        #expect(start.duration(to: .now) < .seconds(3))
    }
}
