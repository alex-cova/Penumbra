import AgentKit
import Foundation
import FoundationModels

/// A `ToolDefinition`'s JSON Schema as a `GenerationSchema`, so the framework can show the tool to the model.
///
/// Objects, arrays, strings, numbers, booleans and enums are carried over. A shape the framework has no
/// counterpart for (`anyOf`, `$ref`, a missing type) becomes a string described as JSON, which the model
/// fills with the JSON text of the value.
enum AppleToolSchema {
    static func generationSchema(for tool: ToolDefinition) throws -> GenerationSchema {
        let schema = tool.schema(strict: false)
        let root: DynamicGenerationSchema
        if case .object(let object) = schema {
            root = objectSchema(name: tool.name, description: tool.description, object: object)
        } else {
            root = DynamicGenerationSchema(name: tool.name, description: tool.description, properties: [])
        }
        return try GenerationSchema(root: root, dependencies: [])
    }

    private static func objectSchema(name: String, description: String?, object: [String: JSONValue]) -> DynamicGenerationSchema {
        let required = Set(object["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        var properties: [DynamicGenerationSchema.Property] = []
        for (key, value) in (object["properties"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            let field = value.objectValue ?? [:]
            properties.append(DynamicGenerationSchema.Property(
                name: key, description: field["description"]?.stringValue,
                schema: schema(named: "\(name).\(key)", field), isOptional: !required.contains(key)))
        }
        return DynamicGenerationSchema(name: name, description: description, properties: properties)
    }

    private static func schema(named name: String, _ field: [String: JSONValue]) -> DynamicGenerationSchema {
        // Strict-mode schemas type an optional field as ["string", "null"].
        let type = field["type"]?.stringValue ?? field["type"]?.arrayValue?.compactMap(\.stringValue).first { $0 != "null" }
        if let cases = field["enum"]?.arrayValue?.compactMap(\.stringValue), !cases.isEmpty {
            return DynamicGenerationSchema(name: name, description: field["description"]?.stringValue, anyOf: cases)
        }
        switch type {
        case "string": return DynamicGenerationSchema(type: String.self)
        case "integer": return DynamicGenerationSchema(type: Int.self)
        case "number": return DynamicGenerationSchema(type: Double.self)
        case "boolean": return DynamicGenerationSchema(type: Bool.self)
        case "array":
            let item = field["items"]?.objectValue ?? [:]
            return DynamicGenerationSchema(arrayOf: schema(named: "\(name).item", item))
        case "object":
            return objectSchema(name: name, description: field["description"]?.stringValue, object: field)
        default:
            return DynamicGenerationSchema(type: String.self)
        }
    }
}
