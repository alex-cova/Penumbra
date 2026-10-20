import XCTest
@testable import Penumbra
@testable import PenumbraLuna

final class LunaDiagramTests: XCTestCase {
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
        usecase-beta
            actor User
            Login("Sign in")
            User --> Login
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
        railroad-ebnf-beta
            assign = name "=" number ;
        """),
        (.agentflow, """
        agentflow-beta
            A[Start] --> B[Tool]
            B --> C[End]
        """),
        (.swimlane, """
        swimlane-beta
            subgraph Alice
                A1[Start] --> A2[Review]
            end
            subgraph Bob
                B1[Approve] --> B2[Done]
            end
            A2 --> B1
        """),
        (.info, """
        info
        showInfo
        """),
        (.flowchart, """
        flowchart LR
            L1[/Lean in/] --> L2[\\Lean out\\]
            L2 --> L3[Done]
        """),
        (.flowchart, """
        flowchart TD
            A o--o B
            B x--x C
            C --o D
        """),
        (.flowchart, """
        flowchart TD
            A~~~B
            B --> C
        """),
        (.stateDiagram, """
        stateDiagram-v2
            [*] --> A
            A --> B
            B --> [*]
        """),
        (.sequenceDiagram, """
        sequenceDiagram
            A->>B: hi
            B-->>A: yo
        """),
        (.classDiagram, """
        classDiagram
            A <|-- B
        """),
        (.erDiagram, """
        erDiagram
            A ||--o{ B : has
        """),
        (.xyChart, """
        xychart-beta
            title "Sales"
            x-axis [Mon, Tue]
            y-axis 0 --> 10
            bar [3, 7]
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

    func testFlowchartElkHeaderDetectsAsFlowchart() throws {
        let graph = try MermaidRenderer.parse("flowchart-elk TD\n    A --> B\n")
        XCTAssertEqual(graph.type, .flowchart)
    }

    func testBareRequirementHeaderDetects() throws {
        let source = """
        requirement
            requirement alpha {
            id: 1
            text: must work
            }
        """
        let graph = try MermaidRenderer.parse(source)
        XCTAssertEqual(graph.type, .requirement)
    }

    func testInfoRendersVersionLine() throws {
        let positioned = try MermaidRenderer.layout("info\nshowInfo")
        XCTAssertEqual(positioned.diagram.type, .info)
        guard let scene = positioned.extraScene else {
            XCTFail("Expected extra scene")
            return
        }
        XCTAssertTrue(scene.items.contains { item in
            if case let .text(text, _, _, _, _, _, _) = item {
                return text.contains("Luna v")
            }
            return false
        })
    }

    func testSwimlaneLanesRenderAsGroups() throws {
        let source = """
        swimlane-beta
            subgraph Alice
                A1[Start] --> A2[Review]
            end
            subgraph Bob
                B1[Approve] --> B2[Done]
            end
            A2 --> B1
        """
        let positioned = try MermaidRenderer.layout(source)
        XCTAssertEqual(positioned.diagram.type, .swimlane)
        let groups = positioned.flowchartGroups ?? []
        XCTAssertEqual(groups.count, 2)
    }

    func testLeanNodeShapesParse() throws {
        let positioned = try MermaidRenderer.layout("flowchart LR\nA[/In/] --> B[\\Out\\]\n")
        let shapes = Dictionary(
            uniqueKeysWithValues: (positioned.flowchartNodes ?? []).map { ($0.id, $0.shape) }
        )
        XCTAssertEqual(shapes["A"], "parallelogram")
        XCTAssertEqual(shapes["B"], "parallelogram-alt")
    }

    func testLeanShapesRenderSVGPolygons() throws {
        let svg = try MermaidRenderer.renderSVG(source: "flowchart LR\nA[/In/] --> B[\\Out\\]\n")
        XCTAssertTrue(svg.contains("polygon"), svg)
    }

    func testCircleAndCrossMarkersParse() throws {
        let positioned = try MermaidRenderer.layout("flowchart TD\nA o--o B\nB x--x C\nC --o D\n")
        let markers = Dictionary(
            uniqueKeysWithValues: (positioned.flowchartEdges ?? []).map {
                ("\($0.source)-\($0.target)", ($0.startMarker, $0.endMarker))
            }
        )
        XCTAssertEqual(markers["A-B"]?.0, "circle")
        XCTAssertEqual(markers["A-B"]?.1, "circle")
        XCTAssertEqual(markers["B-C"]?.0, "cross")
        XCTAssertEqual(markers["B-C"]?.1, "cross")
        XCTAssertEqual(markers["C-D"]?.1, "circle")
    }

    func testMarkersRenderSVGReferences() throws {
        let svg = try MermaidRenderer.renderSVG(source: "flowchart TD\nA o--o B\nB x--x C\n")
        XCTAssertTrue(svg.contains("url(#circle-end)"), svg)
        XCTAssertTrue(svg.contains("url(#cross-end)"), svg)
    }

    func testInvisibleEdgesConstrainLayoutButDoNotDraw() throws {
        let source = "flowchart TD\nA~~~B\nB --> C\n"
        let positioned = try MermaidRenderer.layout(source)
        let invisible = (positioned.flowchartEdges ?? []).first { $0.source == "A" }
        XCTAssertEqual(invisible?.style, "invisible")
        let svg = try MermaidRenderer.renderSVG(source: source)
        XCTAssertFalse(svg.contains("data-style=\"invisible\""), svg)
    }

    func testBarycenterOrdersFanInLayers() throws {
        // Insertion order is X before Y, but Y's only predecessor sorts
        // first: barycenter crossing minimization must place Y left of X.
        let positioned = try MermaidRenderer.layout("flowchart TD\nA --> X\nB --> X\nC --> X\nA --> Y\n")
        let xs = Dictionary(
            uniqueKeysWithValues: (positioned.flowchartNodes ?? []).map { ($0.id, $0.x) }
        )
        let x = try XCTUnwrap(xs["X"])
        let y = try XCTUnwrap(xs["Y"])
        XCTAssertLessThan(y, x)
    }

    func testNewSyntaxRendersASCII() throws {
        let ascii = try MermaidRenderer.renderASCII(source: "flowchart TD\nA[/In/] o--o B\nB~~~C\n")
        XCTAssertFalse(ascii.isEmpty)
    }

    /// Reference CoreGraphics render straight into a bitmap context.
    /// `NSImage.cgImage(forProposedRect:)` resamples fractional-point diagrams
    /// (nondeterministically between ceil/round per dimension on Retina), so
    /// pixel parity must not go through `BMImage` at all. This mirrors
    /// `MermaidImageRenderer._renderPrepared`'s AppKit branch exactly.
    private func referenceCGImage(
        _ positioned: PositionedGraph, theme: DiagramTheme, scale: CGFloat
    ) -> CGImage? {
        let width = max(1, Int(positioned.width * scale))
        let height = max(1, Int(positioned.height * scale))
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        if !theme.transparent {
            ctx.setFillColor(theme.background.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        }
        ctx.scaleBy(x: scale, y: scale)
        // Flip for AppKit bitmap contexts (y=0 at bottom -> y=0 at top).
        ctx.translateBy(x: 0, y: CGFloat(positioned.height))
        ctx.scaleBy(x: 1, y: -1)
        DiagramRenderer(theme: theme).render(
            positioned, in: ctx,
            bounds: CGRect(x: 0, y: 0, width: positioned.width, height: positioned.height))
        return ctx.makeImage()
    }

    private func normalizedPixels(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        guard let context = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = context.data else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        memcpy(&bytes, data, w * h * 4)
        return bytes
    }

    private func meanAbsDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var total: UInt64 = 0
        for i in 0..<a.count {
            total += UInt64(abs(Int(a[i]) - Int(b[i])))
        }
        return Double(total) / Double(a.count)
    }

    /// Re-encodes `positioned` through the matching Metal encoder and returns
    /// every emitted label quad in device pixels. Test-only insight into
    /// where Metal believes text landed.
    private func metalLabelRects(_ positioned: PositionedGraph, scale: CGFloat) throws -> [CGRect] {
        guard let device = MTLCreateSystemDefaultDevice(),
              let cache = MetalLabelCache(device: device)
        else {
            throw XCTSkip("No Metal device")
        }
        let ctx = MetalEncodeContext(theme: .default, config: RenderConfig(), scale: scale, labels: cache)
        switch positioned.content {
        case .flowchart, .stateDiagram:
            var encoder = MetalDiagramRenderer.FlowchartEncoder(
                theme: .default, config: RenderConfig(), scale: scale, labels: cache)
            try encoder.encode(positioned)
            return encoder.debugLabelRects
        case .sequenceDiagram:
            var encoder = MetalSequenceEncoder(ctx: ctx)
            try encoder.encode(positioned: positioned)
            return encoder.ctx.debugLabelRects
        case .classDiagram:
            var encoder = MetalClassEncoder(ctx: ctx)
            try encoder.encode(positioned: positioned)
            return encoder.ctx.debugLabelRects
        case .erDiagram:
            var encoder = MetalEREncoder(ctx: ctx)
            try encoder.encode(positioned: positioned)
            return encoder.ctx.debugLabelRects
        case .xyChart:
            var encoder = MetalXYEncoder(ctx: ctx)
            try encoder.encode(positioned: positioned)
            return encoder.ctx.debugLabelRects
        default:
            guard let scene = positioned.extraScene else { return [] }
            var encoder = MetalExtraEncoder(ctx: ctx)
            try encoder.encode(scene: scene)
            return encoder.ctx.debugLabelRects
        }
    }

    /// Per-label text backstop: for every quad Metal emitted, the CG and
    /// Metal pixels inside that quad must match closely. The global mean
    /// diff dilutes missing text over the whole image (absent labels passed
    /// at < 6.0); a quad-sized window does not. Blank-vs-blank compares
    /// clean, so whitespace-only lines need no special-casing.
    ///
    /// Registration is solved, not assumed: the helper searches whole-quad
    /// offsets in -2...2px and takes the best. Single-line labels center on
    /// the measured line size exactly like CG, so identical glyphs agree to
    /// ~1px; the best offset absorbs that (and an edge-pegged best offset
    /// that beats the center by a real margin fails as misregistered).
    /// Absent or displaced glyphs match at no offset and fail loudly.
    /// (A per-pixel 3x3 minimum was tried first: thin glyph strokes always
    /// find background within 1px, so it passed displaced text.
    /// Whole-quad offsets do not have that hole.)
    ///
    /// Calibration (device px, scale 2): correct renders score ≤ 12 per
    /// quad; reintroduced V-flip scores 20.8+, a +30px label shift 20.6+
    /// plus edge-pegged offsets, offscreen quads fail outright. Keep the
    /// 20.0 tolerance clear of both sides.
    private func assertMetalTextMatches(
        cgPixels: [UInt8],
        metalPixels: [UInt8],
        width: Int,
        height: Int,
        labels: [CGRect],
        tolerance: Double = 20.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(labels.isEmpty, "expected Metal to emit label quads", file: file, line: line)
        var maxDiff = 0.0
        for rect in labels {
            let ix0 = max(0, Int(rect.minX.rounded(.down)))
            let iy0 = max(0, Int(rect.minY.rounded(.down)))
            let ix1 = min(width, Int(rect.maxX.rounded(.up)))
            let iy1 = min(height, Int(rect.maxY.rounded(.up)))
            guard ix1 > ix0, iy1 > iy0 else {
                XCTFail("Metal label quad offscreen: \(rect)", file: file, line: line)
                continue
            }
            var bestMean = Double.infinity
            var bestOffset = (0, 0)
            var centerMean = Double.infinity
            // Center-out order with strict improvement: ties resolve to
            // the smallest offset, so blank quads report (0,0), not an edge.
            var offsets: [(Int, Int)] = [(0, 0)]
            for ring in 1...2 {
                for dy in -ring...ring {
                    for dx in -ring...ring {
                        if max(abs(dx), abs(dy)) == ring { offsets.append((dx, dy)) }
                    }
                }
            }
            for (dx, dy) in offsets {
                    var total: UInt64 = 0
                    var count = 0
                    for y in iy0..<iy1 {
                        for x in ix0..<ix1 {
                            let nx = min(max(x + dx, 0), width - 1)
                            let ny = min(max(y + dy, 0), height - 1)
                            let o = (y * width + x) * 4
                            let no = (ny * width + nx) * 4
                            for c in 0..<4 {
                                total += UInt64(abs(Int(cgPixels[o + c]) - Int(metalPixels[no + c])))
                            }
                            count += 4
                        }
                    }
                    let mean = Double(total) / Double(max(1, count))
                    if dx == 0, dy == 0 { centerMean = mean }
                    if mean < bestMean {
                        bestMean = mean
                        bestOffset = (dx, dy)
                    }
            }
            maxDiff = max(maxDiff, bestMean)
            XCTAssertLessThan(bestMean, tolerance,
                "Metal label mismatch at \(rect) (best offset \(bestOffset))",
                file: file, line: line)
            // Misregistration only counts when the edge is genuinely better
            // than the center: on flat landscapes all offsets tie within
            // noise and the edge pick is meaningless.
            if max(abs(bestOffset.0), abs(bestOffset.1)) >= 2, centerMean - bestMean > 1.0 {
                XCTFail("Metal label misregistered at \(rect) " +
                    "(best offset \(bestOffset), center \(centerMean), best \(bestMean))",
                    file: file, line: line)
            }
        }
        print("TEXT-BACKSTOP labels=\(labels.count) maxRegionDiff=\(maxDiff)")
    }

    private func assertMetalMatchesCG(
        source: String,
        scale: CGFloat = 2,
        tolerance: Double = 6.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try XCTSkipIf(!MetalDiagramBackend.shared.isAvailable, "No Metal device")
        let positioned = try MermaidRenderer.layout(source)
        let theme = DiagramTheme.default
        let cgImage = try XCTUnwrap(referenceCGImage(positioned, theme: theme, scale: scale),
            file: file, line: line)
        let metalImage = try MetalDiagramRenderer().renderCGImage(positioned, theme: theme, scale: scale)
        XCTAssertEqual(cgImage.width, metalImage.width, file: file, line: line)
        XCTAssertEqual(cgImage.height, metalImage.height, file: file, line: line)
        guard let cgPixels = normalizedPixels(cgImage),
              let metalPixels = normalizedPixels(metalImage) else {
            XCTFail("pixel readback failed", file: file, line: line)
            return
        }
        // Antialiasing differs between rasterizers; the mean channel
        // difference must stay tiny (CG-vs-CG noise floor is ~0).
        XCTAssertLessThan(meanAbsDiff(cgPixels, metalPixels), tolerance, file: file, line: line)
        // Per-label text backstop (catches missing/displaced glyphs the
        // global mean dilutes away).
        let labels = try metalLabelRects(positioned, scale: scale)
        assertMetalTextMatches(cgPixels: cgPixels, metalPixels: metalPixels,
            width: cgImage.width, height: cgImage.height, labels: labels,
            file: file, line: line)
    }

    func testMetalMatchesCoreGraphicsFlowchart() throws {
        try XCTSkipIf(!MetalDiagramBackend.shared.isAvailable, "No Metal device")
        let source = """
        flowchart TD
            A[Start] --> B{Decide}
            B -->|yes| C[Done]
            B -->|no| D[Retry]
            D --> B
            subgraph Lane
                C --> E[End]
            end
        """
        let positioned = try MermaidRenderer.layout(source)
        let theme = DiagramTheme.default
        let cgImage = try XCTUnwrap(referenceCGImage(positioned, theme: theme, scale: 2))
        let metalImage = try MetalDiagramRenderer().renderFlowchartCGImage(positioned, theme: theme, scale: 2)
        XCTAssertEqual(cgImage.width, metalImage.width)
        XCTAssertEqual(cgImage.height, metalImage.height)
        guard let cgPixels = normalizedPixels(cgImage),
              let metalPixels = normalizedPixels(metalImage) else {
            XCTFail("pixel readback failed")
            return
        }
        // Antialiasing differs between rasterizers; the mean channel
        // difference must stay tiny (CG-vs-CG noise floor is ~0).
        XCTAssertLessThan(meanAbsDiff(cgPixels, metalPixels), 6.0)
        let labels = try metalLabelRects(positioned, scale: 2)
        assertMetalTextMatches(cgPixels: cgPixels, metalPixels: metalPixels,
            width: cgImage.width, height: cgImage.height, labels: labels)
    }

    func testMetalMatchesCoreGraphicsSequence() throws {
        try assertMetalMatchesCG(source: """
        sequenceDiagram
            participant A as Alice
            actor B as Bob
            A->>+B: hello
            B-->>-A: hi back
            A->>A: think
            loop Every minute
                A->>B: ping
            end
            alt happy path
                B->>A: yay
            else sad path
                B->>A: nay
            end
            Note over A,B: a note
        """)
    }

    func testMetalMatchesCoreGraphicsClass() throws {
        try assertMetalMatchesCG(source: """
        classDiagram
            class Animal {
                +String name
                -int age
                +makeSound()* void
                +tag()$ string
            }
            class Dog {
                +bark() void
            }
            <<interface>> Flyable
            class Bird {
                +fly() void
            }
            class Owner {
                +String name
            }
            Animal <|-- Dog : inherits
            Animal <|.. Bird : realizes
            Dog *-- Owner : "1" owned
            Dog o-- Flyable : can use
            Owner --> Animal : "1" keeps
            Owner ..> Flyable : depends
        """)
    }

    func testMetalMatchesCoreGraphicsER() throws {
        try assertMetalMatchesCG(source: """
        erDiagram
            CUSTOMER ||--o{ ORDER : places
            ORDER ||--|{ LINE-ITEM : contains
            CUSTOMER }o--|| ADDRESS : lives-at
            CUSTOMER {
                string name PK
                string id PK
                int age
            }
            ORDER {
                int number PK
                date created
            }
            LINE-ITEM {
                int quantity
            }
            ADDRESS {
            }
        """)
    }

    func testMetalMatchesCoreGraphicsXY() throws {
        try assertMetalMatchesCG(source: """
        xychart-beta
            title Sales by quarter
            x-axis [Q1, Q2, Q3, Q4]
            y-axis "Revenue" 0 --> 100
            bar [20, 45, 60, 80]
            line [10, 30, 55, 95]
        """)
    }

    func testMetalRefusesUnsupportedContent() throws {
        try XCTSkipIf(!MetalDiagramBackend.shared.isAvailable, "No Metal device")
        let positioned = try MermaidRenderer.layout("sequenceDiagram\nA->>B: hi\n")
        XCTAssertThrowsError(
            try MetalDiagramRenderer().renderFlowchartCGImage(positioned, theme: .default, scale: 2)
        )
    }

    func testMetalMatchesCoreGraphicsPie() throws {
        try assertMetalMatchesCG(source: """
        pie title Pets
            "Dogs" : 40
            "Cats" : 35
            "Birds" : 25
        """)
    }

    func testMetalMatchesCoreGraphicsGantt() throws {
        try assertMetalMatchesCG(source: """
        gantt
            title Shipping
            section Build
            Parse           :a1, 2024-01-01, 3d
            Layout          :after a1, 2d
        """)
    }

    func testMetalMatchesCoreGraphicsMindmap() throws {
        try assertMetalMatchesCG(source: """
        mindmap
          Root
            Child A
            Child B
        """)
    }

    func testMetalMatchesCoreGraphicsVenn() throws {
        try assertMetalMatchesCG(source: """
        venn
            title Sets
            set A Label A
            set B Label B
        """)
    }

    func testMetalMatchesCoreGraphicsRadar() throws {
        try assertMetalMatchesCG(source: """
        radar-beta
            title Skills
            axis [A, B, C, D]
            curve "One" [4, 3, 5, 2]
        """)
    }

    func testMetalMatchesCoreGraphicsGitGraph() throws {
        try assertMetalMatchesCG(source: """
        gitGraph
            commit id: "Init"
            commit
            branch develop
            checkout develop
            commit id: "Feature"
            checkout main
            merge develop
        """)
    }

    func testMetalLayerBackendFallsBackCleanly() throws {
        let layer = MermaidLayer()
        layer.source = "flowchart TD\n    A --> B\n"
        layer.metalBackend = true
        XCTAssertNil(layer.parseError)
        let image = layer.renderImage(scale: 2)
        XCTAssertNotNil(image)
        if MetalDiagramBackend.shared.isAvailable {
            XCTAssertNil(layer.lastMetalFailureReason)
        }
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

    // MARK: - Requirement / C4 / Sankey / Ishikawa / Event modeling regressions

    private func extraSceneTexts(_ scene: ExtraScene) -> [(String, Double, Double, Double, ExtraAnchor, Int)] {
        scene.items.compactMap { item in
            if case let .text(text, x, y, size, _, anchor, weight) = item {
                return (text, x, y, size, anchor, weight)
            }
            return nil
        }
    }

    private func assertTextsDoNotOverlap(
        _ scene: ExtraScene,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let frames = extraSceneTexts(scene).map { entry -> (String, CGRect) in
            let (text, x, y, size, anchor, weight) = entry
            let w = ExtraText.width(text, size: size, weight: weight)
            let x0: Double
            switch anchor {
            case .start: x0 = x
            case .middle: x0 = x - w / 2
            case .end: x0 = x
            }
            return (text, CGRect(x: x0 - 1, y: y - size / 2 - 1, width: w + 2, height: size + 2))
        }
        for i in frames.indices {
            for j in frames.indices where j > i {
                XCTAssertFalse(
                    frames[i].1.intersects(frames[j].1),
                    "'\(frames[i].0)' overlaps '\(frames[j].0)'",
                    file: file, line: line
                )
            }
        }
    }

    private func assertRectsDoNotOverlap(
        _ scene: ExtraScene,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let rects = scene.items.compactMap { item -> CGRect? in
            if case let .rect(x, y, width, height, _, _, _, _) = item {
                return CGRect(x: x, y: y, width: width, height: height)
            }
            return nil
        }
        for i in rects.indices {
            for j in rects.indices where j > i {
                XCTAssertFalse(rects[i].intersects(rects[j]), "boxes overlap", file: file, line: line)
            }
        }
    }

    func testRequirementDocExampleLaysOutSideBySide() throws {
        let source = """
        requirementDiagram
            requirement test_req {
            id: 1
            text: the test text.
            risk: high
            verifymethod: test
            }
            element test_entity {
            type: simulation
            }
            test_entity - satisfies -> test_req
        """
        let graph = try MermaidRenderer.parse(source)
        XCTAssertEqual(graph.type, .requirement)
        guard let extra = graph.payload as? ExtraParsed, case .requirement(let chart) = extra else {
            XCTFail("Expected requirement payload")
            return
        }
        XCTAssertEqual(chart.boxes.count, 2)
        XCTAssertEqual(chart.edges.count, 1)
        XCTAssertEqual(chart.edges[0].label, "satisfies")

        let positioned = try MermaidRenderer.layout(source)
        guard let scene = positioned.extraScene else {
            XCTFail("Expected extra scene")
            return
        }
        assertRectsDoNotOverlap(scene)
        assertTextsDoNotOverlap(scene)
        // Same-row edge drops into the lane below the row (two verticals plus
        // one horizontal run) instead of crossing the narrow gap, and the
        // label sits on the bottom run clear of both boxes' borders.
        let lines = scene.items.compactMap { item -> (Double, Double, Double, Double)? in
            if case let .line(x1, y1, x2, y2, _, _, _) = item { return (x1, y1, x2, y2) }
            return nil
        }
        XCTAssertEqual(lines.count, 3)
        let horizontals = lines.filter { abs($0.1 - $0.3) < 1 }
        XCTAssertEqual(horizontals.count, 1)
        let boxes = scene.items.compactMap { item -> CGRect? in
            if case let .rect(x, y, width, height, _, _, _, _) = item {
                return CGRect(x: x, y: y, width: width, height: height)
            }
            return nil
        }
        XCTAssertEqual(boxes.count, 2)
        let labelFrame: CGRect = {
            let entry = extraSceneTexts(scene).first { $0.0 == "satisfies" }
            XCTAssertNotNil(entry, "Expected the 'satisfies' edge label")
            let w = ExtraText.width("satisfies", size: 10, weight: 400)
            return CGRect(x: entry!.1 - w / 2 - 1, y: entry!.2 - 6, width: w + 2, height: 12)
        }()
        XCTAssertGreaterThan(labelFrame.minY, boxes.map(\.maxY).max() ?? 0)
        for box in boxes {
            XCTAssertFalse(box.intersects(labelFrame), "Edge label overlaps a box border")
        }
    }

    func testRequirementDetailTextIsNotAnEdge() throws {
        let source = """
        requirementDiagram
            requirement test_req {
            id: 1
            text: the test text contains details and satisfies nothing
            }
            element test_entity {
            type: simulation
            }
            test_entity - satisfies -> test_req
        """
        let graph = try MermaidRenderer.parse(source)
        guard let extra = graph.payload as? ExtraParsed, case .requirement(let chart) = extra else {
            XCTFail("Expected requirement payload")
            return
        }
        XCTAssertEqual(chart.boxes.count, 2)
        XCTAssertEqual(chart.edges.count, 1)
        XCTAssertEqual(chart.edges[0].label, "satisfies")
        XCTAssertEqual(chart.boxes[0].detail, "the test text contains details and satisfies nothing")
    }

    func testC4DocExampleWrapsDetailsInsideBoxes() throws {
        let source = """
        C4Context
              title System Context diagram for Internet Banking System
              Person(customerA, "Banking Customer A", "A customer of the bank, with personal bank accounts.")
              System(SystemAA, "Internet Banking System", "Allows customers to view information about their bank accounts, and make payments.")
              Rel(customerA, SystemAA, "Uses")
        """
        let graph = try MermaidRenderer.parse(source)
        XCTAssertEqual(graph.type, .c4)
        let positioned = try MermaidRenderer.layout(source)
        guard let scene = positioned.extraScene else {
            XCTFail("Expected extra scene")
            return
        }
        assertRectsDoNotOverlap(scene)
        assertTextsDoNotOverlap(scene)
        // The long descriptions wrap: no in-box line is wider than the box.
        for (text, _, _, size, _, weight) in extraSceneTexts(scene) where size <= 12 {
            XCTAssertLessThanOrEqual(
                ExtraText.width(text, size: size, weight: weight), 170,
                "'\(text)' overflows its box"
            )
        }
        let texts = extraSceneTexts(scene).map { $0.0 }
        XCTAssertTrue(texts.contains("Uses"))
        // Style directives never become edges or labels.
        let updateSource = """
        C4Context
              title T
              Person(a, "A", "detail")
              System(b, "B", "detail")
              Rel(a, b, "Uses")
              UpdateRelStyle(a, b, $offsetX="-40")
              UpdateLayoutConfig($c4ShapeInRow="3")
        """
        let updateGraph = try MermaidRenderer.parse(updateSource)
        guard let updateExtra = updateGraph.payload as? ExtraParsed, case .c4(let updateChart) = updateExtra else {
            XCTFail("Expected c4 payload")
            return
        }
        XCTAssertEqual(updateChart.edges.count, 1)
        XCTAssertEqual(updateChart.edges[0].label, "Uses")
        let updateTexts = extraSceneTexts(try MermaidRenderer.layout(updateSource).extraScene ?? .empty).map { $0.0 }
        XCTAssertFalse(updateTexts.contains(where: { $0.contains("$") }))
        // The Rel label routes below the row, clear of both boxes' borders.
        let boxes = scene.items.compactMap { item -> CGRect? in
            if case let .rect(x, y, width, height, _, _, _, _) = item {
                return CGRect(x: x, y: y, width: width, height: height)
            }
            return nil
        }
        XCTAssertEqual(boxes.count, 2)
        if let uses = extraSceneTexts(scene).first(where: { $0.0 == "Uses" }) {
            let w = ExtraText.width("Uses", size: uses.3, weight: uses.5)
            let frame = CGRect(x: uses.1 - w / 2 - 1, y: uses.2 - uses.3 / 2 - 1, width: w + 2, height: uses.3 + 2)
            for box in boxes {
                XCTAssertFalse(box.intersects(frame), "Rel label overlaps a box border")
            }
        } else {
            XCTFail("Expected the 'Uses' rel label")
        }
    }

    func testSankeyDocExampleNormalizesFlowWidths() throws {
        let source = """
        sankey
            Bio-conversion,Liquid,0.597
            Bio-conversion,Losses,26.862
            Bio-conversion,Solid,280.322
            Bio-conversion,Gas,81.144
            Biofuel imports,Liquid,35
            Biomass imports,Solid,35
        """
        let positioned = try MermaidRenderer.layout(source)
        XCTAssertEqual(positioned.diagram.type, .sankey)
        guard let scene = positioned.extraScene else {
            XCTFail("Expected extra scene")
            return
        }
        // One closed ribbon per link, each scaled to the 400pt plot.
        let ribbons = scene.items.compactMap { item -> [ExtraPoint]? in
            if case let .polyline(points, _, _, _, closed) = item, closed { return points }
            return nil
        }
        XCTAssertEqual(ribbons.count, 6)
        let thicknesses = ribbons.map { ribbon in
            ribbon.map(\.y).max()! - ribbon.map(\.y).min()!
        }
        XCTAssertTrue(thicknesses.allSatisfy { $0 <= 400 }, "raw values buried the plot: \(thicknesses)")
        XCTAssertTrue(thicknesses.allSatisfy { $0 >= 1 })
        // The 280.322 link dominates its fan-out: thickest ribbon overall.
        XCTAssertEqual(thicknesses.max() ?? -1, thicknesses[2], accuracy: 0.5)
        assertTextsDoNotOverlap(scene)
        let texts = extraSceneTexts(scene).map { $0.0 }
        XCTAssertTrue(texts.contains("Bio-conversion 388.93"))
        XCTAssertTrue(texts.contains("Solid 315.32"))
    }

    func testSankeyQuotedCommasAndMultistageLayers() throws {
        let source = [
            "sankey",
            "    Pumped heat,\"Heating and cooling, homes\",193.026",
            "    Pumped heat,\"Heating and cooling, \"\"commercial\"\"\",70.672",
            "    Raw,Refined,100",
            "    Refined,Shipped,80",
            "    Shipped,Sold,60",
        ].joined(separator: "\n")
        let graph = try MermaidRenderer.parse(source)
        guard let extra = graph.payload as? ExtraParsed, case .sankey(let chart) = extra else {
            XCTFail("Expected sankey payload")
            return
        }
        let targets = chart.links.map(\.target)
        XCTAssertTrue(targets.contains("Heating and cooling, homes"))
        XCTAssertTrue(targets.contains("Heating and cooling, \"commercial\""))
        XCTAssertFalse(targets.contains("\"Heating and cooling"))

        let positioned = try MermaidRenderer.layout(source)
        guard let scene = positioned.extraScene else {
            XCTFail("Expected extra scene")
            return
        }
        // The Raw→Refined→Shipped→Sold chain takes four layers: every band
        // runs left to right with nonzero length.
        let ribbons = scene.items.compactMap { item -> [ExtraPoint]? in
            if case let .polyline(points, _, _, _, closed) = item, closed { return points }
            return nil
        }
        XCTAssertEqual(ribbons.count, 5)
        for ribbon in ribbons {
            let xs = ribbon.map(\.x)
            XCTAssertGreaterThan(xs.max()! - xs.min()!, 10, "degenerate band stacked in one column")
        }
        assertTextsDoNotOverlap(scene)
        let texts = extraSceneTexts(scene).map { $0.0 }
        XCTAssertTrue(texts.contains("Heating and cooling, homes 193.03"))
    }

    func testSankeyBandsStackWithoutOverlap() throws {
        let source = """
        sankey
            Grid,Homes,113.726
            Grid,Industry,342.165
            Grid,Losses,56.691
        """
        let positioned = try MermaidRenderer.layout(source)
        guard let scene = positioned.extraScene else {
            XCTFail("Expected extra scene")
            return
        }
        // Bands leaving Grid occupy disjoint vertical intervals at the
        // source bar: no two links share one line anymore.
        let ribbons = scene.items.compactMap { item -> [ExtraPoint]? in
            if case let .polyline(points, _, _, _, closed) = item, closed { return points }
            return nil
        }
        XCTAssertEqual(ribbons.count, 3)
        let leftX = ribbons.map { $0.map(\.x).min()! }.min()!
        let intervals = ribbons.map { ribbon -> (Double, Double) in
            let ys = ribbon.filter { abs($0.x - leftX) < 1 }.map(\.y)
            return (ys.min()!, ys.max()!)
        }.sorted { $0.0 < $1.0 }
        for (first, second) in zip(intervals, intervals.dropFirst()) {
            XCTAssertLessThanOrEqual(first.1, second.0 + 0.5, "bands overlap at the source bar")
        }
    }

    func testRailroadEbnfDigitStacksAlternatives() throws {
        let source = """
        railroad-ebnf-beta
        title "Digit Definition"
        digit = "0" | "1" | "2" | "3" ;
        """
        let graph = try MermaidRenderer.parse(source)
        guard let extra = graph.payload as? ExtraParsed, case .railroad(let chart) = extra else {
            XCTFail("Expected railroad payload")
            return
        }
        XCTAssertEqual(chart.notation, "ebnf")
        XCTAssertEqual(chart.title, "Digit Definition")
        XCTAssertEqual(chart.rules.map(\.name), ["digit"])
        if case .choice(let alts) = chart.rules[0].definition {
            XCTAssertEqual(alts.count, 4)
        } else {
            XCTFail("Expected a choice of four terminals")
        }

        let positioned = try MermaidRenderer.layout(source)
        guard let scene = positioned.extraScene else {
            XCTFail("Expected extra scene")
            return
        }
        // The first alternative stays on the track; the rest stack below it,
        // centered on it — Pele's own layout assertions.
        let pills = scene.items.compactMap { item -> (Double, Double, Double, Double)? in
            if case let .rect(x, y, width, height, _, _, corner, _) = item, corner > 10 {
                return (x, y, width, height)
            }
            return nil
        }
        XCTAssertEqual(pills.count, 4)
        let first = pills[0]
        for pill in pills.dropFirst() {
            XCTAssertGreaterThanOrEqual(pill.1, first.1 + first.3, "branch not stacked below")
            XCTAssertEqual(pill.0 + pill.2 / 2, first.0 + first.2 / 2, accuracy: 0.5)
        }
        let texts = extraSceneTexts(scene).map { $0.0 }
        for digit in ["0", "1", "2", "3"] {
            XCTAssertTrue(texts.contains(digit), "missing terminal \(digit)")
        }
        XCTAssertTrue(texts.contains("digit"))
        XCTAssertTrue(texts.contains("Digit Definition"))
    }

    func testRailroadNotationsShareOneModel() throws {
        let sources: [(String, String)] = [
            ("railroad-beta", "expression = sequence(nonterminal(\"term\"), zeroOrMore(choice(terminal(\"+\"), terminal(\"-\")))) ;"),
            ("railroad-ebnf-beta", "expression = term, { \"+\" | \"-\" } ;"),
            ("railroad-abnf-beta", "expression = term *( \"+\" / \"-\" ) ;"),
            ("railroad-peg-beta", "expression <- term ( \"+\" / \"-\" )* ;"),
        ]
        for (keyword, rule) in sources {
            let graph = try MermaidRenderer.parse("\(keyword)\n\(rule)")
            guard let extra = graph.payload as? ExtraParsed,
                  case .railroad(let chart) = extra else {
                XCTFail("Expected railroad payload for \(keyword)")
                return
            }
            XCTAssertEqual(chart.rules.count, 1, keyword)
            // A term followed by a loop of the two operators.
            guard case .sequence(let parts) = chart.rules[0].definition,
                  parts.count == 2,
                  case .nonterminal(let name) = parts[0], name == "term",
                  case .repetition(_, let min, let max) = parts[1],
                  min == 0, max == nil else {
                XCTFail("Unexpected shape for \(keyword)")
                return
            }
            let positioned = try MermaidRenderer.layout("\(keyword)\n\(rule)")
            guard let scene = positioned.extraScene else {
                XCTFail("Expected extra scene for \(keyword)")
                return
            }
            // The loop arrow and both operator pills render.
            let arrows = scene.items.filter {
                if case let .polyline(points, _, _, _, closed) = $0 {
                    return closed && points.count == 3
                }
                return false
            }
            XCTAssertFalse(arrows.isEmpty, "missing loop arrow for \(keyword)")
            let texts = extraSceneTexts(scene).map { $0.0 }
            XCTAssertTrue(texts.contains("+"), "missing + for \(keyword)")
            XCTAssertTrue(texts.contains("-"), "missing - for \(keyword)")
        }
    }

    func testKanbanIdsMetadataAndWrapping() throws {
        let source = """
        kanban
          todo[Todo]
            id3[Update Database Function]@{ ticket: MC-2037, assigned: 'knsv', priority: 'High' }
            docs[Create Blog about the new diagram]
          Doing
            id6[Create renderer so that it works in all cases. We also add some extra text here for testing purposes.]
        """
        let graph = try MermaidRenderer.parse(source)
        guard let extra = graph.payload as? ExtraParsed, case .kanban(let chart) = extra else {
            XCTFail("Expected kanban payload")
            return
        }
        XCTAssertEqual(chart.columns.map(\.name), ["Todo", "Doing"])
        XCTAssertEqual(chart.columns[0].cards.map(\.id), ["id3", "docs"])
        XCTAssertEqual(chart.columns[0].cards.map(\.label), ["Update Database Function", "Create Blog about the new diagram"])
        XCTAssertEqual(chart.columns[0].cards[0].ticket, "MC-2037")
        XCTAssertEqual(chart.columns[0].cards[0].assigned, "knsv")
        XCTAssertEqual(chart.columns[0].cards[0].priority, "High")
        XCTAssertNil(chart.columns[0].cards[1].ticket)

        let positioned = try MermaidRenderer.layout(source)
        guard let scene = positioned.extraScene else {
            XCTFail("Expected extra scene")
            return
        }
        let texts = extraSceneTexts(scene).map { $0.0 }
        // Brackets and metadata stay out of the labels…
        XCTAssertFalse(texts.contains(where: { $0.contains("[") || $0.contains("@{") }))
        for name in ["Todo", "Doing", "Update Database Function", "MC-2037", "knsv", "2", "1"] {
            XCTAssertTrue(texts.contains(name), "missing label \(name)")
        }
        // …the long card wraps inside its 200-wide column, and the High
        // card carries a priority stripe.
        let known = Set(["Todo", "Doing", "Update Database Function", "MC-2037", "knsv", "2", "1",
                         "Create Blog about the new diagram"])
        let longLines = texts.filter { !known.contains($0) && !$0.isEmpty }
        XCTAssertGreaterThanOrEqual(longLines.count, 2)
        XCTAssertTrue(longLines.allSatisfy {
            ExtraText.width($0, size: 14) <= 170
        }, "card overflows its column: \(longLines)")
        let stripes = scene.items.filter {
            if case let .line(_, _, _, _, stroke, width, _) = $0, width == 3 {
                return stroke == .translucent(.accent)
            }
            return false
        }
        XCTAssertEqual(stripes.count, 1)
        assertTextsDoNotOverlap(scene)
    }

    func testVennCirclesAreTranslucent() throws {
        let source = """
        venn
          set A Cats
          set B Dogs
          A&B = Both
        """
        let positioned = try MermaidRenderer.layout(source)
        guard let scene = positioned.extraScene else {
            XCTFail("Expected extra scene")
            return
        }
        let fills = scene.items.compactMap { item -> ExtraFill? in
            if case let .ellipse(_, _, _, _, fill, _) = item { return fill }
            return nil
        }
        XCTAssertEqual(fills.count, 2)
        // Series color at low opacity, with a solid series edge — overlaps
        // darken instead of covering.
        XCTAssertEqual(fills[0], .translucent(.series(0)))
        XCTAssertEqual(fills[1], .translucent(.series(1)))
        let strokes = scene.items.compactMap { item -> ExtraFill? in
            if case let .ellipse(_, _, _, _, _, stroke) = item { return stroke }
            return nil
        }
        XCTAssertEqual(strokes, [.series(0), .series(1)])
        let texts = extraSceneTexts(scene).map { $0.0 }
        XCTAssertTrue(texts.contains("Cats"))
        XCTAssertTrue(texts.contains("Dogs"))
    }

    func testRailroadAbnfCountsAndPegPredicates() throws {
        let abnf = try MermaidRenderer.parse("railroad-abnf-beta\nr = 2*4\"a\" 1*\"b\" *\"c\" ;")
        guard let extra = abnf.payload as? ExtraParsed,
              case .railroad(let chart) = extra,
              case .sequence(let parts) = chart.rules[0].definition,
              parts.count == 3,
              case .repetition(_, let min1, let max1) = parts[0],
              case .repetition(_, let min2, let max2) = parts[1],
              case .repetition(_, let min3, let max3) = parts[2] else {
            XCTFail("Unexpected ABNF shape")
            return
        }
        XCTAssertEqual(min1, 2)
        XCTAssertEqual(max1, 4)
        XCTAssertEqual(min2, 1)
        XCTAssertEqual(max2, nil)
        XCTAssertEqual(min3, 0)
        XCTAssertEqual(max3, nil)

        let positioned = try MermaidRenderer.layout("railroad-abnf-beta\nr = 2*4\"a\" ;")
        guard let scene = positioned.extraScene else {
            XCTFail("Expected extra scene")
            return
        }
        let texts = extraSceneTexts(scene).map { $0.0 }
        XCTAssertTrue(texts.contains("2–4×"), "missing count label: \(texts)")

        let peg = try MermaidRenderer.parse("railroad-peg-beta\nr <- !keyword name ;")
        guard let extra2 = peg.payload as? ExtraParsed,
              case .railroad(let chart2) = extra2,
              case .sequence(let seq) = chart2.rules[0].definition,
              seq.count == 2,
              case .special(let text) = seq[0] else {
            XCTFail("Unexpected PEG shape")
            return
        }
        XCTAssertEqual(text, "!keyword")
    }

    func testBlockSpansAndSpaces() throws {
        let source = """
        block
          columns 3
          a["A label"] b:2 c:2 d
          ida space:3 idb idc
        """
        let graph = try MermaidRenderer.parse(source)
        guard let extra = graph.payload as? ExtraParsed, case .block(let chart) = extra else {
            XCTFail("Expected block payload")
            return
        }
        func spans(_ nodes: [BlockNode]) -> [String: Int] {
            Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.span) })
        }
        let top = spans(chart.root.children)
        XCTAssertEqual(top["b"], 2)
        XCTAssertEqual(top["c"], 2)
        XCTAssertEqual(top["d"], 1)
        XCTAssertEqual(chart.root.children.filter { $0.kind == "space" }.count, 3)

