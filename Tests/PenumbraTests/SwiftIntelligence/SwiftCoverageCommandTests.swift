import SwiftIntelligence
import XCTest

final class SwiftCoverageCommandTests: XCTestCase {
    func testTestArgumentsTurnCoverageOnAndKeepFiltersAndTheReport() {
        XCTAssertEqual(SwiftCoverageCommand.testArguments(), ["test", "--enable-code-coverage"])
        XCTAssertEqual(
            SwiftCoverageCommand.testArguments(filters: ["ShapesTests.", "A/b"], xunitOutput: "/tmp/r.xml"),
            ["test", "--enable-code-coverage", "--filter", "ShapesTests.", "--filter", "A/b", "--xunit-output", "/tmp/r.xml"]
        )
    }

    func testThePathIsTheLastLineThatNamesTheJSON() {
        XCTAssertEqual(
            SwiftCoverageCommand.codecovPath(fromOutput: "warning: something\n/tmp/p/.build/codecov/Shapes.json\n")?.path,
            "/tmp/p/.build/codecov/Shapes.json"
        )
        XCTAssertEqual(
            SwiftCoverageCommand.codecovPath(fromOutput: "Building…\n/a/old.json\n/b/new.json  \n")?.path, "/b/new.json"
        )
        XCTAssertNil(SwiftCoverageCommand.codecovPath(fromOutput: "error: no coverage\n"))
        XCTAssertNil(SwiftCoverageCommand.codecovPath(fromOutput: "relative/path.json\n"))
    }
}
