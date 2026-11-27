# Rendering specification

Inline hints are virtual advances in the existing Core Text line. Core Graphics and Metal use the same line-local coordinates. A semantic chip and ghost completion at one anchor occupy adjacent space, with the caret between them. The source storage and editing ranges stay in UTF-16 document coordinates. Code Vision uses the existing row-top insets and viewport overlay.
