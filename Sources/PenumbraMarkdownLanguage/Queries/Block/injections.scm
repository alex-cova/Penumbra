; Adapted from https://github.com/tree-sitter-grammars/tree-sitter-markdown
; (queries/injections.scm).
;
; Fenced code blocks are highlighted using the language named in their info
; string, e.g. "```swift". Resolving that name to a `TreeSitterLanguage`
; requires a `TreeSitterLanguageProvider` supplied by the app; Penumbra
; itself doesn't ship every language.
(fenced_code_block
  (info_string
    (language) @injection.language)
  (code_fence_content) @injection.content)

((html_block) @injection.content
  (#set! injection.language "html"))

(document
  .
  (section
    .
    (thematic_break)
    (_) @injection.content
    (thematic_break))
  (#set! injection.language "yaml"))

((minus_metadata) @injection.content
  (#set! injection.language "yaml"))

((plus_metadata) @injection.content
  (#set! injection.language "toml"))

; Inline content (headings, paragraphs, list items, etc.) is parsed with the
; separate markdown_inline grammar to resolve emphasis, links, code spans,
; and similar inline constructs. `MarkdownLanguageProvider` resolves this
; injection out of the box.
((inline) @injection.content
  (#set! injection.language "markdown_inline"))
