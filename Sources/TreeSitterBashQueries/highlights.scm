[
  (string)
  (raw_string)
  (heredoc_body)
  (heredoc_start)
] @string

(command_name) @function

(variable_name) @property

[
  "case"
  "do"
  "done"
  "elif"
  "else"
  "esac"
  "export"
  "fi"
  "for"
  "function"
  "if"
  "in"
  "unset"
  "while"
  "then"
] @keyword

(comment) @comment

(function_definition name: (word) @function)

(file_descriptor) @number

[
  (command_substitution)
  (process_substitution)
  (expansion)
]@embedded

[
  "$"
  "&&"
  ">"
  ">>"
  "<"
  "|"
] @operator

(
  (command (_) @constant)
  (#match? @constant "^-")
)

(simple_expansion (variable_name) @variable)

(test_operator) @operator

[
  "=="
  "!="
  "=~"
  "="
  ";"
  ";;"
  "|&"
  "||"
  "<<"
  "<<-"
  "<<<"
  ">&"
] @operator

[
  "["
  "]"
  "[["
  "]]"
  "("
  ")"
  "{"
  "}"
] @punctuation.bracket

[
  "local"
  "declare"
  "readonly"
  "typeset"
] @keyword

[
  (ansi_c_string)
  (translated_string)
] @string

(regex) @string.regexp

(
  (command_name (word) @function.builtin)
  (#match? @function.builtin "^(alias|bg|bind|break|builtin|cd|command|compgen|complete|continue|dirs|disown|echo|enable|eval|exec|exit|fg|getopts|hash|help|history|jobs|kill|let|logout|popd|printf|pushd|pwd|read|return|set|shift|shopt|source|suspend|test|times|trap|type|ulimit|umask|unalias|unset|wait)$")
)
