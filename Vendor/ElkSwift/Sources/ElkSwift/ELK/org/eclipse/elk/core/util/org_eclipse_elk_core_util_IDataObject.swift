// Copyright (c) 2010, 2015 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0


import Foundation;

/**
 * An interface for data types, which should be serializable using `description` and
 * parsable using `parse(_:)`. The default initializer must always be
 * accessible and create an instance with default content.
 *
 * @author msp
 */
package protocol IDataObject: Serializable {
    
    /**
     * Parse the given string and set the content of this data object.
     * 
     * @param string a string
     * @throws IllegalArgumentException if the string does not have the expected format
     */
    func parse(_ string: String) throws
}
