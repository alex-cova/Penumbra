; Adapted from https://github.com/tree-sitter-grammars/tree-sitter-markdown
; (tree-sitter-markdown-inline/queries/injections.scm).
((html_tag) @injection.content
  (#set! injection.language "html"))

((latex_block) @injection.content
  (#set! injection.language "latex"))
