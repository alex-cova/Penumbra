import AppKit
import DiagramKit
import SwiftUI

/// The pannable, zoomable surface: DiagramKit supplies the canvas, hit testing and selection; the boxes and
/// UML edges are drawn here.
struct IDEDiagramCanvasView: View {
    let session: IDEDiagramSession

    var body: some View {
        @Bindable var host = session.host
        DiagramCanvasView(
            viewport: $host.viewport,
            marqueeWorld: $host.marqueeWorld,
            canvas: host.document.canvas,
            backgroundOverride: IDEDiagramPalette.codable(IDEAppearance.scheme.editor),
            selection: host.selection,
            interaction: interaction,
            guides: host.activeGuides,
            contentBounds: CanvasEngine.contentBounds(nodes: host.document.nodes),
            onViewSizeChange: { session.canvasSizeChanged($0) }
        ) {
            IDEDiagramContentView(session: session)
        }
    }

    private var interaction: DiagramCanvasInteraction {
        let host = session.host
        return DiagramCanvasInteraction(
            isPanToolActive: false,
            allowsMarqueeSelection: true,
            selectedIDs: { host.selection },
            nodeFrames: { host.document.nodes.map { NodeFrame(id: $0.id, frame: $0.frame) } },
            frame: { host.document.node(id: $0)?.frame },
            hitTestNode: { host.hitTestNode(at: $0) },
            hitTestEdge: { host.hitTestEdge(at: $0) },
            onSelect: { id, additive in host.selectOnly(id, additive: additive) },
            onMarqueeSelect: { ids, additive in
                if additive { host.selection.formUnion(ids) } else { host.selection = ids }
            },
            onClearSelection: { host.selection = [] },
            onSetNodeFrames: { frames, registerUndo in host.applyEdit(.setNodeFrames(frames), registerUndo: registerUndo) },
            onResizeNode: { _, _, _ in },
            onDeleteSelection: {},
            canDeleteSelection: { false },
            onTap: { world, shift in
                if let id = host.hitTestNode(at: world) {
                    host.selectOnly(id, additive: shift)
                } else if let id = host.hitTestEdge(at: world) {
                    host.selectOnly(id, additive: shift)
                } else if !shift {
                    host.selection = []
                }
            },
            onEscape: { host.selection = [] },
            onHoverWorld: nil,
            shouldHandleSelectDrag: true,
            onSelectAll: { host.selectAll() },
            onNudge: { delta in host.nudgeSelection(dx: delta.width, dy: delta.height) },
            nudgeStep: 8,
            intersectingNodes: { host.nodesIntersecting(marquee: $0) },
            onGuidesChange: { host.activeGuides = $0 }
        )
    }
}

private struct IDEDiagramContentView: View {
    let session: IDEDiagramSession
    @Environment(\.visibleWorldRect) private var visibleWorldRect

    var body: some View {
        let host = session.host
        let document = host.document
        let dark = IDEAppearance.scheme.isDark
        let selection = host.selection
        let scene = IDEDiagramSceneBuilder.build(
            document: document,
            routes: host.cachedEdgeRoutes(),
            selection: selection,
            theme: IDEDiagramPalette.theme(dark: dark),
            dark: dark
        )
        let kinds = Dictionary(document.edges.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        let byID = Dictionary(document.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let nodeIDs = Set(byID.keys)
        let pairs = document.edges.map { ($0.sourceID, $0.destinationID) }
        let visibleNodes = scene.visibleNodes(in: visibleWorldRect)
        let visibleEdges = scene.visibleEdges(in: visibleWorldRect)
        let viewport = host.viewport
        let background = IDEAppearance.ColorToken.editor
        let label = IDEAppearance.ColorToken.muted

        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                IDEDiagramEdgeDrawing.draw(
                    visibleEdges, kinds: kinds, viewport: viewport,
                    background: background, labelColor: label, in: &context
                )
            }
            .allowsHitTesting(false)

            if visibleNodes.count > DiagramSceneRenderer.canvasNodeThreshold {
                Canvas { context, _ in
                    DiagramSceneRenderer.drawNodes(visibleNodes, viewport: viewport, in: &context)
                }
                .allowsHitTesting(false)
            } else {
                ForEach(visibleNodes) { sceneNode in
                    if let node = byID[sceneNode.id] {
                        let origin = viewport.worldToView(node.frame.origin)
                        IDEDiagramNodeView(
                            node: node,
                            isSelected: selection.contains(node.id),
                            highlight: DiagramFocusResolver.nodeLevel(
                                nodeID: node.id, selection: selection, edges: pairs, nodeIDs: nodeIDs
                            ),
                            dark: dark
                        )
                        .scaleEffect(viewport.zoom, anchor: .topLeading)
                        .offset(x: origin.x, y: origin.y)
                        .simultaneousGesture(TapGesture(count: 2).onEnded { session.open(node) })
                        .contextMenu { nodeMenu(for: node) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func nodeMenu(for node: IDEDiagramNode) -> some View {
        if node.fileURL != nil {
            Button("Open Source") { session.open(node) }
        }
        if session.request.isClassDiagram, node.kind.isType {
            Button("Show Diagram Around Type") { session.showDiagramAround(node) }
        }
        if node.kind == .project {
            Button("Show Dependencies of Module") { session.showLibraries(of: node) }
        }
        Divider()
        Button("Copy Name") { session.copyName(of: node) }
    }
}
