import Foundation

private let _whitespaceRegex: NSRegularExpression = {
    guard let r = try? NSRegularExpression(pattern: "\\s") else {
        assertionFailure("Invalid regex")
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: ".")
    }
    return r
}()

private let _nonAlphanumericRegex: NSRegularExpression = {
    guard let r = try? NSRegularExpression(pattern: "[^a-zA-Z0-9_]") else {
        assertionFailure("Invalid regex")
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: ".")
    }
    return r
}()

// MARK: - Constants

/**
 * Utility methods for layout-related things.
 */
package final class ElkUtil {
    
    /**
     * Default minimal width for nodes.
     */
    package static let DEFAULT_MIN_WIDTH: Double = 20.0
    
    /**
     * Default minimal height for nodes.
     */
    package static let DEFAULT_MIN_HEIGHT: Double = 20.0
    
    /**
     * Hidden constructor to avoid instantiation.
     */
    private init() {}
    
    // MARK: - Port Side Calculation
    
    /**
     * Determines the port side for the given port from its relative position at
     * its corresponding node.
     *
     * @param port port to analyze
     * @param direction the overall layout direction
     * @return the port side relative to its containing node
     * @throws IllegalStateException if the port does not have a parent node.
     */
    package static func calcPortSide(_ port: ElkPort, direction: Direction) -> PortSide {
        guard let node = port.parent else {
            assertionFailure("port must have a parent node to calculate the port side")
            return .undefined
        }

        let nodeWidth = node.width
        let nodeHeight = node.height
        
        if nodeWidth <= 0 && nodeHeight <= 0 {
            return .undefined
        }
        
        let xpos = port.x
        let ypos = port.y
        
        switch direction {
        case .LEFT, .RIGHT:
            if xpos < 0 {
                return .west
            } else if xpos + port.width > nodeWidth {
                return .east
            }
        case .UP, .DOWN:
            if ypos < 0 {
                return .north
            } else if ypos + port.height > nodeHeight {
                return .south
            }
        default:
            break
        }
        
        let widthPercent = (xpos + port.width / 2) / nodeWidth
        let heightPercent = (ypos + port.height / 2) / nodeHeight
        
        if widthPercent + heightPercent <= 1 && widthPercent - heightPercent <= 0 {
            return .west
        } else if widthPercent + heightPercent >= 1 && widthPercent - heightPercent >= 0 {
            return .east
        } else if heightPercent < 0.5 {
            return .north
        } else {
            return .south
        }
    }
    
    /**
     * Calculate the offset for a port, that is the amount by which it is moved outside of the node.
     * An offset value of 0 means the port has no intersection with the node and touches the outside
     * border of the node.
     *
     * @param port a port
     * @param side the side on the node for the given port
     * @return the offset on the side
     * @throws IllegalStateException if the port does not have a parent node.
     */
    package static func calcPortOffset(_ port: ElkPort, side: PortSide) -> Double {
        guard let node = port.parent else {
            assertionFailure("port must have a parent node to calculate the port offset")
            return 0
        }

        switch side {
        case .north:
            return Double(-(port.y + port.height))
        case .east:
            return Double(port.x - node.width)
        case .south:
            return Double(port.y - node.height)
        case .west:
            return Double(-(port.x + port.width))
        case .undefined:
            return 0
        default:
            return 0
        }
    }
    
    // MARK: - Node Resizing
    
    /**
     * Sets the size of a given node, depending on the minimal size, the number of ports
     * on each side and the label.
     *
     * @param node the node that shall be resized
     * @return a vector holding the width and height resizing ratio, or {@code null} if the size
     *     constraint is set to {@code FIXED}
     */
    @discardableResult
    package static func resizeNode(_ node: ElkNode) -> KVector? {
        let sizeConstraint: SizeConstraint = node.getProperty(CoreOptions.NODE_SIZE_CONSTRAINTS) ?? []
        
        if sizeConstraint.isEmpty {
            return nil
        }
        
        var newWidth: Double = 0
        var newHeight: Double = 0
        
        if sizeConstraint.contains(.ports) {
            let portConstraints: PortConstraints = node.getProperty(CoreOptions.PORT_CONSTRAINTS) ?? .undefined
            var minNorth: Double = 2
            var minEast: Double = 2
            var minSouth: Double = 2
            var minWest: Double = 2
            
            let direction: Direction
            if let parent = node.parent {
                direction = parent.getProperty(CoreOptions.DIRECTION) ?? .undefined
            } else {
                direction = node.getProperty(CoreOptions.DIRECTION) ?? .undefined
            }
            
            for port in node.ports {
                var portSide: PortSide = port.getProperty(CoreOptions.PORT_SIDE) ?? .undefined
                
                if portSide == .undefined {
                    portSide = calcPortSide(port, direction: direction)
                    port.setProperty(CoreOptions.PORT_SIDE, portSide)
                }
                
                if portConstraints == .fixedPos {
                    switch portSide {
                    case .north:
                        minNorth = max(minNorth, port.x + port.width)
                    case .east:
                        minEast = max(minEast, port.y + port.height)
                    case .south:
                        minSouth = max(minSouth, port.x + port.width)
                    case .west:
                        minWest = max(minWest, port.y + port.height)
                    default:
                        break
                    }
                } else {
                    switch portSide {
                    case .north:
                        minNorth += port.width + 2
                    case .east:
                        minEast += port.height + 2
                    case .south:
                        minSouth += port.width + 2
                    case .west:
                        minWest += port.height + 2
                    default:
                        break
                    }
                }
            }
            
            newWidth = max(minNorth, minSouth)
            newHeight = max(minEast, minWest)
        }
        
        return resizeNode(node, newWidth: newWidth, newHeight: newHeight, movePorts: true, moveLabels: true)
    }
    
    /**
     * Resize a node to the given width and height, adjusting port and label positions if needed.
     *
     * @param node a node
     * @param newWidth the new width to set
     * @param newHeight the new height to set
     * @param movePorts whether port positions should be adjusted
     * @param moveLabels whether label positions should be adjusted
     * @return a vector holding the width and height resizing ratio
     */
    @discardableResult
    package static func resizeNode(_ node: ElkNode, newWidth: Double, newHeight: Double, movePorts: Bool, moveLabels: Bool) -> KVector {
        let oldSize = KVector(node.width, node.height)
        
        var newSize = effectiveMinSizeConstraintFor(node)
        newSize.x = max(newSize.x, newWidth)
        newSize.y = max(newSize.y, newHeight)
        
        let widthRatio = newSize.x / oldSize.x
        let heightRatio = newSize.y / oldSize.y
        let widthDiff = newSize.x - oldSize.x
        let heightDiff = newSize.y - oldSize.y
        
        // update port positions
        if movePorts {
            let direction: Direction
            if let parent = node.parent {
                direction = parent.getProperty(CoreOptions.DIRECTION) ?? .undefined
            } else {
                direction = node.getProperty(CoreOptions.DIRECTION) ?? .undefined
            }
            let fixedPorts: Bool = (node.getProperty(CoreOptions.PORT_CONSTRAINTS) as PortConstraints?) == .fixedPos
            
            for port in node.ports {
                var portSide: PortSide = port.getProperty(CoreOptions.PORT_SIDE) ?? .undefined
                
                if portSide == .undefined {
                    portSide = calcPortSide(port, direction: direction)
                    port.setProperty(CoreOptions.PORT_SIDE, portSide)
                }
                
                switch portSide {
                case .north:
                    if !fixedPorts {
                        port.x = port.x * widthRatio
                    }
                case .east:
                    port.x = port.x + widthDiff
                    if !fixedPorts {
                        port.y = port.y * heightRatio
                    }
                case .south:
                    if !fixedPorts {
                        port.x = port.x * widthRatio
                    }
                    port.y = port.y + heightDiff
                case .west:
                    if !fixedPorts {
                        port.y = port.y * heightRatio
                    }
                default:
                    break
                }
            }
        }
        
        // resize the node AFTER ports have been placed, since calcPortSide needs the old size
        node.setDimensions(width: newSize.x, height: newSize.y)
        
        // update label positions
        if moveLabels {
            for label in node.labels {
                let midx = label.x + label.width / 2
                let midy = label.y + label.height / 2
                let widthPercent = midx / oldSize.x
                let heightPercent = midy / oldSize.y
                
                if widthPercent + heightPercent >= 1 {
                    if widthPercent - heightPercent > 0 && midy >= 0 {
                        // label is on the right
                        label.x = label.x + widthDiff
                        label.y = label.y + heightDiff * heightPercent
                    } else if widthPercent - heightPercent < 0 && midx >= 0 {
                        // label is on the bottom
                        label.x = label.x + widthDiff * widthPercent
                        label.y = label.y + heightDiff
                    }
                }
            }
        }
        
        // set fixed size option for the node: now the size is assumed to stay as determined here
        node.setProperty(CoreOptions.NODE_SIZE_CONSTRAINTS, SizeConstraint([]) as Any)
        
        return KVector(widthRatio, heightRatio)
    }
    
    /**
     * Returns the minimum size of the node according to the {@link CoreOptions#NODE_SIZE_MINIMUM} constraint. If that
     * constraint is not set, the size returned by this method will be {@code (0, 0)}.
     * 
     * @param node the node whose minimum size to compute.
     * @return the minimum size.
     */
    package static func effectiveMinSizeConstraintFor(_ node: ElkNode) -> KVector {
        let sizeConstraint: SizeConstraint = node.getProperty(CoreOptions.NODE_SIZE_CONSTRAINTS) ?? []

        if sizeConstraint.contains(.minimumSize) {
            let sizeOptions: SizeOptions = node.getProperty(CoreOptions.NODE_SIZE_OPTIONS) ?? []
            let minSizeVec: KVector = node.getProperty(CoreOptions.NODE_SIZE_MINIMUM) ?? KVector()
            var minSize = KVector(minSizeVec.x, minSizeVec.y)

            // If minimum width or height are not set, maybe default to default values
            if sizeOptions.contains(.defaultMinimumSize) {
                if minSize.x <= 0 {
                    minSize.x = DEFAULT_MIN_WIDTH
                }
                if minSize.y <= 0 {
                    minSize.y = DEFAULT_MIN_HEIGHT
                }
            }
            
            return minSize
        } else {
            return KVector()
        }
    }
    
    /**
     * Applies the scaling factor configured in terms of {@link CoreOptions#SCALE_FACTOR} to {@code node}'s
     * size data, and updates the layout data of {@code node}'s ports and labels accordingly.<br>
     * <b>Note:</b> The scaled layout data won't be reverted during the layout process, see
     * {@link CoreOptions#SCALE_FACTOR}.
     *
     * @param node
     *            the node to be scaled
     */
    package static func applyConfiguredNodeScaling(_ node: ElkNode) {
        let scalingFactor: Double = node.getProperty(CoreOptions.SCALE_FACTOR) ?? 1.0
        if scalingFactor == 1 {
            return
        }
        
        node.setDimensions(width: scalingFactor * node.width, height: scalingFactor * node.height)
        
        // Process port labels
        for port in node.ports {
            for label in port.labels {
                label.setLocation(x: scalingFactor * label.x, y: scalingFactor * label.y)
                label.setDimensions(width: scalingFactor * label.width, height: scalingFactor * label.height)
                
                if let anchor: KVector = label.getProperty(CoreOptions.PORT_ANCHOR) {
                    anchor.x *= scalingFactor
                    anchor.y *= scalingFactor
                }
            }
        }
        
        // Process node labels and ports
        for shape in (node.labels as [ElkShape]) + (node.ports as [ElkShape]) {
            shape.setLocation(x: scalingFactor * shape.x, y: scalingFactor * shape.y)
            shape.setDimensions(width: scalingFactor * shape.width, height: scalingFactor * shape.height)
            
            if let anchor: KVector = shape.getProperty(CoreOptions.PORT_ANCHOR) {
                anchor.x *= scalingFactor
                anchor.y *= scalingFactor
            }
        }
    }
    
    // MARK: - Child Area Dimensions
    
    /**
     * Computes the area occupied by this node's layout and stores the values in {@link CoreOptions#CHILD_AREA_WIDTH} 
     * and {@link CoreOptions#CHILD_AREA_HEIGHT}.
     * @param node the node whose child area should be computed
     */
    package static func computeChildAreaDimensions(_ node: ElkNode) {
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX: Double = 0.0
        var maxY: Double = 0.0
        
        // Collect edge labels
        var edgeLabels: [ElkLabel] = []
        for edge in node.containedEdges {
            edgeLabels.append(contentsOf: edge.labels)
        }
        
        // Iterate over all shapes
        let allShapes: [ElkShape] = (node.labels as [ElkShape]) + (node.children as [ElkShape]) + (edgeLabels as [ElkShape])
        for shape in allShapes {
            let margins: ElkMargin = shape.getProperty(CoreOptions.MARGINS) ?? ElkMargin()
            
            if minX > shape.x - margins.left {
                minX = shape.x - margins.left
            }
            if minY > shape.y - margins.top {
                minY = shape.y - margins.top
            }
            if maxX < shape.x + shape.width + margins.right {
                maxX = shape.x + shape.width + margins.right
            }
            if maxY < shape.y + shape.height + margins.bottom {
                maxY = shape.y + shape.height + margins.bottom
            }
        }
        
        // Iterate over all contained edges and check their bounds
        for edge in node.containedEdges {
            for section in edge.sections {
                let sX = section.startX
                let eX = section.endX
                let sY = section.startY
                let eY = section.endY
                
                minX = min(minX, sX)
                minX = min(minX, eX)
                maxX = max(maxX, sX)
                maxX = max(maxX, eX)
                minY = min(minY, sY)
                minY = min(minY, eY)
                maxY = max(maxY, sY)
                maxY = max(maxY, eY)
                
                for bendpoint in section.bendPoints {
                    minX = min(minX, bendpoint.x)
                    maxX = max(maxX, bendpoint.x)
                    minY = min(minY, bendpoint.y)
                    maxY = max(maxY, bendpoint.y)
                }
            }
        }
        
        // max and min value represent outermost bounds of the layout
        node.setProperty(CoreOptions.CHILD_AREA_WIDTH, maxX - minX)
        node.setProperty(CoreOptions.CHILD_AREA_HEIGHT, maxY - minY)
    }
    
    // MARK: - Junction Points
    
    /**
     * Determine the junction points of the given edge. This is done by comparing the bend points
     * of the given edge with the bend points of all other edges that are connected to the same
     * source port or the same target port. Note that this method requires all edges to have exactly one
     * edge section.
     * 
     * @param edge an edge
     * @return a list of junction points
     * @throws IllegalArgumentException if the edge has no or more than one edge section.
     */
    package static func determineJunctionPoints(_ edge: ElkEdge) -> KVectorChain {
        guard edge.sections.count == 1 else {
            assertionFailure("The edge needs to have exactly one edge section. Found: \(edge.sections.count)")
            return KVectorChain()
        }

        var junctionPoints = KVectorChain()

        if let sourcePort = ElkGraphUtil.connectableShapeToPort(edge.sources[0]) {
            junctionPoints.addAll(other: determineJunctionPoints(edge, sourcePort, false))
        }
        if let targetPort = ElkGraphUtil.connectableShapeToPort(edge.targets[0]) {
            junctionPoints.addAll(other: determineJunctionPoints(edge, targetPort, true))
        }
        
        return junctionPoints
    }
    
    /**
     * Determine the junction points of the given edge with any edge connected to the given port.
     * This is done by comparing the bend points of the given edge with the bend points of all other edges
     * that are connected to the given port. Note that this method requires all edges to have exactly one
     * edge section.
     * 
     * @param edge an edge
     * @param port one of the ports the edge is connected to
     * @param reverse flag to indicate whether the points are traversed forward or reverse
     * @return a list of junction points
     * @throws IllegalArgumentException if a connected edge has no or more than one edge section.
     */
    package static func determineJunctionPoints(_ edge: ElkEdge, _ port: ElkPort, _ reverse: Bool) -> KVectorChain {
        // Ensure exactly one section
        assert(edge.sections.count == 1)
        
        // Grab the edge section
        let section = edge.sections[0]
        
        // Collection for the junction points of the current edge
        var junctionPoints = KVectorChain()
        
        // Store the points of the edge in a map for efficiency
        var pointsMap: [ObjectIdentifier: [KVector]] = [:]
        let sectionPoints = getPoints(section)
        pointsMap[ObjectIdentifier(section)] = sectionPoints
        
        // Store the offset of the other edges
        var offsetMap: [ObjectIdentifier: KVector] = [:]
        
        // let allConnectedEdges be the set of edge sections connected to port without the main edge
        var allConnectedSections: [ElkEdgeSection] = []
        
        for otherEdge in ElkGraphUtil.allIncidentEdges(port) {
            guard otherEdge.sections.count == 1 else {
                assertionFailure("The edge needs to have exactly one edge section. Found: \(otherEdge.sections.count)")
                continue
            }
            
            if otherEdge !== edge {
                let otherSection = otherEdge.sections[0]
                allConnectedSections.append(otherSection)
                
                // Edges might have different containments leading to different coordinate systems
                // We can calculate the offset between the edges by comparing the shared port
                let otherPoints: [KVector]
                if let cached = pointsMap[ObjectIdentifier(otherSection)] {
                    otherPoints = cached
                } else {
                    let computed = getPoints(otherSection)
                    pointsMap[ObjectIdentifier(otherSection)] = computed
                    otherPoints = computed
                }

                let offset: KVector
                if reverse {
                    offset = KVector(sectionPoints[sectionPoints.count - 1]).sub(KVector(otherPoints[otherPoints.count - 1]))
                } else {
                    offset = KVector(sectionPoints[0]).sub(KVector(otherPoints[0]))
                }
                
                offsetMap[ObjectIdentifier(otherSection)] = offset
            }
        }
        
        if !allConnectedSections.isEmpty {
            // let p1 be the start point
            let p1Index = reverse ? sectionPoints.count - 1 : 0
            var p1 = sectionPoints[p1Index]
            
            // for all bend points of this connection
            for i in 1..<sectionPoints.count {
                // let p2 be the next bend point on this connection
                let p2Index = reverse ? sectionPoints.count - 1 - i : i
                let p2 = sectionPoints[p2Index]
                
                // for all other connections that are still on the same track as this one
                var allSectIter = allConnectedSections.makeIterator()
                while let otherSection = allSectIter.next() {
                    guard let otherPoints = pointsMap[ObjectIdentifier(otherSection)] else { continue }
                    
                    if otherPoints.count <= i {
                        allConnectedSections.removeAll(where: { $0 === otherSection })
                        continue
                    } else {
                        // let p3 be the next bend point of the other connection
                        let otherPointIndex = reverse ? otherPoints.count - 1 - i : i
                        let sectionOffset = offsetMap[ObjectIdentifier(otherSection)] ?? KVector()
                        let p3 = KVector(otherPoints[otherPointIndex]).add(sectionOffset)
                        
                        if p2.x != p3.x || p2.y != p3.y {
                            // the next point of this and the other connection differ
                            let dx2 = p2.x - p1.x
                            let dy2 = p2.y - p1.y
                            let dx3 = p3.x - p1.x
                            let dy3 = p3.y - p1.y
                            
                            if (dx3 * dy2) == (dy3 * dx2) && (dx2.sign == dx3.sign) && (dy2.sign == dy3.sign) {
                                // the points p1, p2, p3 form a straight line,
                                // now check whether p2 is between p1 and p3
                                if abs(dx2) < abs(dx3) || abs(dy2) < abs(dy3) {
                                    junctionPoints.add(p2)
                                }
                            } else if i > 1 {
                                // p2 and p3 have diverged, so the last common point is p1
                                junctionPoints.add(p1)
                            }
                            
                            // do not consider the other connection in the next iterations
                            allConnectedSections.removeAll(where: { $0 === otherSection })
                        }
                    }
                }
                // for the next iteration p2 is taken as reference point
                p1 = p2
            }
        }
        
        return junctionPoints
    }
    
    /**
     * Get the edge section points as an array of vectors. 
     * Unnecessary bend points are filtered out automatically. 
     * 
     * @param section an edge section
     * @return an array with all needed edge section points
     */
    package static func getPoints(_ section: ElkEdgeSection) -> [KVector] {
        let n = section.bendPoints.count + 2
        var points: [KVector] = []
        
        // Source point
        points.append(KVector(section.startX, section.startY))
        
        // Bend points
        for bendPoint in section.bendPoints {
            points.append(KVector(bendPoint.x, bendPoint.y))
        }
        
        // Target point
        points.append(KVector(section.endX, section.endY))
        
        // Filter unnecessary bend points from the list
        var i = 1
        while i < points.count - 1 {
            // Unnecessary bend points are given if three points in a row have the same x or y coordinate
            let p1 = points[i - 1]
            let p2 = points[i]
            let p3 = points[i + 1]
            
            if (p1.x == p2.x && p2.x == p3.x) || (p1.y == p2.y && p2.y == p3.y) {
                // Found a straight segment, drop p2 and re-check with the same i
                points.remove(at: i)
            } else {
                // Points are not a straight line, advance
                i += 1
            }
        }
        
        return points
    }
    
    // MARK: - Coordinate Translation
    
    /**
     * Translates the contents of the given node by an offset.
     *
     * @param parent parent node whose children shall be translated
     * @param xoffset x coordinate offset
     * @param yoffset y coordinate offset
     */
    package static func translate(_ parent: ElkNode, xoffset: Double, yoffset: Double) {
        for child in parent.children {
            // Translate node position
            child.setLocation(x: child.x + xoffset, y: child.y + yoffset)
        }
        
        // Translates all edges contained in the parent. This includes edges connecting the parent to its
        // children. For these edges the start or end point might get separated from the node boundary.
        for edge in parent.containedEdges {
            translate(edge, xoffset: xoffset, yoffset: yoffset)
        }
    }
    
    /**
     * Translates the given edge by an offset. This includes all routing information, junction points (if any), and
     * edge labels.
     *
     * @param edge edge that shall be translated
     * @param xoffset x coordinate offset
     * @param yoffset y coordinate offset
     */
    package static func translate(_ edge: ElkEdge, xoffset: Double, yoffset: Double) {
        // Edge sections
        for section in edge.sections {
            translate(section, xoffset: xoffset, yoffset: yoffset)
        }
        
        // Edge labels
        for label in edge.labels {
            label.setLocation(x: label.x + xoffset, y: label.y + yoffset)
        }
        
        // Junction points
        if let junctionPoints: KVectorChain = edge.getProperty(CoreOptions.JUNCTION_POINTS) {
            junctionPoints.offset(xoffset, yoffset)
        }
    }
    
    /**
     * Translates the given edge section by an offset.
     *
     * @param section edge section that shall be translated
     * @param xoffset x coordinate offset
     * @param yoffset y coordinate offset
     */
    package static func translate(_ section: ElkEdgeSection, xoffset: Double, yoffset: Double) {
        // Translate source point
        section.setStartLocation(x: section.startX + xoffset, y: section.startY + yoffset)
        
        // Translate bend points
        for bendPoint in section.bendPoints {
            bendPoint.set(x: bendPoint.x + xoffset, y: bendPoint.y + yoffset)
        }
        
        // Translate target point
        section.setEndLocation(x: section.endX + xoffset, y: section.endY + yoffset)
    }
    
    /**
     * Translates the contents of the given node based on the content alignment property without resizing the node itself.
     * 
     * @param parent The parent node.
     * @param newSize The new size.
     * @param oldSize The old size.
     */
    package static func translate(_ parent: ElkNode, newSize: KVector, oldSize: KVector) {
        let contentAlignment: ContentAlignment = parent.getProperty(CoreOptions.CONTENT_ALIGNMENT) ?? []
        var xTranslate: Double = 0
        var yTranslate: Double = 0
        
        // Horizontal alignment
        if newSize.x > oldSize.x {
            if contentAlignment.contains(.hCenter) {
                xTranslate = (newSize.x - oldSize.x) / 2.0
            } else if contentAlignment.contains(.hRight) {
                xTranslate = newSize.x - oldSize.x
            }
        }
        
        // Vertical alignment
        if newSize.y > oldSize.y {
            if contentAlignment.contains(.vCenter) {
                yTranslate = (newSize.y - oldSize.y) / 2.0
            } else if contentAlignment.contains(.vBottom) {
                yTranslate = newSize.y - oldSize.y
            }
        }
        
        translate(parent, xoffset: xTranslate, yoffset: yTranslate)
    }
    
    // MARK: - Coordinate System Conversion
    
    /**
     * Returns the absolute position of the given element. For nodes and ports, this is exactly what you would expect.
     * Edges don't exactly have an absolute position, so we simply return the absolute position of their containign
     * node. For labels, we walk up the parent relationship and keep adding up positions.
     */
    package static func absolutePosition(_ element: ElkGraphElement) -> KVector {
        if let node = element as? ElkNode {
            return toAbsolute(KVector(node.x, node.y), parent: node.parent)
        } else if let port = element as? ElkPort {
            return toAbsolute(KVector(port.x, port.y), parent: port.parent)
        } else if let edge = element as? ElkEdge, let containingNode = edge.containingNode {
            return absolutePosition(containingNode)
        } else if let label = element as? ElkLabel, let labelParent = label.parent {
            let absoluteParentPosition = absolutePosition(labelParent)
            return KVector(absoluteParentPosition.x + label.x, absoluteParentPosition.y + label.y)
        } else {
            return KVector()
        }
    }
    
    /**
     * Converts the given relative point to an absolute location.
     *
     * @param point a relative point
     * @param parent the parent node to which the point is relative to
     * @return {@code point} for convenience
     */
    package static func toAbsolute(_ point: KVector, parent: ElkNode?) -> KVector {
        var node = parent
        var resultPoint = point
        while let currentNode = node {
            resultPoint.add(currentNode.x, currentNode.y)
            node = currentNode.parent
        }
        return resultPoint
    }

    /**
     * Converts the given absolute point to a relative location.
     *
     * @param point an absolute point
     * @param parent the parent node to which the point shall be made relative to
     * @return {@code point} for convenience
     */
    package static func toRelative(_ point: KVector, parent: ElkNode?) -> KVector {
        var node = parent
        var resultPoint = point
        while let currentNode = node {
            resultPoint.add(-currentNode.x, -currentNode.y)
            node = currentNode.parent
        }
        return resultPoint
    }
    
    /**
     * Creates a vector chain containing the start point, bend points, and end point of the given edge section. Note
     * that modifying the vector chain will be of no consequence to the edge section.
     *
     * @param edgeSection
     *            the edge section to initialize the vector chain with.
     * @return the vector chain.
     */
    package static func createVectorChain(_ edgeSection: ElkEdgeSection) -> KVectorChain {
        let chain = KVectorChain()
        
        chain.add(KVector(edgeSection.startX, edgeSection.startY))
        
        for bendPoint in edgeSection.bendPoints {
            chain.add(KVector(bendPoint.x, bendPoint.y))
        }
        
        chain.add(KVector(edgeSection.endX, edgeSection.endY))
        
        return chain
    }
    
    /**
     * Applies the vector chain's vectors to the given edge section. The first and the last point of the vector chain
     * are used as the section's new source and start point, respectively. The remaining points become the section's
     * new bend points. The method tries to reuse as many bend points as possible instead of wiping all bend points
     * out and creating new ones.
     *
     * @param vectorChain the vector chain to apply.
     * @param section the edge section to apply the chain to.
     * @throws IllegalArgumentException if the vector chain contains less than two vectors.
     */
    package static func applyVectorChain(_ vectorChain: KVectorChain, section: ElkEdgeSection) {
        // We need at least a start and an end point
        guard vectorChain.size() >= 2 else {
            assertionFailure("The vector chain must contain at least a source and a target point.")
            return
        }
        
        // Start point
        let firstPoint = vectorChain.getFirst()!
        section.setStartLocation(x: firstPoint.x, y: firstPoint.y)
        
        // Reuse as many existing bend points as possible
        var oldPointIter = section.bendPoints.makeIterator()
        var newPointIndex = 1
        
        while newPointIndex < vectorChain.size() - 1 {
            let nextPoint = vectorChain.get(newPointIndex)
            newPointIndex += 1
            
            var bendpoint: ElkBendPoint
            if let nextBendpoint = oldPointIter.next() {
                bendpoint = nextBendpoint
            } else {
                bendpoint = ElkGraphFactoryImpl().createElkBendPoint()
                section.bendPoints.append(bendpoint)
            }
            
            bendpoint.set(x: nextPoint.x, y: nextPoint.y)
        }
        
        // Remove existing bend points that we did not use — remove from end
        while section.bendPoints.count > vectorChain.size() - 2 {
            section.bendPoints.removeLast()
        }
        
        // End point
        let lastPoint = vectorChain.getLast()!
        section.setEndLocation(x: lastPoint.x, y: lastPoint.y)
    }
    
    // MARK: - Default Layout Settings
    
    /**
     * Recursively configures default values for all child elements of the passed graph. This
     * includes node, ports, and edges.
     *
     * Note that it is <b>not</b> checked whether the defaults flag is set on the graph.
     *
     * @param graph
     *            the graph to configure.
     */
    package static func configureDefaultsRecursively(_ graph: ElkNode) {
        // note that Iterators#filter(Iterator, Class) isn't used on purpose since
        // it's incompatible with gwt
        var kgeIt = ElkGraphUtil.allContents(graph).makeIterator()
        while let kge = kgeIt.next() {
            if let kge = kge as? ElkGraphElement {
                if let node = kge as? ElkNode {
                    configureWithDefaultValues(node)
                } else if let port = kge as? ElkPort {
                    configureWithDefaultValues(port)
                } else if let edge = kge as? ElkEdge {
                    configureWithDefaultValues(edge)
                }
            }
        }
    }
    
    /**
     * Adds some default values to the passed node. This includes a reasonable size, a label based
     * on the node's identifier and a inside center node label placement.
     *
     * Such default values are useful for fast test case generation.
     *
     * @param node
     *            a node of a graph
     */
    package static func configureWithDefaultValues(_ node: ElkNode) {
        // Make sure the node has a size if the size constraints are fixed
        let sc = node.getProperty(CoreOptions.NODE_SIZE_CONSTRAINTS) as? SizeConstraint

        if (sc == nil || sc == .fixed) && node.width == 0 && node.height == 0 {
            node.width = DEFAULT_MIN_WIDTH * 2 * 2
            node.height = DEFAULT_MIN_HEIGHT * 2 * 2
        }
        
        // label
        ensureLabel(node)
        
        let nlp = node.getProperty(CoreOptions.NODE_LABELS_PLACEMENT) as? NodeLabelPlacement
        if nlp?.isEmpty ?? true {
            node.setProperty(CoreOptions.NODE_LABELS_PLACEMENT, NodeLabelPlacement.insideCenter)
        }
    }
    
    /**
     * Adds some default values to the passed port. This includes a reasonable size
     * and a label based on the port's identifier.
     *
     * Such default values are useful for fast test case generation.
     *
     * @param port
     *            a port of a node of a graph
     */
    package static func configureWithDefaultValues(_ port: ElkPort) {
        if port.width == 0 && port.height == 0 {
            port.width = DEFAULT_MIN_WIDTH / 2.0 / 2.0
            port.height = DEFAULT_MIN_HEIGHT / 2.0 / 2.0
        }
        
        ensureLabel(port)
    }
    
    /**
     * Configures the {@link EdgeLabelPlacement} of the passed edge to be center of the edge.
     *
     * @param edge
     *            an edge of a graph
     */
    package static func configureWithDefaultValues(_ edge: ElkEdge) {
        if !edge.hasProperty(CoreOptions.EDGE_LABELS_PLACEMENT) {
            edge.setProperty(CoreOptions.EDGE_LABELS_PLACEMENT, EdgeLabelPlacement.center)
        }
    }
    
    /**
     * If the element does not already own a label, a label is created based on the element's
     * identifier.
     */
    package static func ensureLabel(_ klge: ElkGraphElement) {
        if klge.labels.isEmpty {
            if let identifier = klge.identifier, !identifier.isEmpty {
                let label = ElkGraphUtil.createLabel(klge)
                label.text = identifier
            }
        }
    }
    
    // MARK: - Visitors
    
    /**
     * Apply the given graph element visitors to the content of the given graph. If validators are involved
     * they are not queried about errors.
     *
     * @param graph the graph the visitors shall be applied to.
     * @param visitors the visitors to apply.
     */
    package static func applyVisitors(_ graph: ElkNode, visitors: [IGraphElementVisitor]) throws {
        var allElements = ElkGraphUtil.propertiesSkippingIteratorFor(graph, true).makeIterator()
        while let nextElement = allElements.next() {
            if let graphElement = nextElement as? ElkGraphElement {
                for visitor in visitors {
                    try visitor.visit(graphElement)
                }
            }
        }
    }
    
    /**
     * Apply the given graph element visitors to the content of the given graph. If validators are involved
     * and at least one error is found, a {@link GraphValidationException} is thrown.
     *
     * @param graph the graph the visitors shall be applied to.
     * @param visitors the visitors to apply.
     * @throws GraphValidationException if an error is found while validating the graph
     */
    package static func applyVisitorsWithValidation(_ graph: ElkNode, visitors: [IGraphElementVisitor]) throws {
        try applyVisitors(graph, visitors: visitors)
        // Validation stub: IValidatingGraphElementVisitor is not available in Swift port.
        // In the Java version this gathers GraphIssue objects and throws GraphValidationException.
    }
    
    // MARK: - Debugging
    
    /**
     * Print information on the given graph element to the given string builder.
     */
    package static func printElementPath(_ element: ElkGraphElement, builder: inout String) {
        // Print the containing element
        if let container = ElkGraphUtil.containingGraph(element) {
            printElementPath(container, builder: &builder)
            builder += " > "
        } else {
            builder += "Root "
        }

        // Print the class name
        let className = String(describing: type(of: element))
        if className.hasPrefix("Elk") {
            builder += String(className.dropFirst(3))
        } else {
            builder += className
        }

        // Print the identifier if present
        if let identifier = element.identifier, !identifier.isEmpty {
            builder += " \(identifier)"
            return
        }

        // Print the label if present
        if let label = element as? ElkLabel {
            let text = label.text
            if !text.isEmpty {
                builder += " \(text)"
                return
            }
        }

        for label in element.labels {
            let text = label.text
            if !text.isEmpty {
                builder += " \(text)"
                return
            }
        }

        // If it's an edge and no identifier nor label is present, print source and target
        if let edge = element as? ElkEdge, edge.isConnected() {
            builder += " ("
            for (i, source) in edge.sources.enumerated() {
                if i > 0 {
                    builder += ", "
                }
                printElementPath(source, builder: &builder)
            }
            builder += " -> "
            for (i, target) in edge.targets.enumerated() {
                if i > 0 {
                    builder += ", "
                }
                printElementPath(target, builder: &builder)
            }
            builder += ")"
        }
    }
    
    /**
     * Returns a path where debug files can be stored. All debug folders end up in an ELK-specific folder placed
     * inside the user's home folder. The returned path can either be that ELK-specific folder itself or a
     * subfolder.
     * <p>
     * If the returned path does not exist, it is not automatically created.
     *
     * @param subfolders optional subfolder names. Can be empty, in which case the ELK-specific subfolder of the user's
     *                   home folder is returned.
     * @return debug folder path, including a trailing separator character. Can return {@code null} if the user's
     *         home folder is not defined.
     */
    package static func debugFolderPath(_ subfolders: [String] = []) -> String? {
        let userHome = NSHomeDirectory()

        var path = userHome
        
        // Make sure we end the path with a separator character
        if !path.hasSuffix("/") {
            path += "/"
        }
        
        // The ELK debug directory
        path += "elk/"
        
        // Append the subfolder names, if any
        for s in subfolders {
            path += s + "/"
        }
        
        return path
    }
    
    /**
     * Takes the given name and makes it safe to be used as a file or folder name. To do so, we replace all spaces by
     * underscores and everything that is neither digit not standard character by hyphens.
     * 
     * @param name the name to convert to a proper path name.
     * @return the proper path name.
     */
    package static func toSafePathName(_ name: String) -> String {
        // Replace whitespace by _
        let nameWithoutWhitespace = _whitespaceRegex.stringByReplacingMatches(in: name, options: [], range: NSRange(location: 0, length: name.count), withTemplate: "_")

        // Replace everything which isn't a-z, A-Z, 0-9 or _ with -
        return _nonAlphanumericRegex.stringByReplacingMatches(in: nameWithoutWhitespace, options: [], range: NSRange(location: 0, length: nameWithoutWhitespace.count), withTemplate: "-")
    }
    
    // MARK: - Miscellaneous
    
    /**
     * Create a unique identifier for the given graph element. Note that this identifier
     * is not necessarily universally unique, since it uses the hash code, which
     * usually covers only the range of heap space addresses.
     *
     * @param element a graph element
     */
    package static func createIdentifier(_ element: ElkGraphElement) {
        element.identifier = String(ObjectIdentifier(element as AnyObject).hashValue)
    }

    /// Computes the part of a label that is inside the port area.
    package static func computeInsidePart(_ labelPos: KVector, _ labelSize: KVector,
                                          _ portSize: KVector, _ labelSpacing: Double,
                                          _ portSide: PortSide) -> Double {
        switch portSide {
        case .EAST, .WEST:
            let insideEnd = min(labelPos.x + labelSize.x, portSize.x)
            let insideStart = max(labelPos.x, 0)
            return max(0, insideEnd - insideStart)
        case .NORTH, .SOUTH:
            let insideEnd = min(labelPos.y + labelSize.y, portSize.y)
            let insideStart = max(labelPos.y, 0)
            return max(0, insideEnd - insideStart)
        default:
            return 0
        }
    }

    /// Computes the maximum amount by which any label of the given port extends inside the node.
    /// This considers all labels of the port and the port's border offset.
    package static func computeInsidePart(_ port: PortAdapter, _ portBorderOffset: Double) -> Double {
        let portSize = port.getSize()
        let portSide = port.getSide()
        var maxInsidePart = 0.0

        for label in port.getLabels() {
            let labelPos = label.getPosition()
            let labelSize = label.getSize()
            let insidePart = computeInsidePart(labelPos, labelSize, portSize, 0, portSide)
            maxInsidePart = max(maxInsidePart, insidePart)
        }

        // The port itself extends inside by its size minus the border offset
        switch portSide {
        case .NORTH, .SOUTH:
            maxInsidePart = max(maxInsidePart, portSize.y + portBorderOffset)
        case .EAST, .WEST:
            maxInsidePart = max(maxInsidePart, portSize.x + portBorderOffset)
        default:
            break
        }

        return maxInsidePart
    }

    /// Returns the bounding box of all labels of the given port, relative to the port's position.
    package static func getLabelsBounds(_ port: PortAdapter) -> ElkRectangle {
        let bounds = ElkRectangle()
        var initialized = false

        for label in port.getLabels() {
            let labelPos = label.getPosition()
            let labelSize = label.getSize()

            if !initialized {
                bounds.x = labelPos.x
                bounds.y = labelPos.y
                bounds.width = labelSize.x
                bounds.height = labelSize.y
                initialized = true
            } else {
                let right = max(bounds.x + bounds.width, labelPos.x + labelSize.x)
                let bottom = max(bounds.y + bounds.height, labelPos.y + labelSize.y)
                bounds.x = min(bounds.x, labelPos.x)
                bounds.y = min(bounds.y, labelPos.y)
                bounds.width = right - bounds.x
                bounds.height = bottom - bounds.y
            }
        }

        return bounds
    }
}
