import Foundation
import SwiftIntelligence
import XCTest

final class SwiftProfileCommandTests: XCTestCase {
    func testRecordLaunchesTheProgramWithTheTimeProfiler() {
        XCTAssertEqual(
            SwiftProfileCommand.recordArguments(
                trace: URL(fileURLWithPath: "/tmp/run.trace"), executable: URL(fileURLWithPath: "/p/.build/release/app"), arguments: ["--n", "3"]
            ),
            ["xctrace", "record", "--template", "Time Profiler", "--output", "/tmp/run.trace", "--launch", "--", "/p/.build/release/app", "--n", "3"]
        )
        XCTAssertTrue(SwiftProfileCommand.recordArguments(
            trace: URL(fileURLWithPath: "/t.trace"), executable: URL(fileURLWithPath: "/a"), timeLimit: "30s"
        ).contains("--time-limit"))
    }

    func testExportAsksForTheTimeProfileTableOfTheFirstRun() {
        let arguments = SwiftProfileCommand.exportArguments(trace: URL(fileURLWithPath: "/t.trace"), output: URL(fileURLWithPath: "/o.xml"))
        XCTAssertEqual(arguments, ["xctrace", "export", "--input", "/t.trace", "--xpath", #"/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]"#, "--output", "/o.xml"])
    }

    func testOnlyATracePackageIsARecording() {
        XCTAssertTrue(SwiftProfileCommand.isTraceRecording(URL(fileURLWithPath: "/x/run.trace")))
        XCTAssertTrue(SwiftProfileCommand.isTraceRecording(URL(fileURLWithPath: "/x/RUN.TRACE")))
        XCTAssertFalse(SwiftProfileCommand.isTraceRecording(URL(fileURLWithPath: "/x/run.jfr")))
    }
}
