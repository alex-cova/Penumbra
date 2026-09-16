// Copyright (c) 2016, 2017 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0

import Foundation

/**
 * A node used by the NetworkSimplex algorithm. It has a set of incoming and outgoing edges.
 */
package final class NNode: Hashable {

    package static func == (lhs: NNode, rhs: NNode) -> Bool { lhs === rhs }
    package func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
    
    // MARK: - Public Properties
    
    /** A package id, unused internally, use it for whatever you want. */
    package var id: Int = 0
    
    /** An object from which this edge is derived. */
    package var origin: Any?
    
    /** The type is attached as label to the debug graph. Apart from this it has no semantic meaning. */
    package var type: String = ""
    
    /**
     * The layer each node is currently assigned to. Note that during layerer execution, the lowest
     * layer is not necessary the zeroth layer. To fulfill this characteristic, a final call of
     * `NetworkSimplex.normalize()` has to be performed.
     */
    package var layer: Int = 0
    
    // MARK: - Internal Properties
    
    /** Internally set and used id to index arrays. */
    internal var internalId: Int = 0
    
    /**
     * A flag indicating whether a specified node is part of the spanning tree determined by
     * `tightTree()`.
     */
    internal var treeNode: Bool = false
    
    /**
     * A collection of edges for which cutvalues are unknown. Cutvalues are updated during every
     * iteration of the network simplex algorithm.
     */
    internal var unknownCutvalues: [NEdge] = []
    
    // MARK: - Private Properties
    
    package var outgoingEdges = ChangeAwareArrayList<NEdge>()
    package var outgoingEdgesModCnt: Int = -1
    package var incomingEdges = ChangeAwareArrayList<NEdge>()
    package var incomingEdgesModCnt: Int = -1
    package var allEdges: [NEdge] = []

    /// Computed property returning the concatenation of incoming and outgoing edges.
    package var connectedEdges: [NEdge] {
        return getConnectedEdges()
    }

    // MARK: - Initializers
    
    internal init() { }
    
    // MARK: - Static Methods
    
    /**
     * @return an `NNodeBuilder` to construct a new node.
     */
    package static func of() -> NNodeBuilder {
        return NNodeBuilder()
    }
    
    // MARK: - Public Methods
    
    /**
     * @return the outgoingEdges
     */
    package func getOutgoingEdges() -> [NEdge] {
        return outgoingEdges.list
    }
    
    /**
     * @return the incomingEdges
     */
    package func getIncomingEdges() -> [NEdge] {
        return incomingEdges.list
    }
    
    /**
     * @return a list with the union of `getOutgoingEdges()` and `getIncomingEdges()`.
     *         The list is cached internally, subsequent calls return the same list as long as
     *         neither of the incoming and outgoing edges changes.
     */
    package func getConnectedEdges() -> [NEdge] {
        if incomingEdgesModCnt != incomingEdges.getModCnt() ||
            outgoingEdgesModCnt != outgoingEdges.getModCnt() {
            
            allEdges.removeAll()
            allEdges.reserveCapacity(incomingEdges.size() + outgoingEdges.size())
            allEdges.append(contentsOf: incomingEdges)
            allEdges.append(contentsOf: outgoingEdges)
            
            incomingEdgesModCnt = incomingEdges.getModCnt()
            outgoingEdgesModCnt = outgoingEdges.getModCnt()
        }
        
        return allEdges
    }
    
    // MARK: - NNodeBuilder
    
    /**
     * Builder class for `NNode`s.
     */
    package final class NNodeBuilder {

        /** The node currently being constructed. */
        package var node: NNode

        init() {
            node = NNode()
        }
        
        /**
         * Sets the id field.
         *
         * @param id a non-negative integer.
         * @return this builder.
         */
        package func id(_ id: Int) -> NNodeBuilder {
            node.id = id
            return self
        }
        
        /**
         * Sets the origin field.
         *
         * @param origin any object.
         * @return this builder.
         */
        package func origin(_ origin: Any) -> NNodeBuilder {
            node.origin = origin
            return self
        }
        
        /**
         * Sets the type field.
         *
         * @param type any string, has no semantic meaning, can be used for debugging.
         * @return this builder.
         */
        package func type(_ type: String) -> NNodeBuilder {
            node.type = type
            return self
        }
        
        /**
         * Finally creates this node. That is, the node is added to the passed `NGraph`.
         *
         * @param graph the `NGraph` this node belongs to.
         * @return the created `NNode`.
         */
        package func create(_ graph: NGraph) -> NNode {
            graph.nodes.append(node)
            return node
        }
    }
    
    // MARK: - ChangeAwareArrayList
    
    /**
     * Delegates all its calls to an internal `ArrayList` An easy implementation would just expose the
     * `AbstractList`'s `modCount` field. However this is not compatible with GWT
     * since GWT's list implementations do not increment the 'modCount' variable.
     */
    package class ChangeAwareArrayList<E: AnyObject>: Sequence, Collection {

        package var list: [E] = []
        package var modCount: Int = 0

        // MARK: - Collection conformance

        package var startIndex: Int { list.startIndex }
        package var endIndex: Int { list.endIndex }

        package subscript(position: Int) -> E {
            get { list[position] }
            set {
                modCount += 1
                list[position] = newValue
            }
        }

        package func index(after i: Int) -> Int {
            return list.index(after: i)
        }

        package func makeIterator() -> IndexingIterator<[E]> {
            return list.makeIterator()
        }

        // MARK: - Java-compatible API

        package func getModCnt() -> Int {
            return modCount
        }

        package func size() -> Int {
            return list.count
        }

        package func isEmpty() -> Bool {
            return list.isEmpty
        }

        package func contains(_ o: E) -> Bool {
            return list.contains(where: { $0 === o })
        }

        package func iterator() -> IndexingIterator<[E]> {
            return list.makeIterator()
        }

        package func toArray() -> [Any] {
            return list.map { $0 as Any }
        }

        package func toArray<T>(_ a: [T]) -> [T] {
            return list.compactMap { $0 as? T }
        }

        @discardableResult
        package func add(_ e: E) -> Bool {
            modCount += 1
            list.append(e)
            return true
        }

        package func append(_ e: E) {
            modCount += 1
            list.append(e)
        }

        package func append(contentsOf elements: [E]) {
            modCount += 1
            list.append(contentsOf: elements)
        }

        @discardableResult
        package func remove(_ o: E) -> Bool {
            guard let index = list.firstIndex(where: { $0 === o }) else { return false }
            modCount += 1
            list.remove(at: index)
            return true
        }

        package func containsAll(_ c: [E]) -> Bool {
            return c.allSatisfy { item in list.contains(where: { $0 === item }) }
        }

        @discardableResult
        package func addAll(_ c: [E]) -> Bool {
            modCount += 1
            list.append(contentsOf: c)
            return true
        }

        @discardableResult
        package func addAll(index: Int, c: [E]) -> Bool {
            modCount += 1
            list.insert(contentsOf: c, at: index)
            return true
        }

        @discardableResult
        package func removeAll(_ c: [E]) -> Bool {
            let initialCount = list.count
            list = list.filter { item in !c.contains(where: { $0 === item }) }
            let changed = list.count != initialCount
            if changed {
                modCount += 1
            }
            return changed
        }

        @discardableResult
        package func retainAll(_ c: [E]) -> Bool {
            let initialCount = list.count
            list = list.filter { item in c.contains(where: { $0 === item }) }
            let changed = list.count != initialCount
            if changed {
                modCount += 1
            }
            return changed
        }

        package func clear() {
            modCount += 1
            list.removeAll()
        }

        package func get(_ index: Int) -> E {
            return list[index]
        }

        @discardableResult
        package func set(_ index: Int, _ element: E) -> E {
            modCount += 1
            let removed = list.remove(at: index)
            list.insert(element, at: index)
            return removed
        }

        package func add(index: Int, _ element: E) {
            modCount += 1
            list.insert(element, at: index)
        }

        @discardableResult
        package func remove(index: Int) -> E {
            modCount += 1
            return list.remove(at: index)
        }

        package func remove(at index: Int) {
            modCount += 1
            list.remove(at: index)
        }

        package func indexOf(_ o: E) -> Int? {
            return list.firstIndex(where: { $0 === o })
        }

        package func lastIndexOf(_ o: E) -> Int? {
            for i in stride(from: list.count - 1, through: 0, by: -1) {
                if list[i] === o { return i }
            }
            return nil
        }

        package func firstIndex(of element: E) -> Int? {
            return list.firstIndex(where: { $0 === element })
        }

        package func subList(from fromIndex: Int, to toIndex: Int) -> [E] {
            return Array(list[fromIndex..<toIndex])
        }
    }
}
