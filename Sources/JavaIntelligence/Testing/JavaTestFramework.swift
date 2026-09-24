import Foundation

/// Which JUnit generation a discovered test method uses.
public enum JavaTestFramework: String, Sendable, Codable, Equatable {
    case junit4
    case junit5
}
