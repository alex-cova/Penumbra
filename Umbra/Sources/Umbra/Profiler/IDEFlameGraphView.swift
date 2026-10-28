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
    /// The session's `treeRevision`: a tree of the same size with other counts still needs a layout.
    private var revision = 0

    /// The match of the search the user stepped to; drawn with a heavier outline and scrolled to.
    private(set) var focusedNode: Int?
    /// Fraction of the root's samples under which a box is faded; 0 is off.
    private(set) var thresholdFraction: Double = 0
    /// How a method is coloured; unset, a package hash (previews and tests).
    var originProvider: ((Int32) -> IDEProfilerSession.FrameOrigin)?

    var onSelectMethod: ((Int32?) -> Void)?
    var onZoom: ((Int) -> Void)?
    var onZoomOut: (() -> Void)?
    /// Class (a binary name), line and recorded source path of the frame to open.
    var onOpenSource: ((String, Int, String?) -> Void)?
    /// A fill that replaces the frame's colour (a differential graph's red and green).
    var nodeTint: ((Int) -> NSColor?)?
    /// A line added to a box's tooltip.
    var extraTooltip: ((Int) -> String?)?
    /// The "what if" items of the context menu, by node.
    var onFocusSubtree: ((Int) -> Void)?
    var onFocusCall: ((Int) -> Void)?
    var onExcludeSubtree: ((Int) -> Void)?
    var onExcludeCalls: ((Int) -> Void)?
    /// A class or package name to leave out of the graph (not a node: it works on a differential graph too).
    var onHideClass: ((String) -> Void)?

    private var rows: [[Box]] = []
    private var pendingReveal: Int?
    private var layoutWidth: CGFloat = 0
    private var hoveredNode: Int?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func update(
        tree: JavaProfileTree, symbols: JavaProfileSymbols, rootNode: Int,
        highlighted: Set<Int32>, selected: Int32?, revision: Int = 0,
        focusedNode: Int? = nil, thresholdFraction: Double = 0
    ) {
        let relayout = self.tree.nodeCount != tree.nodeCount || self.tree.totalSamples != tree.totalSamples
            || self.rootNode != rootNode || self.revision != revision
        self.revision = revision
        self.tree = tree
        self.symbols = symbols
        self.rootNode = rootNode
        highlightedMethods = highlighted
        selectedMethod = selected
        let focusChanged = self.focusedNode != focusedNode
        self.focusedNode = focusedNode
        self.thresholdFraction = thresholdFraction
        if relayout { rows = []; layoutWidth = 0 }
        if focusChanged, let focusedNode { pendingReveal = focusedNode }
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        if abs(bounds.width - layoutWidth) > 0.5 || rows.isEmpty { rebuildLayout() }
        if let node = pendingReveal {
            pendingReveal = nil
            reveal(node: node)
        }
    }

    /// Scrolls so the box of `node` is on screen; a box too thin to have been laid out stays put.
    func reveal(node: Int) {
        for row in rows {
            if let box = row.first(where: { $0.node == node }) {
                let rect = NSRect(x: box.x, y: CGFloat(box.depth) * Self.rowHeight, width: max(box.width, 1), height: Self.rowHeight)
                scrollToVisible(rect.insetBy(dx: 0, dy: -Self.rowHeight * 2))
                return
            }
        }
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
        let rootTotal = max(tree.totalCount(of: rootNode), 1)
        let thresholdCount = thresholdFraction > 0 ? Int(Double(rootTotal) * thresholdFraction) : 0
        for depth in firstRow...lastRow {
            let y = CGFloat(depth) * Self.rowHeight
            for box in rows[depth] where box.x + box.width >= dirtyRect.minX && box.x <= dirtyRect.maxX {
                let frame = tree.frame(of: box.node)
                let method: Int32? = frame >= 0 ? symbols.frame(frame).method : nil
                let rect = NSRect(x: box.x, y: y, width: max(box.width - 0.5, 0.5), height: Self.rowHeight - 1)
                var color = nodeTint?(box.node) ?? fill(for: method, frame: frame)
                let matches = method.map { highlightedMethods.contains($0) } ?? false
                if dimmed, !matches { color = color.blended(withFraction: 0.65, of: .textBackgroundColor) ?? color }
                if thresholdCount > 0, tree.totalCount(of: box.node) < thresholdCount {
                    color = color.blended(withFraction: 0.75, of: .textBackgroundColor) ?? color
                }
                color.setFill()
                rect.fill()
                if box.node == focusedNode {
                    NSColor.controlAccentColor.setStroke()
                    let path = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
                    path.lineWidth = 2.5
                    path.stroke()
                } else if method != nil, method == selectedMethod || box.node == hoveredNode {
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

    /// Red where the target's share grew, green where it shrank (-1...1, by how much of the larger
    /// side the difference is); neutral grey when it did not move.
    static func diffColor(change: Double) -> NSColor {
        let neutral = NSColor(calibratedWhite: 0.58, alpha: 1)
        let magnitude = abs(change)
        guard magnitude >= 0.03 else { return neutral }
        let hot = change > 0
            ? NSColor(calibratedRed: 0.90, green: 0.27, blue: 0.24, alpha: 1)
            : NSColor(calibratedRed: 0.22, green: 0.70, blue: 0.36, alpha: 1)
        return neutral.blended(withFraction: min(1, 0.3 + 0.7 * magnitude), of: hot) ?? hot
    }

    private func fill(for method: Int32?, frame: Int32) -> NSColor {
        if frame == JavaProfileTree.otherFrame { return NSColor.systemGray.withAlphaComponent(0.5) }
        guard let method else { return NSColor.systemGray.withAlphaComponent(0.3) }
        guard let originProvider else { return Self.color(for: method, symbols: symbols, isOther: false) }
        return Self.color(for: originProvider(method))
    }

    /// Project code yellow, libraries purple (grey in the dark theme), the JDK blue-grey, markers
    /// (allocations, waits) a muted green.
    static func color(for origin: IDEProfilerSession.FrameOrigin) -> NSColor {
        switch origin {
        case .project:
            return NSColor(calibratedRed: 0.99, green: 0.83, blue: 0.33, alpha: 1)
        case .library:
            return NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(calibratedWhite: 0.62, alpha: 1)
                    : NSColor(calibratedRed: 0.76, green: 0.66, blue: 0.93, alpha: 1)
            }
        case .jdk:
            return NSColor(calibratedRed: 0.62, green: 0.76, blue: 0.95, alpha: 1)
        case .marker:
            return NSColor(calibratedRed: 0.62, green: 0.84, blue: 0.70, alpha: 1)
        }
    }

    /// The whole graph as a PNG, rows beyond the visible ones included.
    func pngData() -> Data? {
        let area = NSRect(x: 0, y: 0, width: bounds.width, height: max(CGFloat(rows.count) * Self.rowHeight + 8, 1))
        guard let rep = bitmapImageRepForCachingDisplay(in: area) else { return nil }
        // `draw` only paints the dirty rect, so draw the whole area, not the scrolled window.
        cacheDisplay(in: area, to: rep)
        return rep.representation(using: .png, properties: [:])
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
        menu.addItem(.separator())
        for (title, selector) in [
            ("Focus on Subtree", #selector(focusSubtreeFromMenu(_:))),
            ("Focus on Call", #selector(focusCallFromMenu(_:))),
            ("Exclude Subtree", #selector(excludeSubtreeFromMenu(_:))),
            ("Exclude Call", #selector(excludeCallsFromMenu(_:)))
        ] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.representedObject = node
            menu.addItem(item)
        }
        let className = symbols.method(ofFrame: tree.frame(of: node)).className
        if onHideClass != nil, !className.isEmpty {
            menu.addItem(.separator())
            let simple = className.split(whereSeparator: { $0 == "." || $0 == "$" }).last.map(String.init) ?? className
            let hide = NSMenuItem(title: "Hide Class \(simple)", action: #selector(hideClassFromMenu(_:)), keyEquivalent: "")
            hide.target = self
            hide.representedObject = className
            menu.addItem(hide)
            if let dot = className.lastIndex(of: ".") {
                let package = String(className[..<dot])
                let hidePackage = NSMenuItem(title: "Hide Package \(package)", action: #selector(hideClassFromMenu(_:)), keyEquivalent: "")
                hidePackage.target = self
                hidePackage.representedObject = package
                menu.addItem(hidePackage)
            }
        }
        menu.addItem(.separator())
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
        let frame = tree.frame(of: node)
        onOpenSource?(symbols.methods[Int(method)].className, Int(symbols.frame(frame).line), symbols.sourcePath(ofFrame: frame))
    }

    @objc private func hideClassFromMenu(_ item: NSMenuItem) {
        if let name = item.representedObject as? String { onHideClass?(name) }
    }

    @objc private func focusSubtreeFromMenu(_ item: NSMenuItem) {
        if let node = item.representedObject as? Int { onFocusSubtree?(node) }
    }

    @objc private func focusCallFromMenu(_ item: NSMenuItem) {
        if let node = item.representedObject as? Int { onFocusCall?(node) }
    }

    @objc private func excludeSubtreeFromMenu(_ item: NSMenuItem) {
        if let node = item.representedObject as? Int { onExcludeSubtree?(node) }
    }

    @objc private func excludeCallsFromMenu(_ item: NSMenuItem) {
        if let node = item.representedObject as? Int { onExcludeCalls?(node) }
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
            if let method = selectedMethod {
                onOpenSource?(symbols.methods[Int(method)].className, 0, symbols.sourcePath(ofMethod: method))
            }
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
        text += "\ntotal \(total.formatted()) (\(String(format: "%.1f", Double(total) * 100 / Double(rootTotal)))% of all"
        if let parent = tree.parent(of: node), parent != JavaProfileTree.root {
            let parentTotal = max(tree.totalCount(of: parent), 1)
            text += ", \(String(format: "%.1f", Double(total) * 100 / Double(parentTotal)))% of its caller"
        }
        text += ")"
        text += " · self \(own.formatted()) (\(String(format: "%.1f", Double(own) * 100 / Double(rootTotal)))%)"
        if let extra = extraTooltip?(node) { text += "\n" + extra }
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
        guard let graph = context.coordinator.graph, var tree = session.tree, var symbols = session.symbols else { return }
        let comparison = session.comparison
        if let comparison {
            tree = comparison.tree
            symbols = comparison.symbols
        }
        graph.nodeTint = comparison.map { comparison in
            { node in IDEFlameGraphNSView.diffColor(change: comparison.change(ofNode: node)) }
        }
        graph.extraTooltip = comparison.map { comparison in
            { node in
                guard node > 0 else { return nil }
                let before = comparison.baselineShare(ofNode: node) * 100
                let after = comparison.targetShare(ofNode: node) * 100
                return String(
                    format: "baseline %.1f%% (%@) → now %.1f%% (%@)",
                    before, comparison.baselineCounts[node].formatted(), after, comparison.targetCounts[node].formatted()
                )
            }
        }
        graph.onSelectMethod = { [weak session] in if !(session?.isComparing ?? false) { session?.selectedMethod = $0 } }
        graph.onZoom = { [weak session] in session?.zoom(into: $0) }
        graph.onZoomOut = { [weak session] in session?.zoomOut() }
        graph.onOpenSource = { [weak session] className, line, sourcePath in
            guard !className.isEmpty else { return }
            session?.openFrame?(className, line, sourcePath)
        }
        // The "what if"s name nodes of the profile's own tree, which a merged tree is not.
        let whatIf = comparison == nil
        graph.onFocusSubtree = whatIf ? { [weak session] in session?.focusOnSubtree(node: $0) } : nil
        graph.onFocusCall = whatIf ? { [weak session] in session?.focusOnCall(node: $0) } : nil
        graph.onExcludeSubtree = whatIf ? { [weak session] in session?.excludeSubtree(node: $0) } : nil
        graph.onExcludeCalls = whatIf ? { [weak session] in session?.excludeCalls(node: $0) } : nil
        graph.onHideClass = { [weak session] name in
            guard let pattern = JavaClassPattern(name) else { return }
            session?.addClassFilter(.pattern(pattern))
        }
        graph.originProvider = { [weak session] method in
            comparison != nil ? .library : (session?.origin(ofMethod: method) ?? .library)
        }
        session.flameGraphView = graph
        var matches = Set<Int32>()
        for node in comparison == nil ? session.searchMatches : [] {
            let frame = tree.frame(of: node)
            if frame >= 0 { matches.insert(symbols.frame(frame).method) }
        }
        let root = session.zoomStack.last ?? JavaProfileTree.root
        graph.update(tree: tree, symbols: symbols, rootNode: min(root, max(tree.nodeCount - 1, 0)), highlighted: matches, selected: comparison == nil ? session.selectedMethod : nil,
                     revision: session.treeRevision, focusedNode: comparison == nil ? session.focusedMatch : nil,
                     thresholdFraction: session.nodeThresholdPercent / 100)
        if abs(graph.frame.width - scroll.contentSize.width) > 0.5 {
            graph.setFrameSize(NSSize(width: scroll.contentSize.width, height: graph.frame.height))
        }
        graph.needsLayout = true
    }
}
