; Methods

(method_declaration
  name: (identifier) @function.method)
(method_invocation
  name: (identifier) @function.method)
(super) @function.builtin

; Annotations

(annotation
  name: (identifier) @attribute)
(marker_annotation
  name: (identifier) @attribute)
(annotation
  name: (scoped_identifier
    name: (identifier) @attribute))
(marker_annotation
  name: (scoped_identifier
    name: (identifier) @attribute))

"@" @operator

; Types

; `var` is parsed as a type name; it is a reserved type name, so colour it like a keyword.
((type_identifier) @keyword
 (#eq? @keyword "var"))

(type_identifier) @type

(interface_declaration
  name: (identifier) @type)
(class_declaration
  name: (identifier) @type)
(enum_declaration
  name: (identifier) @type)
(record_declaration
  name: (identifier) @type)
(annotation_type_declaration
  name: (identifier) @type)

((field_access
  object: (identifier) @type)
 (#match? @type "^[A-Z]"))
((scoped_identifier
  scope: (identifier) @type)
 (#match? @type "^[A-Z]"))
((method_invocation
  object: (identifier) @type)
 (#match? @type "^[A-Z]"))
((method_reference
  . (identifier) @type)
 (#match? @type "^[A-Z]"))

(constructor_declaration
  name: (identifier) @type)

((import_declaration
  (scoped_identifier
    name: (identifier) @type))
 (#match? @type "^[A-Z]"))

[
  (boolean_type)
  (integral_type)
  (floating_point_type)
  (floating_point_type)
  (void_type)
] @type.builtin

; Declarations. These sit before the `(identifier)` fallbacks so the name wins, and they use
; the same names as the Java semantic pass so its colours land on top without a visible change.

(enum_constant
  name: (identifier) @constant)
(field_declaration
  declarator: (variable_declarator
    name: (identifier) @property))
(field_access
  field: (identifier) @property)
(formal_parameter
  name: (identifier) @variable.parameter)
(spread_parameter
  (variable_declarator
    name: (identifier) @variable.parameter))
(catch_formal_parameter
  name: (identifier) @variable.parameter)
(inferred_parameters
  (identifier) @variable.parameter)
(lambda_expression
  parameters: (identifier) @variable.parameter)

; Variables

((identifier) @constant
 (#match? @constant "^_*[A-Z][A-Z\\d_]+$"))

(identifier) @variable

(this) @variable.builtin

; Literals

[
  (hex_integer_literal)
  (decimal_integer_literal)
  (octal_integer_literal)
  (decimal_floating_point_literal)
  (hex_floating_point_literal)
] @number


(escape_sequence) @string.escape

[
  (character_literal)
  (string_literal)
] @string

[
  (true)
  (false)
  (null_literal)
] @constant.builtin

[
  (line_comment)
  (block_comment)
] @comment

; Keywords

[
  "abstract"
  "assert"
  "break"
  "case"
  "catch"
  "class"
  "continue"
  "default"
  "do"
  "else"
  "enum"
  "exports"
  "extends"
  "final"
  "finally"
  "for"
  "if"
  "implements"
  "import"
  "instanceof"
  "interface"
  "module"
  "native"
  "new"
  "non-sealed"
  "open"
  "opens"
  "package"
  "permits"
  "private"
  "protected"
  "provides"
  "public"
  "record"
  "requires"
  "return"
  "sealed"
  "static"
  "strictfp"
  "switch"
  "synchronized"
  "throw"
  "throws"
  "to"
  "transient"
  "transitive"
  "try"
  "uses"
  "volatile"
  "while"
  "with"
  "yield"
] @keyword
