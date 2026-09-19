import XCTest
@testable import Penumbra
import PenumbraBeautifulMermaid

final class BeautifulMermaidDiagramTests: XCTestCase {
    private let fixtures: [(DiagramType, String)] = [
        (.pie, """
        pie title Preview render time by phase
            "Parse" : 15
            "Layout" : 25
            "Tile" : 20
            "Metal present" : 40
        """),
        (.gantt, """
        gantt
            title Shipping
            section Build
            Parse           :a1, 2024-01-01, 3d
            Layout          :after a1, 2d
            section Ship
            Release         :2024-01-08, 1d
        """),
        (.gitGraph, """
        gitGraph
            commit id: "Init"
            commit
            branch develop
            checkout develop
            commit id: "Feature" tag: "v0.1"
            checkout main
            commit type: HIGHLIGHT
            merge develop
            cherry-pick id: "Feature"
        """),
        (.journey, """
        journey
            title User day
            section Morning
              Code: 5: Me
            section Evening
              Review: 3: Me
        """),
        (.mindmap, """
        mindmap
          root((Penumbra))
            Engine
              Layout
            Preview
              Mermaid
        """),
        (.timeline, """
        timeline
            title Project
            2024 : Start
            2025 : Ship
        """),
        (.quadrantChart, """
        quadrantChart
            title Reach
            x-axis low --> high
            y-axis low --> high
            Foo: [0.3, 0.6]
            Bar: [0.7, 0.2]
        """),
        (.sankey, """
        sankey-beta
        Parse,Layout,15
        Layout,Tile,15
        Tile,Present,15
        """),
        (.radar, """
        radar-beta
            title Skills
            axis [A, B, C, D]
            curve "One" [4, 3, 5, 2]
        """),
        (.treemap, """
        treemap-beta
            "Root"
                "A": 20
                "B": 10
        """),
        (.venn, """
        venn
            title Sets
            set A Label A
            set B Label B
        """),
        (.packet, """
        packet
            0-15: "Source"
            16-31: "Dest"
        """),
        (.block, """
        block-beta
        columns 2
        A["One"] B["Two"]
        """),
        (.requirement, """
        requirementDiagram
            requirement alpha {
            id: 1
            text: must work
            }
            element beta {
            }
            beta - satisfies -> alpha
        """),
        (.architecture, """
        architecture-beta
            group api(cloud)[API]
            service db(database)[DB] in api
        """),
        (.c4, """
        C4Context
            title Context
            Person(user, "User")
            System(sys, "App")
            Rel(user, sys, "Uses")
        """),
        (.kanban, """
        kanban
            Todo
                Task one
            Doing
                Task two
        """),
        (.usecase, """
        usecase
            actor User
            (Login)
            User --> (Login)
        """),
        (.treeView, """
        treeView
            root
              child
        """),
        (.ishikawa, """
        ishikawa
            effect Delay
            People
              staffing
            Process
              steps
        """),
        (.cynefin, """
        cynefin
            title Modes
            Clear
              checklist
            Complex
              probe
        """),
        (.wardley, """
        wardley-beta
            title Map
            component [Build] 0.3, 0.7
            component [Run] 0.8, 0.4
        """),
        (.eventmodeling, """
        eventmodeling
            lane UI
            Clicked
            lane Domain
            Stored
        """),
        (.railroad, """
        railroad
            identifier equals number
        """),
        (.agentflow, """
        agentflow-beta
            A[Start] --> B[Tool]
            B --> C[End]
        """)
    ]

    func testDetectsAndParsesAllNewDiagramTypes() throws {
        for (expected, source) in fixtures {
            let graph = try MermaidRenderer.parse(source)
            XCTAssertEqual(graph.type, expected, "Failed type for \(expected.rawValue)")
        }
    }

    func testLayoutsProducePositiveBounds() throws {
        for (expected, source) in fixtures {
            let positioned = try MermaidRenderer.layout(source)
            XCTAssertEqual(positioned.diagram.type, expected)
            XCTAssertGreaterThan(positioned.width, 0, expected.rawValue)
            XCTAssertGreaterThan(positioned.height, 0, expected.rawValue)
        }
    }

    func testFrontmatterIsStrippedBeforeDetection() throws {
        let source = """
        ---
        title: Chart
        ---
        pie title After frontmatter
            "A" : 1
            "B" : 2
        """
        let graph = try MermaidRenderer.parse(source)
        XCTAssertEqual(graph.type, .pie)
    }

