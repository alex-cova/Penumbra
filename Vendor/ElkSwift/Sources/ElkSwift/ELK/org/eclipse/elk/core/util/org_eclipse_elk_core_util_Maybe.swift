/*******************************************************************************
 * Copyright (c) 2009, 2015 Kiel University and others.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 *******************************************************************************/


/**
 * Object that may contain another object, inspired by the Haskell type Maybe.
 *
 * This class can be used to wrap objects for anonymous classes, or as a wrapper
 * for synchronization on objects that may be nil.
 *
 * - Parameter T: type of contained object
 */
package final class Maybe<T: Hashable>: CustomStringConvertible, Hashable {

    /**
     * Create a maybe with inferred generic type.
     *
     * - Returns: a new instance of given type
     */
    package static func create<D: Hashable>() -> Maybe<D> {
        return Maybe<D>()
    }

    /** the contained object, which may be nil. */
    package var object: T?

    /**
     * Creates a maybe without an object.
     */
    package init() {
        self.object = nil
    }

    /**
     * Creates a maybe with the given object.
     *
     * - Parameter theobject: the object to contain
     */
    package init(_ theobject: T) {
        self.object = theobject
    }

    package static func == (lhs: Maybe<T>, rhs: Maybe<T>) -> Bool {
        if lhs.object == nil {
            return rhs.object == nil
        } else {
            return lhs.object == rhs.object
        }
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(object)
    }

    package var description: String {
        if let obj = object {
            return "maybe(\(obj))"
        } else {
            return "maybe(nil)"
        }
    }

    /**
     * Sets the contained object.
     *
     * - Parameter theobject: the object to set
     */
    package func set(_ theobject: T) {
        self.object = theobject
    }

    /**
     * Returns the contained object.
     *
     * - Returns: the contained object
     */
    package func get() -> T? {
        return object
    }

    // Iterator-like conformance
    package func hasNext() -> Bool {
        return object != nil
    }

    package func next() -> T? {
        defer { object = nil }
        return object
    }

    /**
     * Clear any contained object.
     */
    package func clear() {
        object = nil
    }

    /**
     * Determine whether any object is contained.
     *
     * - Returns: false if an object instance is contained, true otherwise
     */
    package func isEmpty() -> Bool {
        return object == nil
    }

}
