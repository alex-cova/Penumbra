import Foundation

// MARK: - Java Compatibility Types

package protocol Serializable {}

package typealias Boolean = Bool
package typealias Long = Int64
package typealias Number = Double
package typealias Object = AnyObject

package typealias List<E> = [E]
package typealias Map<K: Hashable, V> = [K: V]
package typealias Iterable<E> = AnySequence<E>

package class RuntimeException: Error {
    package let message: String
    package init(_ message: String = "") {
        self.message = message
    }
}

package class StringWriter {
    private var buffer = ""
    package init() {}
    package func write(_ s: String) { buffer += s }
    package func toString() -> String { return buffer }
}

// MARK: - Java Math Compat

package enum DoubleMath {
    package static func fuzzyEquals(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool {
        return abs(a - b) <= tolerance
    }

    /// Compares two doubles with a tolerance. Returns -1, 0, or 1.
    package static func fuzzyCompare(_ a: Double, _ b: Double, _ tolerance: Double) -> Int {
        if fuzzyEquals(a, b, tolerance) {
            return 0
        }
        return a < b ? -1 : 1
    }
}

package enum Strings {
    package static func isNullOrEmpty(_ s: String?) -> Bool {
        return s?.isEmpty ?? true
    }
    package static func nullToEmpty(_ s: String?) -> String {
        return s ?? ""
    }
}

// MARK: - Java Collections Compat

package typealias EnumSet<E: Hashable> = Set<E>
package typealias EnumMap<K: Hashable, V> = Dictionary<K, V>

/// Swift equivalent of Guava's `TreeMultimap<K, V>`.
///
/// A sorted multimap that groups values by key, maintaining sorted order for both
/// keys (by `keyComparator`) and values within each key bucket (by `valueComparator`).
/// Values are inserted in O(log n) via binary search.
///
/// Matches Java's `TreeMultimap.create(keyComparator, valueComparator)` factory pattern.
package struct TreeMultimap<K: Hashable, V>: Sequence {

    private var storage: [K: [V]] = [:]
    private let keyComparator: (K, K) -> Bool
    private let valueComparator: (V, V) -> Bool

    /// Creates a TreeMultimap with custom comparators (less-than semantics).
    package init(
        keyComparator: @escaping (K, K) -> Bool,
        valueComparator: @escaping (V, V) -> Bool
    ) {
        self.keyComparator = keyComparator
        self.valueComparator = valueComparator
    }

    /// Insert a value under the given key, maintaining sorted order.
    package mutating func put(_ key: K, _ value: V) {
        if storage[key] == nil {
            storage[key] = [value]
        } else {
            var arr = storage[key, default: []]
            var lo = 0
            var hi = arr.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if valueComparator(arr[mid], value) {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
            arr.insert(value, at: lo)
            storage[key] = arr
        }
    }

    /// Returns the sorted values for a key, or empty array if absent.
    package func get(_ key: K) -> [V] {
        storage[key] ?? []
    }

    /// Subscript access — returns nil if key has no entries.
    package subscript(_ key: K) -> [V]? {
        storage[key]
    }

    /// All keys in sorted order.
    package var sortedKeys: [K] {
        storage.keys.sorted(by: keyComparator)
    }

    /// All keys in sorted order (Java API name).
    package func keySet() -> [K] {
        sortedKeys
    }

    /// All values flattened, iterated in key-sorted then value-sorted order.
    package func values() -> [V] {
        sortedKeys.flatMap { storage[$0, default: []] }
    }

    /// Whether the multimap has no entries.
    package var isEmpty: Bool {
        storage.isEmpty
    }

    /// Sequence conformance — iterates as `(K, [V])` pairs in key-sorted order.
    package func makeIterator() -> IndexingIterator<[(K, [V])]> {
        sortedKeys.map { ($0, storage[$0, default: []]) }.makeIterator()
    }
}

// MARK: - EMF Compat (minimal stubs)

package protocol EObject: AnyObject {}
package typealias EList<E> = [E]
package typealias EMap<K: Hashable, V> = [K: V]

package protocol EClass: AnyObject {
    var name: String { get }
    func classifierID() -> Int
    func getEPackage() -> (any EPackage)?
}

extension EClass {
    package func classifierID() -> Int { return -1 }
    package func getEPackage() -> (any EPackage)? { return nil }
}

// Convenience: allow calling name() as a function (some transpiled code uses name() instead of .name)
extension EClass {
    package func name() -> String { return name }
}

package protocol EPackage: AnyObject {
}

package class EFactory {
    package init() {}
}

// MARK: - Double Extensions for Java Math

package extension Double {
    func toRadians() -> Double {
        return self * .pi / 180.0
    }
    func toDegrees() -> Double {
        return self * 180.0 / .pi
    }
}

// MARK: - Consumer typealias

package typealias Consumer<T> = (T) -> Void

// MARK: - Missing Protocol Stubs

package protocol IPropertyHolderOptionFilter {}
package protocol LayoutMetaData {}
package protocol TestController {}

// MARK: - IllegalArgumentException

package struct IllegalArgumentException: Error, CustomStringConvertible {
    package let description: String
    package init(_ description: String) {
        self.description = description
    }
}
