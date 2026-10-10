import Penumbra

public extension TreeSitterIndentationScopes {
    static var swift: TreeSitterIndentationScopes {
        return TreeSitterIndentationScopes(
            indent: [
                "protocol_body",
                "class_body",
                "enum_class_body",
                "computed_property",
                "computed_getter",
                "computed_setter",
                "function_body",
                "if_statement",
                "guard_statement",
                "for_statement",
                "while_statement",
                "repeat_while_statement",
                "do_statement",
                "catch_block",
                "lambda_literal",
                "array_literal",
                "dictionary_literal",
                "switch_entry",
                "willset_didset_block",
                "willset_clause",
                "didset_clause"
            ],
            outdent: [
                "else",
                "}",
                "]"
            ])
    }
}
