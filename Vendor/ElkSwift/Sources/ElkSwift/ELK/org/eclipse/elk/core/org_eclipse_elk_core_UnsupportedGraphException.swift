// Copyright (c) 2011, 2015 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0


/**
 * Thrown when a layout algorithm is executed on a graph that is not supported.
 *
 * @author msp
 */
package class UnsupportedGraphException: RuntimeException {

    /** the serial version UID. */
    package static let serialVersionUID: Int64 = 669762537737088914

    /**
     * Create an unsupported graph exception with no parameters.
     */
    package override init(_ message: String = "") {
        super.init(message)
    }
}
