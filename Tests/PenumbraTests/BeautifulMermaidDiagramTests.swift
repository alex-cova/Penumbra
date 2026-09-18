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
}