        let positioned = try MermaidRenderer.layout(source)
        guard let scene = positioned.extraScene else {
            XCTFail("Expected extra scene")
            return
        }
        // Row 0 is `a b b`: the spanned block is ~two cells wide.
        let widths = scene.items.compactMap { item -> Double? in
            if case let .rect(_, _, width, _, _, _, _, false) = item { return width }
            return nil
        }
        XCTAssertEqual(widths.count, 7)
        XCTAssertGreaterThan(widths[1], widths[0] * 1.8, "span lost: \(widths)")
        assertTextsDoNotOverlap(scene)
        let texts = extraSceneTexts(scene).map { $0.0 }
        for name in ["A label", "b", "c", "d", "ida", "idb", "idc"] {
            XCTAssertTrue(texts.contains(name), "missing label \(name)")
        }
    }

    func testBlockCompositeAndEdges() throws {
        let source = """
        block
        columns 1
          db(("DB"))
          block:ID
            A
            B["A wide one in the middle"]
            C
          end
          space
          D
          ID --> D
          C --> D
          style B fill:#969,stroke:#333,stroke-width:4px
        """
        let graph = try MermaidRenderer.parse(source)
        guard let extra = graph.payload as? ExtraParsed, case .block(let chart) = extra else {
            XCTFail("Expected block payload")
            return
        }
        // No bogus blocks from keywords, style lines or gaps.
        func allIDs(_ node: BlockNode) -> [String] {
            [node.id] + node.children.flatMap(allIDs)
        }
        let ids = allIDs(chart.root)
        for bogus in ["block", "end", "space", "style", "fill"] {
            XCTAssertFalse(ids.contains(bogus), "bogus block \(bogus) in \(ids)")
        }
        XCTAssertEqual(chart.edges.map(\.start), ["ID", "C"])
        XCTAssertEqual(chart.edges.map(\.end), ["D", "D"])

        let positioned = try MermaidRenderer.layout(source)
        guard let scene = positioned.extraScene else {
            XCTFail("Expected extra scene")
            return
        }
        // The composite draws one dashed frame; both edges route to D.
        let dashed = scene.items.filter {
            if case let .rect(_, _, _, _, _, _, _, dashed) = $0 { return dashed }
            return false
        }
        XCTAssertEqual(dashed.count, 1)
        let lines = scene.items.compactMap { item -> (Double, Double, Double, Double)? in
            if case let .line(x1, y1, x2, y2, _, _, _) = item { return (x1, y1, x2, y2) }
            return nil
        }
        XCTAssertEqual(lines.count, 2)
        assertTextsDoNotOverlap(scene)
        let texts = extraSceneTexts(scene).map { $0.0 }
        for name in ["DB", "A", "A wide one in the middle", "C", "D"] {
            XCTAssertTrue(texts.contains(name), "missing label \(name)")
        }
    }

    func testBlockShapesLabelsAndEdgeLabels() throws {
        let source = """
        block
          id1[("Database")]
          id2>"plain box"]
          down<[" "]>(down)
          A space B
          A -- "X" --> B
        """
        let graph = try MermaidRenderer.parse(source)
        guard let extra = graph.payload as? ExtraParsed, case .block(let chart) = extra else {
            XCTFail("Expected block payload")
            return
        }
        func byID(_ nodes: [BlockNode]) -> [String: BlockNode] {
            Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        }
        let nodes = byID(chart.root.children)
        XCTAssertEqual(nodes["id1"]?.label, "Database")
        XCTAssertEqual(nodes["id1"]?.shape, "cylinder")
        XCTAssertEqual(nodes["id2"]?.shape, "rect_left_inv_arrow")
        XCTAssertEqual(nodes["down"]?.shape, "block_arrow")
        XCTAssertEqual(nodes["down"]?.directions, ["down"])
        XCTAssertEqual(chart.edges.first?.label, "X")

        let positioned = try MermaidRenderer.layout(source)
        guard let scene = positioned.extraScene else {
            XCTFail("Expected extra scene")
            return
        }
        let texts = extraSceneTexts(scene).map { $0.0 }
        for name in ["Database", "plain box", "A", "B", "X"] {
            XCTAssertTrue(texts.contains(name), "missing label \(name)")
        }
        // The blank arrow block draws a direction glyph, not an empty box.
        let glyphs = scene.items.filter {
            if case let .polyline(points, _, _, _, closed) = $0 {
                return closed && points.count == 3
            }
            return false
        }
        XCTAssertFalse(glyphs.isEmpty, "missing blockArrow direction glyph")
    }

    func testIshikawaDocExampleParsesEffectAndBones() throws {
        let source = """
        ishikawa-beta
            Blurry Photo
            Process
                Out of focus
                Shutter speed too slow
                Protective film not removed
            User
                Shaky hands
            Equipment
                LENS
                    Inappropriate lens
                    Damaged lens
                    Dirty lens
            Environment
                Subject moved too quickly
                Too dark
        """
        let graph = try MermaidRenderer.parse(source)
        XCTAssertEqual(graph.type, .ishikawa)
        guard let extra = graph.payload as? ExtraParsed, case .ishikawa(let chart) = extra else {
            XCTFail("Expected ishikawa payload")
            return
        }
        XCTAssertEqual(chart.effect, "Blurry Photo")
        XCTAssertEqual(chart.bones.map { $0.name }, ["Process", "User", "Equipment", "Environment"])
        XCTAssertEqual(chart.bones[0].causes, ["Out of focus", "Shutter speed too slow", "Protective film not removed"])
        XCTAssertEqual(chart.bones[1].causes, ["Shaky hands"])
        XCTAssertTrue(chart.bones[2].causes.contains("Damaged lens"))

        let positioned = try MermaidRenderer.layout(source)
        guard let scene = positioned.extraScene else {
            XCTFail("Expected extra scene")
            return
        }
        assertTextsDoNotOverlap(scene)
        let texts = extraSceneTexts(scene).map { $0.0 }
        XCTAssertTrue(texts.contains("Blurry Photo"))
        XCTAssertTrue(texts.contains("Too dark"))
    }

    func testEventModelingDocExampleGroupsSwimlanes() throws {
        let source = """
        eventmodeling
        timeframe 01 ui CartUI
        timeframe 02 command AddItem { description: string }
        timeframe 03 event ItemAdded { description: string }
        """
        let graph = try MermaidRenderer.parse(source)
        XCTAssertEqual(graph.type, .eventmodeling)
        guard let extra = graph.payload as? ExtraParsed, case .eventmodeling(let chart) = extra else {
            XCTFail("Expected eventmodeling payload")
            return
        }
        XCTAssertEqual(chart.frames.map(\.name), ["CartUI", "AddItem", "ItemAdded"])
        XCTAssertEqual(chart.frames.map(\.kind), ["UI", "Command", "Event"])
        XCTAssertEqual(
            chart.lanes.map(\.name),
            ["UI / Automation", "Command / Read model", "Events"]
        )

        let positioned = try MermaidRenderer.layout(source)
        guard let scene = positioned.extraScene else {
            XCTFail("Expected extra scene")
            return
        }
        assertRectsDoNotOverlap(scene)
        assertTextsDoNotOverlap(scene)
        let texts = extraSceneTexts(scene).map { $0.0 }
        XCTAssertTrue(texts.contains("CartUI"))
        XCTAssertFalse(texts.contains { $0.contains("timeframe") })
    }

    func testEventModelingSkipsDataBlocks() throws {
        let source = """
        eventmodeling
        tf 01 ui CartUI
        tf 02 cmd AddItem [[AddItem01]]
        tf 03 evt ItemAdded [[ItemAdded]]

        data AddItem01 {
          description: 'john'
        }
        """
        let positioned = try MermaidRenderer.layout(source)
        guard let scene = positioned.extraScene else {
            XCTFail("Expected extra scene")
            return
        }
        let texts = extraSceneTexts(scene).map { $0.0 }
        XCTAssertFalse(texts.contains { $0.contains("john") })
        XCTAssertFalse(texts.contains { $0.contains("description") })
    }

    // MARK: - Architecture regressions

    private func architectureRects(_ scene: ExtraScene) -> [CGRect] {
        scene.items.compactMap { item in
            if case let .rect(x, y, width, height, _, _, _, _) = item {
                return CGRect(x: x, y: y, width: width, height: height)
            }
            return nil
        }
    }

    func testArchitectureDocExampleNestsServicesInGroup() throws {
        let source = """
        architecture-beta
            group api(cloud)[API]
            service db(database)[Database] in api
            service disk1(disk)[Storage] in api
            service disk2(disk)[Storage] in api
            service server(server)[Server] in api
            db:L -- R:server
            disk1:T -- B:server
            disk2:T -- B:db
        """
        let graph = try MermaidRenderer.parse(source)
        XCTAssertEqual(graph.type, .architecture)
        guard let extra = graph.payload as? ExtraParsed, case .architecture(let chart) = extra else {
            XCTFail("Expected architecture payload")
            return
        }
        XCTAssertEqual(chart.groups.map { $0.id }, ["api"])
        XCTAssertEqual(chart.groups[0].label, "API")
        XCTAssertNil(chart.groups[0].group)
        XCTAssertEqual(chart.services.map { $0.id }, ["db", "disk1", "disk2", "server"])
        XCTAssertTrue(chart.services.allSatisfy { $0.group == "api" })
        XCTAssertEqual(chart.edges.count, 3)
        XCTAssertEqual(chart.edges[0].fromPort, "L")
        XCTAssertEqual(chart.edges[0].toPort, "R")
        XCTAssertFalse(chart.edges[0].endArrow)
        XCTAssertTrue(chart.edges.allSatisfy { $0.label.isEmpty })

        let positioned = try MermaidRenderer.layout(source)
        guard let scene = positioned.extraScene else {
            XCTFail("Expected extra scene")
            return
        }
        assertTextsDoNotOverlap(scene)
        let rects = architectureRects(scene)
        // One group box containing the four service boxes.
        XCTAssertEqual(rects.count, 5)
        let group = rects.max { $0.width * $0.height < $1.width * $1.height }!
        for rect in rects where rect != group {
            XCTAssertTrue(group.contains(rect), "service escapes its group")
        }
        for i in rects.indices {
            for j in rects.indices where j > i {
                let overlap = rects[i].intersection(rects[j])
                // Only containment of members inside the group may intersect.
                if overlap.width * overlap.height > 1 {
                    XCTAssertTrue(rects[i].contains(rects[j]) || rects[j].contains(rects[i]))
                }
            }
        }
        // Three port edges, no arrowheads on plain `--` edges.
        let open = scene.items.filter {
            if case let .polyline(points, _, _, _, closed) = $0 { return !closed && points.count >= 2 }
            return false
        }
        let closed = scene.items.filter {
            if case .polyline(_, _, _, _, true) = $0 { return true }
            return false
        }
        XCTAssertEqual(open.count, 3)
        XCTAssertEqual(closed.count, 0)
        let texts = extraSceneTexts(scene).map { $0.0 }
        XCTAssertTrue(texts.contains("API"))
        XCTAssertTrue(texts.contains("Server"))
        XCTAssertFalse(texts.contains { $0.contains(">") })
    }

    func testArchitecturePortEdgesRouteAroundServices() throws {
        // Same-orientation ports (L→R, T→B) must leave along their side normal
        // and travel around the endpoint boxes, not cut straight through them.
        let source = """
        architecture-beta
            group api(cloud)[API]
            service db(database)[Database] in api
            service disk1(disk)[Storage] in api
            service disk2(disk)[Storage] in api
            service server(server)[Server] in api
            db:L -- R:server
            disk1:T -- B:server
            disk2:T -- B:db
        """
        let positioned = try MermaidRenderer.layout(source)
        guard let scene = positioned.extraScene else {
            XCTFail("Expected extra scene")
            return
        }
        let rects = architectureRects(scene)
        let group = rects.max { $0.width * $0.height < $1.width * $1.height }!
        let services = rects.filter { $0 != group }
        XCTAssertEqual(services.count, 4)
        let open = scene.items.compactMap { item -> [CGPoint]? in
            if case let .polyline(points, _, _, _, closed) = item, !closed {
                return points.map { CGPoint(x: $0.x, y: $0.y) }
            }
            return nil
        }
        XCTAssertEqual(open.count, 3)
        for points in open {
            XCTAssertGreaterThanOrEqual(points.count, 2)
            for k in 0..<(points.count - 1) {
                let mid = CGPoint(x: (points[k].x + points[k + 1].x) / 2,
                                  y: (points[k].y + points[k + 1].y) / 2)
                for box in services {
                    XCTAssertFalse(box.insetBy(dx: 0.5, dy: 0.5).contains(mid),
                                   "edge segment cuts through a service box")
                }
            }
        }
    }

    func testRadarBetaDocsExampleRenders() throws {
        let source = """
        ---
        title: "Grades"
        ---
        radar-beta
          axis m["Math"], s["Science"], e["English"]
          axis h["History"], g["Geography"], a["Art"]
          curve a["Alice"]{85, 90, 80, 70, 75, 90}
          curve b["Bob"]{70, 75, 85, 80, 90, 85}

          max 100
          min 0
        """
        let graph = try MermaidRenderer.parse(source)
        guard let extra = graph.payload as? ExtraParsed, case .radar(let chart) = extra else {
            XCTFail("Expected radar payload")
            return
        }
        XCTAssertEqual(chart.axes, ["Math", "Science", "English", "History", "Geography", "Art"])
        XCTAssertEqual(chart.series.map(\.name), ["Alice", "Bob"])
        XCTAssertEqual(chart.series[0].values, [85, 90, 80, 70, 75, 90])
        XCTAssertEqual(chart.max, 100)
        XCTAssertEqual(chart.min, 0)

        let positioned = try MermaidRenderer.layout(source)
        guard let scene = positioned.extraScene else {
            XCTFail("Expected extra scene")
            return
        }
        // Both series draw closed data polygons.
        let data = scene.items.compactMap { item -> [ExtraPoint]? in
            if case let .polyline(points, _, stroke, _, closed) = item, closed, stroke != .muted {
                return points
            }
            return nil
        }
        XCTAssertEqual(data.count, 2)
        // Scaled by max 100: radii from the spoke center match value ratios exactly.
        let spokes = scene.items.compactMap { item -> (Double, Double)? in
            if case let .line(x1, y1, _, _, _, _, _) = item { return (x1, y1) }
            return nil
        }
        XCTAssertFalse(spokes.isEmpty)
        let (ccx, ccy) = spokes[0]
        let alice = data[0].map { hypot($0.x - ccx, $0.y - ccy) }
        XCTAssertEqual(alice[1] / alice[3], 90.0 / 70.0, accuracy: 0.01)
        XCTAssertEqual(alice[0] / alice[3], 85.0 / 70.0, accuracy: 0.01)
    }

    func testTreeViewBoxDrawingParsesHierarchy() throws {
        let source = """
        treeView-beta
        ├── src/
        │   ├── index.ts
        │   └── utils.ts
        ├── package.json
        └── README.md
        """
        let graph = try MermaidRenderer.parse(source)
        guard let extra = graph.payload as? ExtraParsed, case .treeView(let chart) = extra else {
            XCTFail("Expected treeView payload")
            return
        }
        // Directories lose their slash; nesting is a real tree.
        XCTAssertEqual(chart.nodes.map(\.name), ["src", "package.json", "README.md"])
        XCTAssertTrue(chart.nodes[0].isDirectory)
        XCTAssertFalse(chart.nodes[1].isDirectory)
        XCTAssertEqual(chart.nodes[0].children.map(\.name), ["index.ts", "utils.ts"])

        let positioned = try MermaidRenderer.layout(source)
        guard let scene = positioned.extraScene else {
            XCTFail("Expected extra scene")
            return
        }
        let labels = scene.items.compactMap { item -> String? in
            if case let .text(text, _, _, _, _, _, _) = item { return text }
            return nil
        }
        for name in ["src", "index.ts", "utils.ts", "package.json", "README.md"] {
            XCTAssertTrue(labels.contains(name), "missing label \(name)")
        }
        // Guide rails route the hierarchy, and the directory row is bold.
        XCTAssertTrue(scene.items.contains {
            if case .line = $0 { return true }
            return false
        })
        let bolds = scene.items.compactMap { item -> String? in
            if case let .text(text, _, _, _, _, _, weight) = item, weight == 600 { return text }
            return nil
        }
        XCTAssertTrue(bolds.contains("src"))
    }

    func testTreeViewAnnotationsIconsAndDescriptions() throws {
        let source = """
        treeView-beta
          elegant/
            App.tsx :::highlight icon(logos:react) ## main component
            "quoted name" ## quoted
            plain icon(none)
        """
        let graph = try MermaidRenderer.parse(source)
        guard let extra = graph.payload as? ExtraParsed, case .treeView(let chart) = extra else {
            XCTFail("Expected treeView payload")
            return
        }
        XCTAssertEqual(chart.nodes.map(\.name), ["elegant"])
        XCTAssertTrue(chart.nodes[0].isDirectory)
        let kids = chart.nodes[0].children
        XCTAssertEqual(kids.map(\.name), ["App.tsx", "quoted name", "plain"])
        XCTAssertEqual(kids[0].cssClass, "highlight")
        XCTAssertEqual(kids[0].icon, "logos:react")
        XCTAssertEqual(kids[0].description, "main component")
        XCTAssertEqual(kids[1].description, "quoted")
        XCTAssertEqual(kids[2].icon, "none")

        let positioned = try MermaidRenderer.layout(source)
        guard let scene = positioned.extraScene else {
            XCTFail("Expected extra scene")
            return
        }
        let texts = extraSceneTexts(scene).map { $0.0 }
        // Annotation syntax stays out of the labels; the description renders.
        XCTAssertFalse(texts.contains(where: { $0.contains(":::") || $0.contains("icon(") }))
        for name in ["elegant", "App.tsx", "main component", "quoted name", "quoted", "plain"] {
            XCTAssertTrue(texts.contains(name), "missing label \(name)")
        }
        // The highlight row carries a translucent wash.
        XCTAssertTrue(scene.items.contains {
            if case let .rect(_, _, _, _, fill, _, _, _) = $0, fill == .translucent(.accent) {
                return true
            }
            return false
        })
        assertTextsDoNotOverlap(scene)
    }

    func testUseCaseBetaDocsExampleRenders() throws {
        let source = """
        usecase-beta
        direction LR
        actor Customer("Customer")
        systemBoundary "Order system"
          Checkout("Place order")
        end
        Customer --> Checkout
        """
        let graph = try MermaidRenderer.parse(source)
        guard let extra = graph.payload as? ExtraParsed, case .usecase(let chart) = extra else {
            XCTFail("Expected usecase payload")
            return
        }
        XCTAssertEqual(chart.actors.map(\.id), ["Customer"])
        XCTAssertEqual(chart.actors.map(\.label), ["Customer"])
        XCTAssertEqual(chart.cases.map(\.id), ["Checkout"])
        XCTAssertEqual(chart.cases.map(\.label), ["Place order"])
        XCTAssertEqual(chart.boundaries.map(\.label), ["Order system"])
        XCTAssertEqual(chart.boundaries.first?.members, ["Checkout"])
        XCTAssertEqual(chart.edges.count, 1)
        XCTAssertEqual(chart.edges.first?.from, "Customer")
        XCTAssertEqual(chart.edges.first?.to, "Checkout")
        XCTAssertEqual(chart.edges.first?.kind, "association")
        XCTAssertEqual(chart.edges.first?.endMarker, "arrow")

        let positioned = try MermaidRenderer.layout(source)
        guard let scene = positioned.extraScene else {
            XCTFail("Expected extra scene")
            return
        }
        let labels = scene.items.compactMap { item -> String? in
            if case let .text(text, _, _, _, _, _, _) = item { return text }
            return nil
        }
        for name in ["Customer", "Place order", "Order system"] {
            XCTAssertTrue(labels.contains(name), "missing label \(name)")
        }
        // The edge runs from the actor column to the use-case column.
        let lines = scene.items.compactMap { item -> (Double, Double, Double, Double)? in
            if case let .line(x1, y1, x2, y2, _, _, _) = item { return (x1, y1, x2, y2) }
            return nil
        }
        XCTAssertFalse(lines.isEmpty)
        XCTAssertTrue(lines.contains { $0.0 < $0.2 }, "edge never leaves the actor column")
    }

    func testUseCaseBareIdsIncludeAndRects() throws {
        let source = """
        usecase-beta
        Customer --> Login
        actor Customer
        actor Support
        Login("Sign in")
        Report[Generate report]
        "Reset password"
        Support --> Track
        Checkout ..> : include Browse
        """
        let graph = try MermaidRenderer.parse(source)
        guard let extra = graph.payload as? ExtraParsed, case .usecase(let chart) = extra else {
            XCTFail("Expected usecase payload")
            return
        }
        // Bare endpoints become use cases even when the edge precedes them.
        let byID = Dictionary(uniqueKeysWithValues: chart.cases.map { ($0.id, $0) })
        XCTAssertEqual(byID["Login"]?.label, "Sign in")
        XCTAssertEqual(byID["Report"]?.label, "Generate report")
        XCTAssertEqual(byID["Report"]?.shape, "rect")
        XCTAssertEqual(byID["Reset_password"]?.label, "Reset password")
        XCTAssertEqual(byID["Track"]?.label, "Track")
        XCTAssertEqual(chart.actors.map(\.id), ["Customer", "Support"])
        let kinds = Dictionary(uniqueKeysWithValues: chart.edges.map { ("\($0.from)->\($0.to)", $0.kind) })
        XCTAssertEqual(kinds["Customer->Login"], "association")
        XCTAssertEqual(kinds["Support->Track"], "association")
        XCTAssertEqual(kinds["Checkout->Browse"], "include")
        XCTAssertEqual(chart.edges.first { $0.kind == "include" }?.label, "include")

        let positioned = try MermaidRenderer.layout(source)
        guard let scene = positioned.extraScene else {
            XCTFail("Expected extra scene")
            return
        }
        let labels = scene.items.compactMap { item -> String? in
            if case let .text(text, _, _, _, _, _, _) = item { return text }
            return nil
        }
        for name in ["Customer", "Support", "Sign in", "Generate report", "Reset password", "include"] {
            XCTAssertTrue(labels.contains(name), "missing label \(name)")
        }
        // The actor edges are routed to different use cases, not stacked on
        // one hardcoded line. (Figure limbs are short; routed edges span the
        // actor-to-case column gap.)
        let edgeLines = scene.items.compactMap { item -> String? in
            if case let .line(x1, y1, x2, y2, _, _, false) = item, x2 - x1 > 60 {
                return "\(x1),\(y1),\(x2),\(y2)"
            }
            return nil
        }
        XCTAssertEqual(edgeLines.count, 2)
        XCTAssertEqual(edgeLines.count, Set(edgeLines).count, "duplicate edge lines overlap exactly")
    }

    func testArchitectureArrowsJunctionsAndAlignRow() throws {
        let source = """
        architecture-beta
            service left(disk)[Left]
            service right(disk)[Right]
            junction jc
            left:R --> L:jc
            jc:R --> L:right
            align row left jc right
        """
        let graph = try MermaidRenderer.parse(source)
        XCTAssertEqual(graph.type, .architecture)
        guard let extra = graph.payload as? ExtraParsed, case .architecture(let chart) = extra else {
            XCTFail("Expected architecture payload")
            return
        }
        XCTAssertEqual(chart.services.count, 3)
        XCTAssertEqual(chart.services.last?.shape, "junction")
        XCTAssertEqual(chart.edges.count, 2)
        XCTAssertTrue(chart.edges.allSatisfy { $0.endArrow && !$0.startArrow })
        XCTAssertEqual(chart.alignments.count, 1)
        XCTAssertEqual(chart.alignments[0].axis, "row")

        let positioned = try MermaidRenderer.layout(source)
        guard let scene = positioned.extraScene else {
            XCTFail("Expected extra scene")
            return
        }
        assertTextsDoNotOverlap(scene)
        // Junction renders as a circle, not a box.
        let ellipses = scene.items.filter {
            if case .ellipse = $0 { return true }
            return false
        }
        XCTAssertEqual(ellipses.count, 1)
        // Two arrowheads: closed triangles.
        let heads = scene.items.filter {
            if case let .polyline(points, _, _, _, closed) = $0 { return closed && points.count == 3 }
            return false
        }
        XCTAssertEqual(heads.count, 2)
        // Aligned row: node centers share one y.
        let centers = architectureRects(scene).map { $0.midY }
            + ellipses.compactMap { item -> Double? in
                if case let .ellipse(_, y, _, height, _, _) = item { return y + height / 2 }
                return nil
            }
        XCTAssertGreaterThanOrEqual(centers.count, 3)
        XCTAssertLessThan(centers.max()! - centers.min()!, 2)
    }

    func testArchitectureGroupModifierEdgesTouchGroupBorders() throws {
        let source = """
        architecture-beta
            group g1(cloud)[G1]
            group g2(cloud)[G2]
            service s1(server)[S1] in g1
            service s2(server)[S2] in g2
            s1{group}:R --> L:s2{group}
        """
        let graph = try MermaidRenderer.parse(source)
        XCTAssertEqual(graph.type, .architecture)
        guard let extra = graph.payload as? ExtraParsed, case .architecture(let chart) = extra else {
            XCTFail("Expected architecture payload")
            return
        }
        XCTAssertEqual(chart.edges.count, 1)
        XCTAssertTrue(chart.edges[0].fromGroup)
        XCTAssertTrue(chart.edges[0].toGroup)
        XCTAssertTrue(chart.edges[0].endArrow)

        let positioned = try MermaidRenderer.layout(source)
        guard let scene = positioned.extraScene else {
            XCTFail("Expected extra scene")
            return
        }
        let rects = architectureRects(scene)
        guard let edge = scene.items.first(where: {
            if case let .polyline(points, _, _, _, closed) = $0 { return !closed && points.count >= 2 }
            return false
        }) else {
            XCTFail("Expected group edge polyline")
            return
        }
        guard case let .polyline(points, _, _, _, _) = edge else { return }
        let start = points.first!
        let end = points.last!
        XCTAssertTrue(rects.contains { abs($0.maxX - start.x) < 1 && start.y >= $0.minY && start.y <= $0.maxY })
        XCTAssertTrue(rects.contains { abs($0.minX - end.x) < 1 && end.y >= $0.minY && end.y <= $0.maxY })
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

    func testUmbraThemeMatchesArmadaPalette() throws {
        // Armada Dark editor values from ThemeCatalog (Armada_Dark.icls).
        let umbra = DiagramTheme.umbra
        XCTAssertTrue(umbra.background.bmColorEquals(BMColor(hex: "#18191B")))
        XCTAssertTrue(umbra.foreground.bmColorEquals(BMColor(hex: "#E0E1E4")))
        XCTAssertTrue(umbra.effectiveAccent().bmColorEquals(BMColor(hex: "#82D2CE")))
        XCTAssertTrue(umbra.effectiveMuted().bmColorEquals(BMColor(hex: "#909194")))
        XCTAssertEqual(DiagramTheme.theme(named: "Umbra")?.background.bmColorEquals(umbra.background), true)
        XCTAssertTrue(DiagramTheme.allThemes.contains { $0.name == "Umbra" })
        // Umbra is the default mermaid scheme.
        XCTAssertTrue(DiagramTheme.default.background.bmColorEquals(umbra.background))
        XCTAssertTrue(DiagramTheme.default.foreground.bmColorEquals(umbra.foreground))
        // The preview adapter seeds dark pages from Umbra so series colors stay
        // in the teal family instead of rotating around near-white foreground.
        typealias Context = MarkdownPreviewStyle.MermaidRenderingContext
        let dark = Context(
            backgroundRGBA: (0.09, 0.10, 0.11, 1), foregroundRGBA: (0.88, 0.88, 0.90, 1),
            mermaidMaxDimension: 4096)
        let darkTheme = MermaidPaintAdapter.diagramTheme(from: dark)
        XCTAssertTrue(darkTheme.effectiveAccent().bmColorEquals(BMColor(hex: "#82D2CE")))
        XCTAssertTrue(darkTheme.effectiveMuted().bmColorEquals(BMColor(hex: "#909194")))
        let light = Context(
            backgroundRGBA: (1, 1, 1, 1), foregroundRGBA: (0.1, 0.1, 0.1, 1),
            mermaidMaxDimension: 4096)
        let lightTheme = MermaidPaintAdapter.diagramTheme(from: light)
        XCTAssertTrue(lightTheme.effectiveAccent().bmColorEquals(lightTheme.foreground))
    }
}
