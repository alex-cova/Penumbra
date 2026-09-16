import Foundation

/**
 * A property holder which can be used to define individual spacing overrides. The overrides are applied to the
 * element this object is set on, which is done through the `CoreOptions.SPACING_INDIVIDUAL` property.
 */
package class IndividualSpacings: MapPropertyHolder, IDataObject {
    
    /** Serialization identifier. */
    package static let serialVersionUID: Int64 = 737614242607924309
    
    /**
     * Constructs an empty spacings container.
     */
    package override init() {
        super.init()
    }
    
    /**
     * Constructs a new spacings container and copies all properties of `other` to the new container.
     */
    package init(_ other: IndividualSpacings) {
        super.init()
        for (key, value) in other.getAllProperties() {
            setProperty(key, value)
        }
    }
    
    /**
     * Returns the value of the given property as it applies to the given node. First checks whether an individual
     * override is set on the node that has the given property configured. If so, the configured value is returned.
     * Otherwise, the node's parent node, if any, is queried.
     *
     * - Parameters:
     *   - node: the node whose property value to return.
     *   - property: the property.
     * - Returns: the individual override for the property or the default value inherited by the parent node.
     */
    package static func getIndividualOrInherited(_ node: ElkNode, _ property: IProperty) -> Any? {
        var result: Any? = nil
        
        if node.hasProperty(CoreOptions.SPACING_INDIVIDUAL) {
            if let individualSpacings = node.getProperty(CoreOptions.SPACING_INDIVIDUAL) as? IPropertyHolder,
               individualSpacings.hasProperty(property) {
                result = individualSpacings.getProperty(property)
            }
        }
        
        // use the common value
        if result == nil, let parent = node.parent {
            result = parent.getProperty(property)
        }
        
        return result
    }
    
    /**
     * Returns the value of the given property as it applies to the given node. First checks whether an individual
     * override is set on the node that has the given property configured. If so, the configured value is returned.
     * Otherwise, the graph the node is part of, if any, is queried.
     *
     * - Parameters:
     *   - node: the node whose property value to return.
     *   - property: the property.
     * - Returns: the individual override for the property or the default value inherited by the parent node.
     */
    package static func getIndividualOrInherited(_ node: NodeAdapterProtocol, _ property: IProperty) -> Any? {
        var result: Any? = nil
        
        if node.hasProperty(CoreOptions.SPACING_INDIVIDUAL) {
            if let individualSpacings = node.getProperty(CoreOptions.SPACING_INDIVIDUAL) as? IPropertyHolder,
               individualSpacings.hasProperty(property) {
                result = individualSpacings.getProperty(property)
            }
        }
        
        // use the common value
        if result == nil, let graph = node.graph {
            result = graph.getProperty(property)
        }
        
        // if the result is still nil, we need the property's default value
        if result == nil {
            result = property.defaultValue
        }
        
        return result
    }
    
    /**
     * Returns the value of the given property as it applies to the given node adapter. First checks whether an
     * individual override is set on the node that has the given property configured. If so, the configured value
     * is returned. Otherwise, the node's parent graph, if any, is queried.
     */
    package static func getIndividualOrInherited(_ node: NodeAdapter, _ property: IProperty) -> Any? {
        var result: Any? = nil

        if node.hasProperty(CoreOptions.SPACING_INDIVIDUAL) {
            if let individualSpacings: IPropertyHolder = node.getProperty(CoreOptions.SPACING_INDIVIDUAL),
               individualSpacings.hasProperty(property) {
                result = individualSpacings.getProperty(property)
            }
        }

        // use the common value from the parent graph
        if result == nil, let graph = node.getGraph() {
            result = graph.getProperty(property) as Any?
        }

        // if the result is still nil, use the property's default value
        if result == nil {
            result = property.defaultValue
        }

        return result
    }

    /** A (hopefully) unique separator that allows single occurrences of commas, colons, and semi-colons in-between. */
    package static let serializedOptionSeparator = ";,;"
    
    /**
     * {@inheritDoc}
     */
    package func toString() -> String {
        let serialized = getAllProperties().map { entry in
            entry.key + ":" + String(describing: entry.value)
        }.joined(separator: IndividualSpacings.serializedOptionSeparator)
        return serialized
    }
    
    /**
     * {@inheritDoc}
     */
    package func parse(_ string: String) throws {
        guard !string.isEmpty else { return }

        let options = string.components(separatedBy: IndividualSpacings.serializedOptionSeparator)
        for optionString in options {
            let parts = optionString.components(separatedBy: ":")
            guard parts.count == 2 else {
                throw ELK.Error.runtimeError("Invalid option format: \(optionString)")
            }

            let id = parts[0]
            let valueString = parts[1]

            guard let optionData = LayoutMetaDataService.instance.getOptionData(bySuffix: id) else {
                throw ELK.Error.runtimeError("Invalid option id: \(id)")
            }

            guard let value = optionData.parseValue(valueString) else {
                throw ELK.Error.runtimeError("Invalid option value: \(valueString)")
            }

            setProperty(optionData, value)
        }
    }
}

// MARK: - Supporting Types and Protocols (Stubs for completeness)
package protocol NodeAdapterProtocol {
    func hasProperty(_ property: IProperty) -> Bool
    func getProperty(_ property: IProperty) -> Any?
    func setProperty(_ property: IProperty, _ value: Any?)
    var graph: ElkGraph? { get }
    var position: KVector { get set }
    var size: KVector { get set }
    func getPosition() -> KVector
    func setPosition(_ pos: KVector)
    func getSize() -> KVector
    func setSize(_ size: KVector)
    var labels: [Any] { get }
    func getLabels() -> [Any]
    var ports: [Any] { get }
    func getPorts() -> [Any]
    func isCompoundNode() -> Bool
    func getVolatileId() -> Int
    func setVolatileId(_ id: Int)
    var margin: ElkMargin { get set }
    func getMargin() -> ElkMargin
    func setMargin(_ margin: ElkMargin)
    var padding: ElkPadding { get set }
    func getPadding() -> ElkPadding
    func setPadding(_ padding: ElkPadding)
    func getIncomingEdges() -> [Any]
    func getOutgoingEdges() -> [Any]
    func sortPortList()
}
package protocol ElkGraph {
    func hasProperty(_ property: IProperty) -> Bool
    func getProperty(_ property: IProperty) -> Any?
}

// MARK: - Mocked External Types (for completeness)


package struct IPropertyKey<T> {
    package let id: String
}
