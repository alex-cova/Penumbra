import XCTest
@testable import Penumbra
@testable import PenumbraBeautifulMermaid

/// Covers the gitGraph layout's real commit topology: fork edges, merge edges
/// anchored to the merged branch's actual tip, commit types (highlight,
/// reverse, cherry-pick), tags, lane ordering, and both vertical directions.
final class GitGraphDiagramTests: XCTestCase {
    private func extraScene(_ source: String) throws -> ExtraScene {
        let positioned = try MermaidRenderer.layout(source)
        return try XCTUnwrap(positioned.extraScene)
    }

    private func texts(_ scene: ExtraScene) -> [String] {
        scene.items.compactMap { item -> String? in
            if case let .text(text, _, _, _, _, _, _) = item { return text }
            return nil
        }
    }

    private func polylineCount(_ scene: ExtraScene) -> Int {
        scene.items.reduce(0) { count, item in
            if case .polyline = item { return count + 1 }
            return count
        }
    }

    // MARK: - Topology

    func testForkAndMergeProduceCurvedConnectors() throws {
        // Before this change, layoutGitGraph drew each branch as a single
        // flat min→max line and never connected a fork or merge to a real
        // anchor point, so this fixture emitted zero `.polyline`s.
        let scene = try extraScene("""
        gitGraph
            commit
            commit
            branch develop
            checkout develop
            commit
            checkout main
            merge develop
        """)
        XCTAssertGreaterThanOrEqual(polylineCount(scene), 2)
    }

    func testLabelsOnlyRenderWhenGiven() throws {
        let scene = try extraScene("""
        gitGraph
            commit
            commit id: "Alpha"
        """)
        let allTexts = texts(scene)
        XCTAssertTrue(allTexts.contains("Alpha"))
        XCTAssertFalse(allTexts.contains("commit"))
    }

    // MARK: - Tags

    func testTagRendersBannerAndText() throws {
        let scene = try extraScene("""
        gitGraph
            commit
            commit tag: "v1.0"
        """)
        XCTAssertTrue(texts(scene).contains("v1.0"))
        let hasClosedBanner = scene.items.contains { item in
            if case .polyline(_, _, _, _, let closed) = item { return closed }
            return false
        }
        XCTAssertTrue(hasClosedBanner)
    }

    // MARK: - Commit kinds

    func testHighlightCommitRendersAsRect() throws {
        let scene = try extraScene("""
        gitGraph
            commit
            commit id: "Special" type: HIGHLIGHT
        """)
        let hasRectNode = scene.items.contains { item in
            if case .rect(_, _, _, _, _, _, let corner, _) = item { return corner > 0 }
            return false
        }
        XCTAssertTrue(hasRectNode)
    }

    func testReverseCommitAddsCrossLines() throws {
        let baselineScene = try extraScene("gitGraph\n    commit\n    commit")
        let reverseScene = try extraScene("""
        gitGraph
            commit
            commit type: REVERSE
        """)
        func lineCount(_ scene: ExtraScene) -> Int {
            scene.items.reduce(0) { count, item in
                if case .line = item { return count + 1 }
                return count
            }
        }
        XCTAssertGreaterThan(lineCount(reverseScene), lineCount(baselineScene))
    }

    func testCherryPickDrawsDashedEdge() throws {
        let scene = try extraScene("""
        gitGraph
            commit id: "Base"
            branch feature
            checkout feature
            commit id: "FeatureWork"
            checkout main
            cherry-pick id: "FeatureWork"
        """)
        let hasDashedLine = scene.items.contains { item in
            if case .line(_, _, _, _, _, _, let dashed) = item { return dashed }
            return false
        }
        XCTAssertTrue(hasDashedLine)
    }

    // MARK: - Direction

    func testVerticalDirectionsProduceTallerScenes() throws {
        let source = { (direction: String) in
            """
            gitGraph \(direction)
                commit
                commit
                commit
                commit
                commit
            """
        }
        let lrScene = try extraScene(source("LR"))
        let tbScene = try extraScene(source("TB"))
        XCTAssertGreaterThan(tbScene.height, tbScene.width)
        XCTAssertGreaterThan(lrScene.width, lrScene.height)
    }

    func testBottomToTopPutsFirstCommitBelowLast() throws {
        let scene = try extraScene("""
        gitGraph BT
            commit id: "First"
            commit id: "Last"
        """)
        func y(for label: String) -> Double? {
            for item in scene.items {
                if case let .text(text, _, y, _, _, _, _) = item, text == label {
                    return y
                }
            }
            return nil
        }
        let firstY = try XCTUnwrap(y(for: "First"))
        let lastY = try XCTUnwrap(y(for: "Last"))
        XCTAssertGreaterThan(firstY, lastY, "BT direction should place the first commit below the last")
    }

    // MARK: - Lane ordering

    func testExplicitBranchOrderReordersLanes() throws {
        let scene = try extraScene("""
        gitGraph
            commit
            branch late order: 0
            checkout late
            commit id: "OnLate"
            checkout main
            commit id: "OnMain"
        """)
        func y(for label: String) -> Double? {
            for item in scene.items {
                if case let .text(text, _, y, _, _, _, _) = item, text == label {
                    return y
                }
            }
            return nil
        }
        // "late" was declared second but given order: 0, so its lane (y) should
        // come before main's lane.
        let lateY = try XCTUnwrap(y(for: "OnLate"))
        let mainY = try XCTUnwrap(y(for: "OnMain"))
        XCTAssertLessThan(lateY, mainY)
    }

    // MARK: - No clipping

    func testLongLabelsStayWithinSceneBounds() throws {
        let scene = try extraScene("""
        gitGraph
            commit id: "A reasonably long commit message that could clip"
            branch a-fairly-long-branch-name
            checkout a-fairly-long-branch-name
            commit id: "Another long message here"
        """)
        for item in scene.items {
            guard case let .text(text, x, _, size, _, anchor, weight) = item else { continue }
            let measured = ExtraText.width(text, size: size, weight: weight)
            let (minEdge, maxEdge): (Double, Double)
            switch anchor {
            case .start: (minEdge, maxEdge) = (x, x + measured)
            case .middle: (minEdge, maxEdge) = (x - measured / 2, x + measured / 2)
            case .end: (minEdge, maxEdge) = (x - measured, x)
            }
            XCTAssertGreaterThanOrEqual(minEdge, -1, "\"\(text)\" clips the left edge")
            XCTAssertLessThanOrEqual(maxEdge, scene.width + 1, "\"\(text)\" clips the right edge")
        }
    }
}
