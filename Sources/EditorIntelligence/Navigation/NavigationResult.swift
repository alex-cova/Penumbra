import Foundation

/// Result returned by a navigation provider.
///
/// A provider can return a single destination (e.g. go-to-definition) or multiple destinations
/// (e.g. find-references, breadcrumbs).
public enum NavigationResult: Sendable, CustomStringConvertible {
    case single(Location)
    case multiple([Location])

    /// The locations of either case, in order.
    public var locations: [Location] {
        switch self {
        case .single(let location): return [location]
        case .multiple(let locations): return locations
        }
    }

    public var description: String {
        switch self {
        case .single(let location):
            return "single: \(location.displayName)"
        case .multiple(let locations):
            return "multiple: \(locations.count) locations"
        }
    }
}
