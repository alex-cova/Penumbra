// Copyright (c) 2016, 2020 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0


/// Options for setting how children of nodes should be handled in the current layout run.
///
/// The basic idea is this: If you want nodes to be laid out together across hierarchy levels, set hierarchy handling to
/// `.includeChildren` on all nodes that should be laid out in one go. As soon as a node's content should be laid
/// out in a separate layout run, set the node's hierarchy handling to `.separateChildren`.
///
/// If the layout algorithm doesn't support hierarchical layout, this property is ignored and the layout is calculated
/// separately for each child hierarchy.
///
/// Note: Layout algorithms only need to differentiate between `.includeChildren` and
/// `.separateChildren` as `.inherit` is evaluated and set to the appropriate more specific value by ELK.
package enum HierarchyHandling {
    /// Inherit the parent node's hierarchy handling. The root node has no parent node; here, this setting defaults to
    /// `.separateChildren`.
    case inherit

    /// Allows the node's children to be included in the current layout run. Which children are included in the layout
    /// run is determined by their hierarchy handling setting. For a child to actually be included, its hierarchy
    /// handling must be set to either `.inherit` or `.includeChildren`.
    case includeChildren

    /// Lays out the node with a new layout run. Even if its parent node is set to `.includeChildren`, this node
    /// will trigger a separate layout run and will thus not be included in the parent node's layout run.
    case separateChildren

    // MARK: - Uppercase Aliases (Java compatibility)
    package static let INHERIT = HierarchyHandling.inherit
    package static let INCLUDE_CHILDREN = HierarchyHandling.includeChildren
    package static let SEPARATE_CHILDREN = HierarchyHandling.separateChildren
}
