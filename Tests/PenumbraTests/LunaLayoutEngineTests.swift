import XCTest
@testable import PenumbraLuna

/// Unit tests for the ported Pele layout engine (Sources/Luna/Layout/) and the
/// preprocessing/safety layer (Sources/Luna/Preprocess.swift).
final class LunaLayoutEngineTests: XCTestCase {
    private func opt() -> LayeredOptions {
        LayeredOptions(nodeSep: 28, edgeSep: 12, rankSep: 48, portSep: 20, tracks: true, headRoom: 8)
    }

    // MARK: - Layered

    func testCycleReversesAndRoutesAllDirections() {
        for dir in [CompoundDir.tb, .bt, .lr, .rl] {
            var nodes: [CompoundNode] = (0..<3).map { i in
                var n = CompoundNode(w: 60, h: 36, parent: -1)
                n.seq = i
                return n
            }
            var edges = [CompoundEdge(src: 0, dst: 1), CompoundEdge(src: 1, dst: 2), CompoundEdge(src: 2, dst: 0)]
            let size = compoundLayout(nodes: &nodes, edges: &edges, rootDir: dir, opt: opt())
            XCTAssertGreaterThan(size.width, 0, "\(dir)")
            XCTAssertGreaterThan(size.height, 0, "\(dir)")
            for e in edges {
                XCTAssertGreaterThanOrEqual(e.route.count, 6, "\(dir)")
            }
        }
    }

    func testParallelEdgesWithLabelsTakeSeparateTracks() {
        var nodes = [CompoundNode(w: 60, h: 36, parent: -1), CompoundNode(w: 60, h: 36, parent: -1)]
        nodes[0].seq = 0
        nodes[1].seq = 1
        var edges = [
            CompoundEdge(src: 0, dst: 1, labelW: 40, labelH: 14),
            CompoundEdge(src: 0, dst: 1, labelW: 40, labelH: 14),
        ]
        let size = compoundLayout(nodes: &nodes, edges: &edges, rootDir: .tb, opt: opt())
        XCTAssertGreaterThan(size.height, 36 + 48)
        XCTAssertEqual(edges[0].route, edges[0].route)
        XCTAssertNotEqual(edges[0].route, edges[1].route)
    }

    func testCrossSubgraphEdgeRoutesThroughPorts() {
        // Two sibling groups; the edge must leave one border and enter the other.
        var nodes: [CompoundNode] = []
        var g1 = CompoundNode(w: 0, h: 0, parent: -1); g1.isGroup = true; g1.seq = 0
        var a = CompoundNode(w: 60, h: 36, parent: 0); a.seq = 1
        var g2 = CompoundNode(w: 0, h: 0, parent: -1); g2.isGroup = true; g2.seq = 2
        var b = CompoundNode(w: 60, h: 36, parent: 2); b.seq = 3
        nodes = [g1, a, g2, b]
        var edges = [CompoundEdge(src: 1, dst: 3)]
        let size = compoundLayout(nodes: &nodes, edges: &edges, rootDir: .tb, opt: opt())
        XCTAssertGreaterThan(size.width, 0)
        // The route leaves the first group and reaches the second: at least 4 points.
        XCTAssertGreaterThanOrEqual(edges[0].route.count / 3, 4)
    }

    func testGroupSpansDefaultToInfinity() {
        // A group spreads its edges along the whole side (adapter default).
        var nodes: [CompoundNode] = []
        var g = CompoundNode(w: 0, h: 0, parent: -1); g.isGroup = true; g.seq = 0
        g.span = .infinity
        var a = CompoundNode(w: 60, h: 36, parent: 0); a.seq = 1
        var b = CompoundNode(w: 60, h: 36, parent: -1); b.seq = 2
        var c = CompoundNode(w: 60, h: 36, parent: -1); c.seq = 3
        nodes = [g, a, b, c]
        var edges = [CompoundEdge(src: 1, dst: 2), CompoundEdge(src: 1, dst: 3)]
        _ = compoundLayout(nodes: &nodes, edges: &edges, rootDir: .tb, opt: opt())
        for e in edges { XCTAssertFalse(e.route.isEmpty) }
    }

    // MARK: - Shape spans

