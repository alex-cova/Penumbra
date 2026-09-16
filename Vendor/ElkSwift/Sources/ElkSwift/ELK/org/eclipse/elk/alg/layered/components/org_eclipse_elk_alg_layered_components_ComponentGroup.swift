import Foundation

/**
 * Represents a group of connected components grouped for layout purposes.
 * 
 * <p>A component group is conceptually divided into nine sectors as such: (the nine sectors are
 * enumerated in the {@link ComponentGroupSector} enumeration)</p>
 * <pre>
 *   +----+----+----+
 *   | nw | n  | ne |
 *   +----+----+----+
 *   | w  | c  | e  |
 *   +----+----+----+
 *   | sw | s  | se |
 *   +----+----+----+
 * </pre>
 * <p>The port sides of external ports a component connects to determines which sector(s) it will
 * occupy. This is best illustrated by some examples:</p>
 * <ul>
 *   <li>Let {@code c} be a component connected to a northern port. Then {@code c} would be placed in
 *       the {@code n} sector.</li>
 *   <li>Let {@code c} be a comopnent connected to a southern port and to an eastern port. Then
 *       {@code c} would be placed in the {@code se} sector.</li>
 *   <li>Let {@code c} be a component connected to no port at all. Then {@code c} would be placed in the
 *       {@code c} sector.</li>
 *   <li>Let {@code c} be a component connected to a western and to an eastern port. Then {@code c}
 *       would be placed in the {@code w}, {@code c}, and {@code e} sectors. If {@code c} would also
 *       connected to a southern port, it would also occupy the {@code sw}, {@code sc}, and {@code se}
 *       sectors.</li>
 * </ul>
 * <p>With this placement comes a bunch of constraints. For example, for a component to occupy the
 * top three sectors, none of them must be occupied by another component yet. If the addition of a
 * component to this group would cause a constraint to be violated, it cannot be added.</p>
 * 
 * <p>This class is not supposed to be public, but needs to be for JUnit tests to find it.</p>
 */
