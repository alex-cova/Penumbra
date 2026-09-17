; Adapted from https://github.com/tree-sitter-grammars/tree-sitter-markdown
; (tree-sitter-markdown-inline/queries/highlights.scm), remapped onto
; Penumbra's HighlightName vocabulary.

[
  (code_span)
  (link_title)
] @markup.raw

[
  (emphasis_delimiter)
  (code_span_delimiter)
] @punctuation.delimiter

(emphasis) @markup.italic

(strong_emphasis) @markup.bold

[
  (link_destination)
  (uri_autolink)
] @markup.link.url

[
  (link_label)
  (link_text)
  (image_description)
] @markup.link.label

[
  (backslash_escape)
  (hard_line_break)
] @string.escape

(image
  [
    "!"
    "["
    "]"
    "("
    ")"
  ] @punctuation.delimiter)

(inline_link
  [
    "["
    "]"
    "("
    ")"
  ] @punctuation.delimiter)

(shortcut_link
  [
    "["
    "]"
  ] @punctuation.delimiter)