    func testDiamondSpan() {
        XCTAssertEqual(shapeSpan(shape: "diamond", w: 100, h: 60, sideways: false), 60)
        XCTAssertEqual(shapeSpan(shape: "diamond", w: 100, h: 60, sideways: true), 36)
    }

    func testDecisionDiamondSpreadsBranchLabels() throws {
        let positioned = try MermaidRenderer.layout("flowchart TD\nA{D} -->|x| B\nA -->|n| C\n")
        let edges = positioned.flowchartEdges ?? []
        XCTAssertEqual(edges.count, 2)
        for edge in edges {
            XCTAssertGreaterThanOrEqual(edge.points.count, 2)
            XCTAssertNotNil(edge.labelPosition)
        }
        let nodes = Dictionary(uniqueKeysWithValues: (positioned.flowchartNodes ?? []).map { ($0.id, $0) })
        XCTAssertEqual(nodes["A"]?.shape, "diamond")
    }

    func testRoundAndFlatSpans() {
        XCTAssertEqual(shapeSpan(shape: "circle", w: 80, h: 80, sideways: false), 48)
        XCTAssertEqual(shapeSpan(shape: "rectangle", w: 100, h: 40, sideways: false), 76)
        XCTAssertEqual(shapeSpan(shape: "mystery", w: 100, h: 40, sideways: false), 76)
    }

    // MARK: - Lanes

    private func twoLaneGraph() -> ([CompoundNode], [CompoundEdge]) {
        // Pele order: groups last-declared-first (Bob declared last). Written order is Alice, Bob.
        var nodes: [CompoundNode] = []
        var l2 = CompoundNode(w: 0, h: 0, parent: -1); l2.isGroup = true; l2.seq = 0
        var b1 = CompoundNode(w: 60, h: 36, parent: 0); b1.seq = 1
        var b2 = CompoundNode(w: 60, h: 36, parent: 0); b2.seq = 2
        var l1 = CompoundNode(w: 0, h: 0, parent: -1); l1.isGroup = true; l1.seq = 3
        var a1 = CompoundNode(w: 60, h: 36, parent: 3); a1.seq = 4
        var a2 = CompoundNode(w: 60, h: 36, parent: 3); a2.seq = 5
        nodes = [l2, b1, b2, l1, a1, a2]
        // A return branch: back from Bob's lane to Alice's.
        let edges = [CompoundEdge(src: 4, dst: 5), CompoundEdge(src: 5, dst: 1),
                     CompoundEdge(src: 1, dst: 2), CompoundEdge(src: 2, dst: 4)]
        return (nodes, edges)
    }

    func testSwimlaneLanesSitSideBySide() {
        var (nodes, edges) = twoLaneGraph()
        let size = laneLayout(nodes: &nodes, edges: &edges, dir: .tb, opt: opt())
        XCTAssertGreaterThan(size.width, 0)
        // Lane bands run along the flow: Alice (written first) sits left of Bob.
        XCTAssertNotEqual(nodes[3].x, nodes[0].x)
        XCTAssertLessThan(nodes[3].x, nodes[0].x)
    }

    func testSwimlaneReturnBranchRoutes() {
        var (nodes, edges) = twoLaneGraph()
        _ = laneLayout(nodes: &nodes, edges: &edges, dir: .tb, opt: opt())
        for e in edges {
            // Every handoff is routed end to end, including the return branch.
            XCTAssertGreaterThanOrEqual(e.route.count, 6)
        }
    }

    func testSwimlaneNodesStayInTheirLanes() {
        var (nodes, edges) = twoLaneGraph()
        _ = laneLayout(nodes: &nodes, edges: &edges, dir: .tb, opt: opt())
        for i in [4, 5] {
            XCTAssertGreaterThanOrEqual(nodes[i].x - nodes[i].w / 2, nodes[3].x - nodes[3].w / 2 - 1)
            XCTAssertLessThanOrEqual(nodes[i].x + nodes[i].w / 2, nodes[3].x + nodes[3].w / 2 + 1)
        }
        for i in [1, 2] {
            XCTAssertGreaterThanOrEqual(nodes[i].x - nodes[i].w / 2, nodes[0].x - nodes[0].w / 2 - 1)
            XCTAssertLessThanOrEqual(nodes[i].x + nodes[i].w / 2, nodes[0].x + nodes[0].w / 2 + 1)
        }
    }

