import AppKit
import JavaIntelligence
import SwiftUI

/// An icicle flame graph (root at the top) drawn by hand: only boxes wider than a pixel and inside
/// the visible rect are drawn, and hit-testing reads a flat layout array.
///
/// The layout is rebuilt when the tree, the zoom root or the width changes; scrolling and hovering
/// only redraw. A node's width is its total over the root's total, so a node's children sit under it
/// and a method that is hot shows as a wide plateau.
final class IDEFlameGraphNSView: NSView {
    struct Box {
        var node: Int
        var x: CGFloat
        var width: CGFloat
        var depth: Int
    }

    static let rowHeight: CGFloat = 18
    private static let minimumWidth: CGFloat = 0.75

    // Inputs
    private(set) var tree = JavaProfileTree()
    private(set) var symbols = JavaProfileSymbols()
    private(set) var rootNode = JavaProfileTree.root
    private(set) var highlightedMethods: Set<Int32> = []
    private(set) var selectedMethod: Int32?

    var onSelectMethod: ((Int32?) -> Void)?
    var onZoom: ((Int) -> Void)?
    var onZoomOut: (() -> Void)?
    var onOpenSource: ((Int32, Int) -> Void)?

    private var rows: [[Box]] = []
    private var layoutWidth: CGFloat = 0
    private var hoveredNode: Int?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func update(
        tree: JavaProfileTree, symbols: JavaProfileSymbols, rootNode: Int,
        highlighted: Set<Int32>, selected: Int32?
    ) {
        let relayout = self.tree.nodeCount != tree.nodeCount || self.tree.totalSamples != tree.totalSamples
            || self.rootNode != rootNode
        self.tree = tree
        self.symbols = symbols
        self.rootNode = rootNode
        highlightedMethods = highlighted
        selectedMethod = selected
        if relayout { rows = []; layoutWidth = 0 }
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        if abs(bounds.width - layoutWidth) > 0.5 || rows.isEmpty { rebuildLayout() }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: CGFloat(max(rows.count, 1)) * Self.rowHeight + 8)
    }

    private func rebuildLayout() {
        layoutWidth = bounds.width
        rows = []
        let total = tree.totalCount(of: rootNode)
        guard total > 0, layoutWidth > 1 else {
            resizeToContent()
            needsDisplay = true
            return
        }
        let scale = layoutWidth / CGFloat(total)
        // Depth-first with an explicit stack: stacks of thousands of frames must not recurse.
        var stack: [(node: Int, x: CGFloat, depth: Int)] = [(rootNode, 0, 0)]
        while let (node, x, depth) = stack.popLast() {
            let width = CGFloat(tree.totalCount(of: node)) * scale
            guard width >= Self.minimumWidth else { continue }
            while rows.count <= depth { rows.append([]) }
            rows[depth].append(Box(node: node, x: x, width: width, depth: depth))
            var childX = x
            for child in tree.children(of: node) {
                stack.append((child, childX, depth + 1))
                childX += CGFloat(tree.totalCount(of: child)) * scale
            }
        }
        for index in rows.indices { rows[index].sort { $0.x < $1.x } }
        resizeToContent()
        needsDisplay = true
    }

    /// A scroll view's document view is sized by its owner: tall enough for the deepest stack, and
    /// at least the visible height so a shallow graph does not float in the middle.
    private func resizeToContent() {
        let content = CGFloat(max(rows.count, 1)) * Self.rowHeight + 8
        let visible = enclosingScrollView?.contentSize.height ?? 0
        let height = max(content, visible)
        if abs(frame.height - height) > 0.5 { setFrameSize(NSSize(width: frame.width, height: height)) }
        invalidateIntrinsicContentSize()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        guard !rows.isEmpty else { return }
        let firstRow = max(0, Int(dirtyRect.minY / Self.rowHeight))
        let lastRow = min(rows.count - 1, Int(dirtyRect.maxY / Self.rowHeight))
        guard firstRow <= lastRow else { return }
        let font = NSFont.systemFont(ofSize: 10)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black.withAlphaComponent(0.85)]
        let dimmed = !highlightedMethods.isEmpty
        for depth in firstRow...lastRow {
            let y = CGFloat(depth) * Self.rowHeight
            for box in rows[depth] where box.x + box.width >= dirtyRect.minX && box.x <= dirtyRect.maxX {
                let frame = tree.frame(of: box.node)
                let method: Int32? = frame >= 0 ? symbols.frame(frame).method : nil
                let rect = NSRect(x: box.x, y: y, width: max(box.width - 0.5, 0.5), height: Self.rowHeight - 1)
                var color = Self.color(for: method, symbols: symbols, isOther: frame == JavaProfileTree.otherFrame)
                let matches = method.map { highlightedMethods.contains($0) } ?? false
                if dimmed, !matches { color = color.blended(withFraction: 0.65, of: .textBackgroundColor) ?? color }
                color.setFill()
                rect.fill()
                if method != nil, method == selectedMethod || box.node == hoveredNode {
                    NSColor.controlAccentColor.setStroke()
                    let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
                    path.lineWidth = 1.5
                    path.stroke()
                }
                if rect.width > 28 {
                    let label = Self.label(frame: frame, symbols: symbols)
                    let size = NSSize(width: rect.width - 6, height: rect.height)
                    (label as NSString).draw(
                        with: NSRect(origin: NSPoint(x: rect.minX + 3, y: rect.minY + 2), size: size),
                        options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], attributes: attributes
                    )
                }
            }
        }
    }

    static func label(frame: Int32, symbols: JavaProfileSymbols) -> String {
        if frame == JavaProfileTree.otherFrame { return "(other)" }
        if frame < 0 { return "all" }
        let method = symbols.method(ofFrame: frame)
        let simple = method.className.split(separator: ".").last.map(String.init) ?? method.className
        return simple.isEmpty ? method.name : "\(simple).\(method.name)"
    }

    /// A stable pastel per package, so a library's frames read as one band.
    static func color(for method: Int32?, symbols: JavaProfileSymbols, isOther: Bool) -> NSColor {
        if isOther { return NSColor.systemGray.withAlphaComponent(0.5) }
        guard let method else { return NSColor.systemGray.withAlphaComponent(0.3) }
        let package = symbols.packageName(ofMethod: method)
        if package.hasPrefix("java.") || package.hasPrefix("javax.") || package.hasPrefix("jdk.") || package.hasPrefix("sun.") {
            return NSColor(calibratedRed: 0.62, green: 0.76, blue: 0.95, alpha: 1)
        }
        var hash: UInt64 = 1469598103934665603
        for byte in package.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        let hue = CGFloat(hash % 360) / 360
        return NSColor(calibratedHue: hue, saturation: 0.45, brightness: 0.95, alpha: 1)
    }

    // MARK: - Hit testing and input

    func node(at point: NSPoint) -> Int? {
        let depth = Int(point.y / Self.rowHeight)
        guard depth >= 0, depth < rows.count else { return nil }
        let row = rows[depth]
        var low = 0
        var high = row.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let box = row[middle]
            if point.x < box.x { high = middle - 1 } else if point.x > box.x + box.width { low = middle + 1 } else { return box.node }
        }
        return nil
    }

    private func method(of node: Int) -> Int32? {
        let frame = tree.frame(of: node)
        return frame >= 0 ? symbols.frame(frame).method : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let node = node(at: convert(event.locationInWindow, from: nil))
        guard node != hoveredNode else { return }
        hoveredNode = node
        toolTip = node.map(tooltip(for:))
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredNode = nil
        toolTip = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let node = node(at: convert(event.locationInWindow, from: nil)) else {
            onSelectMethod?(nil)
            return
        }
        if event.clickCount >= 2 {
            if tree.frame(of: node) >= 0 { onZoom?(node) }
            return
        }
        onSelectMethod?(method(of: node))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let node = node(at: convert(event.locationInWindow, from: nil)), tree.frame(of: node) >= 0 else { return }
        onSelectMethod?(method(of: node))
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Source", action: #selector(openSourceFromMenu(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = node
        menu.addItem(open)
        let zoom = NSMenuItem(title: "Zoom Into Frame", action: #selector(zoomFromMenu(_:)), keyEquivalent: "")
        zoom.target = self
        zoom.representedObject = node
        menu.addItem(zoom)
        if rootNode != JavaProfileTree.root {
            let out = NSMenuItem(title: "Zoom Out", action: #selector(zoomOutFromMenu), keyEquivalent: "")
            out.target = self
            menu.addItem(out)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func openSourceFromMenu(_ item: NSMenuItem) {
        guard let node = item.representedObject as? Int, let method = method(of: node) else { return }
        onOpenSource?(method, Int(symbols.frame(tree.frame(of: node)).line))
    }

    @objc private func zoomFromMenu(_ item: NSMenuItem) {
        if let node = item.representedObject as? Int { onZoom?(node) }
    }

    @objc private func zoomOutFromMenu() {
        onZoomOut?()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onZoomOut?()                      // Esc
        case 36, 76:                                // Return
            if let method = selectedMethod { onOpenSource?(method, 0) }
        default: super.keyDown(with: event)
        }
    }

    private func tooltip(for node: Int) -> String {
        let frame = tree.frame(of: node)
        if frame == JavaProfileTree.otherFrame {
            return "(other)\nSamples that did not fit the node limit."
        }
        guard frame >= 0 else { return "All samples" }
        let method = symbols.method(ofFrame: frame)
        let total = tree.totalCount(of: node)
        let own = tree.selfCount(of: node)
        let rootTotal = max(tree.totalSamples, 1)
        let line = symbols.frame(frame).line
        var text = (method.className.isEmpty ? "" : method.className + ".") + method.name + "(" + method.parameters + ")"
        if line > 0 { text += " line \(line)" }
        text += "\ntotal \(total.formatted()) (\(String(format: "%.1f", Double(total) * 100 / Double(rootTotal)))%)"
        text += " · self \(own.formatted()) (\(String(format: "%.1f", Double(own) * 100 / Double(rootTotal)))%)"
        return text
    }

    // MARK: - Testing

    var boxCountForTesting: Int { rows.reduce(0) { $0 + $1.count } }
    var rowCountForTesting: Int { rows.count }
}

/// The flame graph in a scroll view, driven by a profiler session.
struct IDEFlameGraphView: NSViewRepresentable {
    let session: IDEProfilerSession

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var graph: IDEFlameGraphNSView?
    }

    func makeNSView(context: Context) -> NSScrollView {
        let graph = IDEFlameGraphNSView()
        graph.autoresizingMask = [.width]
        context.coordinator.graph = graph
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.documentView = graph
        graph.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let graph = context.coordinator.graph, let tree = session.tree, let symbols = session.symbols else { return }
        graph.onSelectMethod = { [weak session] in session?.selectedMethod = $0 }
        graph.onZoom = { [weak session] in session?.zoom(into: $0) }
        graph.onZoomOut = { [weak session] in session?.zoomOut() }
        graph.onOpenSource = { [weak session] method, line in session?.openSource(ofMethod: method, line: line) }
        let query = session.searchText.trimmingCharacters(in: .whitespaces).lowercased()
        var matches = Set<Int32>()
        if !query.isEmpty {
            for (index, _) in symbols.methods.enumerated() where symbols.qualifiedName(ofMethod: Int32(index)).lowercased().contains(query) {
                matches.insert(Int32(index))
            }
        }
        let root = session.zoomStack.last ?? JavaProfileTree.root
        graph.update(tree: tree, symbols: symbols, rootNode: min(root, max(tree.nodeCount - 1, 0)), highlighted: matches, selected: session.selectedMethod)
        if abs(graph.frame.width - scroll.contentSize.width) > 0.5 {
            graph.setFrameSize(NSSize(width: scroll.contentSize.width, height: graph.frame.height))
        }
        graph.needsLayout = true
    }
}
