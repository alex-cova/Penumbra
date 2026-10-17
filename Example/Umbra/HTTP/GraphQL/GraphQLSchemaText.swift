import Foundation

/// Renders a `GraphQLSchema` as SDL-like text: what the `###@scheme:` hover shows (bounded) and
/// what the right-split preview tab opens (in full). Comments (`#`) carry descriptions, so the
/// output stays readable even where the schema came from introspection JSON rather than an SDL file.
enum GraphQLSchemaText {
    /// The whole schema, one definition after another. Empty when it has no custom types.
    static func fullText(for schema: GraphQLSchema, source: String? = nil) -> String {
        var lines: [String] = []
        if let source {
            lines.append("# GraphQL schema: \(source)")
        }
        let custom = customTypes(of: schema)
        guard !custom.isEmpty else { return lines.joined(separator: "\n") }
        var roots: [String] = []
        if let query = schema.queryType { roots.append("query: \(query)") }
        if let mutation = schema.mutationType { roots.append("mutation: \(mutation)") }
        if let subscription = schema.subscriptionType { roots.append("subscription: \(subscription)") }
        if !roots.isEmpty {
            lines.append("# \(custom.count) types · \(roots.joined(separator: " · "))")
        } else {
            lines.append("# \(custom.count) types")
        }
        lines.append("")
        for type in ordered(custom, schema: schema) {
            lines.append(contentsOf: definition(of: type))
            lines.append("")
        }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// The first definitions that fit in `maxLines`, plus a hint that the rest lives in the
    /// preview tab. Empty when the schema has no custom types. Work is bounded by `maxLines`,
    /// never by schema size, so hovering a huge schema stays cheap.
    static func excerpt(for schema: GraphQLSchema, maxLines: Int = 24) -> String {
        let custom = customTypes(of: schema)
        guard !custom.isEmpty, maxLines > 0 else { return "" }
        var lines: [String] = []
        var renderedTypes = 0
        for type in ordered(custom, schema: schema) {
            let block = definition(of: type)
            // Reserve a blank line and the "more" hint while types remain.
            guard lines.count + block.count + 1 <= maxLines - 2 else { break }
            lines.append(contentsOf: block)
            lines.append("")
            renderedTypes += 1
        }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        guard renderedTypes < custom.count else { return lines.joined(separator: "\n") }
        if lines.isEmpty {
            return "# … \(custom.count) more type\(custom.count == 1 ? "" : "s") — open in the editor for the full schema."
        }
        let remaining = custom.count - renderedTypes
        lines.append("")
        lines.append("# … \(remaining) more type\(remaining == 1 ? "" : "s") — open in the editor for the full schema.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Private

    static func customTypes(of schema: GraphQLSchema) -> [GraphQLNamedType] {
        schema.types.values.filter {
            !GraphQLSchema.builtInScalars.contains($0.name) && !$0.name.hasPrefix("__")
        }
    }

    /// Root operation types first, then everything else alphabetically.
    private static func ordered(_ types: [GraphQLNamedType], schema: GraphQLSchema) -> [GraphQLNamedType] {
        let roots = [schema.queryType, schema.mutationType, schema.subscriptionType].compactMap { $0 }
        let byName = Dictionary(uniqueKeysWithValues: types.map { ($0.name, $0) })
        var result = roots.compactMap { byName[$0] }
        let rootNames = Set(roots)
        result.append(contentsOf: types.filter { !rootNames.contains($0.name) }.sorted { $0.name < $1.name })
        return result
    }

    private static func definition(of type: GraphQLNamedType) -> [String] {
        var lines: [String] = []
        if let comment = commentLine(type.description) {
            lines.append(comment)
        }
        switch type.kind {
        case .scalar:
            lines.append("scalar \(type.name)")
        case .enumeration:
            lines.append("enum \(type.name) {")
            for value in type.enumValues {
                if let comment = commentLine(value.description) {
                    lines.append("  \(comment)")
                }
                lines.append("  \(value.name)\(deprecationSuffix(value.deprecationReason))")
            }
            lines.append("}")
        case .inputObject:
            lines.append("input \(type.name) {")
            for field in type.inputFields {
                if let comment = commentLine(field.description) {
                    lines.append("  \(comment)")
                }
                lines.append("  \(field.name): \(field.type.display)\(defaultSuffix(field.defaultValue))")
            }
            lines.append("}")
        case .union:
            lines.append("union \(type.name) = \(type.possibleTypes.joined(separator: " | "))")
        case .object, .interface:
            let keyword = type.kind == .object ? "type" : "interface"
            let conformance = type.interfaces.isEmpty ? "" : " implements \(type.interfaces.joined(separator: " & "))"
            lines.append("\(keyword) \(type.name)\(conformance) {")
            for field in type.fields {
                if let comment = commentLine(field.description) {
                    lines.append("  \(comment)")
                }
                lines.append("  \(field.name)\(argumentsList(field.arguments)): \(field.type.display)\(deprecationSuffix(field.deprecationReason))")
            }
            lines.append("}")
        }
        return lines
    }

    private static func argumentsList(_ arguments: [GraphQLArgument]) -> String {
        guard !arguments.isEmpty else { return "" }
        let rendered = arguments.map { "\($0.name): \($0.type.display)\(defaultSuffix($0.defaultValue))" }
        return "(\(rendered.joined(separator: ", ")))"
    }

    private static func defaultSuffix(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        return " = \(value)"
    }

    private static func deprecationSuffix(_ reason: String?) -> String {
        guard let reason else { return "" }
        return reason.isEmpty ? " @deprecated" : " @deprecated(reason: \"\(reason)\")"
    }

    /// A description's first line as a GraphQL comment, or `nil` when there is none.
    private static func commentLine(_ description: String?) -> String? {
        guard let description else { return nil }
        let first = description.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return "# \(trimmed)"
    }
}
