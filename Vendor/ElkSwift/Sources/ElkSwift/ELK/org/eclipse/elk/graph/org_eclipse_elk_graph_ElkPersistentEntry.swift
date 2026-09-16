/**
 * Copyright (c) 2016 Kiel University and others.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 */

import Foundation

/**
 * A representation of the model object '<em><b>Elk Persistent Entry</b></em>'.
 *
 * <p>
 * The following features are supported:
 * </p>
 * <ul>
 *   <li>{@link #key <em>Key</em>}</li>
 *   <li>{@link #value <em>Value</em>}</li>
 * </ul>
 */
package protocol ElkPersistentEntry: EObject {
    /// Returns the value of the '<em><b>Key</b></em>' attribute.
    var key: String { get set }
    
    /// Returns the value of the '<em><b>Value</b></em>' attribute.
    var value: String { get set }
}
