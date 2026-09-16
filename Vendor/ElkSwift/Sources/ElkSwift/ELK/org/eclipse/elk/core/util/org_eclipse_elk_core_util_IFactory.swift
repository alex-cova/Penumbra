// Copyright (c) 2011, 2015 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0


/**
 * Interface for factories of class instances.
 *
 * In Java this was generic with type parameter T. In Swift, we use Any
 * since this protocol is used as an existential type in several places.
 *
 * @author msp
 */
package protocol IFactory: AnyObject {

    /**
     * Create an instance of the type that is managed by this factory.
     *
     * @return a new instance
     */
    func create() -> Any

    /**
     * Destroy a given instance by freeing all resources that are contained.
     *
     * @param obj the instance to destroy
     */
    func destroy(_ obj: Any)
}
