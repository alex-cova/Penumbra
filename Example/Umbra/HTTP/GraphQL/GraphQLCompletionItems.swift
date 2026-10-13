import EditorIntelligence
import Foundation

/// Completion items for a `GraphQLCompletionSite`, drawn from the schema.
enum GraphQLCompletionItems {
    static func items(
        for site: GraphQLCompletionSite,
        schema: GraphQLSchema,
        range: EditorIntelligence.TextRange,
        source: String
    ) -> [CompletionItem] {
        let make = Maker(range: range, source: source)
        switch site {
        case .operationKeyword:
            var keywords = ["query"]
            if schema.mutationType != nil { keywords.append("mutation") }
            if schema.subscriptionType != nil { keywords.append("subscription") }
            keywords.append("fragment")
            return keywords.map { make.item($0, insert: $0 + " ", kind: .keyword) }

        case .selection(let typeName, _):
            var items = schema.fields(of: typeName).map { field in
                let hasRequiredArguments = field.arguments.contains { $0.isRequired }
                let insert = hasRequiredArguments ? field.name + "()" : field.name
                return make.item(
                    field.name,
                    insert: insert,
                    kind: schema.types[field.type.name]?.kind == .object || schema.types[field.type.name]?.kind == .interface
                        ? .field : .property,
                    detail: field.type.display,
                    labelDetail: argumentSummary(field.arguments),
                    documentation: documentation(field.description, deprecation: field.deprecationReason),
                    isDeprecated: field.isDeprecated,
                    priority: field.isDeprecated ? -1 : 0,
                    caretOffset: hasRequiredArguments ? (field.name as NSString).length + 1 : nil
                )
            }
            items.append(make.item("__typename", insert: "__typename", kind: .property, detail: "String!", priority: -2))
            return items

        case .spread(let parentType):
            var items = [make.item("on", insert: "on ", kind: .keyword, detail: "inline fragment", priority: 1)]
            // A union has no fields of its own, so `__typename` is the only one it allows.
            if schema.types[parentType]?.kind == .union {
                items.append(make.item("__typename", insert: "__typename", kind: .property, detail: "String!"))
            }
            return items

        case .argumentName(let owner, let used):
            return argumentItems(owner: owner, used: used, schema: schema, make: make)

        case .value(let typeName, let variables):
            var items: [CompletionItem] = []
            if let typeName, let type = schema.types[typeName] {
                switch type.kind {
                case .enumeration:
                    items += type.enumValues.map {
                        make.item(
                            $0.name, insert: $0.name, kind: .enumMember, detail: type.name,
                            documentation: documentation($0.description, deprecation: $0.deprecationReason),
                            isDeprecated: $0.deprecationReason != nil
                        )
                    }
                case .scalar where type.name == "Boolean":
                    items += ["true", "false"].map { make.item($0, insert: $0, kind: .keyword, detail: "Boolean") }
                default:
                    break
                }
            }
            items += variables.map { make.item("$" + $0, insert: "$" + $0, kind: .variable) }
            items.append(make.item("null", insert: "null", kind: .keyword, priority: -1))
            return items

        case .objectField(let typeName, let used):
            return (schema.types[typeName]?.inputFields ?? [])
                .filter { !used.contains($0.name) }
                .map { inputItem($0, make: make) }

        case .typeCondition(let parent):
            let names: [String]
            if let parent {
                names = schema.typeConditions(for: parent)
            } else {
                names = schema.types.values
                    .filter { [.object, .interface, .union].contains($0.kind) && !$0.name.hasPrefix("__") }
                    .map(\.name)
                    .sorted()
            }
            return names.map { typeItem($0, schema: schema, make: make) }

        case .variableType:
            return schema.inputTypeNames.map { typeItem($0, schema: schema, make: make) }

        case .directive:
            return schema.directives.map { directive in
                make.item(
                    directive.name,
                    insert: directive.name,
                    kind: .annotation,
                    detail: directive.locations.isEmpty ? nil : directive.locations.joined(separator: " | ").lowercased(),
                    labelDetail: argumentSummary(directive.arguments),
                    documentation: directive.description
                )
            }
        }
    }

    // MARK: - Pieces

    private static func argumentItems(
        owner: GraphQLCompletionSite.ArgumentOwner,
        used: Set<String>,
        schema: GraphQLSchema,
        make: Maker
    ) -> [CompletionItem] {
        let arguments: [GraphQLArgument]
        switch owner {
        case .field(let parent, let name):
            arguments = schema.fields(of: parent).first { $0.name == name }?.arguments ?? []
        case .directive(let name):
            arguments = schema.directives.first { $0.name == name }?.arguments ?? []
        }
        return arguments.filter { !used.contains($0.name) }.map { inputItem($0, make: make) }
    }

    private static func inputItem(_ argument: GraphQLArgument, make: Maker) -> CompletionItem {
        var text = argument.description ?? ""
        if let defaultValue = argument.defaultValue {
            text += (text.isEmpty ? "" : "\n\n") + "Default: `\(defaultValue)`"
        }
        return make.item(
            argument.name,
            insert: argument.name + ": ",
            kind: .property,
            detail: argument.type.display,
            documentation: text.isEmpty ? nil : text,
            priority: argument.isRequired ? 1 : 0
        )
    }

    private static func typeItem(_ name: String, schema: GraphQLSchema, make: Maker) -> CompletionItem {
        let type = schema.types[name]
        let kind: CompletionItemKind
        switch type?.kind {
        case .interface: kind = .interface
        case .enumeration: kind = .enum
        case .object, .inputObject: kind = .class
        default: kind = .type
        }
        return make.item(name, insert: name, kind: kind, detail: type?.kind.display, documentation: type?.description)
    }

    /// `(id: ID!, first: Int)`, or nil with no arguments.
    private static func argumentSummary(_ arguments: [GraphQLArgument]) -> String? {
        guard !arguments.isEmpty else { return nil }
        return "(" + arguments.map { "\($0.name): \($0.type.display)" }.joined(separator: ", ") + ")"
    }

    private static func documentation(_ description: String?, deprecation: String?) -> String? {
        guard let deprecation else { return description }
        let note = deprecation.isEmpty ? "Deprecated." : "Deprecated: \(deprecation)"
        return [description, note].compactMap { $0 }.joined(separator: "\n\n")
    }

    private struct Maker {
        let range: EditorIntelligence.TextRange
        let source: String

        func item(
            _ label: String,
            insert: String,
            kind: CompletionItemKind,
            detail: String? = nil,
            labelDetail: String? = nil,
            documentation: String? = nil,
            isDeprecated: Bool = false,
            priority: Double = 0,
            caretOffset: Int? = nil
        ) -> CompletionItem {
            CompletionItem(
                label: label,
                insertText: insert,
                kind: kind,
                range: range,
                source: source,
                documentation: documentation,
                filterText: label,
                detail: detail,
                labelDetail: labelDetail,
                isDeprecated: isDeprecated,
                priority: priority,
                caretOffset: caretOffset
            )
        }
    }
}

private extension GraphQLTypeKind {
    var display: String {
        switch self {
        case .scalar: "scalar"
        case .object: "type"
        case .interface: "interface"
        case .union: "union"
        case .enumeration: "enum"
        case .inputObject: "input"
        }
    }
}
