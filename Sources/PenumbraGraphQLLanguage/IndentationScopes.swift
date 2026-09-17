import Penumbra

public extension TreeSitterIndentationScopes {
    static var graphQL: TreeSitterIndentationScopes {
        TreeSitterIndentationScopes(
            indent: [
                "selection_set",
                "arguments",
                "variable_definitions",
                "object_value",
                "list_value",
                "input_fields_definition",
                "enum_values_definition"
            ],
            outdent: [
                "}",
                "]"
            ])
    }
}
