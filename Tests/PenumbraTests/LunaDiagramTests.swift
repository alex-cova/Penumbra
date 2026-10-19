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
