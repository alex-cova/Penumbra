; Keys before the string fallback so a key wins when both captures cover the same range.
(pair
  key: (string) @property)

(string) @string

(number) @number

[
  (true)
  (false)
] @boolean

(null) @constant.builtin

(escape_sequence) @string.escape

[
  "["
  "]"
  "{"
  "}"
] @punctuation.bracket

[
  ","
  ":"
] @punctuation.delimiter

"\"" @punctuation.delimiter
