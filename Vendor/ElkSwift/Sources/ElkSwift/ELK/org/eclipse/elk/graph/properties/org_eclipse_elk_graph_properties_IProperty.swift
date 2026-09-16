// Copyright (c) 2009, 2015 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0


/**
 * Interface for property identifiers.
 */
package protocol IProperty: AnyObject {

    /// Returns the default value of this property.
    var defaultValue: Any? { get }

    /// Returns an identifier string for this property.
    var id: String { get }
}

/// Default implementation
package extension IProperty {
    var defaultValue: Any? { return nil }
}
