/**
 * Copyright (c) 2016 Kiel University and others.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 */


/**
 * A property holder implementation based on `EMap` which can be used in Ecore models.
 *
 * This property holder implementation currently has two ways for saving properties: a map of properties as well as a map of *persistent entries*. Persistent entries are String-String pairs containing String representations of properties. When a graph is serialized, it is the persistent entries that get serialized, not the properties themselves. This has two implications. First, to save a graph, one has to call `makePersistent()` first. Second, after loading a graph, one of the methods in `GraphDataUtil` needs to be called to turn persistent entries back into usable properties.
 *
 * The following features are supported:
 * - `properties`: Map of properties configured for this property holder.
 */
package protocol EMapPropertyHolder: EObject, IPropertyHolder {
    /// Map of properties configured for this property holder.
    var properties: [String: Any] { get }
}
