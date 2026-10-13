; Methods
(method) @function.method

; Headers
(header
  name: (_) @constant)

; Variables
(variable_declaration
  name: (identifier) @variable)

; Operators
(comment
  "=" @operator)
(variable_declaration
  "=" @operator)

; keywords
(comment
  "@" @keyword
  name: (_) @keyword)

; Literals
; injections.scm highlights a body the grammar stored in the URL. This capture
; would paint a lone `}` as a string, and that name wins over punctuation.
(request
  url: (_) @string.special.url
  (#not-match? @string.special.url "^\\s*(\\{\\s*\\S|\\[\\s*(\"|[0-9tfn\\[{]|-|])|[}\\]\\s]+)"))

(http_version) @constant

; Response
(status_code) @number
(status_text) @string

; Punctuation
[
  "{{"
  "}}"
] @punctuation.bracket

(header
  ":" @punctuation.delimiter)

; external JSON body
(external_body
  path: (_) @string.special.path)

; `###@scheme:<url>` names the GraphQL schema that completion reads. The grammar makes
; everything after `###` one value; Umbra's semantic tokens split the keyword from the URL.
(request_separator
  value: (_) @keyword
  (#match? @keyword "^\\s*@scheme\\s*:"))

; Comments
[
  (comment)
  (request_separator)
] @comment @spell
