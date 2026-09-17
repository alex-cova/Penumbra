(boolean_scalar) @boolean
(null_scalar) @constant.builtin
(escape_sequence) @string.escape
(integer_scalar) @number
(float_scalar) @number
(comment) @comment
(anchor_name) @type
(alias_name) @type
(tag) @type
(yaml_directive) @keyword

(block_mapping_pair
  key: (flow_node [(double_quote_scalar) (single_quote_scalar)] @property))
(block_mapping_pair
  key: (flow_node (plain_scalar (string_scalar) @property)))
(block_mapping_pair
  value: (flow_node [(double_quote_scalar) (single_quote_scalar)] @string))
(block_mapping_pair
  value: (flow_node (plain_scalar (string_scalar) @string)))

(block_sequence_item (flow_node [(double_quote_scalar) (single_quote_scalar)] @string))
(block_sequence_item (flow_node (plain_scalar (string_scalar) @string)))

(flow_mapping
  (_ key: (flow_node [(double_quote_scalar) (single_quote_scalar)] @property)))
(flow_mapping
  (_ key: (flow_node (plain_scalar (string_scalar) @property))))

[
 ","
 "-"
 ":"
 ">"
 "?"
 "|"
] @punctuation.delimiter

[
 "["
 "]"
 "{"
 "}"
] @punctuation.bracket

[
 "*"
 "&"
 "---"
 "..."
] @punctuation.special