    // MARK: - Preprocessing

    func testFrontMatterTitleConfigAndOffset() throws {
        let p = try preprocessMermaid("---\ntitle: Hi\nconfig:\n  wrap: true\n---\nflowchart TD\n  A-->B\n")
        XCTAssertEqual(p.title, "Hi")
        XCTAssertEqual(p.config["wrap"], .bool(true))
        XCTAssertEqual(p.lineOffset, 5)
        XCTAssertTrue(p.text.hasPrefix("flowchart TD"))
    }

    func testInitAndWrapDirectives() throws {
        let p = try preprocessMermaid("flowchart TD\n%%{init: {\"flowchart\": {\"nodeSpacing\": 10}}}%%\n%%{wrap}%%\nA-->B\n")
        XCTAssertEqual(p.config["wrap"], .bool(true))
        XCTAssertEqual(p.config["flowchart"]?.objectValue?["nodeSpacing"], .number(10))
        XCTAssertFalse(p.text.contains("%%{"))
    }

    func testInvalidFrontMatterThrowsSyntax() {
        XCTAssertThrowsError(try preprocessMermaid("---\nconfig: [oops\n---\nflowchart TD\n")) { error in
            guard case MermaidParserError.syntax(let message, _, _, _) = error else {
                return XCTFail("expected .syntax, got \(error)")
            }
            XCTAssertTrue(message.contains("Front matter"), message)
        }
    }

    func testEntityCodesRoundTripInLabels() throws {
        let graph = try MermaidRenderer.parse("flowchart TD\nA[\"#9829; love\"]-->B\n")
        guard case .flowchart(let model)? = graph.typedPayload else {
            return XCTFail("expected flowchart")
        }
        XCTAssertTrue(model.nodesInOrder.map(\.node.label).contains("♥ love"))
    }

    // MARK: - Limits

    func testOverLimitSourceThrows() {
        let big = String(repeating: "A-->B\n", count: 20_000)
        XCTAssertThrowsError(try MermaidRenderer.parse("flowchart TD\n" + big)) { error in
            guard case MermaidParserError.limit = error else {
                return XCTFail("expected .limit, got \(error)")
            }
        }
    }

    func testDeepNestingThrows() {
        let deep = (0..<101).map { _ in "subgraph S\n" }.joined() + "A-->B\n"
            + String(repeating: "end\n", count: 101)
        XCTAssertThrowsError(try MermaidRenderer.parse("flowchart TD\n" + deep)) { error in
            guard case MermaidParserError.limit = error else {
                return XCTFail("expected .limit, got \(error)")
            }
        }
    }

    func testFanOutGuardFiresBeforeBlowup() {
        // A 100x100 cross product exceeds maxEdges and must throw instead of allocating it.
        let left = (0..<100).map { "A\($0)" }.joined(separator: " & ")
        let right = (0..<100).map { "B\($0)" }.joined(separator: " & ")
        let fan = "flowchart TD\n" + left + " --> " + right + "\n"
        XCTAssertThrowsError(try MermaidRenderer.parse(fan)) { error in
            guard case MermaidParserError.limit = error else {
                return XCTFail("expected .limit, got \(error)")
            }
        }
    }

    // MARK: - Swimlane integration

    func testSwimlaneDefaultLaneForUngroupedNodes() throws {
        let positioned = try MermaidRenderer.layout(
            "swimlane-beta\nsubgraph Alice\nA1[Start] --> A2[End]\nend\nSolo[x]\n")
        let groups = positioned.flowchartGroups ?? []
        let lanes = groups.filter(\.isLane)
        XCTAssertEqual(lanes.count, 2)
        let unnamed = lanes.first { $0.label.isEmpty }
        XCTAssertNotNil(unnamed)
    }

    func testSwimlaneLaneFillFromClass() throws {
        let positioned = try MermaidRenderer.layout(
            "swimlane-beta\nsubgraph Alice\nA1-->A2\nend\nclassDef hot fill:#f9f\nclass Alice hot\n")
        let lanes = (positioned.flowchartGroups ?? []).filter(\.isLane)
        XCTAssertEqual(lanes.first?.laneFill, "#f9f")
    }
}
