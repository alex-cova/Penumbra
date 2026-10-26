import AppKit
import DiagramKit
import SwiftUI
import UniformTypeIdentifiers

enum IDEDiagramExportFormat: CaseIterable {
    case png
    case pdf
    case svg

    var title: String {
        switch self {
        case .png: "PNG Image…"
        case .pdf: "PDF Document…"
        case .svg: "SVG Image…"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .pdf: "pdf"
        case .svg: "svg"
        }
    }

    var contentType: UTType {
        switch self {
        case .png: .png
        case .pdf: .pdf
        case .svg: .svg
        }
    }
}

/// The whole diagram, unscaled and without selection, as a plain SwiftUI view that `ImageRenderer` can draw.
private struct IDEDiagramExportView: View {
    let document: IDEDiagramDocument
    let scene: DiagramScene
    let bounds: CGRect
    let dark: Bool

    var body: some View {
        let viewport = ViewportState(offset: CGPoint(x: -bounds.minX, y: -bounds.minY), zoom: 1)
        let kinds = Dictionary(document.edges.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        let background = IDEAppearance.ColorToken.editor
        ZStack(alignment: .topLeading) {
            background
            Canvas { context, _ in
                IDEDiagramEdgeDrawing.draw(
                    scene.edges, kinds: kinds, viewport: viewport,
                    background: background, labelColor: IDEAppearance.ColorToken.muted, in: &context
                )
            }
            ForEach(document.nodes) { node in
                IDEDiagramNodeView(node: node, isSelected: false, highlight: .normal, dark: dark)
                    .offset(x: node.frame.minX - bounds.minX, y: node.frame.minY - bounds.minY)
            }
        }
        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

@MainActor
enum IDEDiagramExporter {
    static let padding: CGFloat = 32

    static func bounds(of document: IDEDiagramDocument) -> CGRect? {
        guard var union = document.nodes.first?.frame else { return nil }
        for node in document.nodes.dropFirst() { union = union.union(node.frame) }
        return union.insetBy(dx: -padding, dy: -padding)
    }

    static func data(for session: IDEDiagramSession, format: IDEDiagramExportFormat) throws -> Data {
        let document = session.document
        guard let bounds = bounds(of: document) else { throw ExportError.renderFailed }
        let dark = IDEAppearance.scheme.isDark
        let scene = IDEDiagramSceneBuilder.build(
            document: document,
            routes: session.host.cachedEdgeRoutes(),
            selection: [],
            theme: IDEDiagramPalette.theme(dark: dark),
            dark: dark
        )
        switch format {
        case .png:
            return try DiagramExporter.png(
                content: IDEDiagramExportView(document: document, scene: scene, bounds: bounds, dark: dark),
                scale: .x2
            )
        case .pdf:
            return try pdf(IDEDiagramExportView(document: document, scene: scene, bounds: bounds, dark: dark), size: bounds.size)
        case .svg:
            return try svg(document: document, scene: scene, bounds: bounds, dark: dark)
        }
    }

    static func export(_ session: IDEDiagramSession, as format: IDEDiagramExportFormat, window: NSWindow?) {
        guard bounds(of: session.document) != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = fileName(for: session.title) + "." + format.fileExtension
        let write: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data(for: session, format: format).write(to: url, options: .atomic)
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = "Could not export the diagram"
                alert.runModal()
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: write)
        } else {
            panel.begin(completionHandler: write)
        }
    }

    static func fileName(for title: String) -> String {
        let cleaned = title.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        let name = String(cleaned).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return name.isEmpty ? "diagram" : name
    }

    private static func pdf(_ view: some View, size: CGSize) throws -> Data {
        let renderer = ImageRenderer(content: view)
        let data = NSMutableData()
        var rendered = false
        renderer.render { renderSize, render in
            var box = CGRect(origin: .zero, size: renderSize)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil)
            else { return }
            context.beginPDFPage(nil)
            render(context)
            context.endPDFPage()
            context.closePDF()
            rendered = true
        }
        guard rendered, data.length > 0 else { throw ExportError.pdfFailed }
        return data as Data
    }

    private static func svg(document: IDEDiagramDocument, scene: DiagramScene, bounds: CGRect, dark: Bool) throws -> Data {
        let kinds = Dictionary(document.edges.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        let scheme = IDEAppearance.scheme
        let ink = IDEDiagramPalette.codable(scheme.foreground)
        let muted = IDEDiagramPalette.codable(scheme.muted)
        let canvas = IDEDiagramPalette.codable(scheme.editor)
        return try DiagramExporter.svg(bounds: bounds, background: canvas) { graphics in
            for edge in scene.edges {
                let geometry = IDEDiagramEdgeMarkers.geometry(kind: kinds[edge.id] ?? .association, route: edge.route.points, size: 10)
                graphics.polyline(geometry.line, stroke: edge.stroke, lineWidth: max(1, edge.lineWidth), dashed: edge.isDashed)
                for shape in geometry.shapes {
                    let fill: CodableColor? = switch shape.fill {
                    case .none: nil
                    case .background: canvas
                    case .stroke: edge.stroke
                    }
                    graphics.path(shape.points, closed: shape.closed, fill: fill, stroke: edge.stroke, lineWidth: max(1, edge.lineWidth))
                }
                if !edge.label.isEmpty {
                    graphics.text(edge.label, at: edge.labelPoint, fontSize: 10, anchor: "middle", fill: muted)
                }
            }
            for node in document.nodes {
                let colors = IDEDiagramPalette.colors(for: node.kind, dark: dark)
                let frame = node.frame
                graphics.rect(frame, fill: IDEDiagramPalette.codable(colors.fill), stroke: IDEDiagramPalette.codable(colors.stroke), lineWidth: 1)
                let headerHeight = IDEDiagramNodeMetrics.headerHeight + (node.subtitle.isEmpty ? 0 : IDEDiagramNodeMetrics.lineHeight - 2)
                graphics.rect(
                    CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: headerHeight),
                    fill: IDEDiagramPalette.codable(colors.header), stroke: IDEDiagramPalette.codable(colors.stroke), lineWidth: 1
                )
                let titleY = frame.minY + (node.subtitle.isEmpty ? headerHeight / 2 + 4 : 15)
                graphics.text(node.title, at: CGPoint(x: frame.minX + 10, y: titleY), fontSize: 12, weight: "600", fill: ink)
                if !node.subtitle.isEmpty {
                    graphics.text(node.subtitle, at: CGPoint(x: frame.minX + 10, y: frame.minY + headerHeight - 6), fontSize: 9.5, fill: muted)
                }
                guard node.kind.isType, node.kind != .externalType else { continue }
                var y = frame.minY + headerHeight
                for lines in [node.attributes, node.methods] {
                    let shown = IDEDiagramNodeMetrics.displayed(lines)
                    graphics.polyline(
                        [CGPoint(x: frame.minX, y: y), CGPoint(x: frame.maxX, y: y)],
                        stroke: IDEDiagramPalette.codable(colors.stroke), lineWidth: 0.5
                    )
                    y += IDEDiagramNodeMetrics.sectionPadding
                    for line in shown {
                        graphics.text(
                            line, at: CGPoint(x: frame.minX + 10, y: y + 11), fontSize: 10.5,
                            fontFamily: "ui-monospace, Menlo, monospace", fill: line.hasPrefix("- ") ? muted : ink
                        )
                        y += IDEDiagramNodeMetrics.lineHeight
                    }
                    y += IDEDiagramNodeMetrics.sectionPadding
                }
            }
        }
    }
}