package class ComponentGroup {
    
    // MARK: - Constants
    
    // External Port Connection Constraints
    
    /**
     * A map of constraints used to decide whether a component can be placed in this group.
     * 
     * <p>For a new component that is to be placed in this group, the set of external port sides
     * it connects to implies which sets of port sides of other components it is compatible to.
     * For instance, a component connecting to a northern and an eastern port requires that no
     * other component connects to this particular combination of ports. This map maps sets of
     * port sides to a list of port side sets that must not already exist in this group for a
     * component to be added.</p>
     */
    package static let constraints: [Set<PortSide>: [Set<PortSide>]] = {
        var map: [Set<PortSide>: [Set<PortSide>]] = [:]
        
        func add(_ key: Set<PortSide>, _ values: Set<PortSide>...) {
            map[key, default: []].append(contentsOf: values)
        }
        
        add(.none, .northEastSouthWest)
        add(.west, .northEastSouthWest)
        add(.west, .northSouthWest)
        add(.east, .northEastSouth)
        add(.east, .northEastSouthWest)
        add(.north, .northEastSouthWest)
        add(.north, .northEastWest)
        add(.south, .eastSouthWest)
        add(.south, .northEastSouthWest)
        add(.northSouth, .eastWest)
        add(.northSouth, .northEastSouthWest)
        add(.northSouth, .northEastWest)
        add(.northSouth, .eastSouthWest)
        add(.eastWest, .northSouth)
        add(.eastWest, .northSouthWest)
        add(.eastWest, .northEastSouth)
        add(.eastWest, .northEastSouthWest)
        add(.northWest, .northWest)
        add(.northWest, .northEastWest)
        add(.northWest, .northSouthWest)
        add(.northEast, .northEast)
        add(.northEast, .northEastWest)
        add(.northEast, .northEastSouth)
        add(.southWest, .southWest)
        add(.southWest, .eastSouthWest)
        add(.southWest, .northSouthWest)
        add(.eastSouth, .eastSouth)
        add(.eastSouth, .eastSouthWest)
        add(.eastSouth, .northEastSouth)
        add(.northEastWest, .north)
        add(.northEastWest, .northSouth)
        add(.northEastWest, .northWest)
        add(.northEastWest, .northEast)
        add(.northEastWest, .northEastSouthWest)
        add(.northEastWest, .northEastWest)
        add(.northEastWest, .northSouthWest)
        add(.northEastWest, .northEastSouth)
        add(.eastSouthWest, .south)
        add(.eastSouthWest, .northSouth)
        add(.eastSouthWest, .southWest)
        add(.eastSouthWest, .eastSouth)
        add(.eastSouthWest, .eastSouthWest)
        add(.eastSouthWest, .northSouthWest)
        add(.eastSouthWest, .northEastSouth)
        add(.eastSouthWest, .northEastSouthWest)
        add(.northSouthWest, .west)
        add(.northSouthWest, .eastWest)
        add(.northSouthWest, .northWest)
        add(.northSouthWest, .southWest)
        add(.northSouthWest, .northEastWest)
        add(.northSouthWest, .eastSouthWest)
        add(.northSouthWest, .northSouthWest)
        add(.northSouthWest, .northEastSouthWest)
        add(.northEastSouth, .east)
        add(.northEastSouth, .eastWest)
        add(.northEastSouth, .northEast)
        add(.northEastSouth, .eastSouth)
        add(.northEastSouth, .northEastWest)
        add(.northEastSouth, .eastSouthWest)
        add(.northEastSouth, .northEastSouth)
        add(.northEastSouth, .northEastSouthWest)
        add(.northEastSouthWest, .none)
        add(.northEastSouthWest, .west)
        add(.northEastSouthWest, .east)
        add(.northEastSouthWest, .north)
        add(.northEastSouthWest, .south)
        add(.northEastSouthWest, .northSouth)
        add(.northEastSouthWest, .eastWest)
        add(.northEastSouthWest, .northEastWest)
        add(.northEastSouthWest, .eastSouthWest)
        add(.northEastSouthWest, .northSouthWest)
        add(.northEastSouthWest, .northEastSouth)
        add(.northEastSouthWest, .northEastSouthWest)
        
        return map
    }()
    
    // MARK: - Variables
    
    /**
     * A map mapping external port side combinations to components in this group.
     */
    package var components: [Set<PortSide>: [LGraph]] = [:]
    
    // MARK: - Constructors
    
    /**
     * Constructs a new, empty component group.
     */
    package init() {
        
    }
    
    /**
     * Constructs a new component group with the given initial component. This is equivalent to
     * constructing an empty component group and then calling {@link #add(LGraph)}.
     * 
     * @param component the component to be added to the group.
     */
    package init(_ component: LGraph) {
        add(component)
    }
    
    // MARK: - Component Management
    
    /**
     * Tries to add the given component to the group. Before adding the component, a call to
     * {@link #canAdd(LGraph)} determines if the component can actually be added to this
     * group.
     * 
     * @param component the component to be added to this group.
     * @return {@code true} if the component was successfully added, {@code false} otherwise.
     */
    @discardableResult
    package func add(_ component: LGraph) -> Bool {
        if canAdd(component) {
            let key = component.getProperty(InternalProperties.EXT_PORT_CONNECTIONS) ?? Set<PortSide>()
            components[key, default: []].append(component)
            return true
        } else {
            return false
        }
    }
    
    /**
     * Checks whether this group has enough space left to add a given component.
     * 
     * @param component the component to be added to the group.
     * @return {@code true} if the group has enough space left to add the component, {@code false}
     *         otherwise.
     */
    package func canAdd(_ component: LGraph) -> Bool {
        // Check if we have a component with incompatible external port sides
        let candidateSides = component.getProperty(InternalProperties.EXT_PORT_CONNECTIONS) ?? Set<PortSide>()
        guard let constraints = ComponentGroup.constraints[candidateSides] else {
            return true
        }
        
        for constraint in constraints {
            if !components[constraint, default: []].isEmpty {
                // A component with a conflicting external port side combination exists
                return false
            }
        }
        
        // We haven't found any conflicting components
        return true
    }
    
    /**
     * Returns all port sides in this component group.
     * 
     * @return all port sides in this component group.
     */
    package func getPortSides() -> [Set<PortSide>] {
        return Array(components.keys)
    }

    /// Convenience property for port sides.
    package var portSides: [Set<PortSide>] {
        return Array(components.keys)
    }
    
    /**
     * Returns all components in this component group.
     * 
     * @return the components in this component group.
     */
    package func getComponents() -> [LGraph] {
        return components.values.flatMap { $0 }
    }
    
    /**
     * Returns the components in this component group connected to external ports on the given set
     * of port sides.
     * 
     * @param connections external port sides the returned components are to be connected to.
     * @return the collection of components. If there are no components, an empty collection is
     *         returned.
     */
    package func getComponents(_ connections: Set<PortSide>) -> [LGraph] {
        return components[connections, default: []]
    }
}
