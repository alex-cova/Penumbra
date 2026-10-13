; Comments
((comment) @injection.content
 (#set! injection.language "comment"))

; A JSON object's first value is a quote. A selection set starts with a name
; or a spread. The grammar still calls both json_body (`{ me { id } }`).
; Patterns are ICU regular expressions (Foundation), so a character class has
; to be one Foundation accepts.
((json_body) @injection.content
 (#match? @injection.content "^\\{\\s*(\\.\\.\\.|[_A-Za-z])")
 (#set! injection.language "graphql"))

((json_body) @injection.content
 (#not-match? @injection.content "^\\{\\s*(\\.\\.\\.|[_A-Za-z])")
 (#set! injection.language "json"))

((xml_body) @injection.content
 (#set! injection.language "xml"))

((graphql_data) @injection.content
 (#set! injection.language "graphql"))

; One-line bodies miss the grammar's whitespace requirement and stay raw_body.
((raw_body) @injection.content
 (#match? @injection.content "^\\s*\\{\\s*(\\.\\.\\.|[_A-Za-z])")
 (#set! injection.language "graphql"))

((raw_body) @injection.content
 (#match? @injection.content "^\\s*(\\{\\s*(\"|\\})|\\[\\s*(\"|[0-9tfn\\[{]|-|]))")
 (#set! injection.language "json"))

((raw_body) @injection.content
 (#match? @injection.content "^\\s*(query|mutation|subscription)\\b")
 (#set! injection.language "graphql"))

; A one-line body with no newline after it is a second request's URL, and so
; is the closing brace of a body that ends the file. A real URL does not start
; with `{` or `[`.
((target_url) @injection.content
 (#match? @injection.content "^\\s*\\{\\s*(\\.\\.\\.|[_A-Za-z])")
 (#set! injection.language "graphql"))

((target_url) @injection.content
 (#match? @injection.content "^\\s*(\\{\\s*(\"|\\})|\\[\\s*(\"|[0-9tfn\\[{]|-|]))")
 (#set! injection.language "json"))

((target_url) @injection.content
 (#match? @injection.content "^\\s*[}\\]\\s]+$")
 (#set! injection.language "json"))

; Without a blank line after it, a one-line selection is an error plus a
; stray closing brace, not a body. Highlight the error as the language it
; still starts with.
((ERROR) @injection.content
 (#match? @injection.content "\\{\\s*(\\.\\.\\.|[_A-Za-z])")
 (#set! injection.language "graphql"))

((ERROR) @injection.content
 (#match? @injection.content "(\\{\\s*(\"|\\})|\\[\\s*(\"|[0-9tfn\\[{]|-|]))")
 (#set! injection.language "json"))

; Script (default to javascript)
((comment
  name: (_) @_name
  (#eq? @_name "lang")
  value: (_) @injection.language)?
 .
 (_
  (script) @injection.content
  (#offset! @injection.content 0 2 0 -2))
 (#set! injection.language "javascript"))
