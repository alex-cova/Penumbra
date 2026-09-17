import Foundation

public extension LanguageConfiguration {
    /// Built-in configuration for a bundled ``LanguageIdentifier`` string, or `nil` if there is no
    /// dedicated table (callers fall back to ``generic``).
    static func builtIn(forIdentifier identifier: String) -> LanguageConfiguration? {
        switch identifier {
        case "javascript", "jsx":
            return .javaScript
        case "typescript", "tsx":
            return .typeScript
        case "java":
            return .java
        case "swift":
            return .swift
        default:
            return nil
        }
    }

    /// JavaScript / JSX. Node type names follow tree-sitter-javascript.
    ///
    /// Only *named* function forms are included: `function_expression` / `arrow_function` are
    /// almost always anonymous callbacks, and a separator or breadcrumb on every one is noise.
    static let javaScript = LanguageConfiguration(declarations: [
        DeclarationRule(
            nodeTypes: [
                "function_declaration", "generator_function_declaration", "method_definition"
            ],
            kind: .function,
            isMethodSeparatorAnchor: true
        ),
        DeclarationRule(nodeTypes: ["class_declaration"], kind: .type, isMethodSeparatorAnchor: true)
    ])

    /// TypeScript / TSX — the JavaScript table plus TypeScript-only declarations.
    static let typeScript = LanguageConfiguration(declarations: [
        DeclarationRule(
            nodeTypes: [
                "function_declaration", "generator_function_declaration",
                "method_definition", "method_signature", "abstract_method_signature"
            ],
            kind: .function,
            isMethodSeparatorAnchor: true
        ),
        DeclarationRule(
            nodeTypes: [
                "class_declaration", "abstract_class_declaration", "class",
                "interface_declaration", "type_alias_declaration", "enum_declaration"
            ],
            kind: .type,
            isMethodSeparatorAnchor: true
        ),
        DeclarationRule(
            nodeTypes: ["internal_module", "module", "namespace"],
            kind: .namespace,
            nameNodeTypes: ["identifier", "nested_identifier", "string"]
        ),
        DeclarationRule(
            nodeTypes: ["public_field_definition"],
            kind: .property,
            isBreadcrumbSegment: false
        )
    ])

    /// Java. Node type names follow tree-sitter-java. Data-only until a host registers the grammar.
    static let java = LanguageConfiguration(declarations: [
        DeclarationRule(
            nodeTypes: ["method_declaration", "constructor_declaration", "compact_constructor_declaration"],
            kind: .function,
            isMethodSeparatorAnchor: true
        ),
        DeclarationRule(
            nodeTypes: [
                "class_declaration", "interface_declaration", "enum_declaration",
                "record_declaration", "annotation_type_declaration"
            ],
            kind: .type,
            isMethodSeparatorAnchor: true
        ),
        DeclarationRule(
            nodeTypes: ["package_declaration"],
            kind: .namespace,
            nameNodeTypes: ["scoped_identifier", "identifier"],
            isBreadcrumbSegment: false
        ),
        DeclarationRule(
            nodeTypes: ["field_declaration"],
            kind: .property,
            nameNodeTypes: ["variable_declarator", "identifier"],
            isBreadcrumbSegment: false
        )
    ])

    /// Swift. Node type names follow tree-sitter-swift. Data-only until a host registers the grammar.
    static let swift = LanguageConfiguration(declarations: [
        DeclarationRule(
            nodeTypes: [
                "function_declaration", "init_declaration", "deinit_declaration",
                "subscript_declaration"
            ],
            kind: .function,
            nameNodeTypes: ["simple_identifier", "identifier"],
            isMethodSeparatorAnchor: true
        ),
        DeclarationRule(
            nodeTypes: [
                "class_declaration", "protocol_declaration", "typealias_declaration",
                "enum_declaration", "struct_declaration", "actor_declaration"
            ],
            kind: .type,
            nameNodeTypes: ["type_identifier", "simple_identifier", "identifier"],
            isMethodSeparatorAnchor: true
        ),
        DeclarationRule(
            nodeTypes: ["property_declaration"],
            kind: .property,
            nameNodeTypes: ["pattern", "simple_identifier"],
            isBreadcrumbSegment: false
        ),
        DeclarationRule(
            nodeTypes: ["protocol_function_declaration", "protocol_property_declaration"],
            kind: .function,
            nameNodeTypes: ["simple_identifier"]
        )
    ])

    /// Substring-matched fallback for languages without a dedicated table (Python, GraphQL,
    /// Markdown, …). Mirrors the heuristic already used by `TreeSitterLineFoldProvider.isFoldable`.
    static let generic = LanguageConfiguration(declarations: [
        DeclarationRule(
            nodeTypes: ["function", "method", "constructor", "subroutine"],
            kind: .function,
            isMethodSeparatorAnchor: true,
            matchesBySubstring: true
        ),
        DeclarationRule(
            nodeTypes: ["class", "struct", "enum", "interface", "protocol", "trait", "record"],
            kind: .type,
            isMethodSeparatorAnchor: true,
            matchesBySubstring: true
        ),
        DeclarationRule(
            nodeTypes: ["namespace", "module", "package"],
            kind: .namespace,
            isBreadcrumbSegment: false,
            matchesBySubstring: true
        )
    ])
}
