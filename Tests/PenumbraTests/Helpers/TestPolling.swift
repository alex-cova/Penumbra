import XCTest

/// Canonical deadline-based poll for asynchronous test conditions. Prefer this over a fixed
/// `Task.sleep`: it returns as soon as the condition holds and fails with the elapsed time and
/// the call site when it does not, instead of sleeping through a break or flaking under load.
/// Extracted from the identical `waitUntil` helpers duplicated across the completion, git-status,
/// debug-session, and agent-runner suites.
extension XCTestCase {
    /// Polls `condition` until it holds or `timeout` passes. File/line default to the call site.
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
