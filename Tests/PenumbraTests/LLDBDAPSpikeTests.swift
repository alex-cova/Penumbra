import XCTest
@testable import Umbra

/// Gated on `UMBRA_LLDB_DAP=1`. Skipped when `lldb-dap` is absent. A user path overrides discovery
/// through `UMBRA_LLDB_DAP_PATH`.
final class LLDBDAPSpikeTests: XCTestCase {
    func testBreakpointStopVariablesStepAndEvaluate() async throws {
        guard ProcessInfo.processInfo.environment["UMBRA_LLDB_DAP"] == "1" else {
            throw XCTSkip("Set UMBRA_LLDB_DAP=1 to run the lldb-dap spike")
        }
        let userPath = ProcessInfo.processInfo.environment["UMBRA_LLDB_DAP_PATH"]
        guard let adapter = await LLDBDAPSpike.discover(userPath: userPath) else {
            throw XCTSkip("lldb-dap was not found")
        }
        let report = await LLDBDAPSpike.run(adapterPath: adapter)
        XCTAssertTrue(report.launched, report.summary)
        XCTAssertTrue(report.stopped, report.summary)
        XCTAssertTrue(report.variableValue?.contains("21") == true, report.summary)
        XCTAssertTrue(report.stepped, report.summary)
        XCTAssertTrue(report.evaluated?.contains("42") == true, report.summary)
    }
}
