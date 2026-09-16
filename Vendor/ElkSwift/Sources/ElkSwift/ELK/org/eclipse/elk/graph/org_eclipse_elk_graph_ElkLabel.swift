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
 * A representation of the model object '<em><b>Elk Label</b></em>'.
 *
 * Labels are used to associate graph elements with text to be displayed in a diagram. The element the label annotates is its parent element.
 *
 * The following features are supported:
 * - `parent`: Graph element the label annotates.
 * - `text`: The label's text.
 */
package protocol ElkLabel: ElkShape {
    
    /// Graph element the label annotates.
    ///
    /// Setting the parent element automatically updates its list of labels.
    var parent: ElkGraphElement? { get set }
    
    /// The label's text.
    var text: String { get set }
}
