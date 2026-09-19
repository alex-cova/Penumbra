; Adapted from https://github.com/tree-sitter-grammars/tree-sitter-markdown
; (queries/highlights.scm), remapped onto Penumbra's HighlightName vocabulary.
;
; Captures from this layer and every injected layer are sorted by (location asc, length DESC)
; and applied in order, later winning. A whole-node capture is therefore a base layer that
; narrower captures (and the injected markdown_inline layer) paint over.

; --- Headings ---------------------------------------------------------------------
; The whole heading node is captured so a theme that scales `markup.heading.N` grows the `#`
; markers along with the text. `markup.heading.N` peels to `markup.heading` for themes that
; don't distinguish levels.
(atx_heading (atx_h1_marker)) @markup.heading.1
(atx_heading (atx_h2_marker)) @markup.heading.2
(atx_heading (atx_h3_marker)) @markup.heading.3
(atx_heading (atx_h4_marker)) @markup.heading.4
(atx_heading (atx_h5_marker)) @markup.heading.5
(atx_heading (atx_h6_marker)) @markup.heading.6

(setext_heading
  (paragraph) @markup.heading.1
  (setext_h1_underline))

(setext_heading
  (paragraph) @markup.heading.2
  (setext_h2_underline))

[
  (atx_h1_marker)
  (atx_h2_marker)
  (atx_h3_marker)
  (atx_h4_marker)
  (atx_h5_marker)
  (atx_h6_marker)
  (setext_h1_underline)
  (setext_h2_underline)
] @punctuation.special

; --- Code -------------------------------------------------------------------------
; `(fenced_code_block)` is deliberately not captured: as the longest, earliest capture it would
; paint every token the injected grammar doesn't capture (identifiers, whitespace) in the raw
; colour. The fence body belongs to the injected language.
[
  (link_title)
  (indented_code_block)
] @markup.raw

(fenced_code_block_delimiter) @punctuation.delimiter

(info_string
  (language) @type)

; --- Links ------------------------------------------------------------------------
; Also covers `(link_reference_definition)`, whose children are exactly these nodes.
(link_destination) @markup.link.url

(link_label) @markup.link.label

; --- Lists ------------------------------------------------------------------------
[
  (list_marker_plus)
  (list_marker_minus)
  (list_marker_star)
  (list_marker_dot)
  (list_marker_parenthesis)
] @markup.list

(task_list_marker_checked) @markup.list.checked

(task_list_marker_unchecked) @markup.list.unchecked

(thematic_break) @punctuation.special

; --- Tables (GFM) -----------------------------------------------------------------
(pipe_table_header) @markup.table.header

(pipe_table_delimiter_row) @punctuation.special

"|" @punctuation.delimiter

; --- Block quotes -----------------------------------------------------------------
(block_quote) @markup.quote

[
  (block_continuation)
  (block_quote_marker)
] @markup.quote

; --- Escapes ----------------------------------------------------------------------
[
  (backslash_escape)
  (entity_reference)
  (numeric_character_reference)
] @string.escape
