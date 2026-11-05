import XCTest

/// Canonical deadline-based poll for asynchronous test conditions. Prefer this over a fixed
/// `Task.sleep`: it returns as soon as the condition holds and fails with the elapsed time and
/// the call site when it does not, instead of sleeping through a break or flaking under load.
/// Extracted from the identical `waitUntil` helpers duplicated across the completion, git-status,
/// debug-session, and agent-runner suites.
extension XCTestCase {
    /// The shortest time a poll gives up after, whatever a caller asks for.
    ///
    /// A test that creates a workspace and then waits on something asynchronous (a diff, a load)
    /// does not time anything: its callers wrote 2 and 3 seconds as "long enough". Measured here,
    /// the main thread is busy for about 0.25 s after a workspace is made (nine deferred layout
    /// flushes of window-less editor views), and on an idle machine about one workspace in thirty
    /// leaves it blocked for 3 to 6 seconds (the cause is not understood; a failure that XCTest
    /// symbolicates, in a Debug build, adds seconds of its own). A condition that holds ends the
    /// wait at once, so a generous ceiling costs a passing run nothing and only makes a real failure
    /// take longer to report.
    static let minimumPollTimeout: TimeInterval = 15

    /// Polls `condition` until it holds or `timeout` passes (never less than ``minimumPollTimeout``).
    /// File/line default to the call site.
    ///
    /// Main-actor bound because callers poll main-actor state (view flags, controllers).
    @MainActor
    func waitForCondition(
        _ description: @autoclosure () -> String = "",
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async {
        let timeout = max(timeout, Self.minimumPollTimeout)
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            if Date() > deadline {
                let detail = description()
                XCTFail(
                    "Timed out after \(timeout)s waiting for \(detail.isEmpty ? "condition" : detail)",
                    file: file,
                    line: line
                )
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}