    func testZenumlIsUnsupported() {
        XCTAssertThrowsError(try MermaidRenderer.parse("zenuml\nA->B")) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            XCTAssertTrue(message.lowercased().contains("zenuml") || message.lowercased().contains("unsupported"))
        }
    }

    func testPaintAdapterRendersEachType() async {
        for (expected, source) in fixtures {
            let result = await MermaidPaintAdapter.render(
                source: source,
                mermaidStyle: MarkdownPreviewStyle().mermaidRenderingContext,
                contentWidth: 360
            )
            XCTAssertNotNil(result.image, "Expected image for \(expected.rawValue): \(result.errorMessage ?? "")")
            XCTAssertNil(result.errorMessage, expected.rawValue)
        }
    }

    func testMindmapCircleShapeRendersEllipse() throws {
        let source = """
        mindmap
          ((Root))
            Child
        """
        let positioned = try MermaidRenderer.layout(source)
        guard let scene = positioned.extraScene else {
            XCTFail("Expected extra scene")
            return
        }
        XCTAssertTrue(scene.items.contains { item in
            if case .ellipse = item { return true }
            return false
        })
    }

    func testMindmapTextContrastsWithNodeFill() throws {
        let source = """
        mindmap
          root
            A
        """
        let positioned = try MermaidRenderer.layout(source)
        guard let scene = positioned.extraScene else {
            XCTFail("Expected extra scene")
            return
        }
        let textFills = scene.items.compactMap { item -> ExtraFill? in
            if case .text(_, _, _, _, let fill, _, _) = item { return fill }
            return nil
        }
        XCTAssertEqual(textFills.count, 2)
        for fill in textFills {
            guard case .contrast = fill else {
                XCTFail("Mindmap text must be chosen by contrast against its node fill, got \(fill)")
                return
            }
        }
    }

    func testPickContrastingHexChoosesLegibleColor() {
        // Dark theme: light grey node fill must get the dark (background) text colour.
        XCTAssertEqual(pickContrastingHex(on: "#e6e6e6", "#f0f0f0", "#101012"), "#101012")
        // Light theme: dark node fill must get the light text colour.
        XCTAssertEqual(pickContrastingHex(on: "#1e293b", "#111111", "#ffffff"), "#ffffff")
        // Invalid input falls back to the first candidate rather than crashing.
        XCTAssertEqual(pickContrastingHex(on: "not-a-colour", "#111111", "#ffffff"), "#111111")
    }

    func testMindmapUsesElbowConnectors() throws {
        let source = """
        mindmap
          root
            A
            B
        """
        let positioned = try MermaidRenderer.layout(source)
        guard let scene = positioned.extraScene else {
            XCTFail("Expected extra scene")
            return
        }
        let elbowConnectors = scene.items.filter { item in
            if case .polyline(let points, _, _, _, _) = item {
                return points.count == 4
            }
            return false
        }
        XCTAssertGreaterThan(elbowConnectors.count, 0)
    }

    func testMindmapLongLabelExpandsWidth() throws {
        let source = """
        mindmap
          root
            This is a deliberately very long mindmap node label for width testing
        """
        let positioned = try MermaidRenderer.layout(source)
        guard let scene = positioned.extraScene else {
            XCTFail("Expected extra scene")
            return
        }
        let wideRects = scene.items.compactMap { item -> Double? in
            if case .rect(_, _, let width, _, _, _, _, _) = item, width > 150 { return width }
            return nil
        }
        XCTAssertGreaterThan(wideRects.count, 0)
    }

    func testMindmapRadialFrontmatter() throws {
        let source = """
        ---
        config:
          layout: radial
        ---
        mindmap
          root
            North
            East
            South
            West
        """
        let graph = try MermaidRenderer.parse(source)
        XCTAssertEqual(graph.type, .mindmap)
        guard let extra = graph.payload as? ExtraParsed, case .mindmap(let chart) = extra else {
            XCTFail("Expected mindmap payload")
            return
        }
        XCTAssertEqual(chart.layout, .radial)

        let positioned = try MermaidRenderer.layout(source)
        guard let scene = positioned.extraScene else {
            XCTFail("Expected extra scene")
            return
        }
        let textPositions = scene.items.compactMap { item -> (Double, Double)? in
            if case .text(_, let x, let y, _, _, _, _) = item { return (x, y) }
            return nil
        }
        XCTAssertGreaterThan(textPositions.count, 4)

        let xs = textPositions.map(\.0)
        let ys = textPositions.map(\.1)
        XCTAssertGreaterThan(xs.max()! - xs.min()!, 50)
        XCTAssertGreaterThan(ys.max()! - ys.min()!, 50)

        let meanX = xs.reduce(0, +) / Double(xs.count)
        let meanY = ys.reduce(0, +) / Double(ys.count)
        XCTAssertTrue(xs.contains { $0 < meanX })
        XCTAssertTrue(xs.contains { $0 > meanX })
        XCTAssertTrue(ys.contains { $0 < meanY })
        XCTAssertTrue(ys.contains { $0 > meanY })
    }

    func testMindmapRadialAndTreeBothRasterize() async {
        let treeSource = """
        mindmap
          root((Tree))
            Alpha
            Beta
        """
        let radialSource = """
        ---
        config:
          layout: radial
        ---
        mindmap
          root((Radial))
            Alpha
            Beta
        """
        for source in [treeSource, radialSource] {
            let result = await MermaidPaintAdapter.render(
                source: source,
                mermaidStyle: MarkdownPreviewStyle().mermaidRenderingContext,
                contentWidth: 360
            )
            XCTAssertNotNil(result.image, result.errorMessage ?? "missing image")
            XCTAssertNil(result.errorMessage)
        }
    }
}
