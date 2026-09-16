// Copyright (c) 2009, 2015 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0

import Foundation

/**
 * A useful pair implementation.
 */
package final class Pair<F, S>: IteratorProtocol, Sequence {

    /**
     * Constructs a pair with `nil` elements.
     */
    package static func create() -> Pair<F, S> {
        return Pair<F, S>()
    }

    /**
     * Constructs a pair given both elements.
     */
    package static func of(_ first: F, _ second: S) -> Pair<F, S> {
        return Pair<F, S>(first: first, second: second)
    }

    /**
     * Constructs a list of pairs from the entries of a dictionary.
     */
    package static func fromMap<G, T>(_ map: [G: T]) -> [Pair<G, T>] {
        var list = [Pair<G, T>]()
        list.reserveCapacity(map.count)
        for (key, value) in map {
            list.append(Pair<G, T>(key: key, value: value))
        }
        return list
    }

    /**
     * Comparator that uses the first element as base.
     */
    package struct FirstComparator {
        package static func compare(_ o1: Pair<F, S>, _ o2: Pair<F, S>) -> ComparisonResult {
            if o1.first == nil && o2.first == nil { return .orderedSame }
            if o1.first == nil { return .orderedAscending }
            if o2.first == nil { return .orderedDescending }
            return .orderedSame
        }
    }

    package struct SecondComparator {
        package static func compare(_ o1: Pair<F, S>, _ o2: Pair<F, S>) -> ComparisonResult {
            if o1.second == nil && o2.second == nil { return .orderedSame }
            if o1.second == nil { return .orderedAscending }
            if o2.second == nil { return .orderedDescending }
            return .orderedSame
        }
    }

    /** the first element. */
    package var first: F?
    /** the second element. */
    package var second: S?

    /**
     * Constructs a pair with `nil` elements.
     */
    package init() {
    }

    /**
     * Constructs a pair given both elements.
     */
    package init(first: F, second: S) {
        self.first = first
        self.second = second
    }

    /**
     * Convenience positional initializer.
     */
    package convenience init(_ first: F, _ second: S) {
        self.init(first: first, second: second)
    }

    /**
     * Constructs a pair from a dictionary entry.
     */
    package init(key: F, value: S) {
        self.first = key
        self.second = value
    }

    package func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Pair<F, S> else { return false }
        let firstEqual: Bool
        if self.first == nil && other.first == nil {
            firstEqual = true
        } else if let sf = self.first, let of_ = other.first {
            firstEqual = String(describing: sf) == String(describing: of_)
        } else {
            firstEqual = false
        }
        let secondEqual: Bool
        if self.second == nil && other.second == nil {
            secondEqual = true
        } else if let ss = self.second, let os = other.second {
            secondEqual = String(describing: ss) == String(describing: os)
        } else {
            secondEqual = false
        }
        return firstEqual && secondEqual
    }

    var hash: Int {
        var hasher = Hasher()
        if let f = first {
            hasher.combine(String(describing: f))
        }
        if let s = second {
            hasher.combine(String(describing: s))
        }
        return hasher.finalize()
    }

    var description: String {
        if first == nil, second == nil {
            return "pair(nil, nil)"
        } else if first == nil {
            return "pair(nil, \(String(describing: second)))"
        } else if second == nil {
            return "pair(\(String(describing: first)), nil)"
        } else {
            return "pair(\(String(describing: first)), \(String(describing: second)))"
        }
    }

    /**
     * Sets the first element.
     */
    package func setFirst(_ value: F) {
        self.first = value
    }

    /**
     * Returns the first element.
     */
    package func getFirst() -> F? {
        return first
    }

    /**
     * Sets the second element.
     */
    package func setSecond(_ value: S) {
        self.second = value
    }

    /**
     * Returns the second element.
     */
    package func getSecond() -> S? {
        return second
    }

    package func next() -> Any? {
        if let f = first {
            first = nil
            return f
        } else if let s = second {
            second = nil
            return s
        }
        return nil
    }

    /**
     * Clear any contained object, both the first and the second.
     */
    package func clear() {
        first = nil
        second = nil
    }

}
