/**
 * Copyright (c) 2016 Kiel University and others.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 */

// Note: This is a Swift translation of the Java interface. Since Swift does not have direct equivalents for EMF (Eclipse Modeling Framework) constructs like EClass, EAttribute, etc., this translation assumes a simplified structure using Swift protocols and types to represent the core concepts. In a real-world scenario, you would need to implement or use a Swift-based EMF-like framework.

import Foundation

// MARK: - Model Interfaces
// MARK: - Property and Value Types
package typealias PropertyValue = Any

// MARK: - Factory Protocol
// MARK: - Package Protocol

package protocol ElkGraphPackage: EPackage {
    static var eNAME: String { get }
    static var eNS_URI: String { get }
    static var eNS_PREFIX: String { get }
    static var eINSTANCE: ElkGraphPackage { get }
    
    // Meta object IDs
    static var IPROPERTY_HOLDER: Int { get }
    static var EMAP_PROPERTY_HOLDER: Int { get }
    static var ELK_GRAPH_ELEMENT: Int { get }
    static var ELK_SHAPE: Int { get }
    static var ELK_LABEL: Int { get }
    static var ELK_CONNECTABLE_SHAPE: Int { get }
    static var ELK_NODE: Int { get }
    static var ELK_PORT: Int { get }
    static var ELK_EDGE: Int { get }
    static var ELK_BEND_POINT: Int { get }
    static var ELK_EDGE_SECTION: Int { get }
    static var ELK_PROPERTY_TO_VALUE_MAP_ENTRY: Int { get }
    static var IPROPERTY: Int { get }
    static var PROPERTY_VALUE: Int { get }
    
    // Class accessors
    func getIPropertyHolder() -> EClass
    func getEMapPropertyHolder() -> EClass
    func getEMapPropertyHolder_Properties() -> EReference
    func getElkGraphElement() -> EClass
    func getElkGraphElement_Labels() -> EReference
    func getElkGraphElement_Identifier() -> EAttribute
    func getElkShape() -> EClass
    func getElkShape_Height() -> EAttribute
    func getElkShape_Width() -> EAttribute
    func getElkShape_X() -> EAttribute
    func getElkShape_Y() -> EAttribute
    func getElkLabel() -> EClass
    func getElkLabel_Parent() -> EReference
    func getElkLabel_Text() -> EAttribute
    func getElkConnectableShape() -> EClass
    func getElkConnectableShape_OutgoingEdges() -> EReference
    func getElkConnectableShape_IncomingEdges() -> EReference
    func getElkNode() -> EClass
    func getElkNode_Ports() -> EReference
    func getElkNode_Children() -> EReference
    func getElkNode_Parent() -> EReference
    func getElkNode_ContainedEdges() -> EReference
    func getElkNode_Hierarchical() -> EAttribute
    func getElkPort() -> EClass
    func getElkPort_Parent() -> EReference
    func getElkEdge() -> EClass
    func getElkEdge_ContainingNode() -> EReference
    func getElkEdge_Sources() -> EReference
    func getElkEdge_Targets() -> EReference
    func getElkEdge_Sections() -> EReference
    func getElkEdge_Hyperedge() -> EAttribute
    func getElkEdge_Hierarchical() -> EAttribute
    func getElkEdge_Selfloop() -> EAttribute
    func getElkEdge_Connected() -> EAttribute
    func getElkBendPoint() -> EClass
    func getElkBendPoint_X() -> EAttribute
    func getElkBendPoint_Y() -> EAttribute
    func getElkEdgeSection() -> EClass
    func getElkEdgeSection_StartX() -> EAttribute
    func getElkEdgeSection_StartY() -> EAttribute
    func getElkEdgeSection_EndX() -> EAttribute
    func getElkEdgeSection_EndY() -> EAttribute
    func getElkEdgeSection_BendPoints() -> EReference
    func getElkEdgeSection_Parent() -> EReference
    func getElkEdgeSection_OutgoingShape() -> EReference
    func getElkEdgeSection_IncomingShape() -> EReference
    func getElkEdgeSection_OutgoingSections() -> EReference
    func getElkEdgeSection_IncomingSections() -> EReference
    func getElkEdgeSection_Identifier() -> EAttribute
    func getElkPropertyToValueMapEntry() -> EClass
    func getElkPropertyToValueMapEntry_Key() -> EAttribute
    func getElkPropertyToValueMapEntry_Value() -> EAttribute
    func getIProperty() -> EDataType
    func getPropertyValue() -> EDataType
    func getElkGraphFactory() -> ElkGraphFactory
    
    // Literals — not used in Swift port
}

// MARK: - EAttribute, EReference, EDataType Protocols (Simplified)
// NOTE: EPackage and EClass are defined in JavaCompat.swift

package protocol EAttribute {
    // Represents an attribute in the EMF model
}

package protocol EReference {
    // Represents a reference in the EMF model
}

package protocol EDataType {
    // Represents a data type in the EMF model
    func classifierID() -> Int
    func name() -> String
}

extension EDataType {
    package func classifierID() -> Int { return -1 }
    package func name() -> String { return "" }
}

// MARK: - Literals Protocol

// Literals are not used in the Swift port - they were EMF-specific metadata
package protocol ElkGraphPackageLiterals {
    // Meta object literals for classes, features, and data types
}
