import Penumbra

public extension TreeSitterIndentationScopes {
    static var javaScript: TreeSitterIndentationScopes {
        TreeSitterIndentationScopes(
            indent: [
                "array",
                "object",
                "arguments",
                "statement_block",
                "class_body",
                "parenthesized_expression",
                "jsx_element",
                "jsx_opening_element",
                "jsx_expression",
                "switch_body"
            ],
            outdent: [
                "else",
                "}",
                "]"
            ]
        )
    }

    static var json: TreeSitterIndentationScopes {
        TreeSitterIndentationScopes(indent: ["object", "array"], outdent: ["}", "]"])
    }

    static var python: TreeSitterIndentationScopes {
        TreeSitterIndentationScopes(
            indent: [
                "function_definition",
                "for_statement",
                "class_definition",
                "elif_clause",
                "else_clause",
                "except_clause",
                "while_statement",
                "if_statement",
                "try_statement"
            ],
            whitespaceDenotesBlocks: true
        )
    }

    static var yaml: TreeSitterIndentationScopes {
        TreeSitterIndentationScopes(indent: ["block_mapping_pair"], whitespaceDenotesBlocks: true)
    }

    static var html: TreeSitterIndentationScopes {
        TreeSitterIndentationScopes(indent: ["start_tag", "element"], outdent: ["end_tag"])
    }

    static var css: TreeSitterIndentationScopes {
        TreeSitterIndentationScopes(indent: ["block"], outdent: ["}"])
    }
}
