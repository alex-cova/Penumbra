import Foundation

/// The standard introspection query and the reader of its answer.
enum GraphQLIntrospection {
    enum DecodeError: Error, LocalizedError, Equatable {
        case notJSON
        case server(String)
        case noSchema

        var errorDescription: String? {
            switch self {
            case .notJSON: "The response is not JSON."
            case .server(let message): "The server answered with an error: \(message)"
            case .noSchema: "The response has no GraphQL schema."
            }
        }
    }

    /// The TypeRef fragment nests `ofType` seven deep, which covers `[[[Type!]!]!]!`.
    static let query: String = {
        var typeRef = "kind name"
        for _ in 0..<7 {
            typeRef = "kind name ofType { \(typeRef) }"
        }
        return """
        query IntrospectionQuery {
          __schema {
            queryType { name }
            mutationType { name }
            subscriptionType { name }
            types { ...FullType }
            directives { name description locations args { ...InputValue } }
          }
        }
        fragment FullType on __Type {
          kind name description
          fields(includeDeprecated: true) {
            name description
            args { ...InputValue }
            type { ...TypeRef }
            isDeprecated deprecationReason
          }
          inputFields { ...InputValue }
          interfaces { ...TypeRef }
          enumValues(includeDeprecated: true) { name description isDeprecated deprecationReason }
          possibleTypes { ...TypeRef }
        }
        fragment InputValue on __InputValue { name description type { ...TypeRef } defaultValue }
        fragment TypeRef on __Type { \(typeRef) }
        """
    }()

    /// The request body: `{"query": …, "operationName": …}`.
    static var requestBody: Data {
        let body: [String: Any] = ["query": query, "operationName": "IntrospectionQuery"]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    /// Reads `{"data": {"__schema": …}}` or a bare `{"__schema": …}`.
    static func decode(_ data: Data) throws -> GraphQLSchema {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw DecodeError.notJSON
        }
        let container = (root["data"] as? [String: Any]) ?? root
        guard let raw = container["__schema"] as? [String: Any] else {
            if let errors = root["errors"] as? [[String: Any]], let message = errors.first?["message"] as? String {
                throw DecodeError.server(message)
            }
            throw DecodeError.noSchema
        }
        var schema = GraphQLSchema()
        schema.queryType = (raw["queryType"] as? [String: Any])?["name"] as? String
        schema.mutationType = (raw["mutationType"] as? [String: Any])?["name"] as? String
        schema.subscriptionType = (raw["subscriptionType"] as? [String: Any])?["name"] as? String
        for case let item as [String: Any] in (raw["types"] as? [Any]) ?? [] {
            guard let name = item["name"] as? String,
                  let kindName = item["kind"] as? String,
                  let kind = GraphQLTypeKind(rawValue: kindName) else { continue }
            var type = GraphQLNamedType(name: name, kind: kind, description: nonEmpty(item["description"]))
            type.fields = ((item["fields"] as? [Any]) ?? []).compactMap { field(from: $0) }
            type.inputFields = ((item["inputFields"] as? [Any]) ?? []).compactMap { argument(from: $0) }
            type.enumValues = ((item["enumValues"] as? [Any]) ?? []).compactMap { value in
                guard let value = value as? [String: Any], let name = value["name"] as? String else { return nil }
                return GraphQLEnumValue(name: name, description: nonEmpty(value["description"]), deprecationReason: deprecation(value))
            }
            type.possibleTypes = ((item["possibleTypes"] as? [Any]) ?? []).compactMap { typeRef(from: $0)?.name }
            type.interfaces = ((item["interfaces"] as? [Any]) ?? []).compactMap { typeRef(from: $0)?.name }
            schema.types[name] = type
        }
        for case let item as [String: Any] in (raw["directives"] as? [Any]) ?? [] {
            guard let name = item["name"] as? String else { continue }
            schema.directives.append(GraphQLDirectiveDefinition(
                name: name,
                description: nonEmpty(item["description"]),
                arguments: ((item["args"] as? [Any]) ?? []).compactMap { argument(from: $0) },
                locations: (item["locations"] as? [String]) ?? []
            ))
        }
        guard !schema.types.isEmpty else {
            throw DecodeError.noSchema
        }
        schema.finish()
        return schema
    }

    private static func field(from raw: Any) -> GraphQLField? {
        guard let item = raw as? [String: Any],
              let name = item["name"] as? String,
              let type = typeRef(from: item["type"]) else { return nil }
        return GraphQLField(
            name: name,
            arguments: ((item["args"] as? [Any]) ?? []).compactMap { argument(from: $0) },
            type: type,
            description: nonEmpty(item["description"]),
            deprecationReason: deprecation(item)
        )
    }

    private static func argument(from raw: Any) -> GraphQLArgument? {
        guard let item = raw as? [String: Any],
              let name = item["name"] as? String,
              let type = typeRef(from: item["type"]) else { return nil }
        return GraphQLArgument(
            name: name, type: type, description: nonEmpty(item["description"]), defaultValue: item["defaultValue"] as? String
        )
    }

    private static func typeRef(from raw: Any?) -> GraphQLTypeRef? {
        guard let item = raw as? [String: Any], let kind = item["kind"] as? String else { return nil }
        switch kind {
        case "NON_NULL":
            guard let inner = typeRef(from: item["ofType"]) else { return nil }
            return GraphQLTypeRef(name: inner.name, display: inner.display + "!", isRequired: true)
        case "LIST":
            guard let inner = typeRef(from: item["ofType"]) else { return nil }
            return GraphQLTypeRef(name: inner.name, display: "[" + inner.display + "]", isRequired: false)
        default:
            guard let name = item["name"] as? String else { return nil }
            return GraphQLTypeRef(name: name)
        }
    }

    private static func deprecation(_ item: [String: Any]) -> String? {
        guard item["isDeprecated"] as? Bool == true else { return nil }
        return (item["deprecationReason"] as? String) ?? ""
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}
