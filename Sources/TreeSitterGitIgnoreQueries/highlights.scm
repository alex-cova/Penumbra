; Written for Penumbra: the grammar (shunsambongi/tree-sitter-gitignore, MIT) ships no query.
(comment) @comment

(negation) @operator

[
  (directory_separator)
  (directory_separator_escaped)
] @punctuation.delimiter

[
  (wildcard_char_single)
  (wildcard_chars)
  (wildcard_chars_allow_slash)
] @operator

(pattern_char_escaped) @string.special

(bracket_expr
  "[" @punctuation.bracket
  "]" @punctuation.bracket)

(bracket_negation) @operator

[
  (bracket_char)
  (bracket_char_escaped)
] @string.special

(bracket_range) @string.special

(bracket_char_class) @constant.builtin

(pattern_char) @string
