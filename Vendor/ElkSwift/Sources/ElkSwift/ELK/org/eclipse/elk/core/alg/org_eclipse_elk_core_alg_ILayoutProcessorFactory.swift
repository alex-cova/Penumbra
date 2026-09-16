// Copyright (c) 2017 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0


/**
 * Classes that implement this protocol can create layout processors.
 *
 * <p>
 * The usual way is to have an enumeration of all available processors implement this protocol and instantiate the
 * correct one depending on which enumeration case the method was called on.
 * </p>
 *
 * @param G type of the graph the created processor will operate on.
 * @see ILayoutProcessor
 */
package protocol ILayoutProcessorFactory {

    associatedtype G

    /**
     * Returns an implementation of `ILayoutProcessor`. The actual implementation returned depends on the actual
     * type that implements this method.
     *
     * @return new layout processor.
     */
    func create() -> any ILayoutProcessor
}
