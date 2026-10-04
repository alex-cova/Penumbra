import Foundation

public indirect enum ToolParameterType: Sendable, Hashable {
    case string
    case integer
    case number
    case boolean
    case array(of: ToolParameterType)
    case enumeration([String])
}

public struct ToolParameter: Sendable, Hashable {
    public let name: String
    public let type: ToolParameterType
    public let description: String
    public let isOptional: Bool

    public init(_ name: String, _ type: ToolParameterType, _ description: String, optional: Bool = false) {
        self.name = name
        self.type = type
        self.description = description
        self.isOptional = optional
    }
}

/// A tool as the model sees it, written once and rendered per API.
public struct ToolDefinition: Sendable, Hashable {
    public let name: String
    public let description: String
    public let parameters: [ToolParameter]

    public init(name: String, description: String, parameters: [ToolParameter] = []) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    /// The JSON Schema for the arguments object.
    ///
    /// Strict mode, which OpenAI requires for `strict: true`, lists every property in `required`,
    /// sets `additionalProperties: false`, and types optional parameters as nullable. The
    /// non-strict form lists only the required ones, for endpoints that reject nullable types.
    public func schema(strict: Bool) -> JSONValue {
        var properties: [String: JSONValue] = [:]
        var required: [JSONValue] = []
        for parameter in parameters {
            properties[parameter.name] = Self.schema(for: parameter, nullable: strict && parameter.isOptional)
            if strict || !parameter.isOptional { required.append(.string(parameter.name)) }
        }
        var object: [String: JSONValue] = [
            "type": "object",
            "properties": .object(properties),
            "required": .array(required),
        ]
        if strict { object["additionalProperties"] = false }
        return .object(object)
    }

    private static func schema(for parameter: ToolParameter, nullable: Bool) -> JSONValue {
        var fields = fields(for: parameter.type, nullable: nullable)
        fields["description"] = .string(parameter.description)
        return .object(fields)
    }

    private static func fields(for type: ToolParameterType, nullable: Bool) -> [String: JSONValue] {
        func typeName(_ name: String) -> JSONValue { nullable ? [.string(name), "null"] : .string(name) }
        switch type {
        case .string: return ["type": typeName("string")]
        case .integer: return ["type": typeName("integer")]
        case .number: return ["type": typeName("number")]
        case .boolean: return ["type": typeName("boolean")]
        case .array(let element):
            return ["type": typeName("array"), "items": .object(fields(for: element, nullable: false))]
        case .enumeration(let cases):
            var values = cases.map(JSONValue.string)
            if nullable { values.append(.null) }
            return ["type": typeName("string"), "enum": .array(values)]
        }
    }
}
