// Copyright (c) 2010, 2017 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0

import Foundation

/**
 * A chain of vectors. Can be used to describe polylines or similar constructs.
 */
package final class KVectorChain: Sequence, IDataObject {

    // MARK: - Types

    package typealias Element = KVector
    
    // MARK: - Properties
    
    package var elements: [KVector] = []
    
    package static let serialVersionUID: Int64 = -7978287459602078559
    
    // MARK: - Initialization
    
    /// Creates an empty vector chain.
    package init() {
        // Empty
    }
    
    /// Creates a vector chain from a given collection of vectors.
    package init(_ collection: [KVector]) {
        self.elements = collection
    }
    
    /// Creates a vector chain from a given vector array.
    package convenience init(_ vectors: KVector...) {
        self.init(vectors)
    }
    
    // MARK: - Collection Conformance
    
    package var count: Int {
        return elements.count
    }
    
    package var startIndex: Int {
        return elements.startIndex
    }
    
    package var endIndex: Int {
        return elements.endIndex
    }
    
    package subscript(index: Int) -> KVector {
        get {
            return elements[index]
        }
    }
    
    package func index(after i: Int) -> Int {
        return elements.index(after: i)
    }
    
    // MARK: - Collection Methods
    
    package func makeIterator() -> IndexingIterator<[KVector]> {
        return elements.makeIterator()
    }
    
    // MARK: - CustomStringConvertible
    
    package var description: String {
        var builder = "("
        var first = true
        for vector in elements {
            if !first {
                builder += "; "
            }
            builder += "\(vector.x),\(vector.y)"
            first = false
        }
        return builder + ")"
    }
    
    // MARK: - Conversion Methods
    
    package func toArray() -> [KVector] {
        return elements
    }
    
    /// Returns an array containing a subsequence of the elements in this vector chain.
    package func toArray(from beginIndex: Int) -> [KVector] {
        guard beginIndex >= 0 && beginIndex <= elements.count else {
            assertionFailure("IndexOutOfBoundsException")
            return []
        }
        return Array(elements[beginIndex...])
    }
    
    // MARK: - Parsing
    
    package func parse(_ string: String) throws {
        let pattern = "[,;()\\[\\]{}\\s\t\n]+"
        let tokens = string.components(separatedBy: NSRegularExpression.create(pattern)).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        
        elements.removeAll()
        
        do {
            var i = 0
            var xy = 0
            var x: Double = 0, y: Double = 0
            
            while i < tokens.count {
                if let token = Double(tokens[i]) {
                    if xy % 2 == 0 {
                        x = token
                    } else {
                        y = token
                    }
                    
                    if xy > 0 && xy % 2 != 0 {
                        elements.append(KVector(x: x, y: y))
                    }
                    xy += 1
                }
                i += 1
            }
        } catch {
            throw ELK.Error.runtimeError("The given string does not match the expected format for vectors.")
        }
    }
    
    // MARK: - Adding Elements
    
    /// Appends a vector (alias for add).
    package func append(_ vector: KVector) {
        elements.append(vector)
    }

    /// Adds a vector to the chain.
    package func add(_ vector: KVector) {
        elements.append(vector)
    }

    /// Appends a sequence of vectors.
    package func append(contentsOf newElements: some Sequence<KVector>) {
        elements.append(contentsOf: newElements)
    }

    /// Adds a (0,0) vector to the vector chain.
    package func add() {
        add(KVector())
    }

    /// Reverse instance method
    package func reverse() -> KVectorChain {
        return KVectorChain.reverse(self)
    }

    /// Remove all elements
    package func clear() {
        elements.removeAll()
    }

    /// Get first element
    package func getFirst() -> KVector? {
        return elements.first
    }

    /// Get last element
    package func getLast() -> KVector? {
        return elements.last
    }

    /// Check if empty
    package var isEmpty: Bool {
        return elements.isEmpty
    }

    /// Size
    package func size() -> Int {
        return elements.count
    }

    /// Remove element at index
    package func remove(at index: Int) -> KVector {
        return elements.remove(at: index)
    }
    
    /// Adds the vector (x,y) to the vector chain.
    package func add(_ x: Double, _ y: Double) {
        add(KVector(x: x, y: y))
    }
    
    /// Adds a vector to the beginning of the vector chain.
    package func addFirst(_ vector: KVector) {
        elements.insert(vector, at: 0)
    }

    /// Adds a (0,0) vector to the beginning of the vector chain.
    package func addFirst() {
        addFirst(KVector())
    }
    
    /// Adds the vector (x,y) to the beginning of the vector chain.
    package func addFirst(_ x: Double, _ y: Double) {
        addFirst(KVector(x: x, y: y))
    }
    
    /// Adds a vector to the end of the vector chain.
    package func addLast(_ vector: KVector) {
        elements.append(vector)
    }

    /// Adds a (0,0) vector to the end of the vector chain.
    package func addLast() {
        addLast(KVector())
    }
    
    /// Adds the vector (x,y) to the end of the vector chain.
    package func addLast(_ x: Double, _ y: Double) {
        addLast(KVector(x: x, y: y))
    }
    
    /// Add all the vectors in the given array to the end of this vector chain.
    package func addAll(_ vectors: [KVector]) {
        elements.append(contentsOf: vectors)
    }

    /// Add all vectors from another KVectorChain.
    package func addAll(other chain: KVectorChain) {
        elements.append(contentsOf: chain.elements)
    }

    /// Get element at index (Java List.get() equivalent).
    package func get(_ index: Int) -> KVector {
        return elements[index]
    }
    
    /// Add copies of all the vectors to this chain, starting at the given index.
    package func addAllAsCopies(at index: Int, _ chain: [KVector]) {
        let copies = chain.map { KVector($0) }
        elements.insert(contentsOf: copies, at: index)
    }
    
    // MARK: - Mutation Methods
    
    /// Iterate through all vectors and scale them by the given amount.
    package func scale(_ scale: Double) -> KVectorChain {
        for i in 0..<elements.count {
            elements[i].scale(scale)
        }
        return self
    }
    
    /// Iterate through all vectors and scale them with different values for X and Y coordinate.
    package func scale(_ scalex: Double, _ scaley: Double) -> KVectorChain {
        for i in 0..<elements.count {
            elements[i].scale(scalex, scaley)
        }
        return self
    }
    
    /// Iterate through all vectors and add the offset to them.
    package func offset(_ offset: KVector) -> KVectorChain {
        for i in 0..<elements.count {
            elements[i].add(offset)
        }
        return self
    }
    
    /// Iterate through all vectors and add the offset to them without mutating.
    package func offsetNonMutating(_ offset: KVector) -> KVectorChain {
        let result = KVectorChain()
        for vector in elements {
            result.add(KVector.sum(vector, offset))
        }
        return result
    }
    
    /// Iterate through all vectors and add the offset to them.
    package func offset(_ dx: Double, _ dy: Double) -> KVectorChain {
        for i in 0..<elements.count {
            elements[i].add(dx, dy)
        }
        return self
    }
    
    // MARK: - Analysis Methods
    
    /// Calculate the total length of this vector chain.
    package func totalLength() -> Double {
        var length: Double = 0
        if elements.count >= 2 {
            for i in 0..<(elements.count - 1) {
                length += elements[i].distance(to: elements[i + 1])
            }
        }
        return length
    }
    
    /// Determine whether any of the contained vectors is NaN.
    package func hasNaN() -> Bool {
        for vector in elements {
            if vector.isNaN() {
                return true
            }
        }
        return false
    }
    
    /// Determine whether any of the contained vectors is infinite.
    package func hasInfinite() -> Bool {
        for vector in elements {
            if vector.isInfinite() {
                return true
            }
        }
        return false
    }
    
    // MARK: - Geometric Methods
    
    /// Calculate a point on this vector chain with given distance.
    package func pointOnLine(_ dist: Double) -> KVector {
        if elements.count >= 2 {
            let absDistance = abs(dist)
            var distanceSum: Double = 0
            
            if dist >= 0 {
                // traverse the points in normal direction
                var currentPoint = elements[0]
                for i in 1..<elements.count {
                    let oldDistanceSum = distanceSum
                    let nextPoint = elements[i]
                    let additionalDistanceToNext = currentPoint.distance(to: nextPoint)
                    
                    if additionalDistanceToNext > 0 {
                        distanceSum += additionalDistanceToNext
                        if distanceSum >= absDistance {
                            let thisRelative = (absDistance - oldDistanceSum) / additionalDistanceToNext
                            let result = nextPoint.subtracted(by: currentPoint).scaled(by: thisRelative).added(to: currentPoint)
                            return result
                        }
                    }
                    currentPoint = nextPoint
                }
                guard let lastElement = elements.last else { assertionFailure("Cannot determine a point on an empty vector chain."); return KVector() }
                return lastElement
            } else {
                // traverse the points in reversed direction
                guard let lastElement = elements.last else { assertionFailure("Cannot determine a point on an empty vector chain."); return KVector() }
                var currentPoint = lastElement
                for i in stride(from: elements.count - 1, to: 0, by: -1) {
                    let oldDistanceSum = distanceSum
                    let nextPoint = elements[i - 1]
                    let additionalDistanceToNext = currentPoint.distance(to: nextPoint)
                    
                    if additionalDistanceToNext > 0 {
                        distanceSum += additionalDistanceToNext
                        if distanceSum >= absDistance {
                            let thisRelative = (absDistance - oldDistanceSum) / additionalDistanceToNext
                            let result = nextPoint.subtracted(by: currentPoint).scaled(by: thisRelative).added(to: currentPoint)
                            return result
                        }
                    }
                    currentPoint = nextPoint
                }
                guard let firstElement = elements.first else { assertionFailure("Cannot determine a point on an empty vector chain."); return KVector() }
                return firstElement
            }
        } else if elements.count == 1 {
            return elements[0]
        } else {
            assertionFailure("Cannot determine a point on an empty vector chain.")
            return KVector()
        }
    }

    /// Calculate the angle of a line segment of this vector chain with given distance.
    package func angleOnLine(_ dist: Double) -> Double {
        if elements.count >= 2 {
            let absDistance = abs(dist)
            var distanceSum: Double = 0
            
            if dist >= 0 {
                // traverse the points in normal direction
                var currentPoint = elements[0]
                for i in 1..<elements.count {
                    let nextPoint = elements[i]
                    let additionalDistanceToNext = currentPoint.distance(to: nextPoint)
                    
                    if additionalDistanceToNext > 0 {
                        distanceSum += additionalDistanceToNext
                        if distanceSum >= absDistance {
                            return nextPoint.subtracted(by: currentPoint).toRadians()
                        }
                    }
                    currentPoint = nextPoint
                }
                return elements[elements.count - 1].subtracted(by: elements[elements.count - 2]).toRadians()
            } else {
                // traverse the points in reversed direction
                var currentPoint = elements[elements.count - 1]
                for i in stride(from: elements.count - 1, to: 0, by: -1) {
                    let nextPoint = elements[i - 1]
                    let additionalDistanceToNext = currentPoint.distance(to: nextPoint)
                    
                    if additionalDistanceToNext > 0 {
                        distanceSum += additionalDistanceToNext
                        if distanceSum >= absDistance {
                            return nextPoint.subtracted(by: currentPoint).toRadians()
                        }
                    }
                    currentPoint = nextPoint
                }
                return elements[1].subtracted(by: elements[0]).toRadians()
            }
        } else {
            assertionFailure("Need at least two points to determine an angle.")
            return 0
        }
    }
    
    // MARK: - List Iterator

    /// Returns a list iterator for this chain (Java ListIterator equivalent).
    package func listIterator() -> KVectorChainListIterator {
        return KVectorChainListIterator(self)
    }

    /// last property
    package var last: KVector? {
        return elements.last
    }

    /// Insert element at index
    package func insert(_ element: KVector, at index: Int) {
        elements.insert(element, at: index)
    }

    /// Remove all elements matching a collection
    package func removeAll(_ toRemove: [KVector]) {
        elements.removeAll { elem in toRemove.contains { $0 === elem } }
    }

    /// Clone this vector chain
    package func clone() -> KVectorChain {
        let copy = KVectorChain()
        for v in elements {
            copy.add(KVector(v))
        }
        return copy
    }

    // MARK: - Static Methods
    
    /// Returns a new vector chain that is the reverse of the given vector chain.
    package static func reverse(_ chain: KVectorChain) -> KVectorChain {
        let result = KVectorChain()
        for vector in chain.elements.reversed() {
            result.add(KVector(vector))
        }
        return result
    }
}

