import Foundation

/// A GraphQL type reference, reduced to what completion shows: the named type at the bottom, the
/// whole spelling (`[User!]!`) and whether the outermost layer is non-null.
struct GraphQLTypeRef: Codable, Hashable, Sendable {
    var name: String
    var display: String
    var isRequired: Bool

    init(name: String, display: String? = nil, isRequired: Bool = false) {
        self.name = name
        self.display = display ?? name
        self.isRequired = isRequired
    }
}

struct GraphQLArgument: Codable, Hashable, Sendable {
    var name: String
    var type: GraphQLTypeRef
    var description: String?
    var defaultValue: String?

    /// A call has to pass it: non-null with no default.
    var isRequired: Bool {
        type.isRequired && defaultValue == nil
    }
}

struct GraphQLField: Codable, Hashable, Sendable {
    var name: String
    var arguments: [GraphQLArgument]
    var type: GraphQLTypeRef
    var description: String?
    var deprecationReason: String?

    var isDeprecated: Bool {
        deprecationReason != nil
    }
}

struct GraphQLEnumValue: Codable, Hashable, Sendable {
    var name: String
    var description: String?
    var deprecationReason: String?
}

struct GraphQLDirectiveDefinition: Codable, Hashable, Sendable {
    var name: String
    var description: String?
    var arguments: [GraphQLArgument]
    var locations: [String]
}

enum GraphQLTypeKind: String, Codable, Sendable {
    case scalar = "SCALAR"
    case object = "OBJECT"
    case interface = "INTERFACE"
    case union = "UNION"
    case enumeration = "ENUM"
    case inputObject = "INPUT_OBJECT"
}

struct GraphQLNamedType: Codable, Hashable, Sendable {
    var name: String
    var kind: GraphQLTypeKind
    var description: String?
    /// Object and interface fields.
    var fields: [GraphQLField] = []
    var inputFields: [GraphQLArgument] = []
    var enumValues: [GraphQLEnumValue] = []
    /// A union's members, or an interface's implementers.
    var possibleTypes: [String] = []
    /// The interfaces an object or interface declares.
    var interfaces: [String] = []
}

struct GraphQLSchema: Codable, Sendable {
    var queryType: String?
    var mutationType: String?
    var subscriptionType: String?
    var types: [String: GraphQLNamedType] = [:]
    var directives: [GraphQLDirectiveDefinition] = []

    static let builtInScalars = ["Int", "Float", "String", "Boolean", "ID"]

    /// `query`, `mutation` or `subscription`.
    func rootTypeName(for operation: String) -> String? {
        switch operation {
        case "query": queryType
        case "mutation": mutationType
        case "subscription": subscriptionType
        default: nil
        }
    }

    /// Fields a selection on `typeName` may name. A union has only `__typename`.
    func fields(of typeName: String) -> [GraphQLField] {
        types[typeName]?.fields ?? []
    }

    /// Object types a `... on` may name inside `typeName`: its members or implementers, the type
    /// itself, and the interfaces it implements.
    func typeConditions(for typeName: String) -> [String] {
        guard let type = types[typeName] else {
            return []
        }
        var names: [String] = []
        switch type.kind {
        case .union, .interface:
            names = type.possibleTypes
        default:
            break
        }
        names.append(typeName)
        names.append(contentsOf: type.interfaces)
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    /// Fills what a definition leaves implied: root names, built-in scalars and directives, and each
    /// interface's implementers. Run once after building from SDL or introspection.
    mutating func finish() {
        if queryType == nil, types["Query"] != nil {
            queryType = "Query"
        }
        if mutationType == nil, types["Mutation"] != nil {
            mutationType = "Mutation"
        }
        if subscriptionType == nil, types["Subscription"] != nil {
            subscriptionType = "Subscription"
        }
        for name in Self.builtInScalars where types[name] == nil {
            types[name] = GraphQLNamedType(name: name, kind: .scalar)
        }
        let known = Set(directives.map(\.name))
        let required = GraphQLTypeRef(name: "Boolean", display: "Boolean!", isRequired: true)
        let ifArgument = GraphQLArgument(name: "if", type: required)
        let operationOrField = ["FIELD", "FRAGMENT_SPREAD", "INLINE_FRAGMENT"]
        let builtIns = [
            GraphQLDirectiveDefinition(name: "skip", description: "Skips this field when `if` is true.", arguments: [ifArgument], locations: operationOrField),
            GraphQLDirectiveDefinition(name: "include", description: "Includes this field only when `if` is true.", arguments: [ifArgument], locations: operationOrField),
            GraphQLDirectiveDefinition(
                name: "deprecated", description: "Marks a definition as deprecated.",
                arguments: [GraphQLArgument(name: "reason", type: GraphQLTypeRef(name: "String"))],
                locations: ["FIELD_DEFINITION", "ENUM_VALUE", "ARGUMENT_DEFINITION", "INPUT_FIELD_DEFINITION"]
            )
        ]
        directives.append(contentsOf: builtIns.filter { !known.contains($0.name) })
        for type in types.values where type.kind == .object || type.kind == .interface {
            for interface in type.interfaces {
                guard var target = types[interface], target.kind == .interface,
                      !target.possibleTypes.contains(type.name) else { continue }
                target.possibleTypes.append(type.name)
                types[interface] = target
            }
        }
    }

    /// Types a variable definition (`$id: `) may use: scalars, enums and input objects.
    var inputTypeNames: [String] {
        types.values
            .filter { $0.kind == .scalar || $0.kind == .enumeration || $0.kind == .inputObject }
            .map(\.name)
            .filter { !$0.hasPrefix("__") }
            .sorted()
    }
}
