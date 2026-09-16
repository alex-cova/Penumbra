/*******************************************************************************
 * Copyright (c) 2015, 2020 Kiel University and others.
 * 
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 *******************************************************************************/

// Note: This is a partial translation assuming the existence of corresponding Swift modules
// for the graph structures and utility classes. The original Java code relies on specific
// libraries (e.g., ELK graph, Guava) which do not have direct Swift equivalents.

import Foundation

// MARK: - Protocol Definitions
// MARK: - Generic Property Types
// MARK: - Graph Element Types (Stubs for illustration)
// MARK: - Layout Option Data and Service (Stubs)
// MARK: - Main Class

/**
 * A layout configurator is a graph element visitor that applies layout option values. It can be
 * used to modify the layout configuration of a graph after it has been created, e.g. in order to
 * apply multiple layouts with different configurations. Create an instance and then use one of the
 * `configure(_:)` methods to obtain a property holder that can be filled with values for
 * layout options.
 */
package class LayoutConfigurator: IGraphElementVisitor {
    
    /**
     * Property attached to the shape layout of the top-level `ElkNode` holding a reference
     * to an additional layout configurator that shall be applied for the remaining iterations.
     */
    package static let ADD_LAYOUT_CONFIG = Property<LayoutConfigurator>("org.eclipse.elk.addLayoutConfig")
    
    package var elementOptionMap: [ObjectIdentifier: MapPropertyHolder] = [:]
    package var classOptionMap: [ObjectIdentifier: MapPropertyHolder] = [:]
    package var clearLayout: Bool = false
    package var optionFilters: [IOptionFilter] = []
    
    /**
     * Functional interface that allows to specify whether a certain property should be set for a certain graph element.
     */
    package struct IOptionFilter {
        let accept: (ElkGraphElement, IProperty) -> Bool
        
        init(_ accept: @escaping (ElkGraphElement, IProperty) -> Bool) {
            self.accept = accept
        }
        
        package func callAsFunction(_ e: ElkGraphElement, _ p: IProperty) -> Bool {
            accept(e, p)
        }
    }
    
    /**
     * Functional interface that allows to specify whether a certain property should be set for a certain property
     * holder.
     */
    package struct IPropertyHolderOptionFilter {
        let accept: (IPropertyHolder, IProperty) -> Bool
        
        init(_ accept: @escaping (IPropertyHolder, IProperty) -> Bool) {
            self.accept = accept
        }
        
        package func callAsFunction(_ holder: IPropertyHolder, _ property: IProperty) -> Bool {
            accept(holder, property)
        }
    }

    /**
     * Generic filter that prevents the `LayoutConfigurator` from overwriting layout options that are 
     * already set for a graph element.
     */
    package static let NO_OVERWRITE_HOLDER = IPropertyHolderOptionFilter { holder, p in
        !holder.hasProperty(p)
    }
    
    /**
     * Generic filter that prevents the `LayoutConfigurator` from overwriting layout options that are 
     * already set for a graph element.
     */
    package static let NO_OVERWRITE = IOptionFilter { e, p in
        !e.hasProperty(p)
    }
    
    /**
     * A filter that checks for each option whether its configured targets match the input element.
     */
    package static let OPTION_TARGET_FILTER = IOptionFilter { e, property in
        let optionData = LayoutMetaDataService.getInstance().getOptionData(property.id)
        if let data = optionData {
            let targets = data.getTargets()
            switch e {
            case let node as ElkNode:
                if !node.isHierarchical() {
                    return targets.contains(.NODES)
                } else {
                    return targets.contains(.NODES) || targets.contains(.PARENTS)
                }
            case is ElkEdge:
                return targets.contains(.EDGES)
            case is ElkPort:
                return targets.contains(.PORTS)
            case is ElkLabel:
                return targets.contains(.LABELS)
            default:
                return true
            }
        }
        return true
    }

    /**
     * Whether to clear the layout of each graph element before the new configuration is applied.
     */
    package func isClearLayout() -> Bool {
        return clearLayout
    }
    
    /**
     * Set whether to clear the layout of each graph element before the new configuration is applied
     * (the default is `false`).
     * 
     * @return `self`
     */
    package func setClearLayout(_ doClearLayout: Bool) -> LayoutConfigurator {
        self.clearLayout = doClearLayout
        return self
    }
    
    /**
     * Adds a filter that is queried for each combination of graph elements and options. An option
     * value is applied only if the filter matches. If no filter is set, all values are applied.
     * 
     * @return `self`
     */
    @discardableResult
    package func addFilter(_ filter: IOptionFilter) -> LayoutConfigurator {
        self.optionFilters.append(filter)
        return self
    }
    
    /**
     * Returns the list of filters that have been added via `addFilter(_:)` or have been inherited
     * from another `LayoutConfigurator` via `overrideWith(_:)`.
     */
    package func getFilters() -> [IOptionFilter] {
        return optionFilters
    }
    
    /**
     * Add and return a property holder for the given element. If such a property holder is
     * already present, the previous instance is returned.
     */
    package func configure(_ element: ElkGraphElement) -> IPropertyHolder {
        if let result = elementOptionMap[ObjectIdentifier(element as AnyObject)] {
            return result
        } else {
            let result = MapPropertyHolder()
            elementOptionMap[ObjectIdentifier(element as AnyObject)] = result
            return result
        }
    }
    
    /**
     * Return the stored property holder for the given element, or `nil` if none is present.
     */
    package func getProperties(_ element: ElkGraphElement) -> IPropertyHolder? {
        return elementOptionMap[ObjectIdentifier(element as AnyObject)]
    }
    
    /**
     * Add and return a property holder for the given element class. If such a property holder is
     * already present, the previous instance is returned.
     */
    package func configure<T: ElkGraphElement>(_ elementClass: T.Type) -> IPropertyHolder {
        let key = ObjectIdentifier(T.self)
        if let result = classOptionMap[key] {
            return result
        } else {
            let result = MapPropertyHolder()
            classOptionMap[key] = result
            return result
        }
    }
    
    /**
     * Return the stored property holder for the given element class, or `nil` if none is present.
     */
    package func getProperties<T: ElkGraphElement>(_ elementClass: T.Type) -> IPropertyHolder? {
        let key = ObjectIdentifier(T.self)
        return classOptionMap[key]
    }

    /**
     * Apply this layout configurator to the given graph element.
     */
    package func visit(_ element: ElkGraphElement) {
        if clearLayout {
            // In Java, this clears all properties from the element.
            // No direct equivalent on the protocol; skip for now.
        }
        let combined = findClassOptions(for: element)
        combined.copyProperties(from: getProperties(element) ?? MapPropertyHolder())
        applyProperties(to: element, with: combined)
    }
    
    /**
     * Apply all properties held in `properties` to `element`.
     */
    package func applyProperties(to element: ElkGraphElement, with properties: IPropertyHolder?) {
        guard let properties = properties else { return }
        
        let filters = getFilters()
        for (propertyId, value) in properties.getAllProperties() {
            let propertyKey = Property<Any>(propertyId)
            let accept = filters.allSatisfy { $0(element, propertyKey) }
            if accept {
                element.setProperty(propertyKey, value: value)
            }
        }
    }
    
    /**
     * To allow the configuration of layout options using interfaces and super-interfaces, we have to manually check the
     * type hierarchy when visiting a graph element. Since KGraph's type hierarchy is quite small, we do this case by
     * case. The order of the cases is important, since configurations for more specific types should override the
     * general case.
     * 
     * @return the most specific `MapPropertyHolder` fitting the passed `element`'s type.
     */
    package func findClassOptions(for element: ElkGraphElement) -> MapPropertyHolder {
        var combined = MapPropertyHolder()
        
        if element is ElkGraphElement {
            combined.copyProperties(from: classOptionMap[ObjectIdentifier(ElkGraphElement.self)] ?? MapPropertyHolder())
        }
        
        if element is ElkShape {
            combined.copyProperties(from: classOptionMap[ObjectIdentifier(ElkShape.self)] ?? MapPropertyHolder())
        }
        
        if element is ElkLabel {
            combined.copyProperties(from: classOptionMap[ObjectIdentifier(ElkLabel.self)] ?? MapPropertyHolder())
            return combined
        }
        
        if element is ElkConnectableShape {
            combined.copyProperties(from: classOptionMap[ObjectIdentifier(ElkConnectableShape.self)] ?? MapPropertyHolder())
        }
        
        if element is ElkNode {
            combined.copyProperties(from: classOptionMap[ObjectIdentifier(ElkNode.self)] ?? MapPropertyHolder())
            return combined
        }
        
        if element is ElkPort {
            combined.copyProperties(from: classOptionMap[ObjectIdentifier(ElkPort.self)] ?? MapPropertyHolder())
            return combined
        }
        
        if element is ElkEdge {
            combined.copyProperties(from: classOptionMap[ObjectIdentifier(ElkEdge.self)] ?? MapPropertyHolder())
        }
        
        return combined
    }
    
    /**
     * Copy all options from the given configurator to this one, possibly overriding the own options. The
     * `IOptionFilter`s of this configurator are cleared and filled with the filters of `other`.
     * 
     * @return `self`
     */
    package func overrideWith(_ other: LayoutConfigurator) -> LayoutConfigurator {
        for (key, value) in other.elementOptionMap {
            if let thisHolder = elementOptionMap[key] {
                thisHolder.copyProperties(from: value)
            } else {
                let newHolder = MapPropertyHolder()
                newHolder.copyProperties(from: value)
                elementOptionMap[key] = newHolder
            }
        }
        
        for (key, value) in other.classOptionMap {
            if let thisHolder = classOptionMap[key] {
                thisHolder.copyProperties(from: value)
            } else {
                let newHolder = MapPropertyHolder()
                newHolder.copyProperties(from: value)
                classOptionMap[key] = newHolder
            }
        }
        
        clearLayout = other.clearLayout
        optionFilters = other.optionFilters
        
        return self
    }
}
