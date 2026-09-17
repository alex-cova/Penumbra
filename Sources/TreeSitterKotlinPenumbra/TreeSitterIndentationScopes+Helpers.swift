import Penumbra

public extension TreeSitterIndentationScopes {
    static var kotlin: TreeSitterIndentationScopes {
        TreeSitterIndentationScopes(
            indent: [
                "class_body",
                "enum_class_body",
                "function_body",
                "control_structure_body",
                "lambda_literal",
                "when_expression",
                "value_arguments",
                "collection_literal",
            ],
            outdent: ["}", ")", "]"]
        )
    }
}