// MARK: - Helper Extensions

package extension String {
    func components(separatedBy regex: NSRegularExpression) -> [String] {
        var components: [String] = []
        var range = NSRange(location: 0, length: utf16.count)
        
        while let match = regex.firstMatch(in: self, options: [], range: range) {
            if match.range.location != NSNotFound && match.range.location > range.location {
                let substringRange = NSRange(location: range.location, length: match.range.location - range.location)
                if let substringRange = Range(substringRange, in: self) {
                    components.append(String(self[substringRange]))
                }
            }
            range = NSRange(location: match.range.location + match.range.length, length: utf16.count - (match.range.location + match.range.length))
        }
        
        if range.location < utf16.count {
            let substringRange = Range(range, in: self)
            if let substring = substringRange.map({ String(self[$0]) }) {
                components.append(substring)
            }
        }
        
        return components
    }
}

/// Java-style ListIterator for KVectorChain
package class KVectorChainListIterator {
    private let chain: KVectorChain
    private var index: Int = 0

    package init(_ chain: KVectorChain) {
        self.chain = chain
    }

    package func hasNext() -> Bool {
        return index < chain.elements.count
    }

    package func next() -> KVector {
        let element = chain.elements[index]
        index += 1
        return element
    }

    package func nextIndex() -> Int {
        return index
    }

    package func hasPrevious() -> Bool {
        return index > 0
    }

    package func previous() -> KVector {
        index -= 1
        return chain.elements[index]
    }
}

package extension NSRegularExpression {
    static func create(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            guard let fallback = try? NSRegularExpression(pattern: "(?:)", options: []) else {
                assertionFailure("Failed to create fallback NSRegularExpression")
                // This path should be unreachable since "(?:)" is a valid pattern
                return try! NSRegularExpression(pattern: "(?:)", options: [])
            }
            return fallback
        }
    }
}
