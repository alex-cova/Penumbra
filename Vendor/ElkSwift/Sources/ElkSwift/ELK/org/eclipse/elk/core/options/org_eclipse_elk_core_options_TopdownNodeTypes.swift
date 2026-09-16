// Copyright (c) 2022 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0


/**
 * For general purpose topdown layout these node types specify how a node should be handled.
 * These properties only have an effect when `CoreOptions.TOPDOWN_LAYOUT` is set to true.
 */
package enum TopdownNodeTypes {
    
    /**
     * A parallel node is a node whose layout is not scaled down to fit a fixed size. The parallel node's own 
     * size must be set according to the pre-computed required size of the contained layout. A parallel node must
     * use an `ITopdownLayoutProvider` so that its size can be correctly predicted during layout.
     */
    case PARALLEL_NODE
    
    /**
     * A hierarchical node is a node whose layout will be scaled down to fit the fixed size of the hierarchical node.
     * The fixed size of the node is defined by `CoreOptions.TOPDOWN_HIERARCHICAL_NODE_WIDTH` and 
     * `CoreOptions.TOPDOWN_HIERARCHICAL_NODE_ASPECT_RATIO`.
     */
    case HIERARCHICAL_NODE
    
    /**
     * The root node marks the root of the diagram, its child should be a single parallel node which is the visual
     * root of the diagram.
     */
    case ROOT_NODE

}
