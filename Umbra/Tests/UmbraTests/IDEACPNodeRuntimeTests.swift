import Foundation
import XCTest
@testable import Umbra

final class IDEACPNodeRuntimeTests: XCTestCase {
    func testSemverParsing() {
        XCTAssertEqual(IDEACPSemver("v22.1.3"), IDEACPSemver(22, 1, 3))
        XCTAssertEqual(IDEACPSemver("22"), IDEACPSemver(22, 0, 0))
        XCTAssertEqual(IDEACPSemver("22.4-rc.1"), IDEACPSemver(22, 4, 0))
        XCTAssertNil(IDEACPSemver("abc"))
        XCTAssertNil(IDEACPSemver("1.2.3.4"))
        XCTAssertTrue(IDEACPSemver(22, 10, 0) > IDEACPSemver(22, 9, 9))
    }

    func testEnginesRanges() {
        let node = IDEACPSemver(22, 3, 0)
        XCTAssertEqual(node.satisfies(">=22"), .satisfied)
        XCTAssertEqual(node.satisfies(">=24"), .unsatisfied)
        XCTAssertEqual(node.satisfies(">=18 <22"), .unsatisfied)
        XCTAssertEqual(node.satisfies(">=18 <24"), .satisfied)
        XCTAssertEqual(node.satisfies("^22.1"), .satisfied)
        XCTAssertEqual(node.satisfies("^20"), .unsatisfied)
        XCTAssertEqual(node.satisfies("~22.3"), .satisfied)
        XCTAssertEqual(node.satisfies("~22.2"), .unsatisfied)
        XCTAssertEqual(node.satisfies("20 || 22"), .satisfied)
        XCTAssertEqual(node.satisfies("20 || 24"), .unsatisfied)
        XCTAssertEqual(node.satisfies("22"), .satisfied)
        XCTAssertEqual(node.satisfies("lts/*"), .unknown, "syntax Umbra does not read is reported, not guessed")
        XCTAssertEqual(IDEACPSemver(26, 12, 1).satisfies(">=22"), .satisfied)
    }

    func testLocatingNodeUsesTheGivenPathAndPrefersNpmNextToIt() {
        let present: Set<String> = ["/a/node", "/a/npm", "/b/node", "/b/npm"]
        let located = IDEACPNodeRuntime.locate(pathValue: "/x:/a:/b", isExecutable: { present.contains($0) })
        XCTAssertEqual(located?.node, "/a/node")
        XCTAssertEqual(located?.npm, "/a/npm")
        let split = IDEACPNodeRuntime.locate(pathValue: "/c:/d", isExecutable: { ["/c/node", "/d/npm"].contains($0) })
        XCTAssertEqual(split?.node, "/c/node")
        XCTAssertEqual(split?.npm, "/d/npm")
        XCTAssertNil(IDEACPNodeRuntime.locate(pathValue: "/c:/d", isExecutable: { $0 == "/c/npm" }))
    }

    func testCheckReportsMissingTooOldAndUnreadableRequirements() throws {
        XCTAssertThrowsError(try IDEACPNodeRuntime.check(nil, requirement: ">=22")) {
            XCTAssertEqual($0 as? IDEACPAdapterError, .nodeMissing)
        }
        let old = IDEACPNodeInstallation(node: "/n", npm: "/n", version: IDEACPSemver(18, 0, 0))
        XCTAssertThrowsError(try IDEACPNodeRuntime.check(old, requirement: ">=22")) {
            XCTAssertEqual($0 as? IDEACPAdapterError, .nodeTooOld(found: "18.0.0", required: "Node.js >=22"))
        }
        XCTAssertEqual(try IDEACPNodeRuntime.check(acpFakeNode(), requirement: ">=22"), [])
        XCTAssertEqual(try IDEACPNodeRuntime.check(acpFakeNode(), requirement: "weird").count, 1)
        XCTAssertEqual(IDEACPNodeRuntime.requirement(engines: ["node": ">=22"], fallbackMajor: 18), ">=22")
        XCTAssertEqual(IDEACPNodeRuntime.requirement(engines: nil, fallbackMajor: 20), ">=20")
        XCTAssertEqual(IDEACPNodeRuntime.parseVersion("v26.12.1\n"), IDEACPSemver(26, 12, 1))
    }
}
