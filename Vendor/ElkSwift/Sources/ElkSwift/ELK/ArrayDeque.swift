/// A simple FIFO queue backed by an array with O(1) amortized dequeue.
///
/// Unlike `Array.removeFirst()` which is O(n), this uses an index to track
/// the front of the queue, avoiding element shifting on each dequeue.
package struct ArrayDeque<Element> {
    private var storage: [Element]
    private var headIndex: Int = 0

    package init() {
        storage = []
    }

    package init(_ elements: [Element]) {
        storage = elements
    }

    package var isEmpty: Bool {
        headIndex >= storage.count
    }

    package var count: Int {
        storage.count - headIndex
    }

    package mutating func append(_ element: Element) {
        storage.append(element)
    }

    package mutating func append<S: Sequence>(contentsOf elements: S) where S.Element == Element {
        storage.append(contentsOf: elements)
    }

    @discardableResult
    package mutating func removeFirst() -> Element {
        let element = storage[headIndex]
        headIndex += 1
        // Reclaim memory when more than half is consumed
        if headIndex > 64 && headIndex > storage.count / 2 {
            storage.removeFirst(headIndex)
            headIndex = 0
        }
        return element
    }

    package var first: Element? {
        isEmpty ? nil : storage[headIndex]
    }

    package mutating func removeAll(keepingCapacity: Bool = false) {
        storage.removeAll(keepingCapacity: keepingCapacity)
        headIndex = 0
    }

    package func contains(where predicate: (Element) -> Bool) -> Bool {
        for i in headIndex..<storage.count {
            if predicate(storage[i]) { return true }
        }
        return false
    }
}

extension ArrayDeque: Sequence {
    package func makeIterator() -> IndexingIterator<ArraySlice<Element>> {
        storage[headIndex...].makeIterator()
    }
}
