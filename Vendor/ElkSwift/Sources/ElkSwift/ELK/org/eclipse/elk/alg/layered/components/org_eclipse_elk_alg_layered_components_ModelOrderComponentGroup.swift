/*******************************************************************************
 * Copyright (c) 2022 Kiel University and others.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 *******************************************************************************/

/**
 * Model order component group that saves additionally to the port side the order of the components.
 */
package class ModelOrderComponentGroup: ComponentGroup {

    /**
     * Update constraints map with all constraints that occur if the key is inserted in a component group with the
     * value already in it. This contains only additional sides to the CONSTRAINTS of the super class.
     */
    package static let modelOrderConstraints: [Set<PortSide>: [Set<PortSide>]] = {
        var map: [Set<PortSide>: [Set<PortSide>]] = [:]

        func add(_ key: Set<PortSide>, _ values: Set<PortSide>...) {
            map[key, default: []].append(contentsOf: values)
        }

        // Key is inserted in component group with value
        add(.north, .none)
        add(.west, .none)
        add(.northEast, .none)
        add(.northWest, .none)
        add(.northSouthWest, .none)
        add(.northEastWest, .none)

        add(.northWest, .north)

        add(.none, .east)
        add(.north, .east)
        add(.west, .east)
        add(.northEast, .east)
        add(.northSouth, .east)
        add(.northWest, .east)
        add(.northSouthWest, .east)
        add(.northEastWest, .east)
        add(.eastWest, .east)

        add(.none, .south)
        add(.north, .south)
        add(.east, .south)
        add(.west, .south)
        add(.northEast, .south)
        add(.northSouth, .south)
        add(.northWest, .south)
        add(.eastWest, .south)
        add(.southWest, .south)
        add(.northSouthWest, .south)
        add(.northEastSouth, .south)
        add(.northEastWest, .south)

        add(.north, .west)
        add(.northEast, .west)
        add(.northWest, .west)
        add(.northEastWest, .west)

        add(.north, .northEast)
        add(.west, .northEast)
        add(.northWest, .northEast)
        add(.northEast, .northEast)
        add(.northSouthWest, .northEast)

        // NW has nothing since it is in the first slot

        // Only conflicts since it is in the last slot
        add(.none, .eastSouth)
        add(.north, .eastSouth)
        add(.east, .eastSouth)
        add(.south, .eastSouth)
        add(.west, .eastSouth)
        add(.northEast, .eastSouth)
        add(.northSouth, .eastSouth)
        add(.northWest, .eastSouth)
        add(.southWest, .eastSouth)
        add(.eastWest, .eastSouth)
        add(.northEastWest, .eastSouth)
        add(.northSouthWest, .eastSouth)
        add(.northEastSouthWest, .eastSouth)

        add(.none, .southWest)
        add(.north, .southWest)
        add(.east, .southWest)
        add(.west, .southWest)
        add(.northEast, .southWest)
        add(.northSouth, .southWest)
        add(.northWest, .southWest)
        add(.eastWest, .southWest)
        add(.northEastWest, .southWest)
        add(.northEastSouth, .southWest)
        add(.northEastSouthWest, .southWest)

        add(.north, .eastWest)
        add(.west, .eastWest)
        add(.northEast, .eastWest)
        add(.northWest, .eastWest)
        add(.southWest, .eastWest)
        add(.northEastWest, .eastWest)
        add(.northSouthWest, .eastWest)

        // NEW no additional conflicts

        add(.none, .eastSouthWest)
        add(.north, .eastSouthWest)
        add(.east, .eastSouthWest)
        add(.west, .eastSouthWest)
        add(.northEast, .eastSouthWest)
        add(.northSouth, .eastSouthWest)
        add(.northWest, .eastSouthWest)
        add(.eastWest, .eastSouthWest)
        add(.northEastWest, .eastSouthWest)

        add(.north, .northSouthWest)
        add(.east, .northSouthWest)
        add(.south, .northSouthWest)
        add(.northEast, .northSouthWest)

        add(.none, .northEastSouth)
        add(.north, .northEastSouth)
        add(.south, .northEastSouth)
        add(.west, .northEastSouth)
        add(.northEast, .northEastSouth)
        add(.northSouth, .northEastSouth)
        add(.northWest, .northEastSouth)

        add(.northWest, .northEastSouthWest)
        add(.northEast, .northEastSouthWest)

        // Conflicts that seem solvable but that arise since the order of C, EW, W, E is fix
        add(.eastWest, .none)
        add(.eastWest, .west)
        add(.eastWest, .east)

        // Conflicts that seem solvable but that arise since the order of C, NS, N, S is fix
        add(.northSouth, .none)
        add(.northSouth, .north)
        add(.northSouth, .south)

        return map
    }()

    package var componentOrder: [LGraph] = []

    /**
     * Constructs a new, empty component group.
     */
    package override init() {
        super.init()
    }

    /**
     * Constructs a new component group with the given initial component. This is equivalent to
     * constructing an empty component group and then calling add(_ component:).
     *
     * @param component the component to be added to the group.
     */
    package override init(_ component: LGraph) {
        super.init()
        _ = add(component)
        componentOrder.append(component)
    }


    /**
     * Tries to add the given component to the group. Before adding the component, a call to
     * canAdd(_ component:) determines if the component can actually be added to this
     * group.
     *
     * @param component the component to be added to this group.
     * @return true if the component was successfully added, false otherwise.
     */
    @discardableResult
    package override func add(_ component: LGraph) -> Bool {
        if canAdd(component) {
            let portConnections = component.getProperty(InternalProperties.EXT_PORT_CONNECTIONS) ?? Set<PortSide>()
            components[portConnections, default: []].append(component)
            componentOrder.append(component)
            return true
        } else {
            return false
        }
    }

    /**
     * Checks whether this group has enough space left to add a given component.
     *
     * @param component the component to be added to the group.
     * @return true if the group has enough space left to add the component, false
     *         otherwise.
     */
    package override func canAdd(_ component: LGraph) -> Bool {
        let candidateSides = component.getProperty(InternalProperties.EXT_PORT_CONNECTIONS) ?? Set<PortSide>()

        // Check super constraints
        if let superConstraints = ComponentGroup.constraints[candidateSides] {
            for constraint in superConstraints {
                if !components[constraint, default: []].isEmpty {
                    return false
                }
            }
        }

        // Check model order constraints
        if let moConstraints = ModelOrderComponentGroup.modelOrderConstraints[candidateSides] {
            for constraint in moConstraints {
                if !components[constraint, default: []].isEmpty {
                    return false
                }
            }
        }

        return true
    }

    /**
     * @return the componentOrder
     */
    package func getComponentOrder() -> [LGraph] {
        return componentOrder
    }

    /**
     * @return the port sides present in this group's components.
     */
    package override var portSides: [Set<PortSide>] {
        return Array(components.keys)
    }
}
