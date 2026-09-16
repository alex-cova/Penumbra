import Foundation

/**
 * An edge in the graph processed by the `NetworkSimplex` algorithm. It has a source and
 * target `NNode`, a weight and a minimum length (delta).
 */
package class NEdge: Hashable {

    package static func == (lhs: NEdge, rhs: NEdge) -> Bool { lhs === rhs }
    package func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
    
    /** A package id, unused internally, use it for whatever you want. */
    package var id: Int = 0
    
    /** Internally set and used id to index arrays. */
    internal var internalId: Int = 0
    
    /** An object from which this edge is derived. */
    package var origin: Any?
    
    /** The source node of this edge. */
    package var source: NNode?

    /** The target node of this edge. */
    package var target: NNode?
    
    /** The weight of this edge. */
    package var weight: Double = 0.0
    
    /** The minimum length of this edge. */
    package var delta: Int = 1
    
    /**
     * A flag indicating whether a specified edge is part of the spanning tree determined by
     * `tightTree()`.
     */
    internal var treeEdge: Bool = false
    
    /**
     * @return an `NEdgeBuilder` to create a new edge.
     */
    package static func `of`() -> NEdgeBuilder {
        return NEdgeBuilder()
    }
    
    /**
     * @param origin
     *            an object from which this edge originates.
     * @return an `NEdgeBuilder` to create a new edge.
     */
    package static func `of`(_ origin: Any?) -> NEdgeBuilder {
        return NEdgeBuilder()
    }
    
    /**
     * @return the source
     */
    package func getSource() -> NNode? {
        return source
    }

    /**
     * @return the target
     */
    package func getTarget() -> NNode? {
        return target
    }
    
    /**
     * @param some
     *            One of the source and target nodes of this edge.
     * @return the opposite node of `some`. That is, if `some` is the source node of
     *         this edge, the target node is returned and vice versa.
     * @throws IllegalArgumentException
     *             if some is neither target nor source of this edge.
     */
    package func getOther(_ some: NNode) -> NNode {
        guard let src = source, let tgt = target else {
            assertionFailure("NEdge not fully connected")
            return some
        }
        if some === src {
            return tgt
        } else if some === tgt {
            return src
        } else {
            assertionFailure("Node \(some) not part of edge \(self)")
            return some
        }
    }
    
    /**
     * Reversed this edge, i.e. the target becomes the source and the source becomes the target.
     * Also, the lists of incoming and outgoing edges of the source and target node are updated.
     * 
     * @return this.
     */
    package func reverse() -> NEdge {
        let tmp = source
        source = target
        target = tmp

        guard let src = source, let tgt = target else {
            assertionFailure("NEdge not fully connected")
            return self
        }

        tgt.outgoingEdges.remove(self)
        tgt.incomingEdges.append(self)

        src.incomingEdges.remove(self)
        src.outgoingEdges.append(self)

        return self
    }
    
    package var description: String {
        return "NEdge[id=\(id) w=\(weight) d=\(delta)]"
    }
    
    /**
     * Builder class for an `NEdge`. Allows to conveniently construct new edges.
     */
    package final class NEdgeBuilder {

        package var edge: NEdge

        init() {
            edge = NEdge()
        }
        
        /**
         * Sets the id field.
         * 
         * @param id
         *            an id
         * @return this builder.
         */
        package func id(_ id: Int) -> NEdgeBuilder {
            edge.id = id
            return self
        }
        
        /**
         * Sets the origin field.
         * 
         * @param origin
         *            any object.
         * @return this builder.
         */
        package func origin(_ origin: Any?) -> NEdgeBuilder {
            edge.origin = origin
            return self
        }
        
        /**
         * Sets the weight of this edge.
         * 
         * @param weight
         *            some positive weight.
         * @return this builder.
         */
        package func weight(_ weight: Double) -> NEdgeBuilder {
            edge.weight = weight
            return self
        }
        
        /**
         * Sets the minimal length of this edge.
         * 
         * @param delta
         *            a non-negative integer.
         * @return this builder.
         */
        package func delta(_ delta: Int) -> NEdgeBuilder {
            edge.delta = delta
            return self
        }
        
        /**
         * Sets the source node.
         * 
         * @param source
         *            a `NNode`.
         * @return this builder.
         */
        package func source(_ source: NNode) -> NEdgeBuilder {
            edge.source = source
            return self
        }
        
        /**
         * Sets the target node.
         * 
         * @param target
         *            a `NNode`.
         * @return this builder.
         */
        package func target(_ target: NNode) -> NEdgeBuilder {
            edge.target = target
            return self
        }
        
        /**
         * Finally returns the `NEdge` instance. As a side effect the edge is added to the
         * outgoing edges of the source `NNode` and to the incoming edges of the target
         * `NNode`.
         * 
         * @return the newly created `NEdge`.
         * 
         * @throws IllegalStateException
         *             if either no source or target was specified, or if source equals target.
         */
        @discardableResult
        package func create() -> NEdge {
            
            guard let src = edge.source, let tgt = edge.target else {
                assertionFailure("\(NEdge.self) must have a source and target \(NNode.self) specified.")
                return edge
            }

            if src === tgt {
                assertionFailure("Network simplex does not support self-loops: \(edge) \(src) \(tgt)")
                return edge
            }
            
            src.outgoingEdges.append(edge)
            tgt.incomingEdges.append(edge)
            
            return edge
        }
    }
}
