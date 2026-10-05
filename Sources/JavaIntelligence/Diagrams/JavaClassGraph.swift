import Foundation

/// A set of Java types and the relations between them, ready to be drawn as a UML class diagram.
/// ``JavaClassGraphBuilder`` makes one; it knows nothing about how it is drawn.
public struct JavaClassGraph: Sendable, Equatable {
    public struct Node: Sendable, Hashable, Identifiable {
        public var id: String { qualifiedName }
        public let qualifiedName: String
        /// The name without its package, `Outer.Inner` for a nested type.
        public let displayName: String
        public let packageName: String
        public let kind: JavaTypeKind
        public let isAbstract: Bool
        /// A type from the JDK or a dependency jar: shown by name, never expanded.
        public let isExternal: Bool
        /// UML lines, `- name: Type`; empty for an external type or when members are hidden.
        public let attributes: [String]
        /// UML lines, `+ run(int): void`.
        public let methods: [String]
        /// The `.java` file that declares it, when the project does.
        public let sourceURL: URL?

        public init(
            qualifiedName: String, displayName: String, packageName: String, kind: JavaTypeKind,
            isAbstract: Bool = false, isExternal: Bool = false, attributes: [String] = [],
            methods: [String] = [], sourceURL: URL? = nil
        ) {
            self.qualifiedName = qualifiedName
            self.displayName = displayName
            self.packageName = packageName
            self.kind = kind
            self.isAbstract = isAbstract
            self.isExternal = isExternal
            self.attributes = attributes
            self.methods = methods
            self.sourceURL = sourceURL
        }
    }

    public enum EdgeKind: String, Sendable, Hashable, CaseIterable {
        /// A class or interface extending another (generalization).
        case inheritance
        /// A class implementing an interface.
        case realization
        /// A field of the target's type.
        case association
        /// A field holding a collection, map or array of the target's type.
        case aggregation
        /// A method parameter, return or `throws` type.
        case dependency

        /// Extends or implements: the relations that make up a type's hierarchy.
        var isHierarchy: Bool { self == .inheritance || self == .realization }

        /// Stronger relations replace weaker ones between the same two types.
        var strength: Int {
            switch self {
            case .inheritance: 5
            case .realization: 4
            case .aggregation: 3
            case .association: 2
            case .dependency: 1
            }
        }
    }

    public struct Edge: Sendable, Hashable {
        /// The type that has the relation: the subtype, the field's owner, the caller.
        public let source: String
        public let destination: String
        public let kind: EdgeKind
        /// The field name for an association or aggregation.
        public let label: String

        public init(source: String, destination: String, kind: EdgeKind, label: String = "") {
            self.source = source
            self.destination = destination
            self.kind = kind
            self.label = label
        }
    }

    public var nodes: [Node]
    public var edges: [Edge]
    /// More types matched than the node cap allowed.
    public var truncated: Bool
    /// How many types were left out because of the cap.
    public var omittedCount: Int

    public init(nodes: [Node] = [], edges: [Edge] = [], truncated: Bool = false, omittedCount: Int = 0) {
        self.nodes = nodes
        self.edges = edges
        self.truncated = truncated
        self.omittedCount = omittedCount
    }

    public var isEmpty: Bool { nodes.isEmpty }
}

/// Which types a class diagram starts from.
public enum JavaClassGraphScope: Sendable, Hashable {
    /// These qualified names.
    case types([String])
    /// Every type declared in this `.java` file.
    case file(URL)
    /// The project's types declared directly in this package.
    case package(String)
    /// Every type of the project.
    case project
}

public struct JavaClassGraphOptions: Sendable, Hashable {
    public var showMembers: Bool
    public var showPrivateMembers: Bool
    /// Also draw the JDK and dependency types the scope refers to.
    public var showExternalTypes: Bool
    /// How many relation hops beyond the scope's own types to follow, 0...2, in both directions.
    public var neighbourDepth: Int
    public var nodeLimit: Int

    public static let defaultNodeLimit = 150

    public init(
        showMembers: Bool = true,
        showPrivateMembers: Bool = false,
        showExternalTypes: Bool = false,
        neighbourDepth: Int = 0,
        nodeLimit: Int = JavaClassGraphOptions.defaultNodeLimit
    ) {
        self.showMembers = showMembers
        self.showPrivateMembers = showPrivateMembers
        self.showExternalTypes = showExternalTypes
        self.neighbourDepth = max(0, min(2, neighbourDepth))
        self.nodeLimit = max(1, nodeLimit)
    }
}
