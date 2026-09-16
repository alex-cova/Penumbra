import Foundation

/**
 * Comparator which sorts `ILayoutProcessorFactory` layout processor factories based on the order of their
 * enumeration constants. This only works for factories which are indeed enumerations. Plus, the ordinals of the
 * enumeration constants must be ordered such that they reflect dependencies between the processors.
 */
/// Protocol for enums that can provide a deterministic ordinal (matching Java's Enum.ordinal()).
package protocol EnumOrdinal {
    var ordinal: Int { get }
}

package final class EnumBasedFactory {

    package init() {}

    /// Compare two layout processor factories by their raw values (ordinals).
    /// Returns negative if factory1 < factory2, zero if equal, positive if factory1 > factory2.
    package func compare(_ factory1: Any, _ factory2: Any) -> Int {
        let ordinal1 = ordinalOf(factory1)
        let ordinal2 = ordinalOf(factory2)
        if ordinal1 < ordinal2 { return -1 }
        if ordinal1 > ordinal2 { return 1 }
        return 0
    }

    private func ordinalOf(_ value: Any) -> Int {
        // Use EnumOrdinal protocol for deterministic ordering (matches Java Enum.ordinal())
        if let ordinalEnum = value as? EnumOrdinal {
            return ordinalEnum.ordinal
        }
        // Try rawValue for RawRepresentable enums
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .enum {
            if let raw = mirror.children.first(where: { $0.label == "rawValue" })?.value as? Int {
                return raw
            }
        }
        // Fallback: use hash (non-deterministic, but shouldn't be reached for sorted enums)
        if let hashable = value as? AnyHashable {
            return hashable.hashValue
        }
        return 0
    }

}
