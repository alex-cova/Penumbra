// Copyright (c) 2010, 2015 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0


/// Definition of the edge types. To be accessed using `CoreOptions.EDGE_TYPE`.
package enum EdgeType {
    /// no special type.
    case none
    /// the edge is directed.
    case directed
    /// the edge is undirected.
    case undirected
    /// the edge represents an association.
    case association
    /// the edge represents a generalization.
    case generalization
    /// the edge represents a dependency.
    case dependency
}
