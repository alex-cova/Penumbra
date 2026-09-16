// Copyright (c) 2009, 2015 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0

import Foundation

/**
 * Definition of a property that can be set on an `IPropertyHolder`.
 */
package final class Property<T>: IProperty {

    package let id: String
    package let defaultValue: Any?

    package init(_ theid: String) {
        self.id = theid
        self.defaultValue = nil
    }

    package init(_ theid: String, _ thedefaultValue: T) {
        self.id = theid
        self.defaultValue = thedefaultValue
    }

    package init(_ theid: String, defaultValue thedefaultValue: T) {
        self.id = theid
        self.defaultValue = thedefaultValue
    }

    package init(_ other: IProperty, _ thedefaultValue: T) {
        self.id = other.id
        self.defaultValue = thedefaultValue
    }

    /// Convenience init with just a default value (used for inline property declarations)
    package init(defaultValue thedefaultValue: T) {
        self.id = ""
        self.defaultValue = thedefaultValue
    }

    package func getDefault() -> T? {
        return defaultValue as? T
    }

    package var description: String {
        return id
    }
}
