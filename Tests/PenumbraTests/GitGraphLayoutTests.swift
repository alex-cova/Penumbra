import XCTest
@testable import GitIntelligence

final class GitGraphLayoutTests: XCTestCase {
    private func commit(_ hash: String, _ parents: [String] = []) -> GitCommit {
        GitCommit(hash: hash, parents: parents, author: "a", email: "", date: Date(), refs: [], subject: hash)
    }

    func testLinearHistoryUsesOneLane() {
        var layout = GitGraphLayout()
        let rows = layout.append([commit("c", ["b"]), commit("b", ["a"]), commit("a")])
        XCTAssertEqual(rows.map(\.nodeLane), [0, 0, 0])
        XCTAssertEqual(Set(rows.map(\.colorIndex)).count, 1)
        XCTAssertTrue(rows.allSatisfy { !$0.isMerge })
    }

    func testMergeOpensSecondLaneThenJoins() {
        // m merges (b, f); f and b both descend from a.
        var layout = GitGraphLayout()
        let rows = layout.append([
            commit("m", ["b", "f"]),
            commit("f", ["a"]),
            commit("b", ["a"]),
            commit("a")
        ])
        XCTAssertTrue(rows[0].isMerge)
        XCTAssertEqual(rows[0].nodeLane, 0)
        XCTAssertEqual(rows[1].nodeLane, 1)      // f sits on the branch lane
        XCTAssertEqual(rows[2].nodeLane, 0)      // b stays on the main lane
        // a is reached by both lanes: it lands on lane 0 and lane 1 converges into it.
        XCTAssertEqual(rows[3].nodeLane, 0)
        XCTAssertTrue(rows[3].segments.contains { $0.fromLane == 1 && $0.toLane == 0 && $0.toAnchor == .center })
    }

    func testOctopusMergeUsesThreeLanes() {
        var layout = GitGraphLayout()
        let rows = layout.append([commit("m", ["a", "b", "c"])])
        XCTAssertEqual(rows[0].laneCount, 3)
        XCTAssertEqual(Set(rows[0].segments.map(\.toLane)), [0, 1, 2])
    }

    func testTwoTipsSharingParentConverge() {
        var layout = GitGraphLayout()
        let rows = layout.append([commit("x", ["p"]), commit("y", ["p"]), commit("p")])
        XCTAssertEqual(rows[0].nodeLane, 0)
        XCTAssertEqual(rows[1].nodeLane, 1)
        XCTAssertEqual(rows[2].nodeLane, 0)
    }

    func testFreedSlotIsReused() {
        var layout = GitGraphLayout()
        // Lane 1 opens for "f", closes at its root, then "z" should reuse slot 1 rather than lane 2.
        let rows = layout.append([
            commit("m", ["b", "f"]),
            commit("f"),
            commit("z", ["y"]),
            commit("b")
        ])
        XCTAssertEqual(rows[2].nodeLane, 1)
    }

    func testPagedAppendMatchesSinglePass() {
        let commits = [
            commit("m", ["b", "f"]), commit("f", ["a"]), commit("b", ["a"]), commit("a")
        ]
        var single = GitGraphLayout()
        let expected = single.append(commits)
        var paged = GitGraphLayout()
        let actual = paged.append(Array(commits[..<2])) + paged.append(Array(commits[2...]))
        XCTAssertEqual(actual, expected)
    }
}
